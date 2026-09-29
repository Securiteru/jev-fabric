import Base
import ../Codec.bend as Codec
import ../Wire.bend as Wire
import ../vendor/strict-json/json.bend as J

def ok(value: Result<&1, &1, U32 & String, J.JSON>) -> Bool:
  match value:
    case Done{v}:
      True{}
    case Fail{e}:
      False{}

def number(value: Result<&1, &1, U32 & String, Nat>, expected: Nat) -> Bool:
  match value:
    case Done{v}:
      Nat.is_eq(v, expected)
    case Fail{e}:
      False{}

def numeric(text: String, scale: Nat, maximum: Nat) -> Result<&1, &1, U32 & String, Nat>:
  do Result<&1, &1, U32 & String, Nat>:
    value : J.JSON <- Codec.read(text)
    Wire.scalar(value, scale, maximum)

def request_text() -> String:
  "{\"state\":{},\"questions\":{\"q\":{\"type\":\"noul\",\"instructions\":\"x\"}}}"

def response_text(n: String) -> String:
  "{\"model\":\"jev\",\"answers\":{\"q\":{\"type\":\"noul\",\"noul\":" ++ n
    ++ "}},\"usage\":{\"input_tokens\":1,\"output_tokens\":2}}"

# A one-question request with array state around a raw question object.
def question_request(question: String) -> String:
  "{\"state\":[],\"questions\":{\"q\":" ++ question ++ "}}"

def response(text: String) -> Result<&1, &1, U32 & String, J.JSON>:
  do Result<&1, &1, U32 & String, J.JSON>:
    req : J.JSON <- Wire.request(request_text())
    Wire.response(text, req)

def counts(value: Result<&1, &1, U32 & String, Nat & Nat>, input: Nat, output: Nat) -> Bool:
  match value:
    case Done{pair}:
      (actual_input, actual_output) = pair
      Nat.is_eq(actual_input, input) && Nat.is_eq(actual_output, output)
    case Fail{e}:
      False{}

def counted(value: Result<&1, &1, U32 & String, Nat & Nat>) -> Bool:
  match value:
    case Done{pair}:
      True{}
    case Fail{e}:
      False{}

def reply(text: String, request: String) -> Result<&1, &1, U32 & String, Wire.Reply>:
  do Result<&1, &1, U32 & String, Wire.Reply>:
    req : J.JSON <- Wire.request(request)
    Wire.reply(text, req)

# The counts JevCore accounts from a reply, via the fast path and via Wire.usage.
def reply_usage(text: String, request: String) -> Result<&1, &1, U32 & String, Nat & Nat>:
  do Result<&1, &1, U32 & String, Nat & Nat>:
    normalized : Wire.Reply <- reply(text, request)
    Wire.reply_usage(normalized)

def response_for(text: String, request: String) -> Result<&1, &1, U32 & String, J.JSON>:
  do Result<&1, &1, U32 & String, J.JSON>:
    req : J.JSON <- Wire.request(request)
    Wire.response(text, req)

def response_usage(text: String, request: String) -> Result<&1, &1, U32 & String, Nat & Nat>:
  do Result<&1, &1, U32 & String, Nat & Nat>:
    normalized : J.JSON <- response_for(text, request)
    Wire.usage(normalized)

# A score legend copies request criteria into the reply: a request string near 1 MiB
# plus long response lexemes yields a valid response whose normalized reply is too big.
def large_legend_request() -> String:
  "{\"state\":{},\"questions\":{\"q\":{\"type\":\"score\",\"instructions\":\"x\","
    ++ "\"criteria\":[\"a\",\"" ++ String.repeat("b", 1048000n) ++ "\"]}}}"

def long_half() -> String:
  "0.5" ++ String.repeat("0", 1000n)

def large_legend_response() -> String:
  "{\"model\":\"jev\",\"answers\":{\"q\":{\"type\":\"score\",\"score\":1,"
    ++ "\"confidence\":" ++ long_half()
    ++ ",\"probabilities\":{\"0\":" ++ long_half() ++ ",\"1\":" ++ long_half() ++ "}}},"
    ++ "\"usage\":{\"input_tokens\":1,\"output_tokens\":2}}"

def check(tests: List<&2, Bool>, n: Nat) -> IO(Unit):
  match tests:
    case Nil{}:
      IO.print("native wire assertions: " ++ Nat.show(n))
    case Con{True{}, tail}:
      check(tail, 1n+n)
    case Con{False{}, tail}:
      IO.die(Unit, 1, "native wire assertion failed at " ++ Nat.show(n))

def main() -> IO(Unit):
  check([
    ok(Wire.request(request_text())),
    Bool.not(ok(Wire.request("{}"))),
    Bool.not(ok(Wire.request("{\"state\":null,\"questions\":{}}"))),
    Bool.not(ok(Wire.request("{\"state\":{},\"questions\":{}}"))),
    ok(Wire.request(question_request(
      "{\"type\":\"choice\",\"instructions\":{},\"criteria\":{\"a\":null}}"
    ))),
    ok(Wire.request(question_request(
      "{\"type\":\"score\",\"instructions\":{},\"criteria\":[\"a\",{}]}"
    ))),
    Bool.not(ok(Wire.request(question_request(
      "{\"type\":\"score\",\"instructions\":{},\"criteria\":[\"a\"]}"
    )))),
    Bool.not(ok(Wire.request(question_request("{\"type\":\"text\",\"instructions\":{}}")))),
    number(numeric("0.125", 12n, Wire.unit()), Nat.mul(125000n, 1000000n)),
    number(numeric("1e0", 12n, Wire.unit()), Wire.unit()),
    number(numeric("1000e-3", 12n, Wire.unit()), Wire.unit()),
    number(numeric("-0.000e-1000", 12n, Wire.unit()), 0n),
    Bool.not(number(numeric("-1e-1000", 12n, Wire.unit()), 0n)),
    Bool.not(number(numeric("1.000000000000000000001", 12n, Wire.unit()), Wire.unit())),
    Bool.not(number(numeric("1.000000000001", 12n, Wire.unit()), Wire.unit())),
    number(numeric("16777217", 0n, Wire.nat_max()), 16777217n),
    number(numeric("16777217.000", 0n, Wire.nat_max()), 16777217n),
    Bool.not(number(numeric("16777217.00000001", 0n, Wire.nat_max()), 16777217n)),
    Bool.not(number(numeric("281474976710656", 0n, Wire.nat_max()), 0n)),
    number(numeric("281474976710655", 0n, Wire.nat_max()), Wire.nat_max()),
    Bool.not(number(numeric("9007199254740992", 0n, Wire.nat_max()), 0n)),
    Bool.not(number(numeric("1e999999999999", 0n, Wire.nat_max()), 0n)),
    ok(response(response_text("0.1"))), ok(response(response_text("1"))),
    Bool.not(ok(response(response_text("-1e-1000")))),
    Bool.not(ok(response(response_text("1.0000000000000000000001")))),
    Bool.not(ok(response(response_text("true")))),
    Bool.not(ok(response(
      "{\"model\":42,\"answers\":{},\"usage\":{\"input_tokens\":1,\"output_tokens\":2}}"
    ))),
    counts(reply_usage(response_text("0.1"), request_text()), 1n, 2n),
    counts(response_usage(response_text("0.1"), request_text()), 1n, 2n),
    Bool.not(counted(reply_usage(response_text("true"), request_text()))),
    ok(response_for(large_legend_response(), large_legend_request())),
    Bool.not(counted(response_usage(large_legend_response(), large_legend_request()))),
    Bool.not(counted(reply_usage(large_legend_response(), large_legend_request())))
  ], 0n)
