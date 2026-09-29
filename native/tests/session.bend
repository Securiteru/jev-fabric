import Base
import ../Session.bend as S
import ../Process.bend as P
import ../Codec.bend as Codec

def check(ok: Bool) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "session assertion failed")

def wrote(pair: S.Session & S.Written, expect_error: Bool) -> IO(S.Session):
  (session, value) = pair
  match value:
    case Fail{error}:
      do IO<S.Session>:
        check(expect_error)
        return session
    case Done{unit}:
      do IO<S.Session>:
        check(Bool.not(expect_error))
        return session

def send(session: S.Session, text: String, expect_error: Bool) -> IO(S.Session):
  do IO<S.Session>:
    pair : S.Session & S.Written <- S.write(session, text)
    wrote(pair, expect_error)

def reported(value: S.Outcome) -> IO(Unit):
  match value:
    case Fail{error}:
      IO.print("launch-failed")
    case Done{report}:
      IO.print(P.show(report))

def received(
  session: S.Session,
  next: S.Session -> IO(S.Session),
  expected: String,
  found: Bool,
) -> IO(S.Session):
  match found:
    case True{}:
      do IO<S.Session>:
        IO.print("live:" ++ expected)
        return session
    case False{}:
      do IO<S.Session>:
        IO.sleep(10)
        next(session)

def observed(
  pair: S.Session & S.Bytes,
  next: S.Session -> IO(S.Session),
  +expected: String,
) -> IO(S.Session):
  (session, bytes) = pair
  do IO<S.Session>:
    raw : List<&2, U32> <- IO.pass(List<&2, U32>, bytes)
    text : String <- IO.pass(String, Codec.decode_utf8(raw))
    received(session, next, expected, String.contains(text, expected))

def await_text(fuel: Nat, session: S.Session, +expected: String) -> IO(S.Session):
  match fuel:
    case 0n:
      IO.die(S.Session, 1, "live session reply missing")
    case 1n+rest:
      do IO<S.Session>:
        pair : S.Session & S.Bytes <- S.read_stdout(session, 0, 65536)
        observed(pair, next => await_text(rest, next, expected), expected)

# Prints "ready", then answers each stdin line with a running count as JSONL.
def counter() -> List<String>:
  [
    "/bin/sh",
    "-c",
    "printf 'ready\\n'; i=0; while IFS= read -r x; do i=$((i+1)); "
      ++ "printf '{\"count\":%s,\"value\":%s}\\n' \"$i\" \"$x\"; done"
  ]

def handshake() -> IO(Unit):
  do IO<Unit>:
    first : S.Session <- S.start(counter(), 5000)
    ready : S.Session <- await_text(100n, first, "ready")
    sent : S.Session <- send(ready, "10\n", False{})
    reply : S.Session <- await_text(100n, sent, "\"count\":1")
    next : S.Session <- send(reply, "20\n", False{})
    again : S.Session <- await_text(100n, next, "\"count\":2")
    closed : S.Session <- S.close_input(again)
    twice : S.Session <- S.close_input(closed)
    rejected : S.Session <- send(twice, "30\n", True{})
    result : S.Outcome <- S.wait(rejected)
    reported(result)

def fail_result(value: S.Outcome) -> IO(Unit):
  match value:
    case Fail{error}:
      IO.pure(Unit, Unit{})
    case Done{r}:
      IO.die(Unit, 1, "expected launch failure")

def failures(fuel: Nat) -> IO(Unit):
  match fuel:
    case 0n:
      IO.print("failure-cleanup:96")
    case 1n+rest:
      do IO<Unit>:
        bad : S.Session <- S.start([], 1000)
        IO.sleep(10)
        closed : S.Session <- send(bad, "x", True{})
        outcome : S.Outcome <- S.wait(closed)
        fail_result(outcome)
        failures(rest)

def bounded(pair: S.Session & S.Bytes) -> IO(S.Session):
  (session, result) = pair
  match result:
    case Fail{error}:
      IO.pure(S.Session, session)
    case Done{bytes}:
      IO.die(S.Session, 1, "expected read-bound error")

def exact_bytes(bytes: List<&2, U32>) -> Bool:
  match bytes:
    case Con{0, Con{255, Con{10, Nil{}}}}:
      True{}
    case other:
      False{}

def raw(pair: S.Session & S.Bytes) -> IO(S.Session):
  (session, result) = pair
  do IO<S.Session>:
    bytes : List<&2, U32> <- IO.pass(List<&2, U32>, result)
    check(exact_bytes(bytes))
    return session

def bytes() -> IO(Unit):
  do IO<Unit>:
    first : S.Session <- S.start(["/bin/sh", "-c", "printf '\\000\\377\\012' >&2; read x"], 3000)
    IO.sleep(100)
    bad : S.Session & S.Bytes <- S.read_stdout(first, 0, 65537)
    second : S.Session <- bounded(bad)
    bad_offset : S.Session & S.Bytes <- S.read_stdout(second, 1048577, 1)
    third : S.Session <- bounded(bad_offset)
    pair : S.Session & S.Bytes <- S.read_stderr(third, 0, 3)
    fourth : S.Session <- raw(pair)
    result : S.Outcome <- S.wait(fourth)
    reported(result)

def fill_result(pair: S.Session & S.Written, next: S.Session -> IO(S.Session)) -> IO(S.Session):
  (session, result) = pair
  match result:
    case Fail{error}:
      IO.pure(S.Session, session)
    case Done{unit}:
      next(session)

def fill(fuel: Nat, session: S.Session) -> IO(S.Session):
  match fuel:
    case 0n:
      IO.die(S.Session, 1, "stdin never reached bounded backpressure")
    case 1n+rest:
      do IO<S.Session>:
        pair : S.Session & S.Written <- S.write(session, String.repeat("x", 65536n))
        fill_result(pair, next => fill(rest, next))

def blocked_write() -> IO(Unit):
  do IO<Unit>:
    first : S.Session <- S.start(["/bin/sleep", "10"], 150)
    second : S.Session <- fill(32n, first)
    result : S.Outcome <- S.wait(second)
    reported(result)

def finish_pair(first: S.Session, second: S.Session, cancel: Bool) -> IO(Unit):
  match cancel:
    case False{}:
      do IO<Unit>:
        a : S.Outcome <- S.wait(first)
        b : S.Outcome <- S.wait(second)
        reported(a)
        reported(b)
    case True{}:
      do IO<Unit>:
        S.cancel_scope()
        IO.sleep(40)
        a : S.Outcome <- S.wait(first)
        b : S.Outcome <- S.wait(second)
        reported(a)
        reported(b)

def simultaneous(cancel: Bool) -> IO(Unit):
  do IO<Unit>:
    first : S.Session <- S.start(["/bin/cat"], 500)
    second : S.Session <- S.start(["/bin/cat"], 500)
    a : S.Session <- send(first, "one\n", False{})
    b : S.Session <- send(second, "two\n", False{})
    c : S.Session <- await_text(30n, a, "one")
    d : S.Session <- await_text(30n, b, "two")
    finish_pair(c, d, cancel)

def size_ready(pair: S.Session & (U32 & U32), next: S.Session -> IO(S.Session)) -> IO(S.Session):
  (session, (out, err)) = pair
  received(session, next, "spool-cap", U32.is_eq(out, S.spool_limit()))

def await_cap(fuel: Nat, session: S.Session) -> IO(S.Session):
  match fuel:
    case 0n:
      IO.die(S.Session, 1, "spool cap was not reached")
    case 1n+rest:
      do IO<S.Session>:
        pair : S.Session & (U32 & U32) <- S.status(session)
        size_ready(pair, next => await_cap(rest, next))

def limit_report(value: S.Outcome) -> IO(Unit):
  match value:
    case Fail{error}:
      IO.die(Unit, 1, "spool launch failed")
    case Done{P.Report{code, timed, cancelled, cut, err_cut, stdout, stderr}}:
      do IO<Unit>:
        check(cut && Nat.is_eq(String.length(stdout), 32768n))
        IO.print("bounded-tail:32768")

def limits() -> IO(Unit):
  do IO<Unit>:
    first : S.Session <- S.start(["/bin/sh", "-c", "head -c 1100000 /dev/zero; read x"], 3000)
    bounded_write : S.Session <- send(first, String.repeat("x", 65537n), True{})
    full : S.Session <- await_cap(200n, bounded_write)
    result : S.Outcome <- S.wait(full)
    limit_report(result)

def command(args: List<String>) -> IO(Unit):
  match args:
    case Con{"limits", Nil{}}:
      limits()
    case Con{"handshake", Nil{}}:
      handshake()
    case Con{"failures", Nil{}}:
      failures(96n)
    case Con{"bytes", Nil{}}:
      bytes()
    case Con{"blocked", Nil{}}:
      blocked_write()
    case Con{"two", Nil{}}:
      simultaneous(False{})
    case Con{"cancel", Nil{}}:
      simultaneous(True{})
    case other:
      IO.die(Unit, 2, "unknown session probe")

def main() -> IO(Unit):
  do IO<Unit>:
    # IO.args() starts with the program as invoked (Bend 2.0.32+).
    invoked : List<String> <- IO.args()
    args : List<String> = List.drop(&1, String, invoked, 1n)
    command(args)
