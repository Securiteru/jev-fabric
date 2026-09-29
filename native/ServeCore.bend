import Base
import ./Codec.bend as Codec
import ./Json.bend as Json
import ./Wire.bend as Wire
import ./Streams.bend as Streams
import ./TimeCore.bend as Time
import ./Cli.bend as Cli
import ./StoreCore.bend as Store
import ./JobsCore.bend as Jobs
import ./vendor/strict-json/json.bend as J

# Pure policy for `serve`: one JSON request per input line, one JSON response per
# output line. Serve.bend performs the reads, prints and subprocess calls.
# Protocol 2 answers requests concurrently: responses may come out of order and
# are matched by id.
def Error() -> Type:
  U32 & String

def protocol() -> U32:
  2

# Only features this binary implements. Within a protocol major, features are
# only ever added.
def features() -> List<&2, String>:
  [
    "follow",
    "list",
    "label",
    "start-24h",
    "serve-24h",
    "serve-concurrent",
    "sessions",
    "cwd",
    "durable-input",
    "read",
    "jev-request-credential",
  ]

def strings_json(items: List<&2, String>, first: Bool) -> String:
  match items:
    case Nil{}:
      ""
    case Con{item, rest}:
      Bool.pick(String, first, "", ",") ++ Json.quote(item) ++ strings_json(rest, False{})

def features_json() -> String:
  "[" ++ strings_json(features(), True{}) ++ "]"

# What a host needs to choose a binary without guessing from its version.
def capability_fields(version: String, platform: String) -> String:
  "\"version\":" ++ Json.quote(version)
    ++ ",\"protocol\":" ++ U32.show(protocol())
    ++ ",\"store\":" ++ Nat.show(Store.version())
    ++ ",\"platform\":" ++ Json.quote(platform)
    ++ ",\"features\":" ++ features_json()

def capabilities(version: String, platform: String) -> String:
  "{" ++ capability_fields(version, platform) ++ "}"

# A request line has the strict JSON bound; a longer partial line ends the session.
def line_max() -> U32:
  1048576

# stdout and stderr each capture up to this many bytes from a CLI child.
def capture_max() -> U32:
  1048577

# 64 argv entries per child, less the longest CLI prefix (exec's seven).
def argv_max() -> Nat:
  57n

# Time a CLI child keeps after its own deadline to print its receipt.
def grace() -> U32:
  2000

# Upper bound for status, events, stop and start's readiness handshake.
def control_max() -> U32:
  15000

# A session ends after this many input reads; each read returns at least one byte.
def reads_max() -> Nat:
  16777216n

# ---------------------------------------------------------------------------
# Line framing. `pending` holds the current partial line newest first.

type Framed is Data:
  Framed{lines: List<&2, List<&2, U32>>, pending: List<&2, U32>, size: U32}

# A finished line in reading order, without a CRLF carriage return.
def line(pending: List<&2, U32>) -> List<&2, U32>:
  match pending:
    case Con{13, rest}:
      List.reverse(&2, U32, rest)
    case other:
      List.reverse(&2, U32, other)

def frame(
  bytes: List<&2, U32>,
  pending: List<&2, U32>,
  +size: U32,
  done: List<&2, List<&2, U32>>,
) -> Framed:
  match bytes:
    case Nil{}:
      Framed{List.reverse(&2, List<&2, U32>, done), pending, size}
    case Con{10, rest}:
      frame(rest, Nil{}, 0, Con{line(pending), done})
    case Con{b, rest}:
      frame(rest, Con{b, pending}, (size + 1 : U32), done)

# The unterminated last line at end of input, if any.
def last(pending: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match pending:
    case Nil{}:
      Nil{}
    case other:
      [line(other)]

# ---------------------------------------------------------------------------
# Session options: serve [max-evaluations [max-tokens]], defaults as for `jev`.

def counted(value: Maybe<&2, U32>) -> Result<&1, &1, Error, U32>:
  match value:
    case None{}:
      Fail{(2, "serve budgets must be integers: [max-evaluations [max-tokens]]")}
    case Some{n}:
      Done{n}

def count(raw: String) -> Result<&1, &1, Error, U32>:
  counted(U32.read(raw))

def budget(args: List<String>) -> Result<&1, &1, Error, U32 & U32>:
  match args:
    case Nil{}:
      Done{(1, 100000)}
    case Con{calls, Nil{}}:
      do Result<&1, &1, Error, U32 & U32>:
        n : U32 <- count(calls)
        return (n, 100000)
    case Con{calls, Con{tokens, Nil{}}}:
      do Result<&1, &1, Error, U32 & U32>:
        n : U32 <- count(calls)
        t : U32 <- count(tokens)
        return (n, t)
    case other:
      Fail{(2, "usage: serve [--timeout-ms N] [max-evaluations [max-tokens]]")}

def banner(version: String, platform: String, +timeout: U32, +calls: U32, +tokens: U32) -> String:
  "{\"ready\":{\"protocol\":" ++ U32.show(protocol())
    ++ ",\"version\":" ++ Json.quote(version)
    ++ ",\"timeoutMs\":" ++ U32.show(timeout)
    ++ ",\"maxEvaluations\":" ++ U32.show(calls)
    ++ ",\"maxTokens\":" ++ U32.show(tokens)
    ++ ",\"store\":" ++ Nat.show(Store.version())
    ++ ",\"platform\":" ++ Json.quote(platform)
    ++ ",\"features\":" ++ features_json()
    ++ "}}"

# ---------------------------------------------------------------------------
# Requests.

type Op is Data:
  Exec{argv: List<&2, String>, input: String, timeout: Maybe<&2, U32>, cwd: String}
  Start{argv: List<&2, String>, timeout: Maybe<&2, U32>, label: String, cwd: String, pipe: Bool}
  Spawn{argv: List<&2, String>, pipe: Bool, timeout: Maybe<&2, U32>, label: String, cwd: String}
  Status{job: String}
  Events{job: String, after: U32, wait: Maybe<&2, U32>}
  Wait{job: String, timeout: Maybe<&2, U32>}
  Stop{job: String}
  Watch{job: String, literal: String, timeout: Maybe<&2, U32>}
  Write{job: String, text: String}
  CloseInput{job: String}
  ReadOut{job: String, stream: String, offset: Nat, max: Nat, wait: Maybe<&2, U32>, base64: Bool}
  ListJobs{sessions: Bool}
  Capabilities{}
  Validate{request: J.JSON}
  Evaluate{request: J.JSON, timeout: Maybe<&2, U32>, provider: String, credential: String}

def fail(message: String) -> Error:
  (2, message)

def object(value: J.JSON) -> Result<&1, &1, Error, List<&2, J.JSON>>:
  match value:
    case J.Obj{fields}:
      Done{fields}
    case other:
      Fail{fail("request must be a JSON object")}

# The id to echo: a string or number, else null. Validation reports a bad id.
def id_value(found: Maybe<&2, J.JSON>) -> J.JSON:
  match found:
    case Some{J.Str{s}}:
      J.Str{s}
    case Some{J.Num{lex}}:
      J.Num{lex}
    case other:
      J.Null{}

def id(value: J.JSON) -> J.JSON:
  id_value(Codec.field(value, "id"))

def id_valid(found: Maybe<&2, J.JSON>) -> Result<&1, &1, Error, Unit>:
  match found:
    case None{}:
      Done{Unit{}}
    case Some{J.Str{s}}:
      Codec.guard(Nat.is_le(String.length(s), 128n), "id must be at most 128 characters")
    case Some{J.Num{lex}}:
      Done{Unit{}}
    case other:
      Fail{fail("id must be a string or number")}

def found(value: Maybe<&2, J.JSON>, key: String) -> Result<&1, &1, Error, J.JSON>:
  match value:
    case None{}:
      Fail{fail("missing field: " ++ key)}
    case Some{v}:
      Done{v}

def need(fields: List<&2, J.JSON>, +key: String) -> Result<&1, &1, Error, J.JSON>:
  found(Codec.find_field(fields, key), key)

def string(value: J.JSON, +key: String) -> Result<&1, &1, Error, String>:
  match value:
    case J.Str{s}:
      Done{s}
    case other:
      Fail{fail(key ++ " must be a string")}

def text(fields: List<&2, J.JSON>, +key: String) -> Result<&1, &1, Error, String>:
  do Result<&1, &1, Error, String>:
    value : J.JSON <- need(fields, key)
    string(value, key)

def optional_text(found: Maybe<&2, J.JSON>, +key: String) -> Result<&1, &1, Error, String>:
  match found:
    case None{}:
      Done{""}
    case Some{value}:
      string(value, key)

def job_if(job: String, bad: Bool) -> Result<&1, &1, Error, String>:
  match bad:
    case True{}:
      Fail{fail("job must be an id returned by start")}
    case False{}:
      Done{job}

# An id can never start with "-", so it is never read as a CLI option.
def job_checked(+job: String) -> Result<&1, &1, Error, String>:
  job_if(job, String.is_empty(job) || String.starts_with(job, "-"))

def job(fields: List<&2, J.JSON>) -> Result<&1, &1, Error, String>:
  do Result<&1, &1, Error, String>:
    raw : String <- text(fields, "job")
    job_checked(raw)

def timeout_error(max: U32) -> Error:
  fail("timeoutMs must be an integer from 1 to " ++ U32.show(max))

def timeout_parsed(parsed: Result<&1, &1, Error, U32>, max: U32) -> Result<&1, &1, Error, Maybe<&2, U32>>:
  match parsed:
    case Fail{e}:
      Fail{timeout_error(max)}
    case Done{ms}:
      Done{Some{ms}}

def timeout_value(value: J.JSON, +max: U32) -> Result<&1, &1, Error, Maybe<&2, U32>>:
  match value:
    case J.Num{lex}:
      timeout_parsed(Time.parse(lex, max), max)
    case other:
      Fail{timeout_error(max)}

def timeout_found(value: Maybe<&2, J.JSON>, max: U32) -> Result<&1, &1, Error, Maybe<&2, U32>>:
  match value:
    case None{}:
      Done{None{}}
    case Some{v}:
      timeout_value(v, max)

def timeout(fields: List<&2, J.JSON>, max: U32) -> Result<&1, &1, Error, Maybe<&2, U32>>:
  timeout_found(Codec.find_field(fields, "timeoutMs"), max)

# `events.waitMs`: an optional long poll, 1..300000 ms, like `watch`.
def wait_error() -> Error:
  fail("waitMs must be an integer from 1 to 300000")

def wait_parsed(parsed: Result<&1, &1, Error, U32>) -> Result<&1, &1, Error, Maybe<&2, U32>>:
  match parsed:
    case Fail{e}:
      Fail{wait_error()}
    case Done{ms}:
      Done{Some{ms}}

def wait_value(value: J.JSON) -> Result<&1, &1, Error, Maybe<&2, U32>>:
  match value:
    case J.Num{lex}:
      wait_parsed(Time.parse(lex, 300000))
    case other:
      Fail{wait_error()}

def wait_found(value: Maybe<&2, J.JSON>) -> Result<&1, &1, Error, Maybe<&2, U32>>:
  match value:
    case None{}:
      Done{None{}}
    case Some{v}:
      wait_value(v)

def wait_ms(fields: List<&2, J.JSON>) -> Result<&1, &1, Error, Maybe<&2, U32>>:
  wait_found(Codec.find_field(fields, "waitMs"))

# `start.label`: checked exactly as the CLI's --label; absent means none.
def label_value(value: J.JSON) -> Result<&1, &1, Error, String>:
  match value:
    case J.Str{s}:
      Cli.label_checked(s)
    case other:
      Fail{fail("label must be a string")}

def label_found(value: Maybe<&2, J.JSON>) -> Result<&1, &1, Error, String>:
  match value:
    case None{}:
      Done{""}
    case Some{v}:
      label_value(v)

# `cwd`: an absolute directory for the child, checked as the CLI's --cwd.
def cwd_value(value: J.JSON) -> Result<&1, &1, Error, String>:
  match value:
    case J.Str{s}:
      Cli.cwd_checked(s)
    case other:
      Fail{fail("cwd must be a string")}

def cwd_found(value: Maybe<&2, J.JSON>) -> Result<&1, &1, Error, String>:
  match value:
    case None{}:
      Done{""}
    case Some{v}:
      cwd_value(v)

def cwd(fields: List<&2, J.JSON>) -> Result<&1, &1, Error, String>:
  cwd_found(Codec.find_field(fields, "cwd"))

# One of `choices`, or absent (the first choice).
def choice_if(value: String, ok: Bool, message: String) -> Result<&1, &1, Error, String>:
  match ok:
    case True{}:
      Done{value}
    case False{}:
      Fail{fail(message)}

def choice_value(value: J.JSON, +choices: List<&2, String>, +message: String) -> Result<&1, &1, Error, String>:
  match value:
    case J.Str{+s}:
      choice_if(s, Codec.contains(choices, s), message)
    case other:
      Fail{fail(message)}

def choice(found: Maybe<&2, J.JSON>, +fallback: String, choices: List<&2, String>, message: String) -> Result<&1, &1, Error, String>:
  match found:
    case None{}:
      Done{fallback}
    case Some{v}:
      choice_value(v, choices, message)

def cursor_error() -> Error:
  fail("after must be an event sequence number")

def cursor_fit(n: Nat, fits: Bool) -> Result<&1, &1, Error, U32>:
  match fits:
    case True{}:
      Done{U32.from_nat(n)}
    case False{}:
      Fail{cursor_error()}

def cursor_read(value: Maybe<&2, Nat>) -> Result<&1, &1, Error, U32>:
  match value:
    case Some{+n}:
      cursor_fit(n, Nat.is_le(n, 4294967295n))
    case None{}:
      Fail{cursor_error()}

def cursor_value(value: J.JSON) -> Result<&1, &1, Error, U32>:
  match value:
    case J.Num{lex}:
      cursor_read(Nat.read(lex))
    case other:
      Fail{cursor_error()}

def cursor_found(value: Maybe<&2, J.JSON>) -> Result<&1, &1, Error, U32>:
  match value:
    case None{}:
      Done{0}
    case Some{v}:
      cursor_value(v)

def cursor(fields: List<&2, J.JSON>) -> Result<&1, &1, Error, U32>:
  cursor_found(Codec.find_field(fields, "after"))

# A byte offset: a non-negative integer up to 2^48 - 1.
def offset_error() -> Error:
  fail("offset must be a byte offset (a non-negative integer)")

def offset_read(value: Maybe<&2, Nat>) -> Result<&1, &1, Error, Nat>:
  match value:
    case Some{n}:
      Done{n}
    case None{}:
      Fail{offset_error()}

def offset_value(value: J.JSON) -> Result<&1, &1, Error, Nat>:
  match value:
    case J.Num{lex}:
      offset_read(Nat.read(lex))
    case other:
      Fail{offset_error()}

def offset_found(value: Maybe<&2, J.JSON>) -> Result<&1, &1, Error, Nat>:
  match value:
    case None{}:
      Done{0n}
    case Some{v}:
      offset_value(v)

def max_parsed(parsed: Result<&1, &1, Error, U32>) -> Result<&1, &1, Error, Nat>:
  match parsed:
    case Fail{e}:
      Fail{fail("max must be an integer from 1 to 65536")}
    case Done{n}:
      Done{U32.to_nat(n)}

def max_value(value: J.JSON) -> Result<&1, &1, Error, Nat>:
  match value:
    case J.Num{lex}:
      max_parsed(Time.parse(lex, 65536))
    case other:
      Fail{fail("max must be an integer from 1 to 65536")}

def max_found(value: Maybe<&2, J.JSON>) -> Result<&1, &1, Error, Nat>:
  match value:
    case None{}:
      Done{65536n}
    case Some{v}:
      max_value(v)

# `write.text`: at most 65536 Unicode characters, like Session.write.
def text_bounded(text: String, ok: Bool) -> Result<&1, &1, Error, String>:
  match ok:
    case True{}:
      Done{text}
    case False{}:
      Fail{fail("text must be at most 65536 characters")}

def write_text(fields: List<&2, J.JSON>) -> Result<&1, &1, Error, String>:
  do Result<&1, &1, Error, String>:
    +raw : String <- text(fields, "text")
    text_bounded(raw, Nat.is_le(String.length(raw), 65536n))

# A per-request Jev credential: a non-empty string, never echoed back.
def credential_value(value: J.JSON) -> Result<&1, &1, Error, String>:
  match value:
    case J.Str{SNil{}}:
      Fail{fail("credential must be a non-empty string")}
    case J.Str{s}:
      Done{s}
    case other:
      Fail{fail("credential must be a non-empty string")}

def credential_found(value: Maybe<&2, J.JSON>) -> Result<&1, &1, Error, String>:
  match value:
    case None{}:
      Done{""}
    case Some{v}:
      credential_value(v)

def strings(items: List<&2, J.JSON>) -> Result<&1, &1, Error, List<&2, String>>:
  match items:
    case Nil{}:
      Done{Nil{}}
    case Con{item, rest}:
      do Result<&1, &1, Error, List<&2, String>>:
        head : String <- string(item, "argv entries")
        tail : List<&2, String> <- strings(rest)
        return Con{head, tail}

def argv_error() -> Error:
  fail("argv must be an array of 1 to 57 strings")

def argv_named(argv: List<&2, String>, empty: Bool) -> Result<&1, &1, Error, List<&2, String>>:
  match empty:
    case True{}:
      Fail{fail("argv[0] must name a command")}
    case False{}:
      Done{argv}

def argv_sized(argv: List<&2, String>, fits: Bool) -> Result<&1, &1, Error, List<&2, String>>:
  match argv fits:
    case Con{+first, rest} True{}:
      argv_named(Con{first, rest}, String.is_empty(first))
    case _ _:
      Fail{argv_error()}

def argv_checked(+argv: List<&2, String>) -> Result<&1, &1, Error, List<&2, String>>:
  argv_sized(argv, Nat.is_le(List.length(&2, String, argv), argv_max()))

def argv_value(value: J.JSON) -> Result<&1, &1, Error, List<&2, String>>:
  match value:
    case J.Arr{items}:
      do Result<&1, &1, Error, List<&2, String>>:
        list : List<&2, String> <- strings(items)
        argv_checked(list)
    case other:
      Fail{argv_error()}

def argv(fields: List<&2, J.JSON>) -> Result<&1, &1, Error, List<&2, String>>:
  do Result<&1, &1, Error, List<&2, String>>:
    value : J.JSON <- need(fields, "argv")
    argv_value(value)

# The first member not named in `keys`, if any.
def unknown(fields: List<&2, J.JSON>, +keys: List<&2, String>) -> Maybe<&2, String>:
  match fields:
    case Nil{}:
      None{}
    case Con{J.Member{+key, value}, tail}:
      Bool.pick(Maybe<&2, String>, Codec.contains(keys, key), unknown(tail, keys), Some{key})
    case Con{other, tail}:
      Some{""}

def known(extra: Maybe<&2, String>) -> Result<&1, &1, Error, Unit>:
  match extra:
    case None{}:
      Done{Unit{}}
    case Some{key}:
      Fail{fail("unknown request field: " ++ key)}

# Unknown fields are rejected so that a misspelled option never goes unnoticed.
def allowed(fields: List<&2, J.JSON>, +keys: List<&2, String>) -> Result<&1, &1, Error, Unit>:
  known(unknown(fields, Con{"id", Con{"op", keys}}))

def exec_op(+fields: List<&2, J.JSON>) -> Result<&1, &1, Error, Op>:
  do Result<&1, &1, Error, Op>:
    allowed(fields, ["argv", "stdin", "timeoutMs", "cwd"])
    command : List<&2, String> <- argv(fields)
    input : String <- optional_text(Codec.find_field(fields, "stdin"), "stdin")
    ms : Maybe<&2, U32> <- timeout(fields, 3600000)
    dir : String <- cwd(fields)
    return Exec{command, input, ms, dir}

# A job's own lifetime may reach a day; it is not bounded by the session.
def start_op(+fields: List<&2, J.JSON>) -> Result<&1, &1, Error, Op>:
  do Result<&1, &1, Error, Op>:
    allowed(fields, ["argv", "timeoutMs", "label", "cwd", "input"])
    command : List<&2, String> <- argv(fields)
    ms : Maybe<&2, U32> <- timeout(fields, Time.job_max())
    label : String <- label_found(Codec.find_field(fields, "label"))
    dir : String <- cwd(fields)
    +input : String <- choice(Codec.find_field(fields, "input"), "null", ["pipe", "null"], "input must be \"pipe\" or \"null\"")
    return Start{command, ms, label, dir, String.eq(input, "pipe")}

# A session child lives at most a day, and never longer than its connection.
def spawn_op(+fields: List<&2, J.JSON>) -> Result<&1, &1, Error, Op>:
  do Result<&1, &1, Error, Op>:
    allowed(fields, ["argv", "stdin", "timeoutMs", "label", "cwd"])
    command : List<&2, String> <- argv(fields)
    +input : String <- choice(Codec.find_field(fields, "stdin"), "pipe", ["pipe", "null"], "stdin must be \"pipe\" or \"null\"")
    ms : Maybe<&2, U32> <- timeout(fields, Time.job_max())
    label : String <- label_found(Codec.find_field(fields, "label"))
    dir : String <- cwd(fields)
    return Spawn{command, String.eq(input, "pipe"), ms, label, dir}

def write_op(+fields: List<&2, J.JSON>) -> Result<&1, &1, Error, Op>:
  do Result<&1, &1, Error, Op>:
    allowed(fields, ["job", "text"])
    id : String <- job(fields)
    written : String <- write_text(fields)
    return Write{id, written}

def close_op(+fields: List<&2, J.JSON>) -> Result<&1, &1, Error, Op>:
  do Result<&1, &1, Error, Op>:
    allowed(fields, ["job"])
    id : String <- job(fields)
    return CloseInput{id}

def read_op(+fields: List<&2, J.JSON>) -> Result<&1, &1, Error, Op>:
  do Result<&1, &1, Error, Op>:
    allowed(fields, ["job", "stream", "offset", "max", "waitMs", "encoding"])
    id : String <- job(fields)
    +stream : String <- choice(Codec.find_field(fields, "stream"), "", ["stdout", "stderr"], "stream must be \"stdout\" or \"stderr\"")
    +named : String <- choice_if(stream, Bool.not(String.is_empty(stream)), "missing field: stream")
    at : Nat <- offset_found(Codec.find_field(fields, "offset"))
    most : Nat <- max_found(Codec.find_field(fields, "max"))
    wait : Maybe<&2, U32> <- wait_ms(fields)
    +encoding : String <- choice(Codec.find_field(fields, "encoding"), "text", ["text", "base64"], "encoding must be \"text\" or \"base64\"")
    return ReadOut{id, named, at, most, wait, String.eq(encoding, "base64")}

def status_op(+fields: List<&2, J.JSON>) -> Result<&1, &1, Error, Op>:
  do Result<&1, &1, Error, Op>:
    allowed(fields, ["job"])
    id : String <- job(fields)
    return Status{id}

def events_op(+fields: List<&2, J.JSON>) -> Result<&1, &1, Error, Op>:
  do Result<&1, &1, Error, Op>:
    allowed(fields, ["job", "after", "waitMs"])
    id : String <- job(fields)
    after : U32 <- cursor(fields)
    wait : Maybe<&2, U32> <- wait_ms(fields)
    return Events{id, after, wait}

def wait_op(+fields: List<&2, J.JSON>) -> Result<&1, &1, Error, Op>:
  do Result<&1, &1, Error, Op>:
    allowed(fields, ["job", "timeoutMs"])
    id : String <- job(fields)
    ms : Maybe<&2, U32> <- timeout(fields, 3600000)
    return Wait{id, ms}

def stop_op(+fields: List<&2, J.JSON>) -> Result<&1, &1, Error, Op>:
  do Result<&1, &1, Error, Op>:
    allowed(fields, ["job"])
    id : String <- job(fields)
    return Stop{id}

def watch_op(+fields: List<&2, J.JSON>) -> Result<&1, &1, Error, Op>:
  do Result<&1, &1, Error, Op>:
    allowed(fields, ["job", "literal", "timeoutMs"])
    id : String <- job(fields)
    literal : String <- text(fields, "literal")
    ms : Maybe<&2, U32> <- timeout(fields, 300000)
    return Watch{id, literal, ms}

# `scope`: "store" (the default) lists the storage root's jobs, as the CLI does;
# "session" lists this connection's session children.
def list_op(+fields: List<&2, J.JSON>) -> Result<&1, &1, Error, Op>:
  do Result<&1, &1, Error, Op>:
    allowed(fields, ["scope"])
    +scope : String <- choice(Codec.find_field(fields, "scope"), "store", ["store", "session"], "scope must be \"store\" or \"session\"")
    return ListJobs{String.eq(scope, "session")}

def capabilities_op(+fields: List<&2, J.JSON>) -> Result<&1, &1, Error, Op>:
  do Result<&1, &1, Error, Op>:
    allowed(fields, [])
    return Capabilities{}

def validate_op(+fields: List<&2, J.JSON>) -> Result<&1, &1, Error, Op>:
  do Result<&1, &1, Error, Op>:
    allowed(fields, ["request"])
    request : J.JSON <- need(fields, "request")
    return Validate{request}

# `provider` and `credential` apply to this request only: the credential is
# never cached in the session's client, echoed, or written anywhere.
def jev_op(+fields: List<&2, J.JSON>) -> Result<&1, &1, Error, Op>:
  do Result<&1, &1, Error, Op>:
    allowed(fields, ["request", "timeoutMs", "provider", "credential"])
    request : J.JSON <- need(fields, "request")
    ms : Maybe<&2, U32> <- timeout(fields, 3600000)
    provider : String <- choice(Codec.find_field(fields, "provider"), "", ["typesafe", "openrouter", "vercel"], "provider must be typesafe, openrouter or vercel")
    credential : String <- credential_found(Codec.find_field(fields, "credential"))
    return Evaluate{request, ms, provider, credential}

def op(name: String, fields: List<&2, J.JSON>) -> Result<&1, &1, Error, Op>:
  match name:
    case "exec":
      exec_op(fields)
    case "start":
      start_op(fields)
    case "spawn":
      spawn_op(fields)
    case "write":
      write_op(fields)
    case "closeInput":
      close_op(fields)
    case "read":
      read_op(fields)
    case "capabilities":
      capabilities_op(fields)
    case "status":
      status_op(fields)
    case "events":
      events_op(fields)
    case "wait":
      wait_op(fields)
    case "stop":
      stop_op(fields)
    case "watch":
      watch_op(fields)
    case "list":
      list_op(fields)
    case "validate":
      validate_op(fields)
    case "jev":
      jev_op(fields)
    case other:
      Fail{fail("unknown op: use exec, start, spawn, write, closeInput, read, status, events, wait, stop, watch, list, capabilities, validate or jev")}

def request(value: J.JSON) -> Result<&1, &1, Error, Op>:
  do Result<&1, &1, Error, Op>:
    +fields : List<&2, J.JSON> <- object(value)
    id_valid(Codec.find_field(fields, "id"))
    name : String <- text(fields, "op")
    op(name, fields)

# ---------------------------------------------------------------------------
# CLI child plans. Each process and job operation re-enters this executable, so
# a failing command costs one response, never the session.

type Defaults is Data:
  Defaults{work: U32, wait: U32, watch: U32}

type Call is Data:
  Call{argv: List<&2, String>, input: String, timeout: U32, many: Bool}

def expired() -> Error:
  (124, "serve deadline expired")

# The child's own deadline: the requested or default time, within the session's
# remaining time less the receipt grace. Zero means no time is left.
def or(value: Maybe<&2, U32>, fallback: U32) -> U32:
  match value:
    case None{}:
      fallback
    case Some{v}:
      v

def left(+remaining: U32) -> U32:
  Bool.pick(U32, U32.is_gt(remaining, grace()), U32.sub(remaining, grace()), 0)

def inner(requested: Maybe<&2, U32>, fallback: U32, remaining: U32) -> U32:
  U32.min(or(requested, fallback), left(remaining))

def timed_if(argv: List<&2, String>, input: String, ms: U32, many: Bool, zero: Bool) -> Result<&1, &1, Error, Call>:
  match zero:
    case True{}:
      Fail{expired()}
    case False{}:
      Done{Call{argv, input, (ms + grace() : U32), many}}

def timed(argv: List<&2, String>, input: String, +ms: U32, many: Bool) -> Result<&1, &1, Error, Call>:
  timed_if(argv, input, ms, many, U32.is_eq(ms, 0))

def control_if(argv: List<&2, String>, remaining: U32, many: Bool, ok: Bool) -> Result<&1, &1, Error, Call>:
  match ok:
    case True{}:
      Done{Call{argv, "", U32.min(remaining, control_max()), many}}
    case False{}:
      Fail{expired()}

def control(argv: List<&2, String>, +remaining: U32, many: Bool) -> Result<&1, &1, Error, Call>:
  control_if(argv, remaining, many, U32.is_gt(remaining, grace()))

# Process effects take an affine argv list.
def owned(args: List<&2, String>) -> List<String>:
  match args:
    case Nil{}:
      Nil{}
    case Con{head, tail}:
      Con{head, owned(tail)}

def cli(self: String, args: List<&2, String>) -> List<&2, String>:
  Con{self, Con{"--", args}}

def work(defaults: Defaults) -> U32:
  match defaults:
    case Defaults{work, wait, watch}:
      work

def wait(defaults: Defaults) -> U32:
  match defaults:
    case Defaults{work, wait, watch}:
      wait

def watch(defaults: Defaults) -> U32:
  match defaults:
    case Defaults{work, wait, watch}:
      watch

def label_args(label: String) -> List<&2, String>:
  match label:
    case SNil{}:
      Nil{}
    case other:
      ["--label", other]

def input_args(pipe: Bool) -> List<&2, String>:
  match pipe:
    case True{}:
      ["--input", "pipe"]
    case False{}:
      Nil{}

def cwd_args(cwd: String) -> List<&2, String>:
  match cwd:
    case SNil{}:
      Nil{}
    case other:
      ["--cwd", other]

# Without waitMs, events is a snapshot under the control bound. With it, the
# child long-polls for the requested time, cut to the session like `wait`.
def events_plan(self: String, job: String, +after: U32, wait: Maybe<&2, U32>, +remaining: U32) -> Result<&1, &1, Error, Call>:
  match wait:
    case None{}:
      control(cli(self, ["events", job, U32.show(after)]), remaining, True{})
    case Some{requested}:
      +ms : U32 = U32.min(requested, left(remaining))
      timed(cli(self, ["events", "--timeout-ms", U32.show(ms), job, U32.show(after)]), "", ms, True{})

def plan(+self: String, op: Op, defaults: Defaults, +remaining: U32) -> Result<&1, &1, Error, Call>:
  match op:
    case Exec{argv, input, requested, dir}:
      +ms : U32 = inner(requested, 3600000, remaining)
      prefix : List<&2, String> = List.append(
        &2,
        String,
        ["exec", "--timeout-ms", U32.show(ms), "--stdin"],
        List.append(&2, String, cwd_args(dir), ["--"]),
      )
      timed(cli(self, List.append(&2, String, prefix, argv)), input, ms, False{})
    case Start{argv, requested, label, dir, pipe}:
      lifetime : U32 = or(requested, work(defaults))
      options : List<&2, String> = List.append(&2, String, label_args(label), List.append(&2, String, cwd_args(dir), input_args(pipe)))
      prefix : List<&2, String> = List.append(
        &2,
        String,
        ["start", "--timeout-ms", U32.show(lifetime)],
        List.append(&2, String, options, ["--"]),
      )
      control(cli(self, List.append(&2, String, prefix, argv)), remaining, False{})
    case Status{job}:
      control(cli(self, ["status", job]), remaining, False{})
    case Events{job, after, wait}:
      events_plan(self, job, after, wait, remaining)
    case Wait{job, requested}:
      +ms : U32 = inner(requested, wait(defaults), remaining)
      timed(cli(self, ["wait", "--timeout-ms", U32.show(ms), job]), "", ms, False{})
    case Stop{job}:
      control(cli(self, ["stop", job]), remaining, False{})
    case Watch{job, literal, requested}:
      +ms : U32 = inner(requested, watch(defaults), remaining)
      timed(cli(self, ["watch", "--timeout-ms", U32.show(ms), job, literal]), "", ms, True{})
    case ListJobs{sessions}:
      control(cli(self, ["list"]), remaining, False{})
    case other:
      Fail{fail("this request runs in process")}

# ---------------------------------------------------------------------------
# CLI child output: JSON lines on stdout, or an error on stderr.

def values(lines: List<&2, List<&2, U32>>) -> Result<&1, &1, Error, List<&2, J.JSON>>:
  match lines:
    case Nil{}:
      Done{Nil{}}
    case Con{Nil{}, rest}:
      values(rest)
    case Con{bytes, rest}:
      do Result<&1, &1, Error, List<&2, J.JSON>>:
        head : J.JSON <- Codec.read_bytes(bytes)
        tail : List<&2, J.JSON> <- values(rest)
        return Con{head, tail}

def message_if(text: String, empty: Bool) -> String:
  match empty:
    case True{}:
      "jev-fabric command failed"
    case False{}:
      String.take(text, 1024n)

def message_text(+text: String) -> String:
  message_if(text, String.is_empty(text))

def message(err: List<&2, U32>) -> String:
  message_text(String.trim(Streams.finish(Streams.feed(err, Streams.empty()))))

def failed(+code: U32, err: List<&2, U32>) -> Result<&1, &1, Error, String>:
  Fail{(Bool.pick(U32, U32.is_eq(code, 0), 1, code), message(err))}

def result(items: List<&2, J.JSON>, many: Bool, +code: U32, err: List<&2, U32>) -> Result<&1, &1, Error, String>:
  match items many:
    case all True{}:
      Codec.encode(J.Arr{all})
    case Con{first, rest} False{}:
      Codec.encode(first)
    case Nil{} False{}:
      failed(code, err)

def framed_output(framed: Framed, +code: U32, err: List<&2, U32>, many: Bool) -> Result<&1, &1, Error, String>:
  match framed:
    case Framed{lines, pending, size}:
      do Result<&1, &1, Error, String>:
        items : List<&2, J.JSON> <- values(List.append(&2, List<&2, U32>, lines, last(pending)))
        result(items, many, code, err)

def output(code: U32, out: List<&2, U32>, err: List<&2, U32>, many: Bool) -> Result<&1, &1, Error, String>:
  framed_output(frame(out, Nil{}, 0, Nil{}), code, err, many)

def flagged(
  code: U32,
  out: List<&2, U32>,
  err: List<&2, U32>,
  many: Bool,
  clean: Bool,
  timed_out: Bool,
) -> Result<&1, &1, Error, String>:
  match clean timed_out:
    case True{} _:
      output(code, out, err, many)
    case False{} True{}:
      Fail{expired()}
    case False{} False{}:
      Fail{(1, "jev-fabric command output exceeded 1 MiB")}

# Flag bits from posix.c: 1 timed out, 2 stdout cut, 4 stderr cut, 8 cancelled.
def outcome(raw: Result<&1, &1, Error, U32 & (U32 & (List<&2, U32> & List<&2, U32>))>, many: Bool) -> Result<&1, &1, Error, String>:
  match raw:
    case Fail{e}:
      (code, text) = e
      Fail{(code, "jev-fabric could not run the request: " ++ text)}
    case Done{captured}:
      (code, (+flags, (out, err))) = captured
      flagged(code, out, err, many, U32.is_eq(flags, 0), U32.is_ne((flags .&. 1 : U32), 0))

# ---------------------------------------------------------------------------
# In-process operations and responses.

def unreadable(value: Result<&1, &1, Error, J.JSON>) -> Result<&1, &1, Error, J.JSON>:
  match value:
    case Fail{e}:
      (code, message) = e
      Fail{(code, "request line is not strict JSON: " ++ message)}
    case Done{v}:
      Done{v}

def validated(request: J.JSON) -> Result<&1, &1, Error, String>:
  do Result<&1, &1, Error, String>:
    checked : J.JSON <- Wire.validate_request(request)
    Codec.encode(checked)

def encoded_or_null(value: Result<&1, &1, Error, String>) -> String:
  match value:
    case Fail{e}:
      "null"
    case Done{text}:
      text

def encoded(value: J.JSON) -> String:
  encoded_or_null(Codec.encode(value))

def respond(id: J.JSON, result: Result<&1, &1, Error, String>) -> String:
  match result:
    case Done{text}:
      "{\"id\":" ++ encoded(id) ++ ",\"ok\":true,\"result\":" ++ text ++ "}"
    case Fail{e}:
      (code, message) = e
      "{\"id\":" ++ encoded(id) ++ ",\"ok\":false,\"error\":{\"code\":" ++ U32.show(code)
        ++ ",\"message\":" ++ Json.quote(message) ++ "}}"

# ---------------------------------------------------------------------------
# Session children: spawned by one connection, addressed by `s-` ids, ended
# with it. Each child's worker re-enters this executable and reads the
# connection's pipe as the child's stdin.

# Running session children one connection may hold, and the writes (and closes
# and stops) one child may have queued.
def children_max() -> Nat:
  16n

def pending_max() -> U32:
  64

# A worker's supervisor gives it this long past its child's own deadline to
# record the receipt.
def worker_grace() -> U32:
  5000

# The directory behind a session child's id, if `job` is one.
def session_dir(job: String) -> Maybe<&2, String>:
  match job:
    case SCon{'s', SCon{'-', dir}}:
      Some{dir}
    case other:
      None{}

def unknown_child() -> Error:
  (22, "unknown session child for this connection")

def too_many_children() -> Error:
  (22, "this connection already has 16 running session children")

def too_many_pending() -> Error:
  (1, "too many pending requests for this session child")

# A session child lives for its own timeoutMs, or else for the rest of the
# connection, and never past the connection less the receipt grace.
def child_lifetime(requested: Maybe<&2, U32>, +left: U32) -> U32:
  U32.min(or(requested, left), left)

# How long the connection supervises the child's worker: the child's lifetime
# and the grace, within a job's day.
def worker_timeout(+lifetime: U32) -> U32:
  U32.min(U32.add(lifetime, worker_grace()), Time.job_max())

def mode(pipe: Bool) -> String:
  match pipe:
    case True{}:
      "session"
    case False{}:
      "session-null"

# `__job-worker <dir> <ms> <mode> <cwd> <argv...>`, as Jobs.worker_argv.
def worker_argv(self: String, dir: String, +lifetime: U32, pipe: Bool, cwd: String, argv: List<&2, String>) -> List<&2, String>:
  cli(self, Con{"__job-worker", Con{dir, Con{U32.show(lifetime), Con{mode(pipe), Con{cwd, argv}}}}})

def utf8_bytes(text: String) -> Nat:
  Jobs.utf8_bytes(text)

def write_json(id: String, +written: Nat, closed: Bool) -> String:
  Jobs.write_json(id, written, closed)


# The job a request names, if any.
def job_of(op: Op) -> Maybe<&2, String>:
  match op:
    case Status{job}:
      Some{job}
    case Events{job, after, wait}:
      Some{job}
    case Wait{job, timeout}:
      Some{job}
    case Stop{job}:
      Some{job}
    case Watch{job, literal, timeout}:
      Some{job}
    case Write{job, text}:
      Some{job}
    case CloseInput{job}:
      Some{job}
    case ReadOut{job, stream, offset, max, wait, base64}:
      Some{job}
    case other:
      None{}

def target_of(found: Maybe<&2, String>) -> Maybe<&2, String>:
  match found:
    case None{}:
      None{}
    case Some{+job}:
      Bool.pick(Maybe<&2, String>, String.starts_with(job, "s-"), Some{job}, None{})

# The session child a request names, by its full `s-` id.
def session_target(op: Op) -> Maybe<&2, String>:
  target_of(job_of(op))

# The same observation, pointed at the child's directory for a CLI child.
def retarget(op: Op, dir: String) -> Op:
  match op:
    case Status{job}:
      Status{dir}
    case Events{job, after, wait}:
      Events{dir, after, wait}
    case Wait{job, timeout}:
      Wait{dir, timeout}
    case Watch{job, literal, timeout}:
      Watch{dir, literal, timeout}
    case other:
      other
