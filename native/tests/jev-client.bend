import Base
import ../Jev.bend as Jev
import ../Codec.bend as Codec

def show_error(e: U32 & String) -> IO(Unit):
  (code, message) = e
  IO.print("error:" ++ message)

def show(r: Jev.Evaluation) -> IO(Unit):
  match r:
    case Fail{e}:
      show_error(e)
    case Done{v}:
      do IO<Unit>:
        s : String <- IO.pass(String, Codec.encode(v))
        IO.print(s)

def done(result: Jev.Returned) -> IO(Unit):
  (client, value) = result
  show(value)

def second(first: Jev.Returned, request: String) -> IO(Unit):
  (client, result) = first
  do IO<Unit>:
    show(result)
    next : Jev.Returned <- Jev.evaluate(client, request)
    done(next)

def run(+request: String, calls: Maybe<&2, U32>, tokens: Maybe<&2, U32>) -> IO(Unit):
  match calls tokens:
    case Some{n} Some{t}:
      do IO<Unit>:
        client : Jev.Client <- IO.try(Jev.Client, Jev.from_env(1500, n, t))
        first : Jev.Returned <- Jev.evaluate(client, request)
        second(first, request)
    case _ _:
      IO.die(Unit, 2, "bad limits")

def args(values: List<String>) -> IO(Unit):
  match values:
    case Con{request, Con{calls, Con{tokens, Nil{}}}}:
      run(request, U32.read(calls), U32.read(tokens))
    case other:
      IO.die(Unit, 2, "expected request calls tokens")

def main() -> IO(Unit):
  do IO<Unit>:
    # IO.args() starts with the program as invoked (Bend 2.0.32+).
    invoked : List<String> <- IO.args()
    values : List<String> = List.drop(&1, String, invoked, 1n)
    args(values)
