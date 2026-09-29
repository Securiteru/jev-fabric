import Base
import ./TimeCore.bend as Policy

def env_value(value: Result<&1, &1, U32 & String, String>) -> String:
  match value:
    case Fail{error}:
      ""
    case Done{text}:
      text

def env(name: String) -> IO(String):
  do IO<String>:
    value : Result<&1, &1, U32 & String, String> <- IO.get_env(name)
    return env_value(value)

def setting(name: String, fallback: U32, max: U32) -> IO(U32):
  do IO<U32>:
    raw : String <- env(name)
    IO.pass(U32, Policy.config(raw, fallback, max))

def max_timeout() -> U32:
  3600000

# The lifetime ceiling of a detached `start` job only.
def job_max_timeout() -> U32:
  Policy.job_max()

def work() -> IO(U32):
  setting("JEV_FABRIC_TIMEOUT_MS", Policy.work_default(), max_timeout())

def jev() -> IO(U32):
  setting("JEV_FABRIC_JEV_TIMEOUT_MS", Policy.jev_default(), max_timeout())

def wait() -> IO(U32):
  setting("JEV_FABRIC_WAIT_MS", Policy.wait_default(), max_timeout())

def watch() -> IO(U32):
  setting("JEV_FABRIC_WATCH_MS", Policy.watch_default(), 300000)
