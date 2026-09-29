import Base

# Defaults are policy, never sleeps. An operator may override them once.
def work_default() -> U32:
  3600000

def jev_default() -> U32:
  30000

def wait_default() -> U32:
  30000

def watch_default() -> U32:
  5000

# Detached `start` jobs alone may run for a day; every other limit stays one hour.
def job_max() -> U32:
  86400000

def checked(ms: U32, valid: Bool) -> Result<&1, &1, U32 & String, U32>:
  match valid:
    case True{}:
      Done{ms}
    case False{}:
      Fail{(2, "timeout must be an integer within the operation limit")}

def parsed(value: Maybe<&2, U32>, +max: U32) -> Result<&1, &1, U32 & String, U32>:
  match value:
    case None{}:
      Fail{(2, "timeout must be an integer within the operation limit")}
    case Some{+ms}:
      checked(ms, U32.is_ge(ms, 1) && U32.is_le(ms, max))

def trim_zeros(text: String) -> String:
  match text:
    case SCon{'0', rest}:
      trim_zeros(rest)
    case other:
      other

def parse_bounded(raw: String, max: U32, bounded: Bool) -> Result<&1, &1, U32 & String, U32>:
  match bounded:
    case True{}:
      parsed(U32.read(raw), max)
    case False{}:
      Fail{(2, "timeout must be an integer within the operation limit")}

# Eight digits cover every limit (job_max included) and cannot overflow U32.
def parse_trimmed(+raw: String, max: U32) -> Result<&1, &1, U32 & String, U32>:
  parse_bounded(raw, max, Nat.is_le(String.length(raw), 8n))

def parse(raw: String, max: U32) -> Result<&1, &1, U32 & String, U32>:
  parse_trimmed(trim_zeros(raw), max)

def config(raw: String, fallback: U32, max: U32) -> Result<&1, &1, U32 & String, U32>:
  match raw:
    case SNil{}:
      Done{fallback}
    case other:
      parse(other, max)

# Reusable observation of one absolute budget; it owns no OS handles.
type Budget is Data:
  Budget{started: Nat, duration: Nat}

def remaining(budget: Budget, now: Nat) -> Nat:
  match budget:
    case Budget{started, duration}:
      Nat.sub(duration, Nat.sub(now, started))

def cap(left: Nat, local: U32) -> U32:
  U32.from_nat(Nat.min(left, U32.to_nat(local)))
