import Base
import ./MonitorCore.bend as Policy
import ./Host.bend as Host

# Effect interpreter only. All framing and decisions live in the pure core.
def print_lines(lines: List<&2, String>) -> IO(Unit):
  match lines:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{line, rest}:
      do IO<Unit>:
        IO.print(line)
        print_lines(rest)

def emit(step: Policy.Step) -> IO(Policy.Model):
  match step:
    case Policy.Step{model, outs}:
      do IO<Policy.Model>:
        print_lines(outs)
        return model

def emit_end(summary: Policy.Summary, reason: String, terminal: Bool, elapsed: Nat) -> IO(Unit):
  match summary:
    case Policy.Summary{model, finished, lines, batches}:
      match model:
        case Policy.Model{last, out, err, losses, finished2}:
          IO.print(Policy.end_json(reason, terminal, lines, batches, losses, elapsed))

def finalize(
  model: Policy.Model,
  literal: String,
  started: Nat,
  reason: String,
  +terminal: Bool,
) -> IO(Unit):
  do IO<Unit>:
    drained : Policy.Model <- emit(Policy.drain(model, literal, terminal))
    now : Nat <- IO.now()
    emit_end(Policy.summarize(drained), reason, terminal, Nat.sub(now, started))

type Turn is Data:
  Again{model: Policy.Model}
  End{model: Policy.Model, reason: String, terminal: Bool}

def prepare(model: Policy.Model, decision: Policy.Decision) -> IO(Turn):
  match decision:
    case Policy.Poll{}:
      do IO<Turn>:
        IO.sleep(25)
        return Again{model}
    case Policy.Stop{reason, terminal}:
      IO.pure(Turn, End{model, reason, terminal})

# Largest events/receipt file Host will read.
def read_limit() -> U32:
  1048576

def tick(
  +id: String,
  +literal: String,
  started: Nat,
  duration: Nat,
  model: Policy.Model,
) -> IO(Turn):
  do IO<Turn>:
    events : String <- Host.read(id, "events.jsonl", read_limit())
    lines : List<&2, String> = String.split(events, '\n')
    +next : Policy.Model <- emit(Policy.consume(lines, model, literal, Policy.batch_max()))
    receipt : String <- Host.read(id, "receipt.json", read_limit())
    now : Nat <- IO.now()
    prepare(next, Policy.decide(Policy.summarize(next), receipt, Nat.sub(now, started), duration))

def loop(
  remaining: Nat,
  +id: String,
  +literal: String,
  +started: Nat,
  +duration: Nat,
  turn: Turn,
) -> IO(Unit):
  match remaining turn:
    case _ End{model, reason, terminal}:
      finalize(model, literal, started, reason, terminal)
    case 0n Again{model}:
      finalize(model, literal, started, "fuel", False{})
    case 1n+rest Again{model}:
      do IO<Unit>:
        next : Turn <- tick(id, literal, started, duration, model)
        loop(rest, id, literal, started, duration, next)

def watch_parsed(+id: String, +literal: String, parsed: Maybe<&2, Nat>) -> IO(Unit):
  match parsed:
    case None{}:
      IO.die(
        Unit,
        2,
        "usage: watch <id> <duration-ms> <literal>; duration 1..300000, literal 1..256 chars",
      )
    case Some{+duration}:
      do IO<Unit>:
        started : Nat <- IO.now()
        loop(Policy.fuel(duration), id, literal, started, duration, Again{Policy.initial_model()})

# A watch only reads the store, so it checks the format without adopting it.
def watch(id: String, ms: String, +literal: String) -> IO(Unit):
  do IO<Unit>:
    Host.store(False{})
    watch_parsed(id, literal, Policy.validate(ms, literal))

def command(args: List<String>) -> IO(Unit):
  match args:
    case Con{"watch", Con{id, Con{ms, Con{literal, Nil{}}}}}:
      watch(id, ms, literal)
    case other:
      IO.die(Unit, 2, "usage: watch <id> <duration-ms> <literal>")
