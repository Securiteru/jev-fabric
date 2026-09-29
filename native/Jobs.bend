import Base
import ./Host.bend as Host
import ./Process.bend as Process
import ./Json.bend as Json
import ./Streams.bend as Streams
import ./Time.bend as Time
import ./Cli.bend as Cli
import ./JobsCore.bend as Core
import ./SpoolCore.bend as SpoolCore
import ./Spool.bend as Spool
import ./Codec.bend as Codec

# Acceptance ledger: native self-spawn and detached lease; private bounded store;
# running/terminal/wait/stop idempotency; literal argv; live bounded replay; UTF-8
# boundaries; timeout and owned-group cleanup; no JS runtime. See jobs.test.ts.
# Policy bounds: 1024 stored jobs/root, 64 events/job, 2048 bytes/read,
# 1 MiB first-byte spool/stream, Process's final 32 KiB tail/stream, 24h deadline.
# Interactive jobs and session children keep a rolling spool of the latest 1 MiB
# per stream instead (SpoolCore). A session child's worker is owned by a `serve`
# connection and stops its child when that owner exits.
# Labels, `list` and `follow` policy live in JobsCore; this module runs it.
# Observations coalesce to the latest 2048 currently available bytes/stream/tick;
# omittedBytes discloses skips, sequence gaps disclose replay eviction, and
# process.spool_limit discloses reaching the first-byte cap (possibly clipped).
# No protocol-line monitor/filter API or semantic task-completion claims.

# First-byte spool cap per stream; also the largest private file Host reads.
def spool_limit() -> U32:
  1048576

# Bytes observed per stream per tick.
def window() -> U32:
  2048

# Size bound for the "stop" and "ready" marker files.
def marker_limit() -> U32:
  16

def max_jobs() -> U32:
  1024

type Ring is Data:
  Ring{next: U32, newest: List<&2, String>}

# Keeps the 64 newest events, newest first.
def event(ring: Ring, kind: String, data: String) -> Ring:
  match ring:
    case Ring{+next, newest}:
      line : String = "{\"sequence\":" ++ U32.show(next)
        ++ ",\"type\":" ++ Json.quote(kind)
        ++ ",\"data\":" ++ data
        ++ "}"
      Ring{U32.inc(next), Con{line, List.take(&2, String, newest, 63n)}}

def lines(items: List<&2, String>) -> String:
  match items:
    case Nil{}:
      ""
    case Con{line, rest}:
      line ++ "\n" ++ lines(rest)

def save(id: String, ring: Ring) -> IO(Unit):
  match ring:
    case Ring{next, newest}:
      Host.write(id, "events.jsonl", lines(List.reverse(&2, String, newest)))

def output(
  ring: Ring,
  stream: String,
  +offset: Nat,
  +count: Nat,
  +omitted: Nat,
  text: String,
  changed: Bool,
) -> Ring:
  match changed:
    case False{}:
      ring
    case True{}:
      event(
        ring,
        "process.output",
        "{\"stream\":" ++ Json.quote(stream)
          ++ ",\"offset\":" ++ Nat.show(offset)
          ++ ",\"bytes\":" ++ Nat.show(count)
          ++ ",\"omittedBytes\":" ++ Nat.show(omitted)
          ++ ",\"text\":" ++ Json.quote(text)
          ++ "}",
      )

def with_id(id: String, +meta: String, receipt: String) -> String:
  Core.with_id(id, meta, receipt)

def failed(id: String, +meta: String, message: String) -> String:
  Core.failed(id, meta, message)

def running(id: String, +meta: String) -> String:
  Core.running(id, meta)

# The metadata recorded by `start` (or a session spawn): start time, label, lifetime.
def meta_of(id: String) -> IO(String):
  Host.read(id, "meta.json", Core.meta_limit())

def failure_result(id: String, +meta: String, stopped: String) -> String:
  match stopped:
    case SNil{}:
      failed(id, meta, "command launch failed")
    case SCon{head, tail}:
      report : Process.Report = Process.Report{143, False{}, True{}, False{}, False{}, "", ""}
      with_id(id, meta, Process.show(report))

def record_result(+id: String, +meta: String, result: Result<&1, &1, U32 & String, Process.Raw>) -> IO(Unit):
  match result:
    case Done{raw}:
      Host.write(id, "result.json", with_id(id, meta, Process.show(Process.decode(raw))))
    case Fail{error}:
      do IO<Unit>:
        stopped : String <- Host.read(id, "stop", marker_limit())
        Host.write(id, "result.json", failure_result(id, meta, stopped))

def execute(
  +id: String,
  +meta: String,
  argv: List<String>,
  timeout: U32,
  out: File,
  err: File,
  cwd: String,
) -> IO(Unit):
  do IO<Unit>:
    result : Result<&1, &1, U32 & String, Process.Raw> <- Process.Native.exec_logged(
      argv,
      timeout,
      out,
      err,
      cwd,
    )
    record_result(id, meta, result)

# An interactive child: stdin is the given pipe reader, and both streams roll.
def execute_pipe(
  +id: String,
  +meta: String,
  argv: List<String>,
  input: File,
  timeout: U32,
  out: File,
  err: File,
  cwd: String,
) -> IO(Unit):
  do IO<Unit>:
    result : Result<&1, &1, U32 & String, Process.Raw> <- Process.Native.exec_pipe(
      argv,
      input,
      timeout,
      out,
      err,
      True{},
      cwd,
    )
    record_result(id, meta, result)

# Base file effects hand the File back beside their result.
def Sized() -> Type:
  File & Result<&1, &1, U32 & String, U32>

def Bytes() -> Type:
  File & Result<&1, &1, U32 & String, List<&2, U32>>

type Cursor is Type:
  Cursor{file: File, offset: Nat, decoder: Streams.Decoder, rolling: Bool}

type Chunk is Type:
  Chunk{cursor: Cursor, text: String, count: Nat, offset: Nat, omitted: Nat}

def reset(decoder: Streams.Decoder, skipped: Bool) -> Streams.Decoder:
  match skipped:
    case True{}:
      Streams.empty()
    case False{}:
      decoder

def chunk_decoded(
  file: File,
  +start: Nat,
  +count: Nat,
  omitted: Nat,
  rolling: Bool,
  decoded: Streams.Decoder & String,
) -> Chunk:
  (decoder, text) = decoded
  Chunk{Cursor{file, Nat.add(start, count), decoder, rolling}, text, count, start, omitted}

def chunk_of(file: File, +start: Nat, +omitted: Nat, decoder: Streams.Decoder, +bytes: List<&2, U32>, rolling: Bool) -> Chunk:
  +count = List.length(&2, U32, bytes)
  +fresh = reset(decoder, Bool.not(Nat.is_eq(omitted, 0n)))
  chunk_decoded(file, start, count, omitted, rolling, Streams.take(Streams.feed(bytes, fresh)))

def window_nat() -> Nat:
  2048n

def plain_bytes(pair: Bytes, +start: Nat, +omitted: Nat, decoder: Streams.Decoder) -> IO(Chunk):
  (file, result) = pair
  do IO<Chunk>:
    +bytes : List<&2, U32> <- IO.pass(List<&2, U32>, result)
    return chunk_of(file, start, omitted, decoder, bytes, False{})

# Read the newest window of the (capped) spool, never re-reading before `previous`.
def plain_sized(+previous: Nat, decoder: Streams.Decoder, pair: Sized) -> IO(Chunk):
  (file, result) = pair
  do IO<Chunk>:
    +size : U32 <- IO.pass(U32, result)
    +bounded : Nat = Nat.min(U32.to_nat(size), SpoolCore.ring())
    +start : Nat = Nat.max(SpoolCore.minus(bounded, window_nat()), previous)
    read : Bytes <- File.read_at(file, U32.from_nat(start), window())
    plain_bytes(read, start, SpoolCore.minus(start, previous), decoder)

# A rolling spool: the newest window of what the header says was written, less
# anything the writer wrapped over while it was read (disclosed as omitted).
def ring_checked(pair: Spool.Headed, +start: Nat, +omitted: Nat, +bytes: List<&2, U32>, decoder: Streams.Decoder) -> IO(Chunk):
  (file, result) = pair
  do IO<Chunk>:
    +after : SpoolCore.Head <- IO.pass(SpoolCore.Head, result)
    +lost : Nat = SpoolCore.overwritten(start, List.length(&2, U32, bytes), SpoolCore.head_count(after))
    return chunk_of(file, Nat.add(start, lost), Nat.add(omitted, lost), decoder, List.drop(&2, U32, bytes, lost), True{})

def ring_read(pair: Bytes, +start: Nat, +omitted: Nat, decoder: Streams.Decoder) -> IO(Chunk):
  (file, result) = pair
  do IO<Chunk>:
    +bytes : List<&2, U32> <- IO.pass(List<&2, U32>, result)
    after : Spool.Headed <- Spool.head(file)
    ring_checked(after, start, omitted, bytes, decoder)

def ring_headed(+previous: Nat, decoder: Streams.Decoder, pair: Spool.Headed) -> IO(Chunk):
  (file, result) = pair
  do IO<Chunk>:
    +h : SpoolCore.Head <- IO.pass(SpoolCore.Head, result)
    +count : Nat = SpoolCore.head_count(h)
    +start : Nat = Nat.max(SpoolCore.minus(count, window_nat()), previous)
    read : Bytes <- Spool.ring_bytes(file, start, SpoolCore.minus(count, start))
    ring_read(read, start, SpoolCore.minus(start, previous), decoder)

def read(cursor: Cursor) -> IO(Chunk):
  match cursor:
    case Cursor{file, offset, decoder, True{}}:
      do IO<Chunk>:
        pair : Spool.Headed <- Spool.head(file)
        ring_headed(offset, decoder, pair)
    case Cursor{file, offset, decoder, False{}}:
      do IO<Chunk>:
        pair : Sized <- File.size(file)
        plain_sized(offset, decoder, pair)

def limit_reached(ring: Ring, stream: String, reached: Bool) -> Ring:
  match reached:
    case False{}:
      ring
    case True{}:
      event(
        ring,
        "process.spool_limit",
        "{\"stream\":" ++ Json.quote(stream)
          ++ ",\"limitBytes\":1048576,\"mayBeTruncated\":true}",
      )

def cursor_rolling(cursor: Cursor) -> Cursor & Bool:
  match cursor:
    case Cursor{file, offset, decoder, +rolling}:
      (Cursor{file, offset, decoder, rolling}, rolling)

def observed_cursor(ring: Ring, +stream: String, pair: Cursor & Bool, text: String, +count: Nat, +offset: Nat, omitted: Nat) -> Cursor & (Ring & Nat):
  (cursor, rolling) = pair
  +read_any : Bool = Bool.not(Nat.is_eq(count, 0n))
  ring = output(ring, stream, offset, count, omitted, text, read_any)
  # Only a first-byte spool has a cap; a rolling one discloses loss as omitted bytes.
  reached : Bool = read_any && Bool.not(rolling) && Nat.is_ge(Nat.add(offset, count), SpoolCore.ring())
  (cursor, (limit_reached(ring, stream, reached), count))

def observed(ring: Ring, +stream: String, chunk: Chunk) -> Cursor & (Ring & Nat):
  match chunk:
    case Chunk{cursor, text, count, offset, omitted}:
      observed_cursor(ring, stream, cursor_rolling(cursor), text, count, offset, omitted)

def observe(cursor: Cursor, ring: Ring, stream: String) -> IO(Cursor & (Ring & Nat)):
  do IO<Cursor & (Ring & Nat)>:
    chunk : Chunk <- read(cursor)
    return observed(ring, stream, chunk)

def close(cursor: Cursor, ring: Ring, stream: String) -> IO(Ring):
  match cursor:
    case Cursor{file, offset, decoder, rolling}:
      do IO<Ring>:
        File.close(file)
        +text : String = Streams.finish(decoder)
        return output(ring, stream, offset, 0n, 0n, text, Bool.not(String.eq(text, "")))

def cancel(stopped: String) -> IO(Unit):
  match stopped:
    case SNil{}:
      IO.pure(Unit, Unit{})
    case SCon{head, tail}:
      Process.cancel(15)

def persist_changed(id: String, ring: Ring, changed: Bool) -> IO(Unit):
  match changed:
    case True{}:
      save(id, ring)
    case False{}:
      IO.pure(Unit, Unit{})

# Minimum ticks between event-file rewrites (100 ms). Each rewrite copies every
# retained event, so chatty jobs publish at this rate instead of every tick.
def save_interval() -> U32:
  4

# Whether the ring holds events not yet saved, and the ticks since the last save.
type Pending is Data:
  Pending{unsaved: Bool, age: U32}

# A change is saved at once when the last save is save_interval() ticks old, and
# otherwise within save_interval() - 1 further ticks. A finishing tick skips this
# save: the terminal save that follows immediately covers it.
def save_due(pending: Pending, changed: Bool, finished: Bool) -> Bool:
  match pending:
    case Pending{unsaved, age}:
      (unsaved || changed) && Bool.not(finished) && U32.is_ge(age, save_interval())

def after_tick(pending: Pending, changed: Bool, saved: Bool) -> Pending:
  match pending saved:
    case _ True{}:
      Pending{False{}, 1}
    case Pending{unsaved, age} False{}:
      Pending{unsaved || changed, U32.min(U32.inc(age), save_interval())}

def pause(terminal: Bool) -> IO(Unit):
  match terminal:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.sleep(25)

def terminal(+id: String, +receipt: String, out: Cursor, err: Cursor, ring: Ring) -> IO(Unit):
  do IO<Unit>:
    ring : Ring <- close(out, ring, "stdout")
    ring : Ring <- close(err, ring, "stderr")
    # Publish terminal last: once visible, the event snapshot is final too.
    save(id, event(ring, "job.finished", "{\"receiptAvailable\":true}"))
    Host.write(id, "receipt.json", receipt)

type Turn is Type:
  Again{out: Cursor, err: Cursor, ring: Ring, pending: Pending}
  End{out: Cursor, err: Cursor, ring: Ring, receipt: String}

def turn(
  out: Cursor,
  err: Cursor,
  ring: Ring,
  pending: Pending,
  receipt: String,
  done: Bool,
) -> Turn:
  match done:
    case True{}:
      End{out, err, ring, receipt}
    case False{}:
      Again{out, err, ring, pending}

# Finish only on a quiet tick after the result appeared, so late output is drained.
def tick_finish(
  id: String,
  +receipt: String,
  out: Cursor,
  out_count: Nat,
  +pending: Pending,
  pair: Cursor & (Ring & Nat),
) -> IO(Turn):
  (err, payload) = pair
  (ring, err_count) = payload
  +ring = {ring : Ring}
  +done = Bool.not(String.eq(receipt, ""))
  +changed = Bool.not(Nat.is_eq(out_count, 0n)) || Bool.not(Nat.is_eq(err_count, 0n))
  +finished = done && Bool.not(changed)
  +due = save_due(pending, changed, finished)
  do IO<Turn>:
    persist_changed(id, ring, due)
    pause(done)
    return turn(out, err, ring, after_tick(pending, changed, due), receipt, finished)

def tick_err(
  id: String,
  receipt: String,
  err: Cursor,
  pending: Pending,
  pair: Cursor & (Ring & Nat),
) -> IO(Turn):
  (out, (ring, out_count)) = pair
  do IO<Turn>:
    pair : Cursor & (Ring & Nat) <- observe(err, ring, "stderr")
    tick_finish(id, receipt, out, out_count, pending, pair)

# A session child's worker watches its owner: once the process that spawned it
# has gone (it is re-parented), the child is stopped as if by `stop`.
type Owner is Data:
  Owner{watched: Bool, parent: String}

def orphaned(gone: Bool) -> IO(Unit):
  match gone:
    case True{}:
      Process.cancel(15)
    case False{}:
      IO.pure(Unit, Unit{})

def watch_owner(owner: Owner) -> IO(Unit):
  match owner:
    case Owner{False{}, parent}:
      IO.pure(Unit, Unit{})
    case Owner{True{}, parent}:
      do IO<Unit>:
        now : String <- Host.parent()
        orphaned(Bool.not(String.eq(now, parent)))

def tick(+id: String, owner: Owner, out: Cursor, err: Cursor, ring: Ring, pending: Pending) -> IO(Turn):
  do IO<Turn>:
    stopped : String <- Host.read(id, "stop", marker_limit())
    cancel(stopped)
    watch_owner(owner)
    receipt : String <- Host.read(id, "result.json", spool_limit())
    pair : Cursor & (Ring & Nat) <- observe(out, ring, "stdout")
    tick_err(id, receipt, err, pending, pair)

def unsaved(pending: Pending) -> Bool:
  match pending:
    case Pending{unsaved, age}:
      unsaved

def control(fuel: Nat, +id: String, +owner: Owner, turn: Turn) -> IO(Unit):
  match fuel turn:
    case fuel End{out, err, ring, receipt}:
      terminal(id, receipt, out, err, ring)
    case 0n Again{out, err, +ring, pending}:
      do IO<Unit>:
        persist_changed(id, ring, unsaved(pending))
        Process.cancel(15)
        ring : Ring <- close(out, ring, "stdout")
        ring : Ring <- close(err, ring, "stderr")
        IO.die(Unit, 1, "job controller fuel exhausted")
    case 1n+rest Again{out, err, ring, pending}:
      do IO<Unit>:
        next : Turn <- tick(id, owner, out, err, ring, pending)
        control(rest, id, owner, next)

# One tick per 25 ms of the deadline, plus slack for the final drain.
def control_fuel(+timeout: U32) -> Nat:
  U32.to_nat(U32.add(U32.div(timeout, 25), 4096))

def observe_from(
  +id: String,
  owner: Owner,
  +timeout: U32,
  work: Chan(Unit),
  out_read: File,
  err_read: File,
  ring: Ring,
  +rolling: Bool,
) -> IO(Unit):
  do IO<Unit>:
    out_cursor : Cursor = Cursor{out_read, 0n, Streams.empty(), rolling}
    err_cursor : Cursor = Cursor{err_read, 0n, Streams.empty(), rolling}
    # Start as if the last save were old, so the first output is saved at once.
    control(control_fuel(timeout), id, owner, Again{out_cursor, err_cursor, ring, Pending{False{}, save_interval()}})
    IO.join(Unit, work)

def started_ring(+id: String, +meta: String) -> Ring:
  event(Ring{1, Nil{}}, "job.started", "{\"id\":" ++ Json.quote(Core.public_id(id, meta)) ++ "}")

# A batch job: stdin is /dev/null and each spool keeps its first 1 MiB.
def worker_batch(+id: String, +meta: String, argv: List<String>, +timeout: U32, cwd: String) -> IO(Unit):
  do IO<Unit>:
    out : File <- Host.spool(id, "stdout.bin", True{})
    err : File <- Host.spool(id, "stderr.bin", True{})
    out_read : File <- Host.spool(id, "stdout.bin", False{})
    err_read : File <- Host.spool(id, "stderr.bin", False{})
    +ring : Ring = started_ring(id, meta)
    save(id, ring)
    Host.write(id, "ready", "ready")
    work : Chan(Unit) <- IO.fork(Unit, execute(id, meta, argv, timeout, out, err, cwd))
    observe_from(id, Owner{False{}, ""}, timeout, work, out_read, err_read, ring, False{})

def closed_reader(pair: File & File) -> IO(File):
  (reader, writer) = pair
  do IO<File>:
    File.close(writer)
    return reader

# A session child reads the owner's pipe (this worker's stdin) directly, or
# starts with its input already ended.
def session_input(inherit: Bool) -> IO(File):
  match inherit:
    case True{}:
      IO.try(File, Process.stdin())
    case False{}:
      do IO<File>:
        pair : File & File <- IO.try(File & File, Process.pipe())
        closed_reader(pair)

def worker_session(+id: String, +meta: String, argv: List<String>, +timeout: U32, cwd: String, inherit: Bool) -> IO(Unit):
  do IO<Unit>:
    out : File <- Host.spool(id, "stdout.ring", True{})
    err : File <- Host.spool(id, "stderr.ring", True{})
    out_read : File <- Host.spool(id, "stdout.ring", False{})
    err_read : File <- Host.spool(id, "stderr.ring", False{})
    input : File <- session_input(inherit)
    parent : String <- Host.parent()
    +ring : Ring = started_ring(id, meta)
    save(id, ring)
    Host.write(id, "ready", "ready")
    work : Chan(Unit) <- IO.fork(Unit, execute_pipe(id, meta, argv, input, timeout, out, err, cwd))
    observe_from(id, Owner{True{}, parent}, timeout, work, out_read, err_read, ring, True{})

# Ends a job's input for writers: once its child is gone, a write is an error.
def seal_input(+id: String) -> IO(Unit):
  do IO<Unit>:
    sealed : Result<&1, &1, U32 & String, String> <- Host.enqueue(id, "", True{}, Core.queue_max())
    return Unit{}

def fed(pair: File & Result<&1, &1, U32 & String, Unit>, +id: String, closed: Bool) -> IO(Maybe<&1, File>):
  (file, result) = pair
  match result closed:
    case Fail{e} _:
      do IO<Maybe<&1, File>>:
        File.close(file)
        seal_input(id)
        return None{}
    case Done{ok} True{}:
      do IO<Maybe<&1, File>>:
        File.close(file)
        return None{}
    case Done{ok} False{}:
      IO.pure(Maybe<&1, File>, Some{file})

def feed_queue(file: File, +id: String, queue: Core.Queue) -> IO(Maybe<&1, File>):
  match queue:
    case Core.Queue{text, closed}:
      do IO<Maybe<&1, File>>:
        pair : File & Result<&1, &1, U32 & String, Unit> <- File.write(file, text)
        fed(pair, id, closed)

def feed_taken(file: File, +id: String, taken: Result<&1, &1, U32 & String, String>) -> IO(Maybe<&1, File>):
  match taken:
    case Fail{e}:
      IO.pure(Maybe<&1, File>, Some{file})
    case Done{answer}:
      feed_queue(file, id, Core.taken(answer))

# Hands the queued bytes to the child in arrival order, and ends the child's
# input once `close-input` has been drained. After the child has exited, input
# is sealed and whatever is still queued is discarded.
def feed_tick(file: File, +id: String, running: Bool) -> IO(Maybe<&1, File>):
  match running:
    case False{}:
      do IO<Maybe<&1, File>>:
        File.close(file)
        seal_input(id)
        return None{}
    case True{}:
      do IO<Maybe<&1, File>>:
        taken : Result<&1, &1, U32 & String, String> <- Host.dequeue(id, Core.queue_max())
        feed_taken(file, id, taken)

# Drains the input queue every tick (25 ms), in its own fiber: a child that is
# not reading blocks only this fiber, never the observations.
def feeder(fuel: Nat, +id: String, input: Maybe<&1, File>) -> IO(Unit):
  match fuel input:
    case _ None{}:
      IO.pure(Unit, Unit{})
    case 0n Some{file}:
      File.close(file)
    case 1n+rest Some{file}:
      do IO<Unit>:
        result : String <- Host.read(id, "result.json", spool_limit())
        next : Maybe<&1, File> <- feed_tick(file, id, String.is_empty(result))
        IO.sleep(25)
        feeder(rest, id, next)

def worker_piped(
  +id: String,
  +meta: String,
  argv: List<String>,
  +timeout: U32,
  cwd: String,
  out: File,
  err: File,
  out_read: File,
  err_read: File,
  pair: File & File,
) -> IO(Unit):
  (reader, writer) = pair
  do IO<Unit>:
    +ring : Ring = started_ring(id, meta)
    save(id, ring)
    Host.write(id, "ready", "ready")
    work : Chan(Unit) <- IO.fork(Unit, execute_pipe(id, meta, argv, reader, timeout, out, err, cwd))
    feed : Chan(Unit) <- IO.fork(Unit, feeder(control_fuel(timeout), id, Some{writer}))
    observe_from(id, Owner{False{}, ""}, timeout, work, out_read, err_read, ring, True{})
    IO.join(Unit, feed)

# An interactive job (`start --input pipe`): stdin is a pipe fed from the job's
# private input queue, and both streams roll.
def worker_pipe(+id: String, +meta: String, argv: List<String>, +timeout: U32, cwd: String) -> IO(Unit):
  do IO<Unit>:
    out : File <- Host.spool(id, "stdout.ring", True{})
    err : File <- Host.spool(id, "stderr.ring", True{})
    out_read : File <- Host.spool(id, "stdout.ring", False{})
    err_read : File <- Host.spool(id, "stderr.ring", False{})
    pair : File & File <- IO.try(File & File, Process.pipe())
    worker_piped(id, meta, argv, timeout, cwd, out, err, out_read, err_read, pair)

def worker_mode(+id: String, +meta: String, mode: String, argv: List<String>, +timeout: U32, cwd: String) -> IO(Unit):
  match mode:
    case "batch":
      worker_batch(id, meta, argv, timeout, cwd)
    case "pipe":
      worker_pipe(id, meta, argv, timeout, cwd)
    case "session":
      worker_session(id, meta, argv, timeout, cwd, True{})
    case "session-null":
      worker_session(id, meta, argv, timeout, cwd, False{})
    case other:
      IO.die(Unit, 2, "unknown job worker mode")

def worker_fresh(
  +id: String,
  +meta: String,
  mode: String,
  argv: List<String>,
  +timeout: U32,
  cwd: String,
  fresh: Bool,
) -> IO(Unit):
  match fresh:
    case True{}:
      worker_mode(id, meta, mode, argv, timeout, cwd)
    case False{}:
      IO.die(Unit, 1, "job already started or terminal")

def worker(+id: String, mode: String, cwd: String, argv: List<String>, +timeout: U32) -> IO(Unit):
  do IO<Unit>:
    Host.claim(id)
    ready : String <- Host.read(id, "ready", marker_limit())
    receipt : String <- Host.read(id, "receipt.json", spool_limit())
    +meta : String <- meta_of(id)
    worker_fresh(id, meta, mode, argv, timeout, cwd, String.eq(ready, "") && String.eq(receipt, ""))

# Lease probing never sends a signal. Re-read after a dead lease to avoid
# overwriting a receipt published between the first read and the probe.
def recover(+id: String, receipt: String) -> IO(String):
  match receipt:
    case SNil{}:
      do IO<String>:
        +meta : String <- meta_of(id)
        +receipt : String = failed(id, meta, "worker exited without a terminal receipt")
        Host.write(id, "receipt.json", receipt)
        return receipt
    case SCon{head, tail}:
      IO.pure(String, SCon{head, tail})

def liveness(+id: String, alive: Bool) -> IO(String):
  match alive:
    case True{}:
      IO.pure(String, "")
    case False{}:
      do IO<String>:
        receipt : String <- Host.read(id, "receipt.json", spool_limit())
        recover(id, receipt)

def receipt(+id: String, current: String) -> IO(String):
  match current:
    case SNil{}:
      do IO<String>:
        alive : Bool <- Host.alive(id)
        liveness(id, alive)
    case SCon{head, tail}:
      IO.pure(String, SCon{head, tail})

# The terminal receipt, or "" while the worker still holds its lease.
def status_read(+id: String) -> IO(String):
  do IO<String>:
    current : String <- Host.read(id, "receipt.json", spool_limit())
    receipt(id, current)

# Like status_read, but a job whose worker has not written "ready" is reported
# running without a lease probe: probing could race the worker's claim of a
# job that another process is still starting.
def announced(+id: String, ready: String) -> IO(String):
  match ready:
    case SNil{}:
      IO.pure(String, "")
    case SCon{head, tail}:
      receipt(id, "")

def settled_current(+id: String, current: String) -> IO(String):
  match current:
    case SNil{}:
      do IO<String>:
        ready : String <- Host.read(id, "ready", marker_limit())
        announced(id, ready)
    case SCon{head, tail}:
      IO.pure(String, SCon{head, tail})

def settled_read(+id: String) -> IO(String):
  do IO<String>:
    current : String <- Host.read(id, "receipt.json", spool_limit())
    settled_current(id, current)

def show_running(+id: String) -> IO(Unit):
  do IO<Unit>:
    +meta : String <- meta_of(id)
    IO.print(running(id, meta))

def show_status(+id: String, text: String) -> IO(Unit):
  match text:
    case SNil{}:
      show_running(id)
    case SCon{head, tail}:
      IO.print(SCon{head, tail})

def wait_loop(fuel: Nat, +id: String, text: String) -> IO(Unit):
  match fuel text:
    case fuel SCon{head, tail}:
      IO.print(SCon{head, tail})
    case 0n SNil{}:
      show_running(id)
    case 1n+rest SNil{}:
      do IO<Unit>:
        IO.sleep(25)
        text : String <- status_read(id)
        wait_loop(rest, id, text)

def wait(fuel: Nat, +id: String) -> IO(Unit):
  do IO<Unit>:
    text : String <- status_read(id)
    wait_loop(fuel, id, text)

def stop_current(+id: String, text: String) -> IO(Unit):
  match text:
    case SNil{}:
      do IO<Unit>:
        Host.write(id, "stop", "stop")
        wait(80n, id)
    case SCon{head, tail}:
      IO.print(SCon{head, tail})

def ready(fuel: Nat, +id: String, text: String) -> IO(Unit):
  match fuel text:
    case fuel SCon{head, tail}:
      IO.print("{\"id\":" ++ Json.quote(id) ++ "}")
    case 0n SNil{}:
      do IO<Unit>:
        Host.write(id, "stop", "stop")
        IO.die(Unit, 1, "native job did not become ready")
    case 1n+rest SNil{}:
      do IO<Unit>:
        IO.sleep(25)
        text : String <- Host.read(id, "ready", marker_limit())
        ready(rest, id, text)

def spawned(+id: String, +meta: String, result: Result<&1, &1, U32 & String, String>) -> IO(Unit):
  match result:
    case Fail{error}:
      do IO<Unit>:
        Host.write(id, "receipt.json", failed(id, meta, "worker launch failed"))
        IO.die(Unit, 1, "native worker launch failed")
    case Done{ignored}:
      ready(200n, id, "")

# This same executable, re-entered through the private __job-worker command:
# `__job-worker <id> <ms> <mode> <cwd> <command...>`, cwd "" to inherit.
def worker_argv(self: String, id: String, +timeout: U32, mode: String, cwd: String, argv: List<String>) -> List<String>:
  Con{self, Con{"--", Con{"__job-worker", Con{id, Con{U32.show(timeout), Con{mode, Con{cwd, argv}}}}}}}

# meta.json (start time, label, lifetime) is written before the worker exists, so
# every reader of this job, including the worker, sees it.
def start(argv: List<String>, +timeout: U32, +label: String, +cwd: String, +mode: String) -> IO(Unit):
  do IO<Unit>:
    self : String <- Host.self()
    +id : String <- Host.create(max_jobs())
    now : String <- Host.clock()
    +meta : String = Core.meta(label, now, "durable", String.eq(mode, "pipe"))
    Host.write(id, "meta.json", meta)
    result : Result<&1, &1, U32 & String, String> <- Host.spawn(
      worker_argv(self, id, timeout, mode, cwd, argv),
    )
    spawned(id, meta, result)

def replay_keep(line: String, keep: Bool) -> IO(Unit):
  match keep:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      IO.print(line)

def replay_line(line: String, after: U32, sequence: Maybe<&2, U32>) -> IO(Unit):
  match sequence:
    case None{}:
      IO.pure(Unit, Unit{})
    case Some{number}:
      replay_keep(line, U32.is_gt(number, after))

def replay(items: List<&2, String>, +after: U32) -> IO(Unit):
  match items:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{+line, rest}:
      do IO<Unit>:
        replay_line(line, after, Core.sequence(line))
        replay(rest, after)

def events(id: String, after: U32) -> IO(Unit):
  do IO<Unit>:
    text : String <- Host.read(id, "events.jsonl", spool_limit())
    replay(String.split(text, '\n'), after)

def cursor(after: Maybe<&2, U32>) -> IO(U32):
  match after:
    case None{}:
      IO.die(U32, 2, "after-sequence must be a U32")
    case Some{number}:
      IO.pure(U32, number)

def event_after(id: String, after: Maybe<&2, U32>) -> IO(Unit):
  do IO<Unit>:
    +number : U32 <- cursor(after)
    events(id, number)

# Whether `events --timeout-ms` may answer now: an event past the cursor, or a
# terminal receipt (read first, so the final replay is already in the file).
def events_ready(+id: String, +after: U32) -> IO(Bool):
  do IO<Bool>:
    receipt : String <- settled_read(id)
    text : String <- Host.read(id, "events.jsonl", spool_limit())
    return Bool.not(String.is_empty(receipt)) || Core.pending(String.split(text, '\n'), after)

def events_loop(fuel: Nat, +id: String, +after: U32, ready: Bool) -> IO(Unit):
  match fuel ready:
    case _ True{}:
      events(id, after)
    case 0n False{}:
      events(id, after)
    case 1n+rest False{}:
      do IO<Unit>:
        IO.sleep(25)
        found : Bool <- events_ready(id, after)
        events_loop(rest, id, after, found)

# A long poll: the snapshot once it holds an event past the cursor, the job is
# terminal, or the ceiling passes (then possibly empty). It never cancels a job.
def events_wait(+id: String, +after: U32, ms: U32) -> IO(Unit):
  do IO<Unit>:
    found : Bool <- events_ready(id, after)
    # Polls every 25 ms: ceil(ms / 25) further snapshots.
    events_loop(U32.to_nat(U32.div(U32.add(ms, 24), 25)), id, after, found)

def print_all(lines: List<&2, String>) -> IO(Unit):
  match lines:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{line, rest}:
      do IO<Unit>:
        IO.print(line)
        print_all(rest)

type Follow is Data:
  Polling{cursor: U32}
  Ending{cursor: U32, reason: String, receipt: String}

def follow_next(+cursor: U32, receipt: String, decision: Core.Decision) -> Follow:
  match decision:
    case Core.Continue{}:
      Polling{cursor}
    case Core.Finished{}:
      Ending{cursor, "finished", receipt}
    case Core.Expired{}:
      Ending{cursor, "timeout", ""}

def follow_printed(followed: Core.Followed, +receipt: String, +started: Nat, +duration: Nat) -> IO(Follow):
  match followed:
    case Core.Followed{+cursor, outs}:
      do IO<Follow>:
        print_all(outs)
        now : Nat <- IO.now()
        +done : Bool = Bool.not(String.is_empty(receipt))
        return follow_next(cursor, receipt, Core.follow_decision(done, Nat.is_ge(Nat.sub(now, started), duration)))

# The receipt is read before the events: once it exists, the event snapshot
# read after it holds the final replay, so "finished" never skips events.
def follow_tick(+id: String, +started: Nat, +duration: Nat, +cursor: U32) -> IO(Follow):
  do IO<Follow>:
    receipt : String <- settled_read(id)
    text : String <- Host.read(id, "events.jsonl", spool_limit())
    follow_printed(Core.follow(String.split(text, '\n'), cursor), receipt, started, duration)

# A timeout reports the running state in place of a receipt.
def follow_end(+id: String, +cursor: U32, reason: String, receipt: String) -> IO(Unit):
  match receipt:
    case SNil{}:
      do IO<Unit>:
        +meta : String <- meta_of(id)
        IO.print(Core.end_json(reason, cursor, running(id, meta)))
    case SCon{head, tail}:
      IO.print(Core.end_json(reason, cursor, SCon{head, tail}))

def follow_loop(fuel: Nat, +id: String, +started: Nat, +duration: Nat, state: Follow) -> IO(Unit):
  match fuel state:
    case _ Ending{cursor, reason, receipt}:
      follow_end(id, cursor, reason, receipt)
    case 0n Polling{cursor}:
      follow_end(id, cursor, "timeout", "")
    case 1n+rest Polling{cursor}:
      do IO<Unit>:
        IO.sleep(25)
        next : Follow <- follow_tick(id, started, duration, cursor)
        follow_loop(rest, id, started, duration, next)

# Live JSONL: each retained event past the cursor as the worker publishes it,
# a follow.loss record before any sequence gap, then one follow.end. The ceiling
# only bounds observation; it never cancels or renews the job.
def follow(+id: String, +after: U32, ms: U32) -> IO(Unit):
  do IO<Unit>:
    +started : Nat <- IO.now()
    +duration : Nat = U32.to_nat(ms)
    first : Follow <- follow_tick(id, started, duration, after)
    follow_loop(Core.follow_fuel(duration), id, started, duration, first)

def entry_leased(+id: String, meta: String, live: Bool) -> IO(Maybe<&2, Core.Entry>):
  match live:
    case True{}:
      IO.pure(Maybe<&2, Core.Entry>, Some{Core.unsettled(id, meta, "running", "")})
    case False{}:
      do IO<Maybe<&2, Core.Entry>>:
        receipt : Result<&1, &1, U32 & String, String> <- Host.attempt(id, "receipt.json", spool_limit())
        return Core.dead(id, meta, receipt)

def entry_probed(+id: String, meta: String, alive: Result<&1, &1, U32 & String, String>) -> IO(Maybe<&2, Core.Entry>):
  match alive:
    case Fail{error}:
      IO.pure(Maybe<&2, Core.Entry>, None{})
    case Done{text}:
      entry_leased(id, meta, String.eq(text, "1"))

def entry_of(+id: String, probe: Core.Probe) -> IO(Maybe<&2, Core.Entry>):
  match probe:
    case Core.Skip{}:
      IO.pure(Maybe<&2, Core.Entry>, None{})
    case Core.Known{entry}:
      IO.pure(Maybe<&2, Core.Entry>, Some{entry})
    case Core.Lease{meta}:
      do IO<Maybe<&2, Core.Entry>>:
        alive : Result<&1, &1, U32 & String, String> <- Host.probe(id)
        entry_probed(id, meta, alive)

# Reads never end the listing: an unreadable or unsafe directory is left out.
# `sessions` selects session children (a serve connection's own) instead of jobs.
def inspect(+id: String, sessions: Bool) -> IO(Maybe<&2, Core.Entry>):
  do IO<Maybe<&2, Core.Entry>>:
    meta : Result<&1, &1, U32 & String, String> <- Host.attempt(id, "meta.json", Core.meta_limit())
    receipt : Result<&1, &1, U32 & String, String> <- Host.attempt(id, "receipt.json", spool_limit())
    ready : Result<&1, &1, U32 & String, String> <- Host.attempt(id, "ready", marker_limit())
    entry_of(id, Core.classify(id, meta, receipt, ready, sessions))

def inspect_all(ids: List<&2, String>, +sessions: Bool) -> IO(List<&2, Core.Entry>):
  match ids:
    case Nil{}:
      IO.pure(List<&2, Core.Entry>, Nil{})
    case Con{+id, rest}:
      do IO<List<&2, Core.Entry>>:
        found : Maybe<&2, Core.Entry> <- inspect(id, sessions)
        tail : List<&2, Core.Entry> <- inspect_all(rest, sessions)
        return Core.kept(found, tail)

def listed(listing: Core.Listing) -> IO(Unit):
  match listing:
    case Core.Listing{ids, truncated}:
      do IO<Unit>:
        entries : List<&2, Core.Entry> <- inspect_all(ids, False{})
        IO.print(Core.list_json(entries, truncated))

# One JSON object for the job directories under the root, within the 1024 cap.
def list() -> IO(Unit):
  do IO<Unit>:
    text : String <- Host.list(max_jobs())
    listed(Core.listing(text, U32.to_nat(max_jobs())))

def timeout_error(+max: U32) -> String:
  "timeout must be 1.." ++ U32.show(max) ++ " milliseconds"

def in_range(+ms: U32, +max: U32, ok: Bool) -> IO(U32):
  match ok:
    case True{}:
      IO.pure(U32, ms)
    case False{}:
      IO.die(U32, 2, timeout_error(max))

def within(parsed: Maybe<&2, U32>, +max: U32) -> IO(U32):
  match parsed:
    case None{}:
      IO.die(U32, 2, timeout_error(max))
    case Some{+ms}:
      in_range(ms, max, U32.is_ge(ms, 1) && U32.is_le(ms, max))

def directory_checked(result: Result<&1, &1, U32 & String, String>) -> IO(Unit):
  match result:
    case Fail{e}:
      IO.die(Unit, 2, "cwd must be an existing directory")
    case Done{ok}:
      IO.pure(Unit, Unit{})

# An empty cwd inherits this process's; any other must be an existing absolute directory.
def cwd_checked(cwd: String) -> IO(Unit):
  match cwd:
    case SNil{}:
      IO.pure(Unit, Unit{})
    case other:
      do IO<Unit>:
        found : Result<&1, &1, U32 & String, String> <- Host.directory(other)
        directory_checked(found)

def start_checked(ms: String, label: String, +cwd: String, mode: String, argv: List<String>) -> IO(Unit):
  do IO<Unit>:
    +limit : U32 <- within(U32.read(ms), Time.job_max_timeout())
    +chosen : String <- IO.pass(String, Cli.optional_label(label))
    cwd_checked(cwd)
    start(argv, limit, chosen, cwd, mode)

# ---------------------------------------------------------------------------
# `write`, `close-input` and `read`.

def printed(result: Result<&1, &1, U32 & String, String>) -> IO(Unit):
  match result:
    case Fail{e}:
      (code, message) = e
      IO.die(Unit, code, message)
    case Done{text}:
      IO.print(text)

def write_text(+id: String, text: String, close: Bool) -> IO(Unit):
  do IO<Unit>:
    result : Result<&1, &1, U32 & String, String> <- Spool.queue_write(id, text, close)
    printed(result)

def text_allowed(+id: String, text: String, ok: Bool) -> IO(Unit):
  match ok:
    case True{}:
      write_text(id, text, False{})
    case False{}:
      IO.die(Unit, 2, "write takes at most 65536 characters")

def write_checked(+id: String, +text: String) -> IO(Unit):
  text_allowed(id, text, Nat.is_le(String.length(text), 65536n))

def words(items: List<String>) -> String:
  match items:
    case Nil{}:
      ""
    case Con{word, Nil{}}:
      word
    case Con{word, rest}:
      word ++ " " ++ words(rest)

type Slurp is Type:
  Reading{file: File, bytes: List<&2, U32>}
  Slurped{file: File, bytes: List<&2, U32>}

def slurp_more(file: File, bytes: List<&2, U32>, over: Bool) -> Slurp:
  match over:
    case True{}:
      Slurped{file, bytes}
    case False{}:
      Reading{file, bytes}

# Stops once more bytes arrived than 65536 characters can take (4 each).
def slurp_step(pair: File & Result<&1, &1, U32 & String, List<&2, U32>>, +bytes: List<&2, U32>) -> Slurp:
  (file, result) = pair
  match result:
    case Fail{e}:
      Slurped{file, bytes}
    case Done{Nil{}}:
      Slurped{file, bytes}
    case Done{more}:
      +all = List.append(&2, U32, bytes, more)
      slurp_more(file, all, Nat.is_gt(List.length(&2, U32, all), 262144n))

def slurp(fuel: Nat, state: Slurp) -> IO(Slurp):
  match fuel state:
    case _ Slurped{file, bytes}:
      IO.pure(Slurp, Slurped{file, bytes})
    case 0n Reading{file, bytes}:
      IO.pure(Slurp, Slurped{file, bytes})
    case 1n+rest Reading{file, +bytes}:
      do IO<Slurp>:
        pair : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(file, 65536)
        slurp(rest, slurp_step(pair, bytes))

def slurped_text(+id: String, state: Slurp) -> IO(Unit):
  match state:
    case Slurped{file, bytes}:
      do IO<Unit>:
        File.close(file)
        +text : String <- IO.pass(String, Codec.decode_utf8(bytes))
        write_checked(id, text)
    case Reading{file, bytes}:
      do IO<Unit>:
        File.close(file)
        IO.die(Unit, 2, "write takes at most 65536 characters")

def write_stdin(+id: String) -> IO(Unit):
  do IO<Unit>:
    input : File <- IO.try(File, Process.stdin())
    state : Slurp <- slurp(4096n, Reading{input, Nil{}})
    slurped_text(id, state)

def read_planned(plan: Core.ReadPlan) -> IO(Unit):
  match plan:
    case Core.ReadPlan{id, stream, offset, max, wait, encoded}:
      do IO<Unit>:
        result : Result<&1, &1, U32 & String, String> <- Spool.read(id, stream, offset, max, wait, encoded)
        printed(result)

# Verbs that read the store check its format first; verbs that write adopt it.
def stored(mutating: Bool, action: IO(Unit)) -> IO(Unit):
  do IO<Unit>:
    Host.store(mutating)
    action

# Public dispatcher; main forwards these complete argument lists unchanged.
def command(args: List<String>) -> IO(Unit):
  match args:
    case Con{"start", Con{ms, Con{command, rest}}}:
      start_checked(ms, "", "", "batch", Con{command, rest})
    case Con{"__start", Con{ms, Con{label, Con{cwd, Con{mode, Con{command, rest}}}}}}:
      start_checked(ms, label, cwd, mode, Con{command, rest})
    case Con{"__job-worker", Con{id, Con{ms, Con{mode, Con{cwd, Con{command, rest}}}}}}:
      do IO<Unit>:
        +limit : U32 <- within(U32.read(ms), Time.job_max_timeout())
        worker(id, mode, cwd, Con{command, rest}, limit)
    case Con{"status", Con{+id, Nil{}}}:
      do IO<Unit>:
        # status may record a dead worker's receipt, so it adopts the store.
        Host.store(True{})
        text : String <- status_read(id)
        show_status(id, text)
    case Con{"wait", Con{id, Con{ms, Nil{}}}}:
      do IO<Unit>:
        +limit : U32 <- within(U32.read(ms), Time.max_timeout())
        Host.store(True{})
        # Polls every 25 ms: ceil(ms / 25) status reads.
        wait(U32.to_nat(U32.div(U32.add(limit, 24), 25)), id)
    case Con{"stop", Con{+id, Nil{}}}:
      do IO<Unit>:
        Host.store(True{})
        text : String <- status_read(id)
        stop_current(id, text)
    case Con{"events", Con{id, Nil{}}}:
      stored(False{}, events(id, 0))
    case Con{"events", Con{id, Con{after, Nil{}}}}:
      stored(False{}, event_after(id, U32.read(after)))
    case Con{"events", Con{+id, Con{after, Con{ms, Nil{}}}}}:
      do IO<Unit>:
        +limit : U32 <- within(U32.read(ms), 300000)
        +number : U32 <- cursor(U32.read(after))
        Host.store(False{})
        events_wait(id, number, limit)
    case Con{"follow", Con{ms, Con{+id, Nil{}}}}:
      do IO<Unit>:
        +limit : U32 <- within(U32.read(ms), Time.max_timeout())
        Host.store(False{})
        follow(id, 0, limit)
    case Con{"follow", Con{ms, Con{+id, Con{after, Nil{}}}}}:
      do IO<Unit>:
        +limit : U32 <- within(U32.read(ms), Time.max_timeout())
        +number : U32 <- cursor(U32.read(after))
        Host.store(False{})
        follow(id, number, limit)
    case Con{"list", Nil{}}:
      stored(False{}, list())
    case Con{"write", Con{+id, Con{"--stdin", Nil{}}}}:
      write_stdin(id)
    case Con{"write", Con{+id, Con{"--", rest}}}:
      write_checked(id, words(rest))
    case Con{"close-input", Con{+id, Nil{}}}:
      write_text(id, "", True{})
    case Con{"read", rest}:
      do IO<Unit>:
        plan : Core.ReadPlan <- IO.pass(Core.ReadPlan, Core.read_plan(rest, 0n, False{}))
        read_planned(plan)
    case other:
      IO.die(
        Unit,
        2,
        "usage: start <timeout-ms> <command> [args...] | status <id>"
          ++ " | events <id> [after-sequence] | wait <id> <wait-timeout-ms> | stop <id>"
          ++ " | follow <timeout-ms> <id> [after-sequence] | list"
          ++ " | write <id> (--stdin | -- text...) | close-input <id>"
          ++ " | read [--wait-ms N] [--base64] <id> <stdout|stderr> [offset] [max]",
      )
