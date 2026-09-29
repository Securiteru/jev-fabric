import Base

# ASan diagnostic reproducer: no project imports and no custom foreign effect.
def usage() -> IO(Unit):
  IO.print("native dispatch probe")

def execute(argv: List<String>, timeout: Maybe<&2, U32>) -> IO(Unit):
  match timeout:
    case None{}:
      IO.die(Unit, 2, "invalid timeout")
    case Some{ms}:
      IO.print(U32.show(ms))

def dispatch(args: List<String>) -> IO(Unit):
  match args:
    case Nil{}:
      usage()
    case Con{"--help", Nil{}}:
      usage()
    case Con{"--version", Nil{}}:
      IO.print("probe")
    case Con{"exec", Con{timeout, Con{"--stdin", Con{command, rest}}}}:
      execute(Con{command, rest}, U32.read(timeout))
    case Con{"exec", Con{timeout, Con{command, rest}}}:
      execute(Con{command, rest}, U32.read(timeout))
    case args:
      IO.die(Unit, 2, "unsupported")

def main() -> IO(Unit):
  do IO<Unit>:
    # IO.args() starts with the program as invoked (Bend 2.0.32+).
    invoked : List<String> <- IO.args()
    args : List<String> = List.drop(&1, String, invoked, 1n)
    dispatch(args)
