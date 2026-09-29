import Base
import ../Core.bend as Core
import ../MonitorCore.bend as Monitor
import ../HttpCore.bend as Http
import ../CredentialCore.bend as Credential
import ../JevCore.bend as Jev
import ../JobsCore.bend as Jobs
import ../StoreCore.bend as Store
import ../SpoolCore.bend as Spool
import ../ServeCore.bend as Serve
import ../vendor/strict-json/json.bend as J

# These contracts concern the actual policy used by the effect interpreters.
# Base/compiler correctness and the honesty/liveness of IO are assumptions.
law denied_reservation_has_no_budget:
  for remaining: Nat
  for used: Nat
  for tokens: Nat
  for limit: Nat
  {Core.reserve_if(remaining, used, tokens, limit, False{}) == None{} : Maybe<&2, Core.Budget>}

def denied_reservation_has_no_budget(remaining, used, tokens, limit):
  {==}

law reservation_consumes_one:
  for remaining: Nat
  for used: Nat
  {Core.reserve(Core.Budget{1n+remaining, used, 0n, 1n}) == Some{Core.Budget{remaining, 1n+used, 0n, 1n}} : Maybe<&2, Core.Budget>}

def reservation_consumes_one(remaining, used):
  {==}

law zero_token_budget_blocks:
  for remaining: Nat
  for used: Nat
  {Core.reserve(Core.Budget{1n+remaining, used, 0n, 0n}) == None{} : Maybe<&2, Core.Budget>}

def zero_token_budget_blocks(remaining, used):
  {==}

law accounting_never_refunds_a_call:
  for remaining: Nat
  for used: Nat
  for tokens: Nat
  for limit: Nat
  for reported: Nat
  {Core.account(Core.Budget{remaining, used, tokens, limit}, reported) == Core.Budget{remaining, used, Nat.add(tokens, reported), limit} : Core.Budget}

def accounting_never_refunds_a_call(remaining, used, tokens, limit, reported):
  {==}

law failure_is_terminal:
  for result: Core.State
  {Core.settle(Core.Failed{}, result) == Core.Failed{} : Core.State}

def failure_is_terminal(result):
  {==}

law timeout_is_terminal:
  for result: Core.State
  {Core.settle(Core.TimedOut{}, result) == Core.TimedOut{} : Core.State}

def timeout_is_terminal(result):
  {==}

law terminal_monitor_never_polls:
  for lines: Nat
  for elapsed: Nat
  for duration: Nat
  {Monitor.terminal_decision(True{}, lines, elapsed, duration) == Monitor.Stop{"finished", True{}} : Monitor.Decision}

def terminal_monitor_never_polls(lines, elapsed, duration):
  {==}

law limited_monitor_never_polls:
  for elapsed: Nat
  for duration: Nat
  {Monitor.limit_decision(True{}, elapsed, duration) == Monitor.Stop{"output-limit", False{}} : Monitor.Decision}

def limited_monitor_never_polls(elapsed, duration):
  {==}

law expired_monitor_never_polls:
  {Monitor.deadline_decision(True{}) == Monitor.Stop{"deadline", False{}} : Monitor.Decision}

def expired_monitor_never_polls():
  {==}

law disabled_filter_emits_nothing:
  for text: String
  for literal: String
  for previous: String
  {Monitor.limited_match(text, literal, previous, False{}) == None{} : Maybe<&2, String>}

def disabled_filter_emits_nothing(text, literal, previous):
  {==}

law full_channel_cannot_emit:
  for stream: String
  for frame: Monitor.Frame
  for lines: List<&2, Monitor.Line>
  for omitted: Nat
  for clips: Nat
  for previous: String
  for from: U32
  for to: U32
  for batches: Nat
  for text: String
  for clipped: Bool
  for sequence: U32
  for literal: String
  for batch: Nat
  {Monitor.push(stream, Monitor.Channel{frame, Monitor.Pending{lines, omitted, clips}, previous, from, to, 1024n, batches}, Monitor.Line{text, clipped}, sequence, literal, batch) == Monitor.Produced{Monitor.Channel{frame, Monitor.Pending{lines, omitted, clips}, previous, from, to, 1024n, batches}, Nil{}} : Monitor.Produced}

def full_channel_cannot_emit(stream, frame, lines, omitted, clips, previous, from, to, batches, text, clipped, sequence, literal, batch):
  {==}

law encoding_without_fuel_fails:
  for value: J.JSON
  {J.JSON.write_with_fuel(0n, value) == Fail{(22, "JSON encoding work limit")} : Result<&1, &1, U32 & String, String>}

def encoding_without_fuel_fails(value):
  {==}

law rejected_http_has_no_request:
  for url: String
  for key: String
  for body: String
  for timeout: U32
  {Http.request_allowed(url, key, body, timeout, False{}) == Fail{(1, "Invalid HTTPS request configuration")} : Result<&1, &1, U32 & String, Http.Request>}

def rejected_http_has_no_request(url, key, body, timeout):
  {==}

law rejected_credential_exposes_no_key:
  for key: String
  {Credential.checked(key, False{}) == Fail{(1, "Invalid private credential")} : Result<&1, &1, U32 & String, String>}

def rejected_credential_exposes_no_key(key):
  {==}

law failed_transport_rejects_bytes:
  for bytes: List<&2, U32>
  {Http.capture_ok(bytes, False{}) == Fail{(1, "Jev transport failed, was interrupted, or exceeded its output bound")} : Result<&1, &1, U32 & String, List<&2, U32>>}

def failed_transport_rejects_bytes(bytes):
  {==}

law reported_overshoot_disables_calls:
  for settings: Jev.Settings
  for remaining: Nat
  for used: Nat
  for spent: Nat
  for limit: Nat
  for key: String
  for response: J.JSON
  for input: Nat
  for output: Nat
  {Jev.add_usage(settings, Core.Budget{remaining, used, spent, limit}, key, response, input, output, True{}) == (Jev.Client{settings, Core.Budget{0n, used, 1n+limit, limit}, key}, Fail{(1, "Jev reported-token budget exceeded; final request may still be billed")}) : Jev.Returned}

def reported_overshoot_disables_calls(settings, remaining, used, spent, limit, key, response, input, output):
  {==}

law invalid_typed_reply_stays_failed:
  for settings: Jev.Settings
  for budget: Core.Budget
  for key: String
  for error: U32 & String
  {Jev.response_ready(settings, budget, key, Fail{error}) == (Jev.Client{settings, budget, key}, Fail{(1, "Invalid typed Jev response")}) : Jev.Returned}

def invalid_typed_reply_stays_failed(settings, budget, key, error):
  {==}

law receipt_finishes_follow:
  for expired: Bool
  {Jobs.follow_decision(True{}, expired) == Jobs.Finished{} : Jobs.Decision}

def receipt_finishes_follow(expired):
  {==}

law expired_follow_without_receipt_times_out:
  {Jobs.follow_decision(False{}, True{}) == Jobs.Expired{} : Jobs.Decision}

def expired_follow_without_receipt_times_out():
  {==}

law followed_event_is_never_repeated:
  for line: String
  for cursor: U32
  for next: U32
  {Jobs.fresh(line, cursor, next, False{}) == Jobs.Followed{cursor, Nil{}} : Jobs.Followed}

def followed_event_is_never_repeated(line, cursor, next):
  {==}

# Storage format: a home written by a newer jev-fabric is refused and never
# adopted or rewritten, whatever the verb; the current format is used as is.
law newer_store_is_refused:
  for n: Nat
  for shown: String
  {Store.versioned(Nat.add(2n, n), shown) == Store.newer(shown) : Store.Decision}

def newer_store_is_refused(n, shown):
  {==}

law current_store_is_accepted:
  for shown: String
  {Store.versioned(1n, shown) == Store.Accept{} : Store.Decision}

def current_store_is_accepted(shown):
  {==}

law writer_adopts_unmarked_home:
  for created: Bool
  {Store.missing(True{}, created) == Store.Adopt{} : Store.Decision}

def writer_adopts_unmarked_home(created):
  {==}

law reader_leaves_old_home_unmarked:
  {Store.missing(False{}, False{}) == Store.Accept{} : Store.Decision}

def reader_leaves_old_home_unmarked():
  {==}

# Reads by byte offset: loss below the retained window is disclosed exactly,
# a read with nothing lost omits nothing, and an ended stream holds nothing back.
law minus_self:
  for n: Nat
  {Spool.minus(n, n) == 0n : Nat}

def minus_self(n):
  match n:
    case 0n:
      {==}
    case 1n+p:
      minus_self(p)

law read_from_start_discloses_loss:
  for oldest: Nat
  for count: Nat
  for max: Nat
  {Spool.span_omitted(Spool.span(oldest, count, 0n, max)) == oldest : Nat}

def read_from_start_discloses_loss(oldest, count, max):
  {==}

law nothing_lost_nothing_omitted:
  for offset: Nat
  for count: Nat
  for max: Nat
  {Spool.span_omitted(Spool.span(0n, count, offset, max)) == 0n : Nat}

def nothing_lost_nothing_omitted(offset, count, max):
  match offset:
    case 0n:
      {==}
    case 1n+q:
      minus_self(1n+q)

law ended_stream_holds_nothing_back:
  for bytes: List<&2, U32>
  {Spool.kept(bytes, True{}) == bytes : List<&2, U32>}

def ended_stream_holds_nothing_back(bytes):
  {==}

law long_poll_answers_at_its_ceiling:
  for returned: Bool
  for eof: Bool
  {Spool.answer_now(True{}, returned, eof) == True{} : Bool}

def long_poll_answers_at_its_ceiling(returned, eof):
  {==}

# Session children: a child lives for its requested time cut to what is left of
# its connection, and for the rest of the connection when none is requested.
law session_child_is_cut_to_its_connection:
  for requested: U32
  for left: U32
  {Serve.child_lifetime(Some{requested}, left) == U32.min(requested, left) : U32}

def session_child_is_cut_to_its_connection(requested, left):
  {==}

law session_child_defaults_to_its_connection:
  for left: U32
  {Serve.child_lifetime(None{}, left) == U32.min(left, left) : U32}

def session_child_defaults_to_its_connection(left):
  {==}

# Interactive jobs' input queue: ended input refuses every write, the bound
# admits a queue filled exactly and refuses one byte more, and draining hands
# the bytes over in the order they were written.
law closed_queue_refuses_writes:
  for total: Nat
  for max: Nat
  {Jobs.admit(True{}, total, max) == False{} : Bool}

def closed_queue_refuses_writes(total, max):
  {==}

law queue_admits_up_to_its_bound:
  for pending: Nat
  for bytes: Nat
  {Jobs.admit(False{}, Nat.add(pending, bytes), Nat.add(pending, bytes)) == True{} : Bool}

def queue_admits_up_to_its_bound(pending, bytes):
  Nat.ge_refl(Nat.add(pending, bytes))

law past_bound_is_not_within:
  for max: Nat
  for over: Nat
  {Nat.is_ge(max, Nat.add(max, 1n+over)) == False{} : Bool}

def past_bound_is_not_within(max, over):
  match max:
    case 0n:
      {==}
    case 1n+p:
      past_bound_is_not_within(p, over)

law queue_refuses_past_its_bound:
  for max: Nat
  for over: Nat
  {Jobs.admit(False{}, Nat.add(max, 1n+over), max) == False{} : Bool}

def queue_refuses_past_its_bound(max, over):
  past_bound_is_not_within(max, over)

law queue_keeps_arrival_order:
  for first: String
  for second: String
  {Jobs.drained(Jobs.push(Jobs.push(Jobs.empty_queue(), first), second)) == first ++ second : String}

def queue_keeps_arrival_order(first, second):
  {==}

law draining_empties_the_queue:
  for held: String
  for closed: Bool
  {Jobs.drained(Jobs.emptied(Jobs.Queue{held, closed})) == "" : String}

def draining_empties_the_queue(held, closed):
  {==}
