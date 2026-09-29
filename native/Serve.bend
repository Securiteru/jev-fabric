import Base
import ./ServeCore.bend as Core
import ./Cli.bend as Cli
import ./Codec.bend as Codec
import ./Scope.bend as Scope
import ./Jev.bend as Jev
import ./JevCore.bend as JevPolicy
import ./Core.bend as JevBudget
import ./Host.bend as Host
import ./Process.bend as Process
import ./Time.bend as Time
import ./TimeCore.bend as TimePolicy
import ./JobsCore.bend as JobsPolicy
import ./Jobs.bend as Jobs
import ./Spool.bend as Spool
import ./vendor/strict-json/json.bend as J

# `serve`: a JSONL session over stdin/stdout for callers in any language.
#
# Protocol 2 answers requests concurrently. One reader fiber frames stdin into
# lines and hands them to the hub, which owns the session: the affine Jev
# client, the session children and the counts it needs to end cleanly. The hub
# answers quick requests itself and starts a fiber for every other one; each
# fiber prints its own response. Only the event loop prints, so each response
# line is written whole. A session child's stdin belongs to its feeder fiber,
# which applies that child's writes, closes and stops in arrival order.

def Answer() -> Type:
  Result<&1, &1, U32 & String, String>

def Answered() -> Type:
  Jev.Client & Answer

# Fixed for the session: this executable, its deadline, the CLI defaults, the
# hub's inbox and the platform the banner reported.
type Context is Data:
  Context{self: String, scope: Scope.Budget, defaults: Core.Defaults, inbox: Chan(Note), platform: String}

# Requests for one session child's stdin, and the answer of a write in flight.
type Feed is Type:
  FeedWrite{id: J.JSON, text: String}
  FeedClose{id: J.JSON}
  FeedStop{id: J.JSON}
  Wrote{input: File, id: J.JSON, result: Result<&1, &1, U32 & String, Unit>, bytes: Nat}
  FeedEnd{}

type Child is Data:
  Child{id: String, dir: String, feed: Chan(Feed), pending: U32, live: Bool}

# Messages to the hub.
type Note is Type:
  Lines{lines: List<&2, List<&2, U32>>}
  Closed{code: U32, message: String, last: List<&2, List<&2, U32>>}
  Returned{client: Jev.Client}
  Spawned{child: Child}
  Fed{child: String}
  Exited{child: String}
  Finished{}
  Tick{}

def self(context: Context) -> String:
  match context:
    case Context{self, scope, defaults, inbox, platform}:
      self

def scope(context: Context) -> Scope.Budget:
  match context:
    case Context{self, scope, defaults, inbox, platform}:
      scope

def defaults(context: Context) -> Core.Defaults:
  match context:
    case Context{self, scope, defaults, inbox, platform}:
      defaults

def inbox(context: Context) -> Chan(Note):
  match context:
    case Context{self, scope, defaults, inbox, platform}:
      inbox

def platform(context: Context) -> String:
  match context:
    case Context{self, scope, defaults, inbox, platform}:
      platform

def respond(+id: J.JSON, result: Answer) -> IO(Unit):
  IO.print(Core.respond(id, result))

def notify(+context: Context, note: Note) -> IO(Unit):
  do IO<Unit>:
    sent : Bool <- Chan.send(Note, inbox(context), note)
    return Unit{}

# A request fiber prints its answer, then tells the hub it is done.
def answered(+context: Context, +id: J.JSON, result: Answer) -> IO(Unit):
  do IO<Unit>:
    respond(id, result)
    notify(context, Finished{})

# ---------------------------------------------------------------------------
# CLI children: every process and job operation re-enters this executable.

def run_call(call: Core.Call) -> IO(Answer):
  match call:
    case Core.Call{argv, input, timeout, many}:
      do IO<Answer>:
        raw : Result<&1, &1, U32 & String, Process.RawBytes> <- Process.capture(
          Core.owned(argv),
          input,
          timeout,
          Core.capture_max(),
        )
        return Core.outcome(raw, many)

def subprocess(+context: Context, +id: J.JSON, plan: Result<&1, &1, U32 & String, Core.Call>) -> IO(Unit):
  match plan:
    case Fail{e}:
      answered(context, id, Fail{e})
    case Done{call}:
      do IO<Unit>:
        result : Answer <- run_call(call)
        answered(context, id, result)

# ---------------------------------------------------------------------------
# Jev: one affine client, so evaluations run one at a time, in arrival order.

type Queued is Data:
  Queued{id: J.JSON, request: J.JSON, timeout: Maybe<&2, U32>, provider: String, credential: String}

def evaluated(result: Jev.Returned) -> Answered:
  (client, response) = result
  match response:
    case Fail{e}:
      (client, Fail{e})
    case Done{value}:
      (client, Codec.encode(value))

# The session's settings and cached credential come back unchanged; only the
# budget the evaluation spent is kept. A per-request credential is dropped here.
def restored(result: Jev.Returned, settings: JevPolicy.Settings, key: String) -> Jev.Returned:
  (client, response) = result
  match client:
    case JevPolicy.Client{used, budget, spent}:
      (JevPolicy.Client{settings, budget, key}, response)

def model_for(+override: String, fallback: String) -> String:
  JevPolicy.pick_model(override, fallback, String.is_empty(override))

def key_for(+credential: String, fallback: String) -> String:
  Bool.pick(String, String.is_empty(credential), fallback, credential)

def evaluate_routed(
  +context: Context,
  +settings: JevPolicy.Settings,
  budget: JevBudget.Budget,
  key: String,
  route: Result<&1, &1, U32 & String, JevPolicy.Route>,
  request: String,
  +cap: U32,
  +credential: String,
) -> IO(Jev.Returned):
  match route:
    case Fail{e}:
      IO.pure(Jev.Returned, (JevPolicy.Client{settings, budget, key}, Fail{e}))
    case Done{JevPolicy.Route{endpoint, key_env, fallback}}:
      do IO<Jev.Returned>:
        override : String <- Jev.env("JEV_MODEL")
        provider_key : String <- Jev.env(key_env)
        +model : String = model_for(override, fallback)
        chosen : JevPolicy.Settings = JevPolicy.Settings{
          endpoint,
          model,
          JevPolicy.command(settings),
          JevPolicy.timeout(settings),
        }
        client : Jev.Client = JevPolicy.Client{chosen, budget, key_for(credential, provider_key)}
        result : Jev.Returned <- Scope.evaluate_for(scope(context), client, request, cap)
        return restored(result, settings, key)

# A request's own provider and credential apply to that request only.
def evaluate_as(
  +context: Context,
  client: Jev.Client,
  request: String,
  +cap: U32,
  +provider: String,
  +credential: String,
) -> IO(Jev.Returned):
  match client:
    case JevPolicy.Client{+settings, budget, +key}:
      match provider:
        case SNil{}:
          do IO<Jev.Returned>:
            borrowed : Jev.Client = JevPolicy.Client{settings, budget, credential}
            result : Jev.Returned <- Scope.evaluate_for(scope(context), borrowed, request, cap)
            return restored(result, settings, key)
        case other:
          evaluate_routed(context, settings, budget, key, JevPolicy.route(other), request, cap, credential)

def evaluate_request(
  +context: Context,
  client: Jev.Client,
  request: String,
  +cap: U32,
  +provider: String,
  +credential: String,
  plain: Bool,
) -> IO(Answered):
  match plain:
    case True{}:
      do IO<Answered>:
        result : Jev.Returned <- Scope.evaluate_for(scope(context), client, request, cap)
        return evaluated(result)
    case False{}:
      do IO<Answered>:
        result : Jev.Returned <- evaluate_as(context, client, request, cap, provider, credential)
        return evaluated(result)

# Validated here for a precise error; Jev.evaluate validates again before dispatch.
def evaluate_checked(
  +context: Context,
  client: Jev.Client,
  checked: Answer,
  +cap: U32,
  +provider: String,
  +credential: String,
) -> IO(Answered):
  match checked:
    case Fail{e}:
      IO.pure(Answered, (client, Fail{e}))
    case Done{request}:
      +plain = String.is_empty(provider) && String.is_empty(credential)
      evaluate_request(context, client, request, cap, provider, credential, plain)

def jev_timed(+context: Context, client: Jev.Client, queued: Queued, expired: Bool) -> IO(Answered):
  match queued expired:
    case other True{}:
      IO.pure(Answered, (client, Fail{Core.expired()}))
    case Queued{id, request, requested, provider, credential} False{}:
      evaluate_checked(
        context,
        client,
        Core.validated(request),
        Core.or(requested, Time.max_timeout()),
        provider,
        credential,
      )

def jev_answered(+context: Context, +id: J.JSON, answer: Answered) -> IO(Unit):
  (client, result) = answer
  do IO<Unit>:
    respond(id, result)
    notify(context, Returned{client})

def queued_id(queued: Queued) -> J.JSON:
  match queued:
    case Queued{id, request, requested, provider, credential}:
      id

# Runs in its own fiber and hands the client back to the hub when done.
def jev_run(+context: Context, client: Jev.Client, +queued: Queued) -> IO(Unit):
  do IO<Unit>:
    +remaining : U32 <- Scope.remaining(scope(context), Time.max_timeout())
    answer : Answered <- jev_timed(context, client, queued, Bool.not(U32.is_gt(remaining, Core.grace())))
    jev_answered(context, queued_id(queued), answer)

# ---------------------------------------------------------------------------
# Session children. A spawn fiber creates the child's directory, starts its
# worker (this executable, reading the connection's pipe as the child's stdin)
# and waits for it to announce itself; then the same fiber becomes the child's
# feeder. A reaper fiber reports when the worker has exited.

def Raw() -> Type:
  Result<&1, &1, U32 & String, Process.Raw>

def reap(+context: Context, +child: String, outcome: Chan(Raw)) -> IO(Unit):
  do IO<Unit>:
    result : Raw <- IO.join(Raw, outcome)
    notify(context, Exited{child})

# Writes and closes wait their turn behind a write in flight.
type Pending is Data:
  PendingWrite{id: J.JSON, text: String}
  PendingClose{id: J.JSON}

type Feeder is Type:
  Feeder{input: Maybe<&1, File>, busy: Bool, queue: List<&2, Pending>, ending: Bool}

def closed_error() -> U32 & String:
  (1, "session child stdin is closed")

def gone_error() -> U32 & String:
  (1, "session child is no longer reading its input")

def write_answer(+child: String, result: Result<&1, &1, U32 & String, Unit>, +bytes: Nat) -> Answer:
  match result:
    case Fail{e}:
      Fail{gone_error()}
    case Done{ok}:
      Done{Core.write_json(child, bytes, False{})}

def written(pair: File & Result<&1, &1, U32 & String, Unit>, feed: Chan(Feed), +id: J.JSON, +bytes: Nat) -> IO(Unit):
  (file, result) = pair
  do IO<Unit>:
    sent : Bool <- Chan.send(Feed, feed, Wrote{file, id, result, bytes})
    return Unit{}

# A write runs in a fiber of its own, so a child that is not reading never
# holds up a stop; its answer comes back to the feeder, and later writes wait.
def write_fiber(file: File, text: String, feed: Chan(Feed), +id: J.JSON, +bytes: Nat) -> IO(Unit):
  do IO<Unit>:
    pair : File & Result<&1, &1, U32 & String, Unit> <- File.write(file, text)
    written(pair, feed, id, bytes)

def close_input(input: Maybe<&1, File>) -> IO(Unit):
  match input:
    case None{}:
      IO.pure(Unit, Unit{})
    case Some{file}:
      File.close(file)

def fed(+context: Context, +child: String) -> IO(Unit):
  notify(context, Fed{child})

def stopped_wait(+context: Context, +id: J.JSON, +dir: String) -> IO(Unit):
  do IO<Unit>:
    +remaining : U32 <- Scope.remaining(scope(context), Time.max_timeout())
    subprocess(context, id, Core.plan(self(context), Core.Wait{dir, Some{3000}}, defaults(context), remaining))

def stop_marked(+context: Context, +id: J.JSON, +dir: String, marked: Result<&1, &1, U32 & String, String>) -> IO(Unit):
  match marked:
    case Fail{e}:
      answered(context, id, Fail{e})
    case Done{ok}:
      stopped_wait(context, id, dir)

# A stop is applied when it arrives, after the writes before it have started:
# the worker stops the child, and the answer is its receipt.
def stop_fiber(+context: Context, +id: J.JSON, +dir: String) -> IO(Unit):
  do IO<Unit>:
    marked : Result<&1, &1, U32 & String, String> <- Host.put(dir, "stop", "stop")
    stop_marked(context, id, dir, marked)

# Starts one write or close; the feeder is not busy.
def apply(+context: Context, +child: String, feed: Chan(Feed), item: Pending, state: Feeder) -> IO(Feeder):
  match item state:
    case PendingWrite{+id, text} Feeder{None{}, busy, queue, ending}:
      do IO<Feeder>:
        respond(id, Fail{closed_error()})
        fed(context, child)
        return Feeder{None{}, busy, queue, ending}
    case PendingWrite{+id, +text} Feeder{Some{file}, busy, queue, ending}:
      do IO<Feeder>:
        IO.spawn(Unit, write_fiber(file, text, feed, id, Core.utf8_bytes(text)))
        return Feeder{None{}, True{}, queue, ending}
    case PendingClose{+id} Feeder{input, busy, queue, ending}:
      do IO<Feeder>:
        close_input(input)
        respond(id, Done{Core.write_json(child, 0n, True{})})
        fed(context, child)
        return Feeder{None{}, busy, queue, ending}

# Starts queued requests in order until one is in flight again.
def drain(+context: Context, +child: String, +feed: Chan(Feed), items: List<&2, Pending>, state: Feeder) -> IO(Feeder):
  match items:
    case Nil{}:
      IO.pure(Feeder, state)
    case Con{item, rest}:
      match state:
        case Feeder{input, True{}, queue, ending}:
          IO.pure(Feeder, Feeder{input, True{}, Con{item, rest}, ending})
        case Feeder{input, False{}, queue, ending}:
          do IO<Feeder>:
            next : Feeder <- apply(context, child, feed, item, Feeder{input, False{}, queue, ending})
            drain(context, child, feed, rest, next)

# A request queues behind a write in flight or earlier queued requests.
def arrive(+context: Context, +child: String, feed: Chan(Feed), item: Pending, state: Feeder) -> IO(Feeder):
  match state:
    case Feeder{input, False{}, Nil{}, ending}:
      apply(context, child, feed, item, Feeder{input, False{}, Nil{}, ending})
    case Feeder{input, busy, queue, ending}:
      IO.pure(Feeder, Feeder{input, busy, List.append(&2, Pending, queue, [item]), ending})

def feed_received(+context: Context, +child: String, +dir: String, +feed: Chan(Feed), got: Maybe<&1, Feed>, state: Feeder) -> IO(Feeder):
  match got state:
    case None{} Feeder{input, busy, queue, ending}:
      IO.pure(Feeder, Feeder{input, busy, queue, True{}})
    case Some{FeedWrite{id, text}} current:
      arrive(context, child, feed, PendingWrite{id, text}, current)
    case Some{FeedClose{id}} current:
      arrive(context, child, feed, PendingClose{id}, current)
    case Some{FeedStop{+id}} current:
      do IO<Feeder>:
        IO.spawn(Unit, stop_fiber(context, id, dir))
        fed(context, child)
        return current
    case Some{Wrote{file, +id, result, +bytes}} Feeder{input, busy, queue, ending}:
      do IO<Feeder>:
        respond(id, write_answer(child, result, bytes))
        fed(context, child)
        drain(context, child, feed, queue, Feeder{Some{file}, False{}, Nil{}, ending})
    case Some{FeedEnd{}} Feeder{input, busy, queue, ending}:
      IO.pure(Feeder, Feeder{input, busy, queue, True{}})

# Owns the child's stdin until the connection ends and nothing is left to do.
def feeder(fuel: Nat, +context: Context, +child: String, +dir: String, +feed: Chan(Feed), state: Feeder) -> IO(Unit):
  match fuel state:
    case _ Feeder{input, False{}, Nil{}, True{}}:
      close_input(input)
    case 0n Feeder{input, busy, queue, ending}:
      close_input(input)
    case 1n+rest current:
      do IO<Unit>:
        got : Maybe<&1, Feed> <- Chan.recv(Feed, feed)
        next : Feeder <- feed_received(context, child, dir, feed, got, current)
        feeder(rest, context, child, dir, feed, next)

def feeder_fuel() -> Nat:
  4294967295n

# ---------------------------------------------------------------------------
# Spawning a session child.

def spawn_error(+context: Context, +id: J.JSON, error: U32 & String) -> IO(Unit):
  answered(context, id, Fail{error})

def dir_checked(result: Result<&1, &1, U32 & String, String>) -> Result<&1, &1, U32 & String, Unit>:
  match result:
    case Fail{e}:
      Fail{(2, "cwd must be an existing directory")}
    case Done{ok}:
      Done{Unit{}}

def cwd_exists(cwd: String) -> IO(Result<&1, &1, U32 & String, Unit>):
  match cwd:
    case SNil{}:
      IO.pure(Result<&1, &1, U32 & String, Unit>, Done{Unit{}})
    case other:
      do IO<Result<&1, &1, U32 & String, Unit>>:
        found : Result<&1, &1, U32 & String, String> <- Host.directory(other)
        return dir_checked(found)

type Spawn is Data:
  SpawnPlan{id: J.JSON, argv: List<&2, String>, pipe: Bool, lifetime: U32, label: String, cwd: String}

def ready_pause(ready: Bool) -> IO(Unit):
  match ready:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.sleep(5)

def is_ready(found: Result<&1, &1, U32 & String, String>) -> Bool:
  match found:
    case Done{SCon{head, tail}}:
      True{}
    case other:
      False{}

# Waits for the worker to announce itself, polling every 5 ms.
def ready_poll(fuel: Nat, +dir: String, ready: Bool) -> IO(Bool):
  match fuel ready:
    case _ True{}:
      IO.pure(Bool, True{})
    case 0n False{}:
      IO.pure(Bool, False{})
    case 1n+rest False{}:
      do IO<Bool>:
        found : Result<&1, &1, U32 & String, String> <- Host.attempt(dir, "ready", 16)
        +now : Bool = is_ready(found)
        ready_pause(now)
        ready_poll(rest, dir, now)

def plan_id(plan: Spawn) -> J.JSON:
  match plan:
    case SpawnPlan{id, argv, pipe, lifetime, label, cwd}:
      id

def plan_pipe(plan: Spawn) -> Bool:
  match plan:
    case SpawnPlan{id, argv, pipe, lifetime, label, cwd}:
      pipe

def plan_label(plan: Spawn) -> String:
  match plan:
    case SpawnPlan{id, argv, pipe, lifetime, label, cwd}:
      label

def plan_cwd(plan: Spawn) -> String:
  match plan:
    case SpawnPlan{id, argv, pipe, lifetime, label, cwd}:
      cwd

def plan_worker(+context: Context, plan: Spawn, +dir: String) -> List<String>:
  match plan:
    case SpawnPlan{id, argv, pipe, lifetime, label, cwd}:
      Core.owned(Core.worker_argv(self(context), dir, lifetime, pipe, cwd, argv))

def plan_timeout(plan: Spawn) -> U32:
  match plan:
    case SpawnPlan{id, argv, pipe, +lifetime, label, cwd}:
      Core.worker_timeout(lifetime)

def stdin_of(writer: File, pipe: Bool) -> IO(Maybe<&1, File>):
  match pipe:
    case True{}:
      IO.pure(Maybe<&1, File>, Some{writer})
    case False{}:
      do IO<Maybe<&1, File>>:
        File.close(writer)
        return None{}

def spawn_ready(+context: Context, +plan: Spawn, +dir: String, +meta: String, writer: File, ready: Bool) -> IO(Unit):
  match ready:
    case False{}:
      do IO<Unit>:
        File.close(writer)
        marked : Result<&1, &1, U32 & String, String> <- Host.put(dir, "stop", "stop")
        spawn_error(context, plan_id(plan), (1, "session child did not start"))
    case True{}:
      do IO<Unit>:
        +child : String = JobsPolicy.public_id(dir, meta)
        +feed : Chan(Feed) <- Chan.new(Feed, U32.add(Core.pending_max(), 8))
        notify(context, Spawned{Child{child, dir, feed, 0, True{}}})
        answered(context, plan_id(plan), Done{JobsPolicy.running(dir, meta)})
        input : Maybe<&1, File> <- stdin_of(writer, plan_pipe(plan))
        feeder(feeder_fuel(), context, child, dir, feed, Feeder{input, False{}, Nil{}, False{}})

def spawn_piped(
  +context: Context,
  +plan: Spawn,
  +dir: String,
  +meta: String,
  out: File,
  err: File,
  pair: Result<&1, &1, U32 & String, File & File>,
) -> IO(Unit):
  match pair:
    case Fail{e}:
      do IO<Unit>:
        File.close(out)
        File.close(err)
        spawn_error(context, plan_id(plan), e)
    case Done{files}:
      (reader, writer) = files
      do IO<Unit>:
        outcome : Chan(Raw) <- IO.fork(Raw, Process.Native.exec_pipe(
          plan_worker(context, plan, dir),
          reader,
          plan_timeout(plan),
          out,
          err,
          True{},
          "",
        ))
        IO.spawn(Unit, reap(context, JobsPolicy.public_id(dir, meta), outcome))
        ready : Bool <- ready_poll(1000n, dir, False{})
        spawn_ready(context, plan, dir, meta, writer, ready)

def spawn_err(
  +context: Context,
  +plan: Spawn,
  +dir: String,
  +meta: String,
  out: File,
  err: Result<&1, &1, U32 & String, File>,
) -> IO(Unit):
  match err:
    case Fail{e}:
      do IO<Unit>:
        File.close(out)
        spawn_error(context, plan_id(plan), e)
    case Done{file}:
      do IO<Unit>:
        pair : Result<&1, &1, U32 & String, File & File> <- Process.pipe()
        spawn_piped(context, plan, dir, meta, out, file, pair)

def spawn_out(+context: Context, +plan: Spawn, +dir: String, +meta: String, out: Result<&1, &1, U32 & String, File>) -> IO(Unit):
  match out:
    case Fail{e}:
      spawn_error(context, plan_id(plan), e)
    case Done{file}:
      do IO<Unit>:
        err : Result<&1, &1, U32 & String, File> <- Host.jfh_spool(dir, "worker-err.log", True{})
        spawn_err(context, plan, dir, meta, file, err)

def spawn_meta(+context: Context, +plan: Spawn, +dir: String, +meta: String, put: Result<&1, &1, U32 & String, String>) -> IO(Unit):
  match put:
    case Fail{e}:
      spawn_error(context, plan_id(plan), e)
    case Done{ok}:
      do IO<Unit>:
        out : Result<&1, &1, U32 & String, File> <- Host.jfh_spool(dir, "worker-out.log", True{})
        spawn_out(context, plan, dir, meta, out)

def spawn_made(+context: Context, +plan: Spawn, made: Result<&1, &1, U32 & String, String>) -> IO(Unit):
  match made:
    case Fail{e}:
      spawn_error(context, plan_id(plan), e)
    case Done{+dir}:
      do IO<Unit>:
        now : String <- Host.clock()
        +meta : String = JobsPolicy.meta(plan_label(plan), now, "session", plan_pipe(plan))
        put : Result<&1, &1, U32 & String, String> <- Host.put(dir, "meta.json", meta)
        spawn_meta(context, plan, dir, meta, put)

def spawn_cwd(+context: Context, +plan: Spawn, exists: Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  match exists:
    case Fail{e}:
      spawn_error(context, plan_id(plan), e)
    case Done{ok}:
      do IO<Unit>:
        made : Result<&1, &1, U32 & String, String> <- Host.make(1024)
        spawn_made(context, plan, made)

def spawn_fiber(+context: Context, +plan: Spawn) -> IO(Unit):
  do IO<Unit>:
    exists : Result<&1, &1, U32 & String, Unit> <- cwd_exists(plan_cwd(plan))
    spawn_cwd(context, plan, exists)

# ---------------------------------------------------------------------------
# Reading a session child's output, and listing the children, in process.

def read_fiber(
  +context: Context,
  +id: J.JSON,
  +dir: String,
  +stream: String,
  +offset: Nat,
  +max: Nat,
  +wait: U32,
  encoded: Bool,
) -> IO(Unit):
  do IO<Unit>:
    result : Answer <- Spool.read(dir, stream, offset, max, U32.to_nat(wait), encoded)
    answered(context, id, result)

def list_fiber(+context: Context, +id: J.JSON, dirs: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    entries : List<&2, JobsPolicy.Entry> <- Jobs.inspect_all(dirs, True{})
    answered(context, id, Done{JobsPolicy.list_json(entries, False{})})

# ---------------------------------------------------------------------------
# The hub's state: the client (absent while an evaluation runs), queued Jev
# requests, the session children, request fibers in flight, and the ending.

type Ending is Data:
  Serving{}
  Ending{code: U32, message: String, ticks: Nat}

type Hub is Type:
  Hub{client: Maybe<&1, Jev.Client>, waiting: List<&2, Queued>, children: List<&2, Child>, inflight: Nat, ending: Ending}

def child_id(child: Child) -> String:
  match child:
    case Child{id, dir, feed, pending, live}:
      id

def child_dir(child: Child) -> String:
  match child:
    case Child{id, dir, feed, pending, live}:
      dir

def child_feed(child: Child) -> Chan(Feed):
  match child:
    case Child{id, dir, feed, pending, live}:
      feed

def pending_ok(child: Child) -> Bool:
  match child:
    case Child{id, dir, feed, pending, live}:
      U32.is_lt(pending, Core.pending_max())

def find(children: List<&2, Child>, +id: String) -> Maybe<&2, Child>:
  match children:
    case Nil{}:
      None{}
    case Con{+child, rest}:
      Bool.pick(Maybe<&2, Child>, String.eq(child_id(child), id), Some{child}, find(rest, id))

def counted(child: Child, +id: String, add: Bool) -> Child:
  match child:
    case Child{+cid, dir, feed, +pending, live}:
      +less = U32.sub(pending, Bool.pick(U32, U32.is_eq(pending, 0), 0, 1))
      +changed = Bool.pick(U32, add, U32.inc(pending), less)
      Child{cid, dir, feed, Bool.pick(U32, String.eq(cid, id), changed, pending), live}

def pending_changed(children: List<&2, Child>, +id: String, +add: Bool) -> List<&2, Child>:
  match children:
    case Nil{}:
      Nil{}
    case Con{child, rest}:
      Con{counted(child, id, add), pending_changed(rest, id, add)}

def exited(child: Child, +id: String) -> Child:
  match child:
    case Child{+cid, dir, feed, pending, live}:
      Child{cid, dir, feed, pending, live && Bool.not(String.eq(cid, id))}

def mark_exited(children: List<&2, Child>, +id: String) -> List<&2, Child>:
  match children:
    case Nil{}:
      Nil{}
    case Con{child, rest}:
      Con{exited(child, id), mark_exited(rest, id)}

def live_count(children: List<&2, Child>) -> Nat:
  match children:
    case Nil{}:
      0n
    case Con{Child{id, dir, feed, pending, live}, rest}:
      Nat.add(Bool.pick(Nat, live, 1n, 0n), live_count(rest))

def settled(children: List<&2, Child>) -> Bool:
  match children:
    case Nil{}:
      True{}
    case Con{Child{id, dir, feed, +pending, live}, rest}:
      Bool.not(live) && U32.is_eq(pending, 0) && settled(rest)

def dirs(children: List<&2, Child>) -> List<&2, String>:
  match children:
    case Nil{}:
      Nil{}
    case Con{Child{id, dir, feed, pending, live}, rest}:
      Con{dir, dirs(rest)}

def started(state: Hub) -> Hub:
  match state:
    case Hub{client, waiting, children, inflight, ending}:
      Hub{client, waiting, children, Nat.add(inflight, 1n), ending}

def finished(state: Hub) -> Hub:
  match state:
    case Hub{client, waiting, children, inflight, ending}:
      Hub{client, waiting, children, Nat.sub(inflight, 1n), ending}

def children_of(state: Hub) -> Hub & List<&2, Child>:
  match state:
    case Hub{client, waiting, +children, inflight, ending}:
      (Hub{client, waiting, children, inflight, ending}, children)

# Starts a request fiber; the hub counts it until it reports Finished.
def run(state: Hub, action: IO(Unit)) -> IO(Hub):
  do IO<Hub>:
    IO.spawn(Unit, action)
    return started(state)

def refuse(state: Hub, +id: J.JSON, error: U32 & String) -> IO(Hub):
  do IO<Hub>:
    respond(id, Fail{error})
    return state

# ---------------------------------------------------------------------------
# Dispatch.

# Jev requests share the one client: they wait their turn in arrival order.
def jev_arrive(+context: Context, state: Hub, +queued: Queued) -> IO(Hub):
  match state:
    case Hub{Some{client}, waiting, children, inflight, ending}:
      do IO<Hub>:
        IO.spawn(Unit, jev_run(context, client, queued))
        return Hub{None{}, waiting, children, inflight, ending}
    case Hub{None{}, waiting, children, inflight, ending}:
      IO.pure(Hub, Hub{None{}, List.append(&2, Queued, waiting, [queued]), children, inflight, ending})

def jev_returned(+context: Context, state: Hub, client: Jev.Client) -> IO(Hub):
  match state:
    case Hub{old, Nil{}, children, inflight, ending}:
      IO.pure(Hub, Hub{Some{client}, Nil{}, children, inflight, ending})
    case Hub{old, Con{+next, rest}, children, inflight, ending}:
      do IO<Hub>:
        IO.spawn(Unit, jev_run(context, client, next))
        return Hub{old, rest, children, inflight, ending}

def send_feed(+child: Child, item: Feed, state: Hub) -> IO(Hub):
  match state:
    case Hub{client, waiting, children, inflight, ending}:
      do IO<Hub>:
        sent : Bool <- Chan.send(Feed, child_feed(child), item)
        return Hub{client, waiting, pending_changed(children, child_id(child), True{}), inflight, ending}

def fed_if(+child: Child, item: Feed, state: Hub, +id: J.JSON, ok: Bool) -> IO(Hub):
  match ok:
    case True{}:
      send_feed(child, item, state)
    case False{}:
      refuse(state, id, Core.too_many_pending())

def stop_if(+child: Child, state: Hub, +id: J.JSON, ok: Bool) -> IO(Hub):
  match ok:
    case True{}:
      do IO<Hub>:
        next : Hub <- send_feed(child, FeedStop{id}, state)
        return started(next)
    case False{}:
      refuse(state, id, Core.too_many_pending())

# A request addressed to one of this connection's session children. Writes,
# closes and stops go through the child's feeder, in arrival order.
def session_request(
  +context: Context,
  state: Hub,
  +id: J.JSON,
  op: Core.Op,
  +child: Child,
  +remaining: U32,
) -> IO(Hub):
  match op:
    case Core.Write{job, text}:
      fed_if(child, FeedWrite{id, text}, state, id, pending_ok(child))
    case Core.CloseInput{job}:
      fed_if(child, FeedClose{id}, state, id, pending_ok(child))
    case Core.Stop{job}:
      stop_if(child, state, id, pending_ok(child))
    case Core.ReadOut{job, stream, offset, max, wait, encoded}:
      run(state, read_fiber(context, id, child_dir(child), stream, offset, max, Core.inner(wait, 0, remaining), encoded))
    case other:
      run(state, subprocess(context, id, Core.plan(self(context), Core.retarget(other, child_dir(child)), defaults(context), remaining)))

def session_found(+context: Context, state: Hub, +id: J.JSON, op: Core.Op, found: Maybe<&2, Child>, +remaining: U32) -> IO(Hub):
  match found:
    case None{}:
      refuse(state, id, Core.unknown_child())
    case Some{+child}:
      session_request(context, state, id, op, child, remaining)

def session_pair(+context: Context, pair: Hub & List<&2, Child>, +id: J.JSON, op: Core.Op, +child: String, +remaining: U32) -> IO(Hub):
  (current, children) = pair
  session_found(context, current, id, op, find(children, child), remaining)

def session_lookup(+context: Context, state: Hub, +id: J.JSON, op: Core.Op, +child: String, +remaining: U32) -> IO(Hub):
  session_pair(context, children_of(state), id, op, child, remaining)

def spawn_allowed(+context: Context, state: Hub, +id: J.JSON, op: Core.Op, +left: U32, room: Bool) -> IO(Hub):
  match op room:
    case Core.Spawn{argv, pipe, requested, label, cwd} True{}:
      run(state, spawn_fiber(context, SpawnPlan{id, argv, pipe, Core.child_lifetime(requested, left), label, cwd}))
    case other False{}:
      refuse(state, id, Core.too_many_children())
    case other True{}:
      refuse(state, id, (1, "not a spawn request"))

def spawn_pair(+context: Context, pair: Hub & List<&2, Child>, +id: J.JSON, op: Core.Op, +left: U32) -> IO(Hub):
  (current, children) = pair
  spawn_allowed(context, current, id, op, left, Nat.is_lt(live_count(children), Core.children_max()))

def spawn_arrive(+context: Context, state: Hub, +id: J.JSON, op: Core.Op, +left: U32) -> IO(Hub):
  spawn_pair(context, children_of(state), id, op, left)

def list_pair(+context: Context, pair: Hub & List<&2, Child>, +id: J.JSON) -> IO(Hub):
  (current, children) = pair
  run(current, list_fiber(context, id, dirs(children)))

def list_sessions(+context: Context, state: Hub, +id: J.JSON) -> IO(Hub):
  list_pair(context, children_of(state), id)

# The time left for a session child: the connection's, less the receipt grace.
def child_left(+context: Context) -> IO(U32):
  do IO<U32>:
    now : Nat <- IO.now()
    +left : U32 = TimePolicy.cap(TimePolicy.remaining(scope(context), now), TimePolicy.job_max())
    return Core.left(left)

# An interactive job's input is queued by the hub itself, so writes and closes
# are applied in the order they arrived. Queueing is one short locked append.
def durable_write(state: Hub, +id: J.JSON, +job: String, text: String, close: Bool) -> IO(Hub):
  do IO<Hub>:
    result : Answer <- Spool.queue_write(job, text, close)
    respond(id, result)
    return state

def refuse_or_answer(state: Hub, +id: J.JSON, result: Answer) -> IO(Hub):
  do IO<Hub>:
    respond(id, result)
    return state

# Requests that name no session child.
def unaddressed(+context: Context, state: Hub, +id: J.JSON, op: Core.Op, +remaining: U32) -> IO(Hub):
  match op:
    case Core.Validate{request}:
      refuse_or_answer(state, id, Core.validated(request))
    case Core.Capabilities{}:
      refuse_or_answer(state, id, Done{Core.capabilities(Cli.version(), platform(context))})
    case Core.Evaluate{request, requested, provider, credential}:
      jev_arrive(context, state, Queued{id, request, requested, provider, credential})
    case Core.Spawn{argv, pipe, requested, label, cwd}:
      do IO<Hub>:
        +left : U32 <- child_left(context)
        spawn_arrive(context, state, id, Core.Spawn{argv, pipe, requested, label, cwd}, left)
    case Core.ListJobs{True{}}:
      list_sessions(context, state, id)
    case Core.Write{job, text}:
      durable_write(state, id, job, text, False{})
    case Core.CloseInput{job}:
      durable_write(state, id, job, "", True{})
    case Core.ReadOut{job, stream, offset, max, wait, encoded}:
      run(state, read_fiber(context, id, job, stream, offset, max, Core.inner(wait, 0, remaining), encoded))
    case other:
      run(state, subprocess(context, id, Core.plan(self(context), other, defaults(context), remaining)))

def addressed(+context: Context, state: Hub, +id: J.JSON, op: Core.Op, target: Maybe<&2, String>, +remaining: U32) -> IO(Hub):
  match target:
    case None{}:
      unaddressed(context, state, id, op, remaining)
    case Some{+child}:
      session_lookup(context, state, id, op, child, remaining)

def dispatch(+context: Context, state: Hub, +id: J.JSON, +op: Core.Op, +remaining: U32) -> IO(Hub):
  addressed(context, state, id, op, Core.session_target(op), remaining)

# ---------------------------------------------------------------------------
# Ending: stop the session children (process group, then force), let every
# request in flight answer, then remove the children's directories.

def ticker(fuel: Nat, +context: Context, more: Bool) -> IO(Unit):
  match fuel more:
    case _ False{}:
      IO.pure(Unit, Unit{})
    case 0n True{}:
      IO.pure(Unit, Unit{})
    case 1n+rest True{}:
      do IO<Unit>:
        IO.sleep(100)
        sent : Bool <- Chan.send(Note, inbox(context), Tick{})
        ticker(rest, context, sent)

def ending_child(child: Child) -> IO(Unit):
  match child:
    case Child{id, +dir, feed, pending, live}:
      do IO<Unit>:
        sent : Bool <- Chan.send(Feed, feed, FeedEnd{})
        marked : Result<&1, &1, U32 & String, String> <- Host.put(dir, "stop", "stop")
        return Unit{}

def end_children(children: List<&2, Child>) -> IO(Unit):
  match children:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{child, rest}:
      do IO<Unit>:
        ending_child(child)
        end_children(rest)

# The first ending wins: its code is the session's exit code.
def begin_end(+context: Context, state: Hub, code: U32, message: String) -> IO(Hub):
  match state:
    case Hub{client, waiting, +children, inflight, Serving{}}:
      do IO<Hub>:
        end_children(children)
        IO.spawn(Unit, ticker(600n, context, True{}))
        return Hub{client, waiting, children, inflight, Ending{code, message, 0n}}
    case other:
      IO.pure(Hub, other)

def force(now: Bool) -> IO(Unit):
  match now:
    case True{}:
      Process.cancel(15)
    case False{}:
      IO.pure(Unit, Unit{})

# Stragglers are forced 3 seconds after the session ended.
def forced(state: Hub) -> IO(Hub):
  match state:
    case Hub{client, waiting, children, inflight, Ending{code, message, +ticks}}:
      do IO<Hub>:
        force(Nat.is_eq(ticks, 29n))
        return Hub{client, waiting, children, inflight, Ending{code, message, Nat.add(ticks, 1n)}}
    case other:
      IO.pure(Hub, other)

def open_state(state: Hub) -> Hub & Bool:
  match state:
    case Hub{client, waiting, children, inflight, Serving{}}:
      (Hub{client, waiting, children, inflight, Serving{}}, True{})
    case other:
      (other, False{})

# ---------------------------------------------------------------------------
# Answering lines. After an expiry the rest are dropped.

def timed(+context: Context, state: Hub, +id: J.JSON, op: Core.Op, +remaining: U32, expired: Bool) -> IO(Hub):
  match expired:
    case True{}:
      do IO<Hub>:
        respond(id, Fail{Core.expired()})
        begin_end(context, state, 124, "serve deadline expired")
    case False{}:
      dispatch(context, state, id, op, remaining)

def parsed(+context: Context, state: Hub, +id: J.JSON, request: Result<&1, &1, U32 & String, Core.Op>) -> IO(Hub):
  match request:
    case Fail{e}:
      refuse(state, id, e)
    case Done{op}:
      do IO<Hub>:
        +remaining : U32 <- Scope.remaining(scope(context), Time.max_timeout())
        timed(context, state, id, op, remaining, Bool.not(U32.is_gt(remaining, Core.grace())))

def decoded(+context: Context, state: Hub, value: Result<&1, &1, U32 & String, J.JSON>) -> IO(Hub):
  match value:
    case Fail{e}:
      refuse(state, J.Null{}, e)
    case Done{+request}:
      parsed(context, state, Core.id(request), Core.request(request))

def answer_line(+context: Context, state: Hub, line: List<&2, U32>) -> IO(Hub):
  match line:
    case Nil{}:
      IO.pure(Hub, state)
    case bytes:
      decoded(context, state, Core.unreadable(Codec.read_bytes(bytes)))

def answer_if(+context: Context, state: Hub, line: List<&2, U32>, open: Bool) -> IO(Hub):
  match open:
    case True{}:
      answer_line(context, state, line)
    case False{}:
      IO.pure(Hub, state)

def answer_step(+context: Context, pair: Hub & Bool, line: List<&2, U32>) -> IO(Hub):
  (state, open) = pair
  answer_if(context, state, line, open)

def open_hub(pair: Hub & Bool) -> Hub:
  (state, open) = pair
  state

def answer_open(lines: List<&2, List<&2, U32>>, +context: Context, pair: Hub & Bool) -> IO(Hub):
  match lines:
    case Nil{}:
      IO.pure(Hub, open_hub(pair))
    case Con{line, rest}:
      do IO<Hub>:
        next : Hub <- answer_step(context, pair, line)
        answer_open(rest, context, open_state(next))

def answer_all(lines: List<&2, List<&2, U32>>, +context: Context, state: Hub) -> IO(Hub):
  answer_open(lines, context, open_state(state))

# ---------------------------------------------------------------------------
# The hub loop.

type Step is Type:
  Continue{hub: Hub}
  Conclude{hub: Hub}

def with_children(state: Hub, children: List<&2, Child>) -> Hub:
  match state:
    case Hub{client, waiting, old, inflight, ending}:
      Hub{client, waiting, children, inflight, ending}

def fed_note(state: Hub, +child: String) -> Hub:
  match state:
    case Hub{client, waiting, children, inflight, ending}:
      Hub{client, waiting, pending_changed(children, child, False{}), inflight, ending}

def exited_note(state: Hub, +child: String) -> Hub:
  match state:
    case Hub{client, waiting, children, inflight, ending}:
      Hub{client, waiting, mark_exited(children, child), inflight, ending}

# A child whose spawn finished after the session began to end is ended at once.
def spawned_note(state: Hub, +child: Child) -> IO(Hub):
  match state:
    case Hub{client, waiting, children, inflight, Serving{}}:
      IO.pure(Hub, Hub{client, waiting, List.append(&2, Child, children, [child]), inflight, Serving{}})
    case Hub{client, waiting, children, inflight, ending}:
      do IO<Hub>:
        ending_child(child)
        return Hub{client, waiting, List.append(&2, Child, children, [child]), inflight, ending}

def closed_note(+context: Context, state: Hub, +code: U32, message: String, last: List<&2, List<&2, U32>>) -> IO(Hub):
  do IO<Hub>:
    answered_last : Hub <- answer_all(last, context, state)
    begin_end(context, answered_last, code, message)

def noted(+context: Context, state: Hub, note: Note) -> IO(Hub):
  match note:
    case Lines{lines}:
      answer_all(lines, context, state)
    case Closed{code, message, last}:
      closed_note(context, state, code, message, last)
    case Returned{client}:
      jev_returned(context, state, client)
    case Spawned{child}:
      spawned_note(state, child)
    case Fed{child}:
      IO.pure(Hub, fed_note(state, child))
    case Exited{child}:
      IO.pure(Hub, exited_note(state, child))
    case Finished{}:
      IO.pure(Hub, finished(state))
    case Tick{}:
      forced(state)

def conclude_if(state: Hub, done: Bool) -> Step:
  match done:
    case True{}:
      Conclude{state}
    case False{}:
      Continue{state}

# The session ends once it is ending and nothing is left in flight.
def drained(state: Hub) -> Step:
  match state:
    case Hub{Some{client}, Nil{}, +children, 0n, Ending{code, message, ticks}}:
      conclude_if(Hub{Some{client}, Nil{}, children, 0n, Ending{code, message, ticks}}, settled(children))
    case other:
      Continue{other}

def received(+context: Context, state: Hub, got: Maybe<&1, Note>) -> IO(Step):
  match got:
    case None{}:
      IO.pure(Step, Conclude{state})
    case Some{note}:
      do IO<Step>:
        next : Hub <- noted(context, state, note)
        return drained(next)

def remove_all(dirs: List<&2, String>) -> IO(Unit):
  match dirs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{dir, rest}:
      do IO<Unit>:
        removed : Result<&1, &1, U32 & String, String> <- Host.remove(dir)
        remove_all(rest)

def exit_with(code: U32, message: String) -> IO(Unit):
  match code:
    case 0:
      IO.pure(Unit, Unit{})
    case failed:
      IO.die(Unit, failed, message)

# Session children are unaddressable once their connection has ended, so their
# directories go with it.
def conclude(+context: Context, state: Hub) -> IO(Unit):
  match state:
    case Hub{client, waiting, children, inflight, Ending{code, message, ticks}}:
      do IO<Unit>:
        remove_all(dirs(children))
        Chan.close(Note, inbox(context))
        exit_with(code, message)
    case Hub{client, waiting, children, inflight, Serving{}}:
      do IO<Unit>:
        remove_all(dirs(children))
        Chan.close(Note, inbox(context))
        return Unit{}

def hub_loop(fuel: Nat, +context: Context, step: Step) -> IO(Unit):
  match fuel step:
    case _ Conclude{state}:
      conclude(context, state)
    case 0n Continue{state}:
      IO.die(Unit, 1, "serve message limit reached; start a new session")
    case 1n+rest Continue{state}:
      do IO<Unit>:
        got : Maybe<&1, Note> <- Chan.recv(Note, inbox(context))
        next : Step <- received(context, state, got)
        hub_loop(rest, context, next)

def hub_fuel() -> Nat:
  4294967295n

# ---------------------------------------------------------------------------
# The reader: frames stdin into lines for the hub.

type Reading is Type:
  More{input: File, pending: List<&2, U32>, size: U32}
  Stopped{}

def stop_reading(input: File, +context: Context, note: Note) -> IO(Reading):
  do IO<Reading>:
    File.close(input)
    notify(context, note)
    return Stopped{}

def overflowed(input: File, +context: Context, pending: List<&2, U32>, +size: U32, over: Bool) -> IO(Reading):
  match over:
    case True{}:
      do IO<Reading>:
        respond(J.Null{}, Fail{(2, "request line exceeds 1 MiB")})
        stop_reading(input, context, Closed{2, "request line exceeds 1 MiB", Nil{}})
    case False{}:
      IO.pure(Reading, More{input, pending, size})

# A partial line longer than any valid request cannot be answered, so the
# session ends instead of resynchronizing.
def framed_more(input: File, +context: Context, framed: Core.Framed) -> IO(Reading):
  match framed:
    case Core.Framed{lines, pending, +size}:
      do IO<Reading>:
        notify(context, Lines{lines})
        overflowed(input, context, pending, size, U32.is_gt(size, Core.line_max()))

# End of input answers an unterminated last line, then ends the session.
def chunk(input: File, +context: Context, pending: List<&2, U32>, +size: U32, bytes: List<&2, U32>) -> IO(Reading):
  match bytes:
    case Nil{}:
      stop_reading(input, context, Closed{0, "", Core.last(pending)})
    case more:
      framed_more(input, context, Core.frame(more, pending, size, Nil{}))

def got_input(pair: File & Result<&1, &1, U32 & String, List<&2, U32>>, +context: Context, pending: List<&2, U32>, +size: U32) -> IO(Reading):
  (input, result) = pair
  match result:
    case Fail{e}:
      stop_reading(input, context, Closed{1, "serve could not read its input", Nil{}})
    case Done{bytes}:
      chunk(input, context, pending, size, bytes)

def reader(fuel: Nat, +context: Context, state: Reading) -> IO(Unit):
  match fuel state:
    case _ Stopped{}:
      IO.pure(Unit, Unit{})
    case 0n More{input, pending, size}:
      do IO<Unit>:
        stopped : Reading <- stop_reading(input, context, Closed{1, "serve read limit reached; start a new session", Nil{}})
        return Unit{}
    case 1n+rest More{input, pending, size}:
      do IO<Unit>:
        pair : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(input, 65536)
        next : Reading <- got_input(pair, context, pending, size)
        reader(rest, context, next)

# ---------------------------------------------------------------------------
# Launch.

def launch(+ms: U32, budget: U32 & U32) -> IO(Unit):
  (+calls, +tokens) = budget
  do IO<Unit>:
    now : Nat <- IO.now()
    client : Jev.Client <- IO.try(Jev.Client, Jev.connect(calls, tokens))
    executable : String <- Host.self()
    work : U32 <- Time.work()
    wait : U32 <- Time.wait()
    watch : U32 <- Time.watch()
    input : File <- IO.try(File, Process.stdin())
    +platform : String <- Host.platform()
    inbox : Chan(Note) <- Chan.new(Note, 256)
    +context : Context = Context{
      executable,
      TimePolicy.Budget{now, U32.to_nat(ms)},
      Core.Defaults{work, wait, watch},
      inbox,
      platform,
    }
    IO.print(Core.banner(Cli.version(), platform, ms, calls, tokens))
    IO.spawn(Unit, reader(Core.reads_max(), context, More{input, Nil{}, 0}))
    hub_loop(hub_fuel(), context, Continue{Hub{Some{client}, Nil{}, Nil{}, 0n, Serving{}}})

# The connection may last a day, like a job; the CLI checked the ceiling.
def serve(timeout: Maybe<&2, U32>, args: List<String>) -> IO(Unit):
  match timeout:
    case None{}:
      IO.die(Unit, 2, "serve timeout must be 1..86400000 milliseconds")
    case Some{ms}:
      do IO<Unit>:
        budget : U32 & U32 <- IO.pass(U32 & U32, Core.budget(args))
        launch(ms, budget)
