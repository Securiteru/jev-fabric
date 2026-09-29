import Base
import ../Process.bend as Process
import ../Session.bend as Session
import ../Scope.bend as Scope
import ../Jev.bend as Jev
import ../JevCore.bend as Policy
import ../Core.bend as Core
import ../Codec.bend as Codec

def assert(ok: Bool) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "timer fixture assertion failed")

def print_written(pair: Session.Session & Session.Written) -> IO(Unit):
  (session, result) = pair
  do IO<Unit>:
    IO.pass(Unit, result)
    report : Process.Report <- IO.try(Process.Report, Session.wait(session))
    IO.print(Process.show(report))

def print_timeout(client: Jev.Client) -> IO(Unit):
  match client:
    case Policy.Client{settings, budget, key}:
      IO.print(U32.show(Policy.timeout(settings)))

def defaults() -> IO(Unit):
  do IO<Unit>:
    report : Process.Report <- Process.exec_input(["/bin/cat"], "buffered\n")
    IO.print(Process.show(report))
    session : Session.Session <- Session.open(["/bin/cat"])
    written : Session.Session & Session.Written <- Session.write(session, "session\n")
    print_written(written)
    client : Jev.Client <- IO.try(Jev.Client, Jev.connect(2, 100))
    print_timeout(client)
    budget : Scope.Budget <- Scope.open()
    scoped : Process.Report <- Scope.exec(budget, ["/bin/echo", "scoped-default"])
    IO.print(Process.show(scoped))

def expired_session(result: Result<&1, &1, Session.Error, Session.Session>) -> IO(Unit):
  match result:
    case Fail{error}:
      (code, message) = error
      do IO<Unit>:
        assert(U32.is_eq(code, 124))
        IO.print("expired session: no launch")
    case Done{session}:
      do IO<Unit>:
        ignored : Session.Outcome <- Session.wait(session)
        IO.die(Unit, 1, "expired session unexpectedly launched")

def unused_budget(budget: Core.Budget) -> IO(Unit):
  match budget:
    case Core.Budget{remaining, used, spent, limit}:
      assert(Nat.is_eq(remaining, 2n) && Nat.is_eq(used, 0n))

def unused_client(client: Jev.Client) -> IO(Unit):
  match client:
    case Policy.Client{settings, budget, key}:
      unused_budget(budget)

def expired_answer(answer: Jev.Evaluation) -> IO(Unit):
  match answer:
    case Fail{error}:
      (code, message) = error
      assert(U32.is_eq(code, 124))
    case Done{value}:
      IO.die(Unit, 1, "expired evaluation dispatched")

def expired_evaluation(result: Jev.Returned) -> IO(Unit):
  (client, answer) = result
  do IO<Unit>:
    unused_client(client)
    expired_answer(answer)
    IO.print("expired Jev: no reservation")

# Prints its own PID so the test can prove the deadline reaped it.
def pid_sleeper() -> List<String>:
  ["/bin/sh", "-c", "printf '%s\\n' \"$$\"; exec sleep 60"]

# Must never launch: the test asserts the marker file stays absent.
def touch(marker: String) -> List<String>:
  ["/bin/sh", "-c", "touch \"$1\"", "sh", marker]

# The budgets here and in `scope` leave ~250 ms per OS timer overshoot (macOS sleeps can run
# that late) plus time for a sleeper to print its PID before the shared deadline reaps it.
def active_session() -> IO(Unit):
  do IO<Unit>:
    budget : Scope.Budget <- Scope.with_timeout(600)
    IO.sleep(80)
    session : Session.Session <- IO.try(Session.Session, Scope.start(budget, pid_sleeper()))
    report : Process.Report <- IO.try(Process.Report, Session.wait(session))
    IO.print(Process.show(report))

def scope(+marker: String) -> IO(Unit):
  do IO<Unit>:
    +budget : Scope.Budget <- Scope.with_timeout(1000)
    IO.sleep(100)
    first : Process.Report <- Scope.run_for(budget, pid_sleeper(), "", 100)
    IO.print(Process.show(first))
    second : Process.Report <- Scope.exec(budget, pid_sleeper())
    IO.print(Process.show(second))
    IO.sleep(30)
    third : Process.Report <- Scope.exec(budget, touch(marker))
    IO.print(Process.show(third))
    session : Result<&1, &1, Session.Error, Session.Session> <- Scope.start(budget, touch(marker))
    expired_session(session)
    client : Jev.Client <- IO.try(Jev.Client, Jev.connect(2, 100))
    result : Jev.Returned <- Scope.evaluate(budget, client, "{}")
    expired_evaluation(result)
    active_session()

def shown(result: Jev.Returned) -> IO(Jev.Client):
  (client, answer) = result
  do IO<Jev.Client>:
    value : Codec.Value <- IO.pass(Codec.Value, answer)
    text : String <- IO.pass(String, Codec.encode(value))
    IO.print(text)
    return client

def scope_jev(+request: String) -> IO(Unit):
  do IO<Unit>:
    +budget : Scope.Budget <- Scope.with_timeout(2000)
    client : Jev.Client <- IO.try(Jev.Client, Jev.connect(2, 100))
    first : Jev.Returned <- Scope.evaluate_for(budget, client, request, 500)
    next : Jev.Client <- shown(first)
    IO.sleep(50)
    second : Jev.Returned <- Scope.evaluate(budget, next, request)
    last : Jev.Client <- shown(second)
    print_timeout(last)

def dispatch(args: List<String>) -> IO(Unit):
  match args:
    case Con{"defaults", Nil{}}:
      defaults()
    case Con{"scope", Con{marker, Nil{}}}:
      scope(marker)
    case Con{"jev", Con{request, Nil{}}}:
      scope_jev(request)
    case other:
      IO.die(Unit, 2, "invalid timer fixture mode")

def main() -> IO(Unit):
  do IO<Unit>:
    # IO.args() starts with the program as invoked (Bend 2.0.32+).
    invoked : List<String> <- IO.args()
    args : List<String> = List.drop(&1, String, invoked, 1n)
    dispatch(args)
