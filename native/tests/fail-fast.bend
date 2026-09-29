import Base
import ../Process.bend as Process

# Records its PID in the marker, then sleeps until the native exit reaps it.
def sleeper(marker: String) -> List<String>:
  ["/bin/sh", "-c", "printf '%s\\n' \"$$\" > \"$1\"; exec sleep 60", "sh", marker]

def await_marker(marker: String) -> List<String>:
  ["/bin/sh", "-c", "while [ ! -s \"$1\" ]; do sleep 0.01; done", "sh", marker]

def fail_fast(+marker: String) -> IO(Unit):
  do IO<Unit>:
    child : Chan(Process.Report) <- IO.fork(Process.Report, Process.run_input(sleeper(marker), "", 60000))
    ready : Process.Report <- Process.run_input(await_marker(marker), "", 1500)
    failure : Process.Report <- Process.run_input(["/jev-fabric-native-intentionally-missing"], "", 1000)
    IO.die(Unit, 1, "unreachable: missing command should fail")

def args(values: List<String>) -> IO(Unit):
  match values:
    case Con{marker, Nil{}}:
      fail_fast(marker)
    case values:
      IO.die(Unit, 2, "expected an owned marker path")

def main() -> IO(Unit):
  do IO<Unit>:
    # IO.args() starts with the program as invoked (Bend 2.0.32+).
    invoked : List<String> <- IO.args()
    values : List<String> = List.drop(&1, String, invoked, 1n)
    args(values)
