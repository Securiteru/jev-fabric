import Base
import ../Http.bend as Http

def show(result: Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(Unit):
  match result:
    case Fail{error}:
      IO.print("error")
    case Done{bytes}:
      IO.print("ok:" ++ Nat.show(List.length(&2, U32, bytes)))

# Posts `count` times from one process, so pooled connections can be reused.
def repeat(count: Nat, +url: String, +body: String) -> IO(Unit):
  match count:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+left:
      do IO<Unit>:
        reply : Result<&1, &1, U32 & String, List<&2, U32>> <- Http.post(
          url,
          "SYNTHETIC_NOT_A_SECRET",
          body,
          1500
        )
        show(reply)
        repeat(left, url, body)

def count_of(text: Maybe<&2, Nat>) -> Nat:
  match text:
    case None{}:
      1n
    case Some{n}:
      n

def dispatch(args: List<String>) -> IO(Unit):
  match args:
    case Con{url, Con{body, Nil{}}}:
      repeat(1n, url, body)
    case Con{url, Con{body, Con{count, Nil{}}}}:
      repeat(count_of(Nat.read(count)), url, body)
    case other:
      IO.die(Unit, 2, "expected URL, JSON body and optional repeat count")

def main() -> IO(Unit):
  do IO<Unit>:
    # IO.args() starts with the program as invoked (Bend 2.0.32+).
    invoked : List<String> <- IO.args()
    args : List<String> = List.drop(&1, String, invoked, 1n)
    dispatch(args)
