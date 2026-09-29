import Base
import ./Json.bend as Json
import ./Time.bend as Time

def Raw() -> Type:
  U32 & (U32 & (String & String))

# Custom foreign effects. These are native C, not JavaScript. A `cwd` is an
# absolute directory the child starts in, or "" to inherit this process's.
def Native.exec(
  argv: List<String>,
  input: String,
  timeout_ms: U32,
  inherit_stdin: Bool,
  cwd: String,
) -> IO(Result<&1, &1, U32 & String, Raw>):
  import "./posix.c"

def RawBytes() -> Type:
  U32 & (U32 & (List<&2, U32> & List<&2, U32>))

# Bounded byte-exact private capture. Callers must reject either truncation flag.
def Native.capture(
  argv: List<String>,
  input: String,
  timeout_ms: U32,
  limit: U32,
) -> IO(Result<&1, &1, U32 & String, RawBytes>):
  import "./posix.c"

def capture(
  argv: List<String>,
  input: String,
  timeout_ms: U32,
  limit: U32,
) -> IO(Result<&1, &1, U32 & String, RawBytes>):
  Native.capture(argv, input, timeout_ms, limit)

# One CLOEXEC pipe; both ends are independent File handles the caller owns.
def Native.pipe() -> IO(Result<&1, &1, U32 & String, File & File>):
  import "./pipe.c"

def pipe() -> IO(Result<&1, &1, U32 & String, File & File>):
  Native.pipe()

# This process's standard input as an owned File: a CLOEXEC duplicate of fd 0,
# readable whether fd 0 is a pipe, socket, terminal or file. Closing it leaves
# fd 0 open.
def Native.stdin() -> IO(Result<&1, &1, U32 & String, File>):
  import "./pipe.c"

def stdin() -> IO(Result<&1, &1, U32 & String, File>):
  Native.stdin()

# Interrupt this executable's owned process scope, never a persisted arbitrary PID.
def Native.cancel() -> IO(Unit):
  import "./posix.c"

def cancel(signal: U32) -> IO(Unit):
  Native.cancel()

type Report is Data:
  Report{
    code: U32,
    timed_out: Bool,
    cancelled: Bool,
    stdout_cut: Bool,
    stderr_cut: Bool,
    stdout: String,
    stderr: String,
  }

def flag_set(flags: U32, bit: U32) -> Bool:
  U32.is_ne((flags .&. bit : U32), 0)

# Flag bits set by posix.c: 1 timed out, 2 stdout cut, 4 stderr cut, 8 cancelled.
def decode(raw: Raw) -> Report:
  (code, (+flags, (stdout, stderr))) = raw
  timed_out = flag_set(flags, 1)
  cancelled = flag_set(flags, 8)
  stdout_cut = flag_set(flags, 2)
  stderr_cut = flag_set(flags, 4)
  Report{code, timed_out, cancelled, stdout_cut, stderr_cut, stdout, stderr}

# Bend 2.0.28+ Base owns `Process.run`, so the explicit-timer buffered form is
# `run_input`, the counterpart of `exec_input`.
def run_input(argv: List<String>, input: String, timeout_ms: U32) -> IO(Report):
  do IO<Report>:
    raw : Raw <- IO.try(Raw, Native.exec(argv, input, timeout_ms, False{}, ""))
    return decode(raw)

# As run_input or run_stdin, started in `cwd` (absolute, or "" to inherit).
def run_in(argv: List<String>, input: String, timeout_ms: U32, inherit_stdin: Bool, cwd: String) -> IO(Report):
  do IO<Report>:
    raw : Raw <- IO.try(Raw, Native.exec(argv, input, timeout_ms, inherit_stdin, cwd))
    return decode(raw)

# Timer-free convenience; use run for an explicit local override.
def exec_input(argv: List<String>, input: String) -> IO(Report):
  do IO<Report>:
    ms : U32 <- Time.work()
    run_input(argv, input, ms)

def exec(argv: List<String>) -> IO(Report):
  exec_input(argv, "")

def run_stdin(argv: List<String>, timeout_ms: U32) -> IO(Report):
  do IO<Report>:
    raw : Raw <- IO.try(Raw, Native.exec(argv, "", timeout_ms, True{}, ""))
    return decode(raw)

def exec_stdin(argv: List<String>) -> IO(Report):
  do IO<Report>:
    ms : U32 <- Time.work()
    run_stdin(argv, ms)


# Spool the first 1 MiB per stream to owned regular files; retain bounded final tails.
# Both file handles are consumed and closed by the effect, including failure paths.
def Native.exec_logged(
  argv: List<String>,
  timeout_ms: U32,
  stdout: File,
  stderr: File,
  cwd: String,
) -> IO(Result<&1, &1, U32 & String, Raw>):
  import "./posix.c"

# Interactive sibling of exec_logged: input is the read end of a stdin pipe
# the effect consumes and closes; stdout/stderr are spool writer handles it
# consumes too. Deadlines, process-group cleanup and tails match. Spools keep
# the first 1 MiB, or with `rolling` the latest 1 MiB behind a header that
# publishes the bytes written and when the stream ended (see SpoolCore).
def Native.exec_pipe(
  argv: List<String>,
  input: File,
  timeout_ms: U32,
  stdout: File,
  stderr: File,
  rolling: Bool,
  cwd: String,
) -> IO(Result<&1, &1, U32 & String, Raw>):
  import "./posix.c"

def logged_within(
  argv: List<String>,
  timeout_ms: U32,
  stdout: File,
  stderr: File,
  within: Bool,
) -> IO(Report):
  match within:
    case True{}:
      do IO<Report>:
        raw : Raw <- IO.try(Raw, Native.exec_logged(argv, timeout_ms, stdout, stderr, ""))
        return decode(raw)
    case False{}:
      do IO<Report>:
        File.close(stdout)
        File.close(stderr)
        IO.die(Report, 22, "run_logged timeout must be 1..3600000 milliseconds")

# The effect itself admits a detached job's day; this API keeps the hour.
def run_logged(
  argv: List<String>,
  +timeout_ms: U32,
  stdout: File,
  stderr: File,
) -> IO(Report):
  logged_within(argv, timeout_ms, stdout, stderr, U32.is_le(timeout_ms, Time.max_timeout()))

def state_code(success: Bool) -> String:
  match success:
    case True{}:
      "exited"
    case False{}:
      "failed"

def state(code: U32, timed_out: Bool, cancelled: Bool) -> String:
  match timed_out cancelled:
    case True{} cancelled:
      "timed_out"
    case False{} True{}:
      "cancelled"
    case False{} False{}:
      state_code(U32.is_eq(code, 0))

def show(report: Report) -> String:
  match report:
    case Report{+code, +timed_out, +cancelled, out_cut, err_cut, stdout, stderr}:
      "{\"schemaVersion\":1,\"state\":" ++ Json.quote(state(code, timed_out, cancelled))
        ++ ",\"exitCode\":" ++ U32.show(code)
        ++ ",\"timedOut\":" ++ Json.boolean(timed_out)
        ++ ",\"cancelled\":" ++ Json.boolean(cancelled)
        ++ ",\"stdout\":" ++ Json.quote(stdout)
        ++ ",\"stderr\":" ++ Json.quote(stderr)
        ++ ",\"truncated\":{\"stdout\":" ++ Json.boolean(out_cut)
        ++ ",\"stderr\":" ++ Json.boolean(err_cut)
        ++ "}}"

def exit_code(report: Report) -> U32:
  match report:
    case Report{code, timed_out, cancelled, out_cut, err_cut, stdout, stderr}:
      code
