<img src="https://raw.githubusercontent.com/monotykamary/jev-fabric/main/static/banner-ink.svg" alt="jev-fabric" width="100%" />

# jev-fabric 🧵

Native process orchestration with typed, explicit Jev decisions. One small
executable owns your processes, remembers what they said, and asks
[Jev](https://typesafe.ai/blog/introducing-system-one-models-and-jev) a question
**only when you tell it to**.

Written in [Bend](https://github.com/bendlang/bend). No Node, Python or daemon at
runtime. Independent of Pi, Codex, Claude or any other harness.

```text
● agent: starts a dev server, a test run, a game bridge
│
● jev-fabric owns each one: process group, deadline, bounded logs
│
● agent watches for "ready", reads a bounded receipt, not 40 MB of logs
│
● one fuzzy call left? ask Jev: choice · noul · score, never free text
│
✓ typed answer → a branch you already wrote          no hidden inference
```

**Your agent now has hands that don't get lost in the logs.**

<img src="https://raw.githubusercontent.com/monotykamary/jev-fabric/main/static/demo.svg" alt="jev-fabric racing Wikipedia and playing Doom with typed Jev choices" width="100%" />

## Give it to your agent

Paste this into Codex, Claude Code or any coding agent:

```text
Install jev-fabric with `curl -fsSL https://raw.githubusercontent.com/monotykamary/jev-fabric/main/install.sh | sh`, add its skill with `npx skills add monotykamary/jev-fabric`, then verify with `jev-fabric -- exec /bin/echo ready`. Don't make any Jev (network model) calls until I give you credentials and ask.
```

That's it. The agent installs a checksum-verified release, learns the workflow
from the skill, and proves the binary runs.

## Install it yourself

```sh
curl -fsSL https://raw.githubusercontent.com/monotykamary/jev-fabric/main/install.sh | sh
npx skills add monotykamary/jev-fabric        # or: bunx skills add monotykamary/jev-fabric
```

Releases ship a macOS universal binary and Linux x64/arm64 binaries. The installer
verifies `SHA256SUMS`, installs to `~/.local/bin/jev-fabric`, and puts the Bend
library at `~/.local/share/jev-fabric/current/native`. Set `JEV_FABRIC_VERSION=v0.1.0`
to pin a release or `JEV_FABRIC_PREFIX` to change the prefix.

Update any time with `jev-fabric -- update`. Like `bend update`, it prints and
runs the same `curl … | sh`, and the variables above still apply.

From npm, with no install script or download at install time:

```sh
npx jev-fabric -- --version                    # or: npm install -g jev-fabric
```

npm installs only the matching `jev-fabric-darwin`, `jev-fabric-linux-x64` or
`jev-fabric-linux-arm64` package (Linux builds need glibc 2.28 or newer). Hosts
that embed jev-fabric call `require("jev-fabric").binaryPath()` and spawn the
executable directly; the `serve` clients ship in the package too. Pi Fabric
prefers your own compatible install and falls back to this package.

<details>
<summary>Build from source</summary>

Requires **Bend 2.0.34**, Clang and Bun (for the build-time safety gate).

```sh
sh scripts/build-native.sh             # or: bun run build
build/jev-fabric -- --help
```

</details>

## A handful of verbs. Every process.

```sh
jev-fabric -- exec /bin/echo hello                        # literal argv, bounded receipt
printf 'hi\n' | jev-fabric -- exec --stdin /bin/cat         # forward stdin
jev-fabric -- run examples/native/pipeline.bend             # compile + run Bend (needs bend)

id=$(jev-fabric -- start --label dev /bin/sh -c 'npm run dev' | jq -r .id)   # survives its launcher
jev-fabric -- watch "$id" ready                            # live, filtered, bounded lines
jev-fabric -- follow "$id"                                 # live JSONL events until it ends
jev-fabric -- events "$id"                                 # bounded JSONL replay
jev-fabric -- wait "$id"                                   # waiting never cancels
jev-fabric -- stop "$id"                                   # idempotent, never signals a stale PID
jev-fabric -- list                                         # every job in this storage root
jev-fabric -- read "$id" stdout 0                          # raw bytes by offset
jev-fabric -- exec --cwd /srv/app /bin/ls                  # start in another directory
jev-fabric -- capabilities                                 # protocol, store format, features
```

The first `--` separates Bend runtime options from yours. Shell syntax only
happens when you invoke a shell. Every child gets its own process group and a
deadline; receipts keep 32 KiB tails, spools keep the first 1 MiB per stream,
jobs keep their latest 64 events, and any loss is disclosed, never silent.

**Timers are optional ceilings, not delays.** Work defaults to one hour, Jev to
30 s, `wait` and `follow` to 30 s and `watch` to 5 s. Override per call with
`--timeout-ms N` before the command, or once with `JEV_FABRIC_TIMEOUT_MS`,
`JEV_FABRIC_JEV_TIMEOUT_MS`, `JEV_FABRIC_WAIT_MS` and `JEV_FABRIC_WATCH_MS`.
A `start` job alone may be given up to 24 hours (`--timeout-ms 86400000`), for
dev servers and other long-lived work; its default stays the work default.

**Interactive jobs.** `start --input pipe` keeps a job's stdin open: `write` and
`close-input` feed it from any process, through a bounded private queue its
worker drains every 25 ms, and `read` returns its output by byte offset.

```sh
id=$(jev-fabric -- start --input pipe -- python3 -u -i | jq -r .id)
printf 'print(6 * 7)\n' | jev-fabric -- write "$id" --stdin
jev-fabric -- read --wait-ms 5000 "$id" stdout      # {"text":"42\n","next":3,...}
```

**Jobs are durable, not tied to one harness.** Any process that shares a storage
root (`JEV_FABRIC_HOME`, or `.jev-fabric-native/` in the working directory) can
`list` its jobs, `follow` one as it runs, or pick it up again after a restart.
`follow` prints each retained event as the worker publishes it, discloses
evicted events with a `follow.loss` record, and ends with one `follow.end`
carrying the final receipt. A default root is created with a `.gitignore`.
Every root records its format (`.jev-fabric-store.json`), so different
jev-fabric versions share it safely: a root written by a newer format is
refused, never rewritten.

## Typed decisions, on purpose

Jev is a *System One* model: it answers structured questions with typed values
in a few hundred milliseconds instead of generating text.

```sh
export JEV_PROVIDER=typesafe
export JEV_CREDENTIAL_COMMAND='["pass","show","typesafe"]'   # or TYPESAFE_API_KEY
jev-fabric -- validate examples/native/request.json          # offline
jev-fabric -- jev examples/native/request.json 10000         # one billed call
```

```json
{"model":"jev-1.13.0","answers":{
  "healthy":{"type":"noul","noul":0.95},
  "next":{"type":"choice","choice":"verify","confidence":1.0,"probabilities":{"verify":1.0,"repair":0.0}},
  "confidence":{"type":"score","score":1.0,"confidence":1.0,"probabilities":{"0":0.0,"1":1.0},"legend":{"0":"Low","1":"High"}}},
  "usage":{"input_tokens":380,"output_tokens":61}}
```

- **Nothing calls Jev implicitly.** No output, match or exit code triggers a model call.
- **Strict both ways.** Requests and answers pass strict JSON/UTF-8 and complete
  choice/noul/score validation: a `choice` is always one of your keys,
  probabilities sum to one, unknown fields are stripped.
- **Private credentials.** Keys come from the provider variable or a literal argv
  resolver, and never enter argv, logs or receipts.
- **Budgets and no retries.** Clients bound calls and reported tokens. Failed
  dispatches still count, and nothing is retried automatically.
- **Warm connections.** HTTPS runs through the system libcurl in-process with a
  pooled TLS connection: verified certificates, no redirects, no proxies, 1 MiB
  bound. `JEV_FABRIC_HTTP=exec` forces a fresh `curl` process per request.

## Sessions from Python or TypeScript

`jev-fabric -- serve` keeps one process open and speaks JSONL on stdin/stdout:
one request per line, one response per line, matched by `id`. Requests run
concurrently, so a long poll never holds up the next request. The session holds
one Jev client, so its call and token budget covers the whole session, its
credential resolves once, and its TLS connection stays warm. Each job request
runs the CLI as a child, so a failing command costs one error response, never
the session.

It also owns **session children**: interactive processes that live as long as
the connection, with stdin you `write` to and output you `read` by byte offset.
A write-then-read round trip through a `cat` child takes about 3 ms.

```text
→ {"id":1,"op":"spawn","argv":["python3","-u","-i"]}
← {"id":1,"ok":true,"result":{"id":"s-9c…","lifetime":"session","state":"running",…}}
→ {"id":2,"op":"read","job":"s-9c…","stream":"stdout","waitMs":5000}
→ {"id":3,"op":"write","job":"s-9c…","text":"print(6 * 7)\n"}
← {"id":3,"ok":true,"result":{"id":"s-9c…","written":13,"closed":false}}
← {"id":2,"ok":true,"result":{"id":"s-9c…","stream":"stdout","offset":0,"bytes":3,"omittedBytes":0,"text":"42\n","next":3,"eof":false,"state":"running"}}
```

Each stream keeps a rolling window of the latest 1 MiB; offsets never reset and
a read below the window discloses the gap as `omittedBytes`. Closing the
connection stops its children. The shared vocabulary for lifetimes, verbs and
records is in [Shell composition](docs/composition.md).

```python
from jev_fabric import Fabric                     # clients/python, stdlib only

with Fabric(max_evaluations=20) as fabric:        # explicit session budget
    job = fabric.start(["/bin/sh", "-c", "npm run dev"])
    fabric.watch(job, "ready", timeout_ms=30000)
    answer = fabric.jev(request)                  # typed, validated, warm connection

    repl = fabric.spawn(["python3", "-u", "-i"])["id"]   # ends with the session
    fabric.write(repl, "print(6 * 7)\n")
    print(fabric.read(repl, "stdout", wait_ms=5000)["text"])
```

```ts
import { Fabric } from './jev-fabric.ts';         // clients/typescript, node: built-ins only

const fabric = await Fabric.open({ maxEvaluations: 20 });
const receipt = await fabric.exec(['make', 'test'], { timeoutMs: 600000 });
await fabric.close();
```

Both clients are single files with no dependencies, installed at
`~/.local/share/jev-fabric/current/clients/`. They only frame JSON; budgets,
deadlines, credentials and validation stay in the binary. Any other language can
speak the [protocol](docs/serve-protocol.md) directly. See
[`examples/clients/`](examples/clients/) for runnable versions.

## Loops in Bend

When a loop needs more than one request at a time (persistent child sessions,
concurrent effects, shared deadline scopes), write a small Bend program: one
affine Jev client, one warm connection, and the checked library.

| Demo | What it does | Measured |
| --- | --- | --- |
| [`wikirace.bend`](examples/native/wikirace.bend) | Races Wikipedia links toward a target. Pages with more than 255 links become a tournament of 255-way `choice` calls | Doom (1993) → Albert Einstein in **3 clicks, 6.6 s** |
| [`doom.bend`](examples/native/doom.bend) + [`bridge.py`](examples/doom/) | Plays ViZDoom's *defend the center* from structured game state, one `choice` per tick | **11 kills, no damage** in 150 decisions, **408 ms** mean |
| [`persistent.bend`](examples/native/persistent.bend) | One child process keeps state across three JSONL requests | offline |
| [`scoped.bend`](examples/native/scoped.bend) | Concurrent processes share one deadline budget | offline |

Pooled HTTPS turned the Doom loop from **1144 ms → 365 ms** per decision: only
the first call pays the TLS handshake.

```python
import Base
import ./native/Jev.bend as Jev

def main() -> IO(Unit):
  do IO<Unit>:
    client : Jev.Client <- IO.try(Jev.Client, Jev.connect(1, 10000))   # calls, tokens
    result : Jev.Returned <- Jev.evaluate(client, request_json)
    ...
```

See the [native API](docs/native-api.md) and the skill's
[Bend reference](skills/jev-fabric/references/bend-api.md).

## Boundaries

- **Trusted native execution, not a sandbox.** Commands run with your privileges.
- **`exited` is not success.** A zero exit is an observation; verify the work.
- **Bounded observations, not a lossless protocol.** No reboot resume,
  exactly-once execution or rollback.
- **Checked policy core.** Project Bend code has no unsafe definitions; sixteen
  pure policy modules and three proof roots check without trust warnings, and 49
  laws cover selected runtime policy. Effects cross an explicit, allowlisted
  foreign boundary of ten C functions. This is
  [scoped proof coverage](docs/safe-bend.md), not whole-program verification.

## Develop

```sh
bun install --frozen-lockfile --ignore-scripts
bun run check:native-safety      # also enforced by native builds
bun run test:native              # includes serve conformance and both clients (needs python3)
bun run typecheck                # the TypeScript client and example
bun run demo                     # native, no model call
```

More: [architecture](docs/architecture.md), [shell composition](docs/composition.md),
[serve protocol](docs/serve-protocol.md),
[Bend migration](docs/bend-migration.md), [acceptance ledger](docs/native-rewrite-ledger.md).

## License

MIT
