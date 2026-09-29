import Base
import ./StoreCore.bend as Store

# OS/private-filesystem boundary only. Job states, deadlines, events and polling
# policy live in Jobs.bend. All paths are relative to a checked private root.
# Operations: 0 self, 1 create, 2 read, 3 write, 4 claim, 5 alive, 6 spawn,
# 8 list, 9 clock, 10 parent, 11 enqueue, 12 dequeue, 13 remove, 14 platform,
# 15 directory, 16 store, 17 adopt (7 is jfh_spool's).
def jfh_os(
  op: U32,
  id: String,
  name: String,
  text: String,
  argv: List<String>,
  limit: U32,
) -> IO(Result<&1, &1, U32 & String, String>):
  import "./host.c"

# The writer is exclusively created; readers get independent owned descriptors.
# Consume both with File.close, or pass writers to Process.run_logged.
def jfh_spool(id: String, name: String, writing: Bool) -> IO(Result<&1, &1, U32 & String, File>):
  import "./host.c"

def spool(id: String, name: String, writing: Bool) -> IO(File):
  IO.try(File, jfh_spool(id, name, writing))

def self() -> IO(String):
  IO.try(String, jfh_os(0, "", "", "", [], 0))

# ---------------------------------------------------------------------------
# The storage format marker. Every verb that touches the store checks it first:
# a newer store is refused (code 22) and left untouched; a home without one is
# adopted by the first verb that writes to it.

def Checked() -> Type:
  Result<&1, &1, U32 & String, Unit>

# "+" when this call created the root, else "=", then the marker's text.
def store_answer() -> IO(Result<&1, &1, U32 & String, String>):
  jfh_os(16, "", "", "", [], 0)

def adopted(result: Result<&1, &1, U32 & String, String>) -> Checked:
  match result:
    case Fail{e}:
      Fail{e}
    case Done{text}:
      Done{Unit{}}

def store_decided(decision: Store.Decision) -> IO(Checked):
  match decision:
    case Store.Accept{}:
      IO.pure(Checked, Done{Unit{}})
    case Store.Adopt{}:
      do IO<Checked>:
        result : Result<&1, &1, U32 & String, String> <- jfh_os(17, "", "", Store.marker(), [], 0)
        return adopted(result)
    case Store.Refuse{message}:
      IO.pure(Checked, Fail{(Store.refused_code(), message)})

def store_read(answer: Result<&1, &1, U32 & String, String>, mutating: Bool) -> IO(Checked):
  match answer:
    case Fail{e}:
      IO.pure(Checked, Fail{e})
    case Done{text}:
      store_decided(Store.decide(text, mutating))

# As store, but a refusal is returned instead of ending the program.
def store_attempt(mutating: Bool) -> IO(Checked):
  do IO<Checked>:
    answer : Result<&1, &1, U32 & String, String> <- store_answer()
    store_read(answer, mutating)

def store(mutating: Bool) -> IO(Unit):
  IO.try(Unit, store_attempt(mutating))

def created(checked: Checked, max_jobs: U32) -> IO(Result<&1, &1, U32 & String, String>):
  match checked:
    case Fail{e}:
      IO.pure(Result<&1, &1, U32 & String, String>, Fail{e})
    case Done{ok}:
      jfh_os(1, "", "", "", [], max_jobs)

# A new private directory under a checked store, or the failure.
def make(max_jobs: U32) -> IO(Result<&1, &1, U32 & String, String>):
  do IO<Result<&1, &1, U32 & String, String>>:
    checked : Checked <- store_attempt(True{})
    created(checked, max_jobs)

def create(max_jobs: U32) -> IO(String):
  IO.try(String, make(max_jobs))

# Missing files return empty text; unsafe/oversize files fail closed.
def read(id: String, name: String, limit: U32) -> IO(String):
  IO.try(String, jfh_os(2, id, name, "", [], limit))

# As read, but a failure is returned instead of ending the program.
def attempt(id: String, name: String, limit: U32) -> IO(Result<&1, &1, U32 & String, String>):
  jfh_os(2, id, name, "", [], limit)

def write(id: String, name: String, text: String) -> IO(Unit):
  do IO<Unit>:
    # host.c rejects text longer than this limit.
    ignored : String <- IO.try(String, jfh_os(3, id, name, text, [], 1048576))
    return Unit{}

# Claim holds a private advisory lease until this process exits, then detaches.
def claim(id: String) -> IO(Unit):
  do IO<Unit>:
    ignored : String <- IO.try(String, jfh_os(4, id, "", "", [], 0))
    return Unit{}

def alive(id: String) -> IO(Bool):
  do IO<Bool>:
    text : String <- IO.try(String, jfh_os(5, id, "", "", [], 0))
    return String.eq(text, "1")

# As alive, returning "1" or "0", or the failure instead of ending the program.
def probe(id: String) -> IO(Result<&1, &1, U32 & String, String>):
  jfh_os(5, id, "", "", [], 0)

def spawn(argv: List<String>) -> IO(Result<&1, &1, U32 & String, String>):
  jfh_os(6, "", "", "", argv, 0)

# Newline-terminated ids of private job-shaped directories under the root, at
# most limit + 1 of them, in directory order. Other entries are skipped.
def list(limit: U32) -> IO(String):
  IO.try(String, jfh_os(8, "", "", "", [], limit))

# Wall-clock time in epoch milliseconds, as decimal digits.
def clock() -> IO(String):
  IO.try(String, jfh_os(9, "", "", "", [], 0))

# As write, but a failure is returned instead of ending the program.
def put(id: String, name: String, text: String) -> IO(Result<&1, &1, U32 & String, String>):
  jfh_os(3, id, name, text, [], 1048576)

# A new reader of a private file, or the failure (a missing file is ENOENT).
def open(id: String, name: String) -> IO(Result<&1, &1, U32 & String, File>):
  jfh_spool(id, name, False{})

# The parent process id, as decimal digits. It changes when the parent exits.
def parent() -> IO(String):
  IO.try(String, jfh_os(10, "", "", "", [], 0))

# Appends to a job's private input queue unless the queue would exceed `limit`
# bytes (ENOSPC) or input has ended (EPIPE); `close` ends input after the text.
def enqueue(id: String, text: String, close: Bool, limit: U32) -> IO(Result<&1, &1, U32 & String, String>):
  jfh_os(11, id, Bool.pick(String, close, "close", ""), text, [], limit)

# Takes every queued byte: "C" (input has ended) or "O", then the text.
def dequeue(id: String, limit: U32) -> IO(Result<&1, &1, U32 & String, String>):
  jfh_os(12, id, "", "", [], limit)

# Deletes a job directory whose worker has exited (EBUSY while its lease is held).
def remove(id: String) -> IO(Result<&1, &1, U32 & String, String>):
  jfh_os(13, id, "", "", [], 0)

# The build's operating system and CPU, such as darwin-arm64 or linux-x64.
def platform() -> IO(String):
  IO.try(String, jfh_os(14, "", "", "", [], 0))

# Whether an absolute path names an existing directory (a failure otherwise).
def directory(path: String) -> IO(Result<&1, &1, U32 & String, String>):
  jfh_os(15, "", "", path, [], 0)
