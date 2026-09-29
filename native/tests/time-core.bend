import Base
import ../TimeCore.bend as Time
import ../Cli.bend as Cli

def ms_is(result: Result<&1, &1, U32 & String, U32>, expected: U32) -> Bool:
  match result:
    case Fail{error}:
      False{}
    case Done{actual}:
      U32.is_eq(actual, expected)

def bad_ms(result: Result<&1, &1, U32 & String, U32>) -> Bool:
  match result:
    case Fail{error}:
      True{}
    case Done{actual}:
      False{}

def bad_cli(result: Result<&1, &1, U32 & String, Cli.Plan>) -> Bool:
  match result:
    case Fail{error}:
      True{}
    case Done{plan}:
      False{}

def joined(items: List<String>) -> String:
  match items:
    case Nil{}:
      ""
    case Con{head, rest}:
      head ++ "," ++ joined(rest)

def plan_is(result: Result<&1, &1, U32 & String, Cli.Plan>, expected: List<String>) -> Bool:
  match result:
    case Fail{error}:
      False{}
    case Done{plan}:
      match plan:
        case Cli.Timed{command, args, timeout, input, label}:
          match timeout:
            case None{}:
              False{}
            case Some{ms}:
              String.eq(joined(Cli.canonical(command, args, ms, input, label)), joined(expected))
        case Cli.Pass{args}:
          String.eq(joined(args), joined(expected))

def label_ok(result: Result<&1, &1, U32 & String, String>) -> Bool:
  match result:
    case Fail{error}:
      False{}
    case Done{text}:
      True{}

def check(tests: List<&2, Bool>, n: Nat) -> IO(Unit):
  match tests:
    case Nil{}:
      IO.print("native timer policy assertions: " ++ Nat.show(n))
    case Con{True{}, rest}:
      check(rest, 1n+n)
    case Con{False{}, rest}:
      IO.die(Unit, 1, "timer policy failed at " ++ Nat.show(n))

# Two lists: one literal of every check exceeds the compiler's arity limit.
def timers() -> List<&2, Bool>:
  [
    U32.is_eq(Time.work_default(), 3600000),
    U32.is_eq(Time.jev_default(), 30000),
    U32.is_eq(Time.wait_default(), 30000),
    U32.is_eq(Time.watch_default(), 5000),
    ms_is(Time.config("", 50, 100), 50),
    ms_is(Time.parse("00060", 100), 60),
    ms_is(Time.parse("3600000", 3600000), 3600000),
    bad_ms(Time.parse("0", 3600000)),
    bad_ms(Time.parse("-1", 3600000)),
    bad_ms(Time.parse("1.5", 3600000)),
    bad_ms(Time.parse("3600001", 3600000)),
    bad_ms(Time.parse("4294967297", 3600000)),
    bad_ms(Time.parse("300001", 300000)),
    Nat.is_eq(Time.remaining(Time.Budget{100n, 300n}, 200n), 200n),
    Nat.is_eq(Time.remaining(Time.Budget{100n, 300n}, 400n), 0n),
    Nat.is_eq(Time.remaining(Time.Budget{100n, 300n}, 500n), 0n),
    U32.is_eq(Time.cap(200n, 50), 50),
    U32.is_eq(Time.cap(50n, 200), 50),
    U32.is_eq(Time.cap(Nat.add(4294967295n, 2n), 100), 100),
    bad_cli(Cli.parse(["exec", "--timeout-ms", "3", "--timeout-ms", "4", "/bin/echo"])),
    bad_cli(Cli.parse(["exec", "--timeout-ms", "3", "4", "/bin/echo"])),
    bad_cli(Cli.parse(["start", "--stdin", "/bin/echo"])),
    bad_cli(Cli.parse(["exec", "--timeout-ms"])),
    bad_cli(Cli.parse(["watch", "id", "300001", "ready"])),
    U32.is_eq(Time.job_max(), 86400000),
    ms_is(Time.parse("86400000", Time.job_max()), 86400000),
    bad_ms(Time.parse("86400001", Time.job_max())),
    bad_ms(Time.parse("99999999", 3600000))
  ]

def cli() -> List<&2, Bool>:
  [
    plan_is(Cli.parse(["start", "--timeout-ms", "86400000", "/bin/echo"]), ["__start", "86400000", "", "", "batch", "/bin/echo"]),
    bad_cli(Cli.parse(["start", "--timeout-ms", "86400001", "/bin/echo"])),
    bad_cli(Cli.parse(["exec", "--timeout-ms", "3600001", "/bin/echo"])),
    bad_cli(Cli.parse(["wait", "--timeout-ms", "86400000", "id"])),
    plan_is(Cli.parse(["start", "--label", "dev server", "--timeout-ms", "5", "--", "--label"]), ["__start", "5", "dev server", "", "batch", "--label"]),
    plan_is(Cli.parse(["start", "--cwd", "/srv/app", "--timeout-ms", "5", "/bin/echo"]), ["__start", "5", "", "/srv/app", "batch", "/bin/echo"]),
    bad_cli(Cli.parse(["start", "--cwd", "relative", "/bin/echo"])),
    bad_cli(Cli.parse(["start", "--cwd", "/a", "--cwd", "/b", "/bin/echo"])),
    bad_cli(Cli.parse(["wait", "--cwd", "/a", "id"])),
    U32.is_eq(Cli.max("serve"), 86400000),
    plan_is(Cli.parse(["start", "--input", "pipe", "--timeout-ms", "5", "/bin/cat"]), ["__start", "5", "", "", "pipe", "/bin/cat"]),
    bad_cli(Cli.parse(["start", "--input", "file", "/bin/cat"])),
    bad_cli(Cli.parse(["exec", "--input", "pipe", "/bin/cat"])),
    bad_cli(Cli.parse(["serve", "--timeout-ms", "86400001"])),
    bad_cli(Cli.parse(["start", "--label", "a", "--label", "b", "/bin/echo"])),
    bad_cli(Cli.parse(["exec", "--label", "a", "/bin/echo"])),
    bad_cli(Cli.parse(["start", "--label", "", "/bin/echo"])),
    bad_cli(Cli.parse(["start", "--label", "two\nlines", "/bin/echo"])),
    bad_cli(Cli.parse(["start", "--label"])),
    label_ok(Cli.label_checked(String.repeat("é", 120n))),
    Bool.not(label_ok(Cli.label_checked(String.repeat("x", 121n)))),
    Bool.not(label_ok(Cli.label_checked(SCon{Char.from_u32(9), "tab"}))),
    Bool.not(label_ok(Cli.label_checked(SCon{Char.from_u32(133), "next line"}))),
    Bool.not(label_ok(Cli.label_checked(SCon{Char.from_u32(8232), "separator"}))),
    label_ok(Cli.optional_label("")),
    plan_is(Cli.parse(["events", "id"]), ["events", "id"]),
    plan_is(Cli.parse(["events", "--timeout-ms", "500", "id", "7"]), ["events", "id", "7", "500"]),
    plan_is(Cli.parse(["events", "--timeout-ms", "500", "id"]), ["events", "id", "0", "500"]),
    bad_cli(Cli.parse(["events", "--timeout-ms", "300001", "id"])),
    plan_is(Cli.parse(["follow", "--timeout-ms", "250", "id", "3"]), ["follow", "250", "id", "3"]),
    bad_cli(Cli.parse(["follow", "id", "1", "2"]))
  ]

def main() -> IO(Unit):
  check(List.append(&2, Bool, timers(), cli()), 0n)
