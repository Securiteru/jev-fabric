import Base
import ./Codec.bend as Codec
import ./Json.bend as Json
import ./vendor/strict-json/json.bend as J

# Pure job-record policy: job metadata and labels, the `list` summary, and the
# `follow` stream over retained events. Jobs.bend performs the reads, lease
# probes, prints and sleeps; nothing here touches the filesystem or a clock.

def Error() -> Type:
  U32 & String

# Largest meta.json Host reads: an escaped 120-scalar label plus two numbers.
def meta_limit() -> U32:
  4096

# ---------------------------------------------------------------------------
# Metadata. `start` writes meta.json once, before it spawns the worker.

def label_if(label: String, empty: Bool) -> String:
  match empty:
    case True{}:
      ""
    case False{}:
      ",\"label\":" ++ Json.quote(label)

# The `"label"` member of a receipt, running state or list entry; none when empty.
def label_field(+label: String) -> String:
  label_if(label, String.is_empty(label))

def input_field(interactive: Bool) -> String:
  match interactive:
    case True{}:
      ",\"input\":\"pipe\""
    case False{}:
      ""

# `started` is the host's wall clock in epoch milliseconds, as decimal digits.
# `lifetime` is "durable" for `start` jobs and "session" for session children;
# `interactive` records a stdin kept open for `write`.
def meta(+label: String, started: String, lifetime: String, interactive: Bool) -> String:
  "{\"schemaVersion\":1,\"startedAt\":" ++ started ++ label_field(label)
    ++ ",\"lifetime\":" ++ Json.quote(lifetime)
    ++ input_field(interactive)
    ++ "}"

def document_of(parsed: Result<&1, &1, Error, J.JSON>) -> J.JSON:
  match parsed:
    case Fail{error}:
      J.Null{}
    case Done{value}:
      value

# A missing or unreadable record reads as null, so every field is absent.
def document(text: String) -> J.JSON:
  document_of(Codec.read(text))

def text_of(found: Maybe<&2, J.JSON>) -> String:
  match found:
    case Some{J.Str{s}}:
      s
    case other:
      ""

def number_of(found: Maybe<&2, J.JSON>) -> String:
  match found:
    case Some{J.Num{lex}}:
      lex
    case other:
      ""

# The job's label, or "" for none (including jobs started before labels).
def meta_label(meta: String) -> String:
  text_of(Codec.field(document(meta), "label"))

def lifetime_or_durable(text: String) -> String:
  match text:
    case "session":
      "session"
    case other:
      "durable"

# "session" for a session child, else "durable" (jobs from before 0.5 included).
def meta_lifetime(meta: String) -> String:
  lifetime_or_durable(text_of(Codec.field(document(meta), "lifetime")))

def is_session(meta: String) -> Bool:
  String.eq(meta_lifetime(meta), "session")

# Whether the job's stdin stays open for `write` (an interactive job).
def meta_interactive(meta: String) -> Bool:
  String.eq(text_of(Codec.field(document(meta), "input")), "pipe")

def public_if(id: String, session: Bool) -> String:
  match session:
    case True{}:
      "s-" ++ id
    case False{}:
      id

# The id callers use: a session child's carries an `s-` prefix before its directory.
def public_id(id: String, +meta: String) -> String:
  public_if(id, is_session(meta))

# The opening members every record of a job shares: its public id, label and lifetime.
def identity(id: String, +meta: String) -> String:
  "\"id\":" ++ Json.quote(public_id(id, meta))
    ++ label_field(meta_label(meta))
    ++ ",\"lifetime\":" ++ Json.quote(meta_lifetime(meta))

# Replaces a receipt's opening brace with the job's identity and spool limit.
def with_id(id: String, +meta: String, receipt: String) -> String:
  match receipt:
    case SCon{head, tail}:
      "{" ++ identity(id, meta) ++ ",\"spoolLimitBytes\":1048576," ++ tail
    case SNil{}:
      "{}"

def failed(id: String, +meta: String, message: String) -> String:
  with_id(
    id,
    meta,
    "{\"schemaVersion\":1,\"state\":\"failed\",\"exitCode\":null,\"error\":"
      ++ Json.quote(message)
      ++ "}",
  )

def running(id: String, +meta: String) -> String:
  "{\"schemaVersion\":1," ++ identity(id, meta)
    ++ ",\"state\":\"running\",\"spoolLimitBytes\":1048576}"

# ---------------------------------------------------------------------------
# `list`: one bounded summary of the job directories under the storage root.

type Entry is Data:
  Entry{id: String, state: String, label: String, started: String, exit: String, session: Bool}

def state_of(found: Maybe<&2, J.JSON>) -> String:
  match found:
    case Some{J.Str{s}}:
      s
    case other:
      "failed"

# The state a terminal receipt records.
def receipt_state(receipt: String) -> String:
  state_of(Codec.field(document(receipt), "state"))

def exit_of(found: Maybe<&2, J.JSON>) -> String:
  match found:
    case Some{J.Num{lex}}:
      lex
    case other:
      "null"

# A job with a terminal receipt reports that receipt's state and exit code.
def settled(id: String, +meta: String, receipt: String) -> Entry:
  +info = document(meta)
  +doc = document(receipt)
  Entry{
    public_id(id, meta),
    state_of(Codec.field(doc, "state")),
    text_of(Codec.field(info, "label")),
    number_of(Codec.field(info, "startedAt")),
    exit_of(Codec.field(doc, "exitCode")),
    is_session(meta),
  }

# A job without a receipt: `exit` is a JSON fragment, or "" to omit exitCode.
def unsettled(id: String, +meta: String, state: String, exit: String) -> Entry:
  +info = document(meta)
  Entry{
    public_id(id, meta),
    state,
    text_of(Codec.field(info, "label")),
    number_of(Codec.field(info, "startedAt")),
    exit,
    is_session(meta),
  }

# What the driver still has to do for one directory.
type Probe is Data:
  Skip{}
  Known{entry: Entry}
  Lease{meta: String}

# A worker that has not written "ready" has not yet claimed its lease, so the
# lease is never probed: a probe could race the claim of a starting job.
def announced(id: String, meta: String, empty: Bool) -> Probe:
  match empty:
    case True{}:
      Known{unsettled(id, meta, "starting", "")}
    case False{}:
      Lease{meta}

def receipted(id: String, meta: String, receipt: String, +ready: String, empty: Bool) -> Probe:
  match empty:
    case True{}:
      announced(id, meta, String.is_empty(ready))
    case False{}:
      Known{settled(id, meta, receipt)}

# A directory with no job files belongs to `run` or a library Session, not to a
# job. The store's list leaves out session children, which only their owner can
# address; an owner's list (`sessions`) holds nothing else.
def job_files(id: String, +meta: String, +receipt: String, +ready: String, foreign: Bool) -> Probe:
  match foreign:
    case True{}:
      Skip{}
    case False{}:
      receipted(id, meta, receipt, ready, String.is_empty(receipt))

# Any unreadable or unsafe job file leaves the directory out of the list.
def classify(
  +id: String,
  meta: Result<&1, &1, Error, String>,
  receipt: Result<&1, &1, Error, String>,
  ready: Result<&1, &1, Error, String>,
  sessions: Bool,
) -> Probe:
  match meta receipt ready:
    case Done{+m} Done{+r} Done{+y}:
      +empty = String.is_empty(m) && String.is_empty(r) && String.is_empty(y)
      job_files(id, m, r, y, empty || Bool.xor(is_session(m), sessions))
    case _ _ _:
      Skip{}

def dead_receipt(id: String, meta: String, receipt: String) -> Entry:
  match receipt:
    case SNil{}:
      unsettled(id, meta, "failed", "null")
    case SCon{head, tail}:
      settled(id, meta, SCon{head, tail})

# After a dead lease the receipt is read again: the worker may have published it
# between the first read and the probe. Without one, the job reports failed, as
# `status` does, but `list` never writes the recovery receipt itself.
def dead(id: String, meta: String, receipt: Result<&1, &1, Error, String>) -> Maybe<&2, Entry>:
  match receipt:
    case Fail{error}:
      None{}
    case Done{text}:
      Some{dead_receipt(id, meta, text)}

def kept(found: Maybe<&2, Entry>, rest: List<&2, Entry>) -> List<&2, Entry>:
  match found:
    case None{}:
      rest
    case Some{entry}:
      Con{entry, rest}

def present(line: String, rest: List<&2, String>, empty: Bool) -> List<&2, String>:
  match empty:
    case True{}:
      rest
    case False{}:
      Con{line, rest}

def nonempty(lines: List<&2, String>) -> List<&2, String>:
  match lines:
    case Nil{}:
      Nil{}
    case Con{+line, rest}:
      present(line, nonempty(rest), String.is_empty(line))

type Listing is Data:
  Listing{ids: List<&2, String>, truncated: Bool}

# Host lists at most max + 1 ids, so a longer list discloses truncation.
def listing(text: String, +max: Nat) -> Listing:
  +ids = nonempty(String.split(text, '\n'))
  Listing{List.take(&2, String, ids, max), Nat.is_gt(List.length(&2, String, ids), max)}

def nat_or_zero(value: Maybe<&2, Nat>) -> Nat:
  match value:
    case None{}:
      0n
    case Some{n}:
      n

def started_at(entry: Entry) -> Nat:
  match entry:
    case Entry{id, state, label, started, exit, session}:
      nat_or_zero(Nat.read(started))

# Newest first; jobs without a start time (older versions) sort last.
def newer(a: Entry, b: Entry) -> Bool:
  Nat.is_ge(started_at(a), started_at(b))

def optional(key: String, value: String, empty: Bool) -> String:
  match empty:
    case True{}:
      ""
    case False{}:
      ",\"" ++ key ++ "\":" ++ value

# A session child's entry also names its lifetime; store entries keep the 0.4 shape.
def entry_json(entry: Entry) -> String:
  match entry:
    case Entry{id, state, +label, +started, +exit, session}:
      "{\"id\":" ++ Json.quote(id)
        ++ ",\"state\":" ++ Json.quote(state)
        ++ label_field(label)
        ++ optional("lifetime", "\"session\"", Bool.not(session))
        ++ optional("startedAt", started, String.is_empty(started))
        ++ optional("exitCode", exit, String.is_empty(exit))
        ++ "}"

def rest_json(entries: List<&2, Entry>) -> String:
  match entries:
    case Nil{}:
      ""
    case Con{entry, rest}:
      "," ++ entry_json(entry) ++ rest_json(rest)

def entries_json(entries: List<&2, Entry>) -> String:
  match entries:
    case Nil{}:
      ""
    case Con{entry, rest}:
      entry_json(entry) ++ rest_json(rest)

def list_json(+entries: List<&2, Entry>, truncated: Bool) -> String:
  "{\"jobs\":[" ++ entries_json(List.sort(~Entry, ~newer, entries))
    ++ "],\"truncated\":" ++ Json.boolean(truncated)
    ++ "}"

# ---------------------------------------------------------------------------
# `follow`: retained events past a cursor, as the worker publishes them.

def first(items: List<&2, String>) -> String:
  match items:
    case Nil{}:
      ""
    case Con{head, tail}:
      head

# Each event line starts with {"sequence":N, (a 12-character prefix before N).
def sequence(line: String) -> Maybe<&2, U32>:
  U32.read(String.drop(first(String.split(line, ',')), 12n))

def newer_than(found: Maybe<&2, U32>, +after: U32) -> Bool:
  match found:
    case None{}:
      False{}
    case Some{+n}:
      U32.is_gt(n, after)

# Whether any retained event lies past the cursor.
def pending(lines: List<&2, String>, +after: U32) -> Bool:
  match lines:
    case Nil{}:
      False{}
    case Con{line, rest}:
      newer_than(sequence(line), after) || pending(rest, after)

def loss_json(+after: U32, +next: U32) -> String:
  "{\"type\":\"follow.loss\",\"after\":" ++ U32.show(after)
    ++ ",\"next\":" ++ U32.show(next)
    ++ "}"

# `receipt` is the final receipt, or the running state on a timeout.
def end_json(reason: String, +next: U32, receipt: String) -> String:
  "{\"type\":\"follow.end\",\"reason\":" ++ Json.quote(reason)
    ++ ",\"next\":" ++ U32.show(next)
    ++ ",\"receipt\":" ++ receipt
    ++ "}"

# The advanced cursor and the lines to print, in order.
type Followed is Data:
  Followed{cursor: U32, outs: List<&2, String>}

def followed_cursor(value: Followed) -> U32:
  match value:
    case Followed{cursor, outs}:
      cursor

def followed_outs(value: Followed) -> List<&2, String>:
  match value:
    case Followed{cursor, outs}:
      outs

# A sequence gap means the ring evicted events the follower never saw.
def gap(+after: U32, +next: U32, line: String, skipped: Bool) -> List<&2, String>:
  match skipped:
    case True{}:
      [loss_json(after, next), line]
    case False{}:
      [line]

# An event at or before the cursor was already printed and is never printed again.
def fresh(line: String, +cursor: U32, +next: U32, unseen: Bool) -> Followed:
  match unseen:
    case False{}:
      Followed{cursor, Nil{}}
    case True{}:
      Followed{next, gap(cursor, next, line, U32.is_gt(next, U32.add(cursor, 1)))}

def sequenced(line: String, +cursor: U32, found: Maybe<&2, U32>) -> Followed:
  match found:
    case None{}:
      Followed{cursor, Nil{}}
    case Some{+next}:
      fresh(line, cursor, next, U32.is_gt(next, cursor))

def follow_line(+line: String, +cursor: U32) -> Followed:
  sequenced(line, cursor, sequence(line))

def follow(lines: List<&2, String>, +cursor: U32) -> Followed:
  match lines:
    case Nil{}:
      Followed{cursor, Nil{}}
    case Con{+line, rest}:
      +head = follow_line(line, cursor)
      +tail = follow(rest, followed_cursor(head))
      Followed{followed_cursor(tail), List.append(&2, String, followed_outs(head), followed_outs(tail))}

# One poll every 25 ms of the ceiling, plus slack; the driver also checks the clock.
def follow_fuel(duration: Nat) -> Nat:
  Nat.add(Nat.div(duration, 25n), 64n)

type Decision is Data:
  Continue{}
  Finished{}
  Expired{}

def expiry(expired: Bool) -> Decision:
  match expired:
    case True{}:
      Expired{}
    case False{}:
      Continue{}

# A terminal receipt ends a follow as finished, even at its ceiling. The driver
# reads the receipt before the events, so the final replay is already printed.
def follow_decision(finished: Bool, expired: Bool) -> Decision:
  match finished:
    case True{}:
      Finished{}
    case False{}:
      expiry(expired)

# ---------------------------------------------------------------------------
# Interactive jobs (`start --input pipe`): writers append to a private input
# queue in the job directory and the worker drains it into the child's stdin
# every tick. Host applies `admit` under the queue's lock, with `queue_max()`.

# Bytes a job's queue may hold before its worker has drained them.
def queue_max() -> U32:
  1048576

# Whether a write of `total` pending bytes (those queued plus the new ones) is
# accepted: never once input has ended, and never past the bound.
def admit(closed: Bool, +total: Nat, +max: Nat) -> Bool:
  match closed:
    case True{}:
      False{}
    case False{}:
      Nat.is_ge(max, total)

# The queue as the worker sees it: the bytes not yet handed to the child, in
# arrival order, and whether input has ended.
type Queue is Data:
  Queue{text: String, closed: Bool}

def empty_queue() -> Queue:
  Queue{"", False{}}

# An accepted write lands after everything before it.
def push(queue: Queue, text: String) -> Queue:
  match queue:
    case Queue{held, closed}:
      Queue{held ++ text, closed}

def seal(queue: Queue) -> Queue:
  match queue:
    case Queue{held, closed}:
      Queue{held, True{}}

# Draining takes every pending byte, in order, and leaves the queue empty.
def drained(queue: Queue) -> String:
  match queue:
    case Queue{held, closed}:
      held

def emptied(queue: Queue) -> Queue:
  match queue:
    case Queue{held, closed}:
      Queue{"", closed}

# Host's dequeue answer: "C" when input has ended, else "O", then the bytes.
def taken(answer: String) -> Queue:
  match answer:
    case SCon{'C', text}:
      Queue{text, True{}}
    case SCon{c, text}:
      Queue{text, False{}}
    case SNil{}:
      Queue{"", False{}}

# UTF-8 bytes of a string, as a write record reports them.
def utf8_bytes(text: String) -> Nat:
  match text:
    case SNil{}:
      0n
    case SCon{Chr{code}, rest}:
      Nat.add(U32.to_nat(Codec.width(code)), utf8_bytes(rest))

def write_json(id: String, +written: Nat, closed: Bool) -> String:
  "{\"id\":" ++ Json.quote(id)
    ++ ",\"written\":" ++ Nat.show(written)
    ++ ",\"closed\":" ++ Json.boolean(closed)
    ++ "}"

# ---------------------------------------------------------------------------
# `read [--wait-ms N] [--base64] <id> <stdout|stderr> [offset] [max]`.

type ReadPlan is Data:
  ReadPlan{id: String, stream: String, offset: Nat, max: Nat, wait: Nat, base64: Bool}

def read_usage() -> Error:
  (2, "usage: read [--wait-ms N] [--base64] <id> <stdout|stderr> [offset] [max]")

def stream_if(stream: String, ok: Bool) -> Result<&1, &1, Error, String>:
  match ok:
    case True{}:
      Done{stream}
    case False{}:
      Fail{(2, "stream must be stdout or stderr")}

def stream_checked(+stream: String) -> Result<&1, &1, Error, String>:
  stream_if(stream, String.eq(stream, "stdout") || String.eq(stream, "stderr"))

def nat_checked(value: Maybe<&2, Nat>, message: String) -> Result<&1, &1, Error, Nat>:
  match value:
    case Some{n}:
      Done{n}
    case None{}:
      Fail{(2, message)}

def bounded_if(n: Nat, message: String, ok: Bool) -> Result<&1, &1, Error, Nat>:
  match ok:
    case True{}:
      Done{n}
    case False{}:
      Fail{(2, message)}

def bounded(+n: Nat, +low: Nat, +high: Nat, message: String) -> Result<&1, &1, Error, Nat>:
  bounded_if(n, message, Nat.is_ge(n, low) && Nat.is_le(n, high))

def read_max_of(raw: String) -> Result<&1, &1, Error, Nat>:
  do Result<&1, &1, Error, Nat>:
    +n : Nat <- nat_checked(Nat.read(raw), "max must be an integer from 1 to 65536")
    bounded(n, 1n, 65536n, "max must be an integer from 1 to 65536")

def read_wait_of(raw: String) -> Result<&1, &1, Error, Nat>:
  do Result<&1, &1, Error, Nat>:
    +n : Nat <- nat_checked(Nat.read(raw), "--wait-ms must be an integer from 1 to 300000")
    bounded(n, 1n, 300000n, "--wait-ms must be an integer from 1 to 300000")

def read_offset_of(raw: String) -> Result<&1, &1, Error, Nat>:
  nat_checked(Nat.read(raw), "offset must be a byte offset")

def read_positional(args: List<String>, wait: Nat, base64: Bool) -> Result<&1, &1, Error, ReadPlan>:
  match args:
    case Con{id, Con{stream, Nil{}}}:
      do Result<&1, &1, Error, ReadPlan>:
        named : String <- stream_checked(stream)
        return ReadPlan{id, named, 0n, 65536n, wait, base64}
    case Con{id, Con{stream, Con{offset, Nil{}}}}:
      do Result<&1, &1, Error, ReadPlan>:
        named : String <- stream_checked(stream)
        at : Nat <- read_offset_of(offset)
        return ReadPlan{id, named, at, 65536n, wait, base64}
    case Con{id, Con{stream, Con{offset, Con{max, Nil{}}}}}:
      do Result<&1, &1, Error, ReadPlan>:
        named : String <- stream_checked(stream)
        at : Nat <- read_offset_of(offset)
        most : Nat <- read_max_of(max)
        return ReadPlan{id, named, at, most, wait, base64}
    case other:
      Fail{read_usage()}

def read_plan(args: List<String>, wait: Nat, base64: Bool) -> Result<&1, &1, Error, ReadPlan>:
  match args:
    case Con{"--wait-ms", Con{raw, rest}}:
      do Result<&1, &1, Error, ReadPlan>:
        ms : Nat <- read_wait_of(raw)
        read_plan(rest, ms, base64)
    case Con{"--base64", rest}:
      read_plan(rest, wait, True{})
    case Con{"--", rest}:
      read_positional(rest, wait, base64)
    case other:
      read_positional(other, wait, base64)
