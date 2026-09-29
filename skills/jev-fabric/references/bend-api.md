# Writing jev-fabric programs in Bend

Use a Bend program when a task needs a loop: many Jev calls with one client, a
persistent child process, or processes and decisions sharing one deadline.
Requires the Bend 2.0.34 compiler (`bend guide` is the language reference).

## Setup

Imports are relative paths. Link the installed library next to your program:

```bash
ln -s ~/.local/share/jev-fabric/current/native native   # from a curl install
jev-fabric -- run bot.bend some-arg                      # compile + run, one deadline
# or compile once and reuse:
bend bot.bend -o bot && ./bot -- some-arg
```

```python
import Base
import ./native/Process.bend as Process
import ./native/Session.bend as Session
import ./native/Jev.bend as Jev
import ./native/Codec.bend as Codec
import ./native/Scope.bend as Scope
```

Bend essentials: values are affine (use once; `+x` to reuse `Data`), a `match` only
inspects a parameter (move computed values into a helper def), no mutual recursion,
defs only call defs above them, and loops count down a `Nat` fuel argument.
`IO.args()` starts with the program as invoked; drop it before parsing arguments.

## Process.bend

```python
report : Process.Report <- Process.exec(["/bin/echo", "hi"])
report : Process.Report <- Process.exec_input(["/bin/cat"], "buffered stdin")
report : Process.Report <- Process.run_input(argv, "", 5000)  # explicit ms ceiling
report : Process.Report <- Process.run_in(argv, "", 5000, False{}, "/abs/dir")  # in a cwd
IO.print(Process.show(report))                                 # JSON receipt
```

`Process.capture(argv, input, timeout_ms, cap)` returns raw bytes (exit code,
flags, stdout, stderr) for binary-safe output up to ~1 MiB. At most 32
concurrent children per process, 64 argv entries.

## Session.bend: a persistent child

```python
session : Session.Session <- Session.open(["python3", "bridge.py"])
pair : Session.Session & Session.Written <- Session.write(session, "move\n")
pair : Session.Session & Session.Bytes <- Session.read_stdout(session, offset, 65536)
report : Process.Report <- IO.try(Process.Report, Session.wait(session))
```

Thread the returned session into the next call. An empty read is not EOF: poll
with a short `IO.sleep` and a fuel bound until your protocol's line terminator
arrives, advancing `offset` by the bytes received. Each stream spools its first
1 MiB; restart the child before that if the protocol is long-lived. Always
`Session.wait` at the end.

## Jev.bend

```python
client : Jev.Client <- IO.try(Jev.Client, Jev.connect(200, 1000000))  # calls, tokens
returned : Jev.Returned <- Jev.evaluate(client, request_json)
```

`Jev.Returned` is `Jev.Client & Result<..., Codec.Value>`. Destructure it in a
helper def, keep the client for the next call, and branch on the result:

```python
def decided(returned: Jev.Returned) -> IO(Jev.Client):
  (client, result) = returned
  match result:
    case Fail{(code, message)}:
      do IO<Jev.Client>:
        IO.print("jev failed: " ++ message)
        return client
    case Done{value}:
      do IO<Jev.Client>:
        text : String <- IO.pass(String, Codec.encode(value))
        IO.print(text)
        return client
```

Read fields with `Codec.field(value, "answers")`, `Codec.text(v)` and `Codec.array(v)`
inside a `do Maybe<&2, T>:` block. Build request JSON with `Json.quote` for every
string you interpolate. The affine client prevents overlapping evaluations; the
first call resolves the credential and later calls reuse it and the pooled TLS
connection.

## Scope.bend: one shared deadline

```python
+scope : Scope.Budget <- Scope.open()                 # or Scope.with_timeout(ms)
report : Process.Report <- Scope.exec(scope, argv)
returned : Jev.Returned <- Scope.evaluate(scope, client, request)
```

Every operation uses the remaining time; expired budgets refuse to launch or
dispatch (code 124) instead of starting work.

## Environment

| Variable | Effect |
| --- | --- |
| `JEV_PROVIDER` | `typesafe` (default), `openrouter` or `vercel` |
| `TYPESAFE_API_KEY` / `OPENROUTER_API_KEY` / `AI_GATEWAY_API_KEY` | Provider key |
| `JEV_CREDENTIAL_COMMAND` | JSON argv printing the key, e.g. `["pass","show","jev"]` |
| `JEV_MODEL` | Model override |
| `JEV_FABRIC_HTTP` | `auto` (default: pooled libcurl, curl fallback), `pooled` or `exec` |
| `JEV_FABRIC_TIMEOUT_MS` / `JEV_FABRIC_JEV_TIMEOUT_MS` | Default ceilings |
| `JEV_FABRIC_HOME` | Job storage root (default `.jev-fabric-native`) |
