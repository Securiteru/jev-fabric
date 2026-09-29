import Base
import ../Codec.bend as Codec
import ../Wire.bend as Wire
import ../vendor/strict-json/json.bend as J

def print_result(value: Result<&1, &1, U32 & String, String>) -> IO(Unit):
  match value:
    case Done{text}:
      IO.print(text)
    case Fail{e}:
      IO.die(Unit, 1, "rejected")

def encoded(value: Result<&1, &1, U32 & String, J.JSON>) -> Result<&1, &1, U32 & String, String>:
  do Result<&1, &1, U32 & String, String>:
    v : J.JSON <- value
    Codec.encode(v)

def response(text: String, request: String) -> Result<&1, &1, U32 & String, String>:
  do Result<&1, &1, U32 & String, String>:
    req : J.JSON <- Wire.request(request)
    encoded(Wire.response(text, req))

def body(request: String, model: String) -> Result<&1, &1, U32 & String, String>:
  do Result<&1, &1, U32 & String, String>:
    req : J.JSON <- Wire.request(request)
    Wire.body(req, model)

def run(args: List<String>) -> IO(Unit):
  match args:
    case ["codec", text]:
      print_result(encoded(Codec.read(text)))
    case ["request", text]:
      print_result(encoded(Wire.request(text)))
    case ["response", request, text]:
      print_result(response(text, request))
    case ["body", request, model]:
      print_result(body(request, model))
    case other:
      IO.die(Unit, 2, "usage: codec/request text | response request text | body request model")

def main() -> IO(Unit):
  do IO<Unit>:
    # IO.args starts with the program as invoked (Bend 2.0.32+).
    invoked : List<String> <- IO.args
    args : List<String> = List.drop(&1, String, invoked, 1n)
    run(args)
