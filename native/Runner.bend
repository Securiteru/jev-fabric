import Base
import ./Process.bend as Process
import ./Host.bend as Host
import ./Time.bend as Time

def root(value: Result<&1, &1, U32 & String, String>) -> String:
  match value:
    case Fail{e}:
      ".jev-fabric-native"
    case Done{text}:
      text

def finish(code: U32, success: Bool) -> IO(Unit):
  match success:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, code, "native program did not complete successfully")

def report(+result: Process.Report) -> IO(Unit):
  do IO<Unit>:
    IO.print(Process.show(result))
    +code : U32 = Process.exit_code(result)
    finish(code, U32.is_eq(code, 0))

def run_remaining(path: String, args: List<String>, remaining: U32, expired: Bool) -> IO(Unit):
  match expired:
    case True{}:
      IO.die(Unit, 124, "native program deadline expired during compilation")
    case False{}:
      do IO<Unit>:
        result : Process.Report <- Process.run_stdin(Con{path, Con{"--", args}}, remaining)
        report(result)

# Compilation and the program share one deadline.
def compiled(
  result: Process.Report,
  path: String,
  args: List<String>,
  started: Nat,
  timeout: U32,
  ok: Bool,
) -> IO(Unit):
  match ok:
    case False{}:
      report(result)
    case True{}:
      do IO<Unit>:
        now : Nat <- IO.now()
        +remaining : Nat = Nat.sub(U32.to_nat(timeout), Nat.sub(now, started))
        run_remaining(path, args, U32.from_nat(remaining), Nat.is_eq(remaining, 0n))

def compile(+timeout: U32, source: String, args: List<String>) -> IO(Unit):
  do IO<Unit>:
    configured : Result<&1, &1, U32 & String, String> <- IO.get_env("JEV_FABRIC_HOME")
    id : String <- Host.create(1024)
    +path : String = root(configured) ++ "/" ++ id ++ "/program"
    started : Nat <- IO.now()
    +result : Process.Report <- Process.run_input(["bend", source, "-o", path], "", timeout)
    compiled(result, path, args, started, timeout, U32.is_eq(Process.exit_code(result), 0))

def allowed(timeout: U32, source: String, args: List<String>, valid: Bool) -> IO(Unit):
  match valid:
    case False{}:
      IO.die(Unit, 2, "run requires 1..3600000 ms and a .bend source path (not an option)")
    case True{}:
      compile(timeout, source, args)

def runnable(+ms: U32, +source: String) -> Bool:
  U32.is_ge(ms, 1)
    && U32.is_le(ms, Time.max_timeout())
    && String.ends_with(source, ".bend")
    && Bool.not(String.starts_with(source, "-"))

def run(parsed: Maybe<&2, U32>, +source: String, args: List<String>) -> IO(Unit):
  match parsed:
    case None{}:
      IO.die(Unit, 2, "invalid native program timeout")
    case Some{+ms}:
      allowed(ms, source, args, runnable(ms, source))
