import Base
import ./TimeCore.bend as Policy
import ./Time.bend as Time
import ./Process.bend as Process
import ./Session.bend as Session
import ./Jev.bend as Jev
import ./JevCore.bend as JevPolicy
import ./Core.bend as Core

# A shared deadline budget, not a separate OS ownership/cancellation group.
def Budget() -> Data:
  Policy.Budget

def Started() -> Type:
  Result<&1, &1, Session.Error, Session.Session>

def with_timeout(ms: U32) -> IO(Budget):
  do IO<Budget>:
    valid : U32 <- IO.pass(U32, Policy.parsed(Some{ms}, Time.max_timeout()))
    now : Nat <- IO.now()
    return Policy.Budget{now, U32.to_nat(valid)}

def open() -> IO(Budget):
  do IO<Budget>:
    ms : U32 <- Time.work()
    with_timeout(ms)

def remaining(scope: Budget, cap: U32) -> IO(U32):
  do IO<U32>:
    valid : U32 <- IO.pass(U32, Policy.parsed(Some{cap}, Time.max_timeout()))
    now : Nat <- IO.now()
    return Policy.cap(Policy.remaining(scope, now), valid)

def run_ready(argv: List<String>, input: String, ms: U32, expired: Bool) -> IO(Process.Report):
  match expired:
    case True{}:
      timed_out : Process.Report = Process.Report{124, True{}, False{}, False{}, False{}, "", ""}
      IO.pure(Process.Report, timed_out)
    case False{}:
      Process.run_input(argv, input, ms)

def run_for(scope: Budget, argv: List<String>, input: String, cap: U32) -> IO(Process.Report):
  do IO<Process.Report>:
    +ms : U32 <- remaining(scope, cap)
    run_ready(argv, input, ms, U32.is_eq(ms, 0))

def run(scope: Budget, argv: List<String>, input: String) -> IO(Process.Report):
  run_for(scope, argv, input, Time.max_timeout())

def exec(scope: Budget, argv: List<String>) -> IO(Process.Report):
  run(scope, argv, "")

def start_ready(argv: List<String>, ms: U32, expired: Bool) -> IO(Started):
  match expired:
    case True{}:
      IO.pure(Started, Fail{(124, "scope deadline expired before session start")})
    case False{}:
      do IO<Started>:
        session : Session.Session <- Session.start(argv, ms)
        return Done{session}

def start_for(scope: Budget, argv: List<String>, cap: U32) -> IO(Started):
  do IO<Started>:
    +ms : U32 <- remaining(scope, cap)
    start_ready(argv, ms, U32.is_eq(ms, 0))

def start(scope: Budget, argv: List<String>) -> IO(Started):
  start_for(scope, argv, Time.max_timeout())

def settings_timeout(settings: JevPolicy.Settings, ms: U32) -> JevPolicy.Settings:
  match settings:
    case JevPolicy.Settings{endpoint, model, command, timeout}:
      JevPolicy.Settings{endpoint, model, command, ms}

def restore_client(client: Jev.Client, settings: JevPolicy.Settings) -> Jev.Client:
  match client:
    case JevPolicy.Client{previous, budget, key}:
      JevPolicy.Client{settings, budget, key}

def restored(result: Jev.Returned, settings: JevPolicy.Settings) -> Jev.Returned:
  (client, response) = result
  (restore_client(client, settings), response)

# Evaluate with the client's timeout lowered to `ms`, then hand back its original settings.
def evaluate_ready(
  +settings: JevPolicy.Settings,
  budget: Core.Budget,
  key: String,
  request: String,
  ms: U32,
  expired: Bool,
) -> IO(Jev.Returned):
  match expired:
    case True{}:
      error : U32 & String = (124, "scope deadline expired before Jev evaluation")
      IO.pure(Jev.Returned, JevPolicy.returned(settings, budget, key, Fail{error}))
    case False{}:
      do IO<Jev.Returned>:
        client : Jev.Client = JevPolicy.Client{settings_timeout(settings, ms), budget, key}
        result : Jev.Returned <- Jev.evaluate(client, request)
        return restored(result, settings)

def evaluate_scoped(
  scope: Budget,
  client: Jev.Client,
  request: String,
  cap: U32,
) -> IO(Jev.Returned):
  match client:
    case JevPolicy.Client{+settings, budget, key}:
      do IO<Jev.Returned>:
        +ms : U32 <- remaining(scope, U32.min(cap, JevPolicy.timeout(settings)))
        evaluate_ready(settings, budget, key, request, ms, U32.is_eq(ms, 0))

def evaluate_for(
  scope: Budget,
  client: Jev.Client,
  request: String,
  cap: U32,
) -> IO(Jev.Returned):
  do IO<Jev.Returned>:
    valid : U32 <- IO.pass(U32, Policy.parsed(Some{cap}, Time.max_timeout()))
    evaluate_scoped(scope, client, request, valid)

def evaluate(scope: Budget, client: Jev.Client, request: String) -> IO(Jev.Returned):
  evaluate_for(scope, client, request, Time.max_timeout())
