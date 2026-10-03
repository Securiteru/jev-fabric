import Base
import ./Process.bend as Process
import ./Jobs.bend as Jobs
import ./Monitor.bend as Monitor
import ./Runner.bend as Runner
import ./Input.bend as Input
import ./Codec.bend as Codec
import ./Wire.bend as Wire
import ./Jev.bend as Jev
import ./Cli.bend as Cli
import ./Time.bend as Time
import ./Serve.bend as Serve
import ./ServeCore.bend as ServeCore
import ./Host.bend as Host

def finish(code: U32, ok: Bool) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, code, "subprocess did not complete successfully")

def directory_checked(result: Result<&1, &1, U32 & String, String>) -> IO(Unit):
  match result:
    case Fail{e}:
      IO.die(Unit, 2, "cwd must be an existing directory")
    case Done{ok}:
      IO.pure(Unit, Unit{})

# An empty cwd inherits this process's; any other must be an existing directory.
def cwd_checked(cwd: String) -> IO(Unit):
  match cwd:
    case SNil{}:
      IO.pure(Unit, Unit{})
    case other:
      do IO<Unit>:
        found : Result<&1, &1, U32 & String, String> <- Host.directory(other)
        directory_checked(found)

def execute(argv: List<String>, timeout: Maybe<&2, U32>, inherit_stdin: Bool, +cwd: String) -> IO(Unit):
  match timeout:
    case None{}:
      IO.die(Unit, 2, "timeout must be an integer from 1 to 3600000 milliseconds")
    case Some{ms}:
      do IO<Unit>:
        cwd_checked(cwd)
        +result : Process.Report <- Process.run_in(argv, "", ms, inherit_stdin, cwd)
        IO.print(Process.show(result))
        +code : U32 = Process.exit_code(result)
        finish(code, U32.is_eq(code, 0))

def print_value(value: Codec.Value) -> IO(Unit):
  do IO<Unit>:
    text : String <- IO.pass(String, Codec.encode(value))
    IO.print(text)

def evaluated(result: Jev.Returned) -> IO(Unit):
  (client, response) = result
  do IO<Unit>:
    value : Codec.Value <- IO.pass(Codec.Value, response)
    print_value(value)

def evaluate_file(path: String, timeout: Maybe<&2, U32>, tokens: Maybe<&2, U32>) -> IO(Unit):
  match timeout tokens:
    case Some{ms} Some{limit}:
      do IO<Unit>:
        request : String <- IO.try(String, Input.read(path))
        client : Jev.Client <- IO.try(Jev.Client, Jev.from_env(ms, 1, limit))
        result : Jev.Returned <- Jev.evaluate(client, request)
        evaluated(result)
    case _ _:
      IO.die(Unit, 2, "Jev timeout and token limit must be integers")

def validate_file(path: String) -> IO(Unit):
  do IO<Unit>:
    text : String <- IO.try(String, Input.read(path))
    value : Codec.Value <- IO.pass(Codec.Value, Wire.request(text))
    print_value(value)

def usage_text() -> String:
  "jev-fabric native Bend\n"
    ++ "usage: jev-fabric -- <command>\n"
    ++ "  exec [--timeout-ms N] [--stdin] [--cwd DIR] [--] <command> [args...]\n"
    ++ "  run [--timeout-ms N] [--] <program.bend> [args...]\n"
    ++ "  validate <request.json>\n"
    ++ "  jev [--timeout-ms N] <request.json> [max-tokens]\n"
    ++ "  start [--timeout-ms N] [--label TEXT] [--cwd DIR] [--] <command> [args...]\n"
    ++ "  status <id> | list | events [--timeout-ms N] <id> [after-sequence]\n"
    ++ "  follow [--timeout-ms N] <id> [after-sequence] (live JSONL events)\n"
    ++ "  watch [--timeout-ms N] <id> <literal>\n"
    ++ "  wait [--timeout-ms N] <id> | stop <id>\n"
    ++ "  serve [--timeout-ms N] [max-evaluations [max-tokens]] (JSONL session on stdin/stdout)\n"
    ++ "  capabilities (version, protocol, store format, platform and features, as JSON)\n"
    ++ "  update (reinstall the latest release via curl | sh)\n"
    ++ "Defaults: work 1h, Jev 30s, wait 30s, follow 30s, watch 5s; start and serve allow up to 24h.\n"
    ++ "Timers are ceilings, not delays.\n"
    ++ "Configure JEV_FABRIC_TIMEOUT_MS, JEV_FABRIC_JEV_TIMEOUT_MS,"
    ++ " JEV_FABRIC_WAIT_MS, JEV_FABRIC_WATCH_MS.\n"
    ++ "Legacy positional milliseconds remain supported."
    ++ " Prefix options stop at the command/file; -- escapes numeric command names.\n"
    ++ "Native trusted code, not a sandbox. Shell interpretation is explicit.\n"
    ++ "Jev uses provider environment credentials or JEV_CREDENTIAL_COMMAND,"
    ++ " pooled system libcurl (JEV_FABRIC_HTTP=exec: one curl per request),"
    ++ " and no automatic retries."

# `update` reinstalls the latest release the way `bend update` does: it shows the
# exact command, runs it, and exits with its status. JEV_FABRIC_PREFIX and
# JEV_FABRIC_VERSION pass through to the installer.
def update_command() -> String:
  "curl -fsSL https://raw.githubusercontent.com/fabric-runtime/jev-fabric/main/install.sh | sh"

# Ten minutes covers a slow download; the installer itself takes seconds.
def update_timeout() -> U32:
  600000

# Base has no raw stderr write; print_err adds the final newline back.
def relay_err(+text: String, empty: Bool) -> IO(Unit):
  match empty:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.print_err(String.trim_end(text))

def updated(report: Process.Report) -> IO(Unit):
  match report:
    case Process.Report{+code, timed_out, cancelled, out_cut, err_cut, stdout, +stderr}:
      do IO<Unit>:
        IO.write(stdout)
        relay_err(stderr, String.is_empty(stderr))
        finish(code, U32.is_eq(code, 0))

def update() -> IO(Unit):
  do IO<Unit>:
    IO.print_err(update_command())
    report : Process.Report <- Process.run_input(["/bin/sh", "-c", update_command()], "", update_timeout())
    updated(report)

def usage() -> IO(Unit):
  IO.print(usage_text())

def capabilities() -> IO(Unit):
  do IO<Unit>:
    platform : String <- Host.platform()
    IO.print(ServeCore.capabilities(Cli.version(), platform))

def dispatch(args: List<String>) -> IO(Unit):
  match args:
    case Nil{}:
      usage()
    case Con{"--help", Nil{}}:
      usage()
    case Con{"--version", Nil{}}:
      IO.print(Cli.version() ++ " (Bend 2.0.34)")
    case Con{"update", Nil{}}:
      update()
    case Con{"capabilities", Nil{}}:
      capabilities()
    case Con{"exec", Con{timeout, Con{"--stdin", Con{command, rest}}}}:
      execute(Con{command, rest}, U32.read(timeout), True{}, "")
    case Con{"exec", Con{timeout, Con{command, rest}}}:
      execute(Con{command, rest}, U32.read(timeout), False{}, "")
    case Con{"run", Con{timeout, Con{source, rest}}}:
      Runner.run(U32.read(timeout), source, rest)
    case Con{"watch", rest}:
      Monitor.command(Con{"watch", rest})
    case Con{"serve", Con{timeout, rest}}:
      Serve.serve(U32.read(timeout), rest)
    case Con{"validate", Con{path, Nil{}}}:
      validate_file(path)
    case Con{"jev", Con{timeout, Con{path, Nil{}}}}:
      evaluate_file(path, U32.read(timeout), Some{100000})
    case Con{"jev", Con{timeout, Con{path, Con{tokens, Nil{}}}}}:
      evaluate_file(path, U32.read(timeout), U32.read(tokens))
    case args:
      Jobs.command(args)

def default_timeout(command: String) -> IO(U32):
  match command:
    case "jev":
      Time.jev()
    case "wait":
      Time.wait()
    case "follow":
      Time.wait()
    case "watch":
      Time.watch()
    case other:
      Time.work()

def selected_timeout(command: String, timeout: Maybe<&2, U32>) -> IO(U32):
  match timeout:
    case Some{ms}:
      IO.pure(U32, ms)
    case None{}:
      default_timeout(command)

def execute_plan(command: String, args: List<String>, ms: U32, input: Bool, +launch: Cli.Launch) -> IO(Unit):
  match command:
    case "exec":
      execute(args, Some{ms}, input, Cli.launch_cwd(launch))
    case other:
      dispatch(Cli.canonical(other, args, ms, input, launch))

def planned(plan: Cli.Plan) -> IO(Unit):
  match plan:
    case Cli.Pass{args}:
      dispatch(args)
    case Cli.Timed{+command, args, timeout, input, launch}:
      do IO<Unit>:
        ms : U32 <- selected_timeout(command, timeout)
        execute_plan(command, args, ms, input, launch)

def normalized(result: Result<&1, &1, U32 & String, Cli.Plan>) -> IO(Unit):
  match result:
    case Fail{error}:
      (code, message) = error
      IO.die(Unit, code, message)
    case Done{plan}:
      planned(plan)

def main() -> IO(Unit):
  do IO<Unit>:
    # IO.args() starts with the program as invoked (Bend 2.0.32+).
    invoked : List<String> <- IO.args()
    args : List<String> = List.drop(&1, String, invoked, 1n)
    normalized(Cli.parse(args))
