import Base
import ./Codec.bend as Codec
import ./vendor/strict-json/json.bend as J

# Pure storage-format policy. A storage home records its format in the marker
# `.jev-fabric-store.json`; Host reads and writes it, and this module decides
# whether this binary may use the home. Within one store version changes are
# additive, so any binary whose version is at least the home's may use it.

def Error() -> Type:
  U32 & String

# The store format this binary reads and writes.
def version() -> Nat:
  1n

# The marker written into a new home, or adopted by a home that lacks one.
def marker() -> String:
  "{\"store\":1}\n"

type Decision is Data:
  Accept{}
  Adopt{}
  Refuse{message: String}

def unreadable() -> Decision:
  Refuse{"storage home marker .jev-fabric-store.json is not readable by this jev-fabric"}

def newer(shown: String) -> Decision:
  Refuse{"storage home uses store format " ++ shown
    ++ "; this jev-fabric supports store format 1 (upgrade jev-fabric to use it)"}

def above_one(rest: Nat, shown: String) -> Decision:
  match rest:
    case 0n:
      Accept{}
    case 1n+later:
      newer(shown)

# Store 1 is this binary's; a newer one is refused, never rewritten. Store 0 is
# not a format any release wrote.
def versioned(found: Nat, shown: String) -> Decision:
  match found:
    case 0n:
      unreadable()
    case 1n+rest:
      above_one(rest, shown)

def number(found: Maybe<&2, Nat>, shown: String) -> Decision:
  match found:
    case None{}:
      unreadable()
    case Some{n}:
      versioned(n, shown)

def store_field(found: Maybe<&2, J.JSON>) -> Decision:
  match found:
    case Some{J.Num{+lex}}:
      number(Nat.read(lex), lex)
    case other:
      unreadable()

def parsed(value: Result<&1, &1, Error, J.JSON>) -> Decision:
  match value:
    case Fail{e}:
      unreadable()
    case Done{document}:
      store_field(Codec.field(document, "store"))

# A home without a marker is adopted when this call created it, or when the verb
# writes to it anyway; a read-only verb leaves an old home as it found it.
def missing(mutating: Bool, created: Bool) -> Decision:
  match mutating created:
    case True{} _:
      Adopt{}
    case False{} True{}:
      Adopt{}
    case False{} False{}:
      Accept{}

def marked(text: String, created: Bool, mutating: Bool) -> Decision:
  match text:
    case SNil{}:
      missing(mutating, created)
    case other:
      parsed(Codec.read(other))

# Host's answer is "+" when it just created the root, else "=", then the marker.
def decide(answer: String, mutating: Bool) -> Decision:
  match answer:
    case SCon{'+', text}:
      marked(text, True{}, mutating)
    case SCon{c, text}:
      marked(text, False{}, mutating)
    case SNil{}:
      missing(mutating, False{})

# The exit code of a refused home, as for other unsafe job access.
def refused_code() -> U32:
  22
