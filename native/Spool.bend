import Base
import ./Host.bend as Host
import ./SpoolCore.bend as Core
import ./JobsCore.bend as Jobs

# `read`: raw bytes of one stream from a byte offset, with an optional long poll.
# Every failure is returned, never fatal, so `serve` can read in process. Policy
# (which bytes, loss, UTF-8 hold-back, the record) lives in SpoolCore.

def Error() -> Type:
  U32 & String

def Bytes() -> Type:
  File & Result<&1, &1, Error, List<&2, U32>>

def Headed() -> Type:
  File & Result<&1, &1, Error, Core.Head>

type Seen is Data:
  Seen{start: Nat, omitted: Nat, bytes: List<&2, U32>, ended: Bool}

def Looked() -> Type:
  File & Result<&1, &1, Error, Seen>

# ---------------------------------------------------------------------------
# Rolling spools.

def headed(pair: Bytes) -> Headed:
  (file, result) = pair
  match result:
    case Fail{e}:
      (file, Fail{e})
    case Done{+bytes}:
      (file, Done{Core.head(bytes)})

def head(file: File) -> IO(Headed):
  do IO<Headed>:
    pair : Bytes <- File.read_at(file, 0, Core.head_size())
    return headed(pair)

def joined(pair: Bytes, first: List<&2, U32>) -> Bytes:
  (file, result) = pair
  match result:
    case Fail{e}:
      (file, Fail{e})
    case Done{bytes}:
      (file, Done{List.append(&2, U32, first, bytes)})

def wrapped(pair: Bytes, rest: List<&2, Core.Slice>) -> IO(Bytes):
  (file, result) = pair
  match result rest:
    case Fail{e} _:
      IO.pure(Bytes, (file, Fail{e}))
    case Done{bytes} Nil{}:
      IO.pure(Bytes, (file, Done{bytes}))
    case Done{bytes} Con{Core.Slice{at, length}, more}:
      do IO<Bytes>:
        second : Bytes <- File.read_at(file, at, length)
        return joined(second, bytes)

# The bytes of a span, in one read or two when they wrap around the ring.
def sliced(file: File, parts: List<&2, Core.Slice>) -> IO(Bytes):
  match parts:
    case Nil{}:
      IO.pure(Bytes, (file, Done{Nil{}}))
    case Con{Core.Slice{at, length}, rest}:
      do IO<Bytes>:
        first : Bytes <- File.read_at(file, at, length)
        wrapped(first, rest)

def ring_bytes(file: File, +start: Nat, +length: Nat) -> IO(Bytes):
  match length:
    case 0n:
      IO.pure(Bytes, (file, Done{Nil{}}))
    case other:
      sliced(file, Core.slices(start, other))

# The writer may have wrapped over the start of what was read: the header read
# afterwards says how much, and those bytes are disclosed as omitted instead.
def rolling_checked(pair: Headed, +span: Core.Span, +bytes: List<&2, U32>) -> Looked:
  (file, result) = pair
  match result:
    case Fail{e}:
      (file, Fail{e})
    case Done{+h}:
      +start = Core.span_start(span)
      +length = List.length(&2, U32, bytes)
      +count = Core.head_count(h)
      +lost = Core.overwritten(start, length, count)
      +next = Nat.add(start, length)
      look : Seen = Seen{
        Nat.add(start, lost),
        Nat.add(Core.span_omitted(span), lost),
        List.drop(&2, U32, bytes, lost),
        Core.ended(Core.head_closed(h), next, count),
      }
      (file, Done{look})

def rolling_read(pair: Bytes, +span: Core.Span) -> IO(Looked):
  (file, result) = pair
  match result:
    case Fail{e}:
      IO.pure(Looked, (file, Fail{e}))
    case Done{bytes}:
      do IO<Looked>:
        after : Headed <- head(file)
        return rolling_checked(after, span, bytes)

def rolling_first(pair: Headed, +offset: Nat, +max: Nat) -> IO(Looked):
  (file, result) = pair
  match result:
    case Fail{e}:
      IO.pure(Looked, (file, Fail{e}))
    case Done{h}:
      +count = Core.head_count(h)
      +span = Core.span(Core.oldest(count), count, offset, max)
      do IO<Looked>:
        read : Bytes <- ring_bytes(file, Core.span_start(span), Core.span_length(span))
        rolling_read(read, span)

def rolling_look(file: File, +offset: Nat, +max: Nat) -> IO(Looked):
  do IO<Looked>:
    first : Headed <- head(file)
    rolling_first(first, offset, max)

# ---------------------------------------------------------------------------
# Batch spools: the first 1 MiB, as plain bytes.

def plain_read(pair: Bytes, +start: Nat, ended: Bool) -> Looked:
  (file, result) = pair
  match result:
    case Fail{e}:
      (file, Fail{e})
    case Done{bytes}:
      (file, Done{Seen{start, 0n, bytes, ended}})

def ring_bytes_plain(file: File, +start: Nat, +length: Nat) -> IO(Bytes):
  match length:
    case 0n:
      IO.pure(Bytes, (file, Done{Nil{}}))
    case other:
      File.read_at(file, U32.from_nat(start), U32.from_nat(other))

def plain_sized(pair: File & Result<&1, &1, Error, U32>, +offset: Nat, +max: Nat, finished: Bool) -> IO(Looked):
  (file, result) = pair
  match result:
    case Fail{e}:
      IO.pure(Looked, (file, Fail{e}))
    case Done{size}:
      +count = Nat.min(U32.to_nat(size), Core.ring())
      +span = Core.span(0n, count, offset, max)
      +start = Core.span_start(span)
      +length = Core.span_length(span)
      +ended = Core.ended(finished, Nat.add(start, length), count)
      do IO<Looked>:
        read : Bytes <- ring_bytes_plain(file, start, length)
        return plain_read(read, start, ended)

def plain_look(file: File, +offset: Nat, +max: Nat, finished: Bool) -> IO(Looked):
  do IO<Looked>:
    sized : File & Result<&1, &1, Error, U32> <- File.size(file)
    plain_sized(sized, offset, max, finished)

# ---------------------------------------------------------------------------
# The job's state, read without writing anything: a dead worker without a
# receipt reads as failed, as `status` would report it.

type Status is Data:
  Status{state: String, terminal: Bool}

def Stated() -> Type:
  Result<&1, &1, Error, Status>

def probed(alive: Result<&1, &1, Error, String>) -> Stated:
  match alive:
    case Fail{e}:
      Fail{e}
    case Done{text}:
      Bool.pick(Stated, String.eq(text, "1"), Done{Status{"running", False{}}}, Done{Status{"failed", True{}}})

def announced(+id: String, ready: Result<&1, &1, Error, String>) -> IO(Stated):
  match ready:
    case Fail{e}:
      IO.pure(Stated, Fail{e})
    case Done{SNil{}}:
      IO.pure(Stated, Done{Status{"starting", False{}}})
    case Done{other}:
      do IO<Stated>:
        alive : Result<&1, &1, Error, String> <- Host.probe(id)
        return probed(alive)

def receipted(+id: String, receipt: Result<&1, &1, Error, String>) -> IO(Stated):
  match receipt:
    case Fail{e}:
      IO.pure(Stated, Fail{e})
    case Done{SNil{}}:
      do IO<Stated>:
        ready : Result<&1, &1, Error, String> <- Host.attempt(id, "ready", 16)
        announced(id, ready)
    case Done{text}:
      IO.pure(Stated, Done{Status{Jobs.receipt_state(text), True{}}})

def status(+id: String) -> IO(Stated):
  do IO<Stated>:
    receipt : Result<&1, &1, Error, String> <- Host.attempt(id, "receipt.json", 1048576)
    receipted(id, receipt)

def terminal(stated: Stated) -> Bool:
  match stated:
    case Fail{e}:
      False{}
    case Done{Status{state, done}}:
      done

# ---------------------------------------------------------------------------
# The long poll.

type Poll is Type:
  Polling{file: File}
  Answered{file: File, look: Seen}
  Failed{file: File, error: Error}

def iteration(file: File, rolling: Bool, +id: String, +offset: Nat, +max: Nat) -> IO(Looked):
  match rolling:
    case True{}:
      rolling_look(file, offset, max)
    case False{}:
      do IO<Looked>:
        stated : Stated <- status(id)
        plain_look(file, offset, max, terminal(stated))

def chosen(file: File, look: Seen, answer: Bool) -> Poll:
  match answer:
    case True{}:
      Answered{file, look}
    case False{}:
      Polling{file}

def decided(pair: Looked, +elapsed: Nat, +wait: Nat) -> Poll:
  (file, result) = pair
  match result:
    case Fail{e}:
      Failed{file, e}
    case Done{Seen{start, omitted, +bytes, +ended}}:
      +kept = Core.kept(bytes, ended)
      +answer = Core.answer_now(Nat.is_ge(elapsed, wait), Bool.not(List.is_empty(&2, U32, kept)), ended)
      chosen(file, Seen{start, omitted, kept, ended}, answer)

def poll(
  fuel: Nat,
  state: Poll,
  +rolling: Bool,
  +id: String,
  +offset: Nat,
  +max: Nat,
  +started: Nat,
  +wait: Nat,
) -> IO(Poll):
  match fuel state:
    case _ Answered{file, look}:
      IO.pure(Poll, Answered{file, look})
    case _ Failed{file, error}:
      IO.pure(Poll, Failed{file, error})
    case 0n Polling{file}:
      do IO<Poll>:
        pair : Looked <- iteration(file, rolling, id, offset, max)
        return decided(pair, wait, wait)
    case 1n+rest Polling{file}:
      do IO<Poll>:
        before : Nat <- IO.now()
        IO.sleep(Core.interval(Nat.sub(before, started)))
        pair : Looked <- iteration(file, rolling, id, offset, max)
        now : Nat <- IO.now()
        next : Poll = decided(pair, Nat.sub(now, started), wait)
        poll(rest, next, rolling, id, offset, max, started, wait)

def recorded(stated: Stated, look: Seen, +public: String, +stream: String, encoded: Bool) -> Result<&1, &1, Error, String>:
  match stated look:
    case Fail{e} _:
      Fail{e}
    case Done{Status{state, done}} Seen{start, omitted, +bytes, ended}:
      +eof = ended || (done && List.is_empty(&2, U32, bytes))
      Done{Core.record(Core.Read{public, stream, start, omitted, bytes, eof, state}, encoded)}

def finish(result: Poll, +id: String, +public: String, +stream: String, encoded: Bool) -> IO(Result<&1, &1, Error, String>):
  match result:
    case Answered{file, look}:
      do IO<Result<&1, &1, Error, String>>:
        File.close(file)
        stated : Stated <- status(id)
        return recorded(stated, look, public, stream, encoded)
    case Failed{file, error}:
      do IO<Result<&1, &1, Error, String>>:
        File.close(file)
        return Fail{error}
    case Polling{file}:
      do IO<Result<&1, &1, Error, String>>:
        File.close(file)
        return Fail{(1, "read ended without an answer")}

def read_open(
  opened: Result<&1, &1, Error, File & Bool>,
  +id: String,
  +public: String,
  +stream: String,
  +offset: Nat,
  +max: Nat,
  +wait: Nat,
  encoded: Bool,
) -> IO(Result<&1, &1, Error, String>):
  match opened:
    case Fail{e}:
      IO.pure(Result<&1, &1, Error, String>, Fail{e})
    case Done{pair}:
      (file, +rolling) = pair
      do IO<Result<&1, &1, Error, String>>:
        +started : Nat <- IO.now()
        first : Looked <- iteration(file, rolling, id, offset, max)
        state : Poll = decided(first, 0n, wait)
        result : Poll <- poll(Nat.add(wait, 2n), state, rolling, id, offset, max, started, wait)
        finish(result, id, public, stream, encoded)

def plain_opened(result: Result<&1, &1, Error, File>) -> Result<&1, &1, Error, File & Bool>:
  match result:
    case Fail{e}:
      Fail{(22, "job has no output to read yet")}
    case Done{file}:
      Done{(file, False{})}

# A rolling spool (`<stream>.ring`) if the job has one, else the batch spool.
def ring_opened(+id: String, +stream: String, result: Result<&1, &1, Error, File>) -> IO(Result<&1, &1, Error, File & Bool>):
  match result:
    case Done{file}:
      IO.pure(Result<&1, &1, Error, File & Bool>, Done{(file, True{})})
    case Fail{e}:
      do IO<Result<&1, &1, Error, File & Bool>>:
        plain : Result<&1, &1, Error, File> <- Host.open(id, stream ++ ".bin")
        return plain_opened(plain)

def open_stream(+id: String, +stream: String) -> IO(Result<&1, &1, Error, File & Bool>):
  do IO<Result<&1, &1, Error, File & Bool>>:
    ring : Result<&1, &1, Error, File> <- Host.open(id, stream ++ ".ring")
    ring_opened(id, stream, ring)

def read_meta(
  meta: Result<&1, &1, Error, String>,
  +id: String,
  +stream: String,
  +offset: Nat,
  +max: Nat,
  +wait: Nat,
  encoded: Bool,
) -> IO(Result<&1, &1, Error, String>):
  match meta:
    case Fail{e}:
      IO.pure(Result<&1, &1, Error, String>, Fail{e})
    case Done{+text}:
      do IO<Result<&1, &1, Error, String>>:
        opened : Result<&1, &1, Error, File & Bool> <- open_stream(id, stream)
        read_open(opened, id, Jobs.public_id(id, text), stream, offset, max, wait, encoded)

def read_checked(
  checked: Host.Checked,
  +id: String,
  +stream: String,
  +offset: Nat,
  +max: Nat,
  +wait: Nat,
  encoded: Bool,
) -> IO(Result<&1, &1, Error, String>):
  match checked:
    case Fail{e}:
      IO.pure(Result<&1, &1, Error, String>, Fail{e})
    case Done{ok}:
      do IO<Result<&1, &1, Error, String>>:
        meta : Result<&1, &1, Error, String> <- Host.attempt(id, "meta.json", Jobs.meta_limit())
        read_meta(meta, id, stream, offset, max, wait, encoded)

# Up to `max` bytes of `stream` ("stdout" or "stderr") of the job in directory
# `id`, from `offset`; with `wait` > 0, a long poll of up to that many ms.
def read(
  +id: String,
  +stream: String,
  +offset: Nat,
  +max: Nat,
  +wait: Nat,
  encoded: Bool,
) -> IO(Result<&1, &1, Error, String>):
  do IO<Result<&1, &1, Error, String>>:
    checked : Host.Checked <- Host.store_attempt(False{})
    read_checked(checked, id, stream, offset, max, wait, encoded)

# ---------------------------------------------------------------------------
# Writes to an interactive job (`start --input pipe`): queued for its worker.

def enqueued(result: Result<&1, &1, Error, String>, +id: String, +bytes: Nat, close: Bool) -> Result<&1, &1, Error, String>:
  match result close:
    case Fail{(32, message)} True{}:
      Done{Jobs.write_json(id, 0n, True{})}
    case Fail{(32, message)} False{}:
      Fail{(1, "job input is closed")}
    case Fail{(28, message)} _:
      Fail{(1, "job input queue is full: 1 MiB is waiting for the child to read it")}
    case Fail{e} _:
      Fail{e}
    case Done{pending} True{}:
      Done{Jobs.write_json(id, 0n, True{})}
    case Done{pending} False{}:
      Done{Jobs.write_json(id, bytes, False{})}

def queue_stated(stated: Stated, +dir: String, +id: String, +text: String, +close: Bool) -> IO(Result<&1, &1, Error, String>):
  match stated close:
    case Fail{e} _:
      IO.pure(Result<&1, &1, Error, String>, Fail{e})
    case Done{Status{state, True{}}} True{}:
      IO.pure(Result<&1, &1, Error, String>, Done{Jobs.write_json(id, 0n, True{})})
    case Done{Status{state, True{}}} False{}:
      IO.pure(Result<&1, &1, Error, String>, Fail{(1, "job has finished")})
    case Done{Status{state, False{}}} closing:
      +bytes = Jobs.utf8_bytes(text)
      do IO<Result<&1, &1, Error, String>>:
        result : Result<&1, &1, Error, String> <- Host.enqueue(dir, text, closing, Jobs.queue_max())
        return enqueued(result, id, bytes, closing)

def queue_kind(+info: String, +dir: String, text: String, close: Bool, interactive: Bool) -> IO(Result<&1, &1, Error, String>):
  match interactive:
    case False{}:
      IO.pure(Result<&1, &1, Error, String>, Fail{(22, "job was not started with --input pipe")})
    case True{}:
      do IO<Result<&1, &1, Error, String>>:
        stated : Stated <- status(dir)
        queue_stated(stated, dir, Jobs.public_id(dir, info), text, close)

def queue_meta(meta: Result<&1, &1, Error, String>, +dir: String, text: String, close: Bool) -> IO(Result<&1, &1, Error, String>):
  match meta:
    case Fail{e}:
      IO.pure(Result<&1, &1, Error, String>, Fail{e})
    case Done{+info}:
      queue_kind(info, dir, text, close, Jobs.meta_interactive(info))

def queue_checked(checked: Host.Checked, +dir: String, text: String, close: Bool) -> IO(Result<&1, &1, Error, String>):
  match checked:
    case Fail{e}:
      IO.pure(Result<&1, &1, Error, String>, Fail{e})
    case Done{ok}:
      do IO<Result<&1, &1, Error, String>>:
        meta : Result<&1, &1, Error, String> <- Host.attempt(dir, "meta.json", Jobs.meta_limit())
        queue_meta(meta, dir, text, close)

# Appends `text` to an interactive job's input, or with `close` ends its input
# (idempotent). A write record, or the failure; nothing is ever fatal.
def queue_write(+dir: String, text: String, close: Bool) -> IO(Result<&1, &1, Error, String>):
  do IO<Result<&1, &1, Error, String>>:
    checked : Host.Checked <- Host.store_attempt(True{})
    queue_checked(checked, dir, text, close)
