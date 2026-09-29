import Base
import ../TimeCore.bend as Time
import ../Cli.bend as Cli

# Definitional policy contracts, not proofs of OS scheduling or clock honesty.
law denied_timeout_never_becomes_a_limit:
  for ms: U32
  {Time.checked(ms, False{}) == Fail{(2, "timeout must be an integer within the operation limit")} : Result<&1, &1, U32 & String, U32>}

def denied_timeout_never_becomes_a_limit(ms):
  {==}

law omitted_configuration_uses_default:
  for fallback: U32
  for max: U32
  {Time.config("", fallback, max) == Done{fallback} : Result<&1, &1, U32 & String, U32>}

def omitted_configuration_uses_default(fallback, max):
  {==}

law elapsed_time_is_subtracted_not_renewed:
  for start: Nat
  for duration: Nat
  for now: Nat
  {Time.remaining(Time.Budget{start, duration}, now) == Nat.sub(duration, Nat.sub(now, start)) : Nat}

def elapsed_time_is_subtracted_not_renewed(start, duration, now):
  {==}

law local_cap_is_applied_before_narrowing:
  for left: Nat
  for local: U32
  {Time.cap(left, local) == U32.from_nat(Nat.min(left, U32.to_nat(local))) : U32}

def local_cap_is_applied_before_narrowing(left, local):
  {==}

law duplicate_timeout_is_rejected:
  for first: U32
  for second: U32
  {Cli.unique(Some{first}, second) == Fail{(2, "specify the timeout only once")} : Result<&1, &1, U32 & String, U32>}

def duplicate_timeout_is_rejected(first, second):
  {==}

law rejected_label_is_never_stored:
  for text: String
  {Cli.label_allowed(text, False{}) == Fail{(2, "label must be 1..120 printable characters on one line")} : Result<&1, &1, U32 & String, String>}

def rejected_label_is_never_stored(text):
  {==}

law serve_connection_may_last_a_day:
  {Cli.max("serve") == 86400000 : U32}

def serve_connection_may_last_a_day():
  {==}
