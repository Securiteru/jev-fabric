import Base
import ./Process.bend as Process
import ./Host.bend as Host
import ./Time.bend as Time

def Error() -> Type:
  U32 & String

def Outcome() -> Type:
  Result<&1, &1, Error, Process.Report>

def Written() -> Type:
  Result<&1, &1, Error, Unit>

def Bytes() -> Type:
  Result<&1, &1, Error, List<&2, U32>>

# Affine stdin, two independent readers, and a join channel. Reads preserve
# first-byte spools, not an unlimited/lossless protocol: check spool_limit().
type Session is Type:
  Session{stdin: Maybe<&1, File>, stdout: File, stderr: File, result: Chan(Outcome)}

def mapped(raw: Result<&1, &1, Error, Process.Raw>) -> Outcome:
  match raw:
    case Fail{error}:
      Fail{error}
    case Done{value}:
      Done{Process.decode(value)}

def supervised(
  argv: List<String>,
  timeout: U32,
  input: File,
  stdout: File,
  stderr: File,
) -> IO(Outcome):
  do IO<Outcome>:
    raw : Result<&1, &1, Error, Process.Raw> <- Process.Native.exec_pipe(
      argv,
      input,
      timeout,
      stdout,
      stderr,
      False{},
      "",
    )
    return mapped(raw)

def opened(
  pair: File & File,
  argv: List<String>,
  timeout: U32,
  out: File,
  err: File,
  out_read: File,
  err_read: File,
) -> IO(Session):
  (input, writer) = pair
  do IO<Session>:
    result : Chan(Outcome) <- IO.fork(Outcome, supervised(argv, timeout, input, out, err))
    return Session{Some{writer}, out_read, err_read, result}

# Launch errors are recoverable through wait. Close/wait even after write errors.
def start(argv: List<String>, timeout: U32) -> IO(Session):
  do IO<Session>:
    +id : String <- Host.create(1024)
    out : File <- Host.spool(id, "stdout.bin", True{})
    err : File <- Host.spool(id, "stderr.bin", True{})
    out_read : File <- Host.spool(id, "stdout.bin", False{})
    err_read : File <- Host.spool(id, "stderr.bin", False{})
    pair : File & File <- IO.try(File & File, Process.pipe())
    opened(pair, argv, timeout, out, err, out_read, err_read)

# Choose a lifetime once; writes and reads never renew it.
def open(argv: List<String>) -> IO(Session):
  do IO<Session>:
    ms : U32 <- Time.work()
    start(argv, ms)

def wrote(pair: File & Written) -> Maybe<&1, File> & Written:
  (file, result) = pair
  (Some{file}, result)

def write_stdin(target: Maybe<&1, File>, text: String) -> IO(Maybe<&1, File> & Written):
  match target:
    case None{}:
      IO.pure(Maybe<&1, File> & Written, (None{}, Fail{(1, "session stdin is closed")}))
    case Some{file}:
      do IO<Maybe<&1, File> & Written>:
        pair : File & Written <- File.write(file, text)
        return wrote(pair)

def written(
  pair: Maybe<&1, File> & Written,
  stdout: File,
  stderr: File,
  result: Chan(Outcome),
) -> Session & Written:
  (stdin, outcome) = pair
  (Session{stdin, stdout, stderr, result}, outcome)

def write_open(session: Session, text: String) -> IO(Session & Written):
  match session:
    case Session{stdin, stdout, stderr, result}:
      do IO<Session & Written>:
        pair : Maybe<&1, File> & Written <- write_stdin(stdin, text)
        return written(pair, stdout, stderr, result)

def write_allowed(session: Session, text: String, allowed: Bool) -> IO(Session & Written):
  match allowed:
    case False{}:
      IO.pure(Session & Written, (session, Fail{(1, "session write exceeds 65536 characters")}))
    case True{}:
      write_open(session, text)

def write(session: Session, +text: String) -> IO(Session & Written):
  write_allowed(session, text, Nat.is_le(String.length(text), 65536n))

def close_stdin(target: Maybe<&1, File>) -> IO(Unit):
  match target:
    case None{}:
      IO.pure(Unit, Unit{})
    case Some{file}:
      File.close(file)

# Idempotent; preserves output readers and the join channel.
def close_input(session: Session) -> IO(Session):
  match session:
    case Session{stdin, stdout, stderr, result}:
      do IO<Session>:
        close_stdin(stdin)
        return Session{None{}, stdout, stderr, result}

def spool_limit() -> U32:
  1048576

def read_bounded(file: File, offset: U32, max: U32, allowed: Bool) -> IO(File & Bytes):
  match allowed:
    case True{}:
      File.read_at(file, offset, max)
    case False{}:
      message : String = "session read requires offset <= 1048576 and max <= 65536"
      IO.pure(File & Bytes, (file, Fail{(1, message)}))

def read_allowed(+offset: U32, +max: U32) -> Bool:
  U32.is_le(max, 65536) && U32.is_le(offset, spool_limit())

def read_done(
  pair: File & Bytes,
  stdin: Maybe<&1, File>,
  other: File,
  result: Chan(Outcome),
  error_stream: Bool,
) -> Session & Bytes:
  (file, outcome) = pair
  match error_stream:
    case False{}:
      (Session{stdin, file, other, result}, outcome)
    case True{}:
      (Session{stdin, other, file, result}, outcome)

def read_stdout(session: Session, +offset: U32, +max: U32) -> IO(Session & Bytes):
  match session:
    case Session{stdin, stdout, stderr, result}:
      do IO<Session & Bytes>:
        pair : File & Bytes <- read_bounded(stdout, offset, max, read_allowed(offset, max))
        return read_done(pair, stdin, stderr, result, False{})

def read_stderr(session: Session, +offset: U32, +max: U32) -> IO(Session & Bytes):
  match session:
    case Session{stdin, stdout, stderr, result}:
      do IO<Session & Bytes>:
        pair : File & Bytes <- read_bounded(stderr, offset, max, read_allowed(offset, max))
        return read_done(pair, stdin, stdout, result, True{})

def size_err(
  pair: File & Result<&1, &1, Error, U32>,
  stdin: Maybe<&1, File>,
  stdout: File,
  result: Chan(Outcome),
  count_out: U32,
) -> IO(Session & (U32 & U32)):
  (stderr, value) = pair
  do IO<Session & (U32 & U32)>:
    count_err : U32 <- IO.pass(U32, value)
    return (Session{stdin, stdout, stderr, result}, (count_out, count_err))

def size_out(
  pair: File & Result<&1, &1, Error, U32>,
  stdin: Maybe<&1, File>,
  stderr: File,
  result: Chan(Outcome),
) -> IO(Session & (U32 & U32)):
  (stdout, value) = pair
  do IO<Session & (U32 & U32)>:
    count_out : U32 <- IO.pass(U32, value)
    next : File & Result<&1, &1, Error, U32> <- File.size(stderr)
    size_err(next, stdin, stdout, result, count_out)

# Reaching the first-byte cap means the stream may be clipped. A final Report
# separately discloses truncated 32 KiB tails. Empty live reads do not mean EOF.
def status(session: Session) -> IO(Session & (U32 & U32)):
  match session:
    case Session{stdin, stdout, stderr, result}:
      do IO<Session & (U32 & U32)>:
        pair : File & Result<&1, &1, Error, U32> <- File.size(stdout)
        size_out(pair, stdin, stderr, result)

def wait(session: Session) -> IO(Outcome):
  match session:
    case Session{stdin, stdout, stderr, result}:
      do IO<Outcome>:
        close_stdin(stdin)
        outcome : Outcome <- IO.join(Outcome, result)
        File.close(stdout)
        File.close(stderr)
        return outcome

# Sticky cancellation of every child owned by this native process, not one Session.
def cancel_scope() -> IO(Unit):
  Process.cancel(15)
