import Base
import ../Process.bend as Process

def ok(report: Process.Report, code: U32, text: String) -> Bool:
  match report:
    case Process.Report{actual, timed_out, cancelled, out_cut, err_cut, out, err}:
      U32.is_eq(actual, code)
        && String.eq(out, text)
        && Bool.not(timed_out)
        && Bool.not(cancelled)

def assert(ok: Bool) -> IO(Unit):
  match ok:
    case False{}:
      IO.die(Unit, 1, "native IO assertion failed")
    case True{}:
      IO.pure(Unit, Unit{})

def waits_for_marker(marker: String) -> List<String>:
  ["/bin/sh", "-c", "while [ ! -f \"$1\" ]; do sleep 0.01; done; printf first", "sh", marker]

def creates_marker(marker: String) -> List<String>:
  ["/bin/sh", "-c", "printf ready > \"$1\"; printf second", "sh", marker]

def tests(+marker: String) -> IO(Unit):
  do IO<Unit>:
    # If an effect blocks Bend's IO loop, the first process times out before
    # the second can create this marker. No timing benchmark is needed.
    first : Chan(Process.Report) <- IO.fork(
      Process.Report,
      Process.run_input(waits_for_marker(marker), "", 1500)
    )
    second : Chan(Process.Report) <- IO.fork(
      Process.Report,
      Process.run_input(creates_marker(marker), "", 1500)
    )
    a : Process.Report <- IO.join(Process.Report, first)
    b : Process.Report <- IO.join(Process.Report, second)
    assert(ok(a, 0, "first"))
    assert(ok(b, 0, "second"))
    echo : Process.Report <- Process.run_input(["/bin/cat"], "native stdin\n", 1000)
    assert(ok(echo, 0, "native stdin\n"))
    IO.print("native IO assertions: 3")

def args(values: List<String>) -> IO(Unit):
  match values:
    case Con{marker, Nil{}}:
      tests(marker)
    case values:
      IO.die(Unit, 2, "expected an owned marker path")

def main() -> IO(Unit):
  do IO<Unit>:
    # IO.args() starts with the program as invoked (Bend 2.0.32+).
    invoked : List<String> <- IO.args()
    values : List<String> = List.drop(&1, String, invoked, 1n)
    args(values)
