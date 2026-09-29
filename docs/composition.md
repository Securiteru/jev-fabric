# Shell composition

One vocabulary for running, observing and driving processes, shared by the
`jev-fabric` CLI, the `serve` protocol, the Bend library and hosts that embed
jev-fabric (such as Pi Fabric). A caller should be able to move a command between
these surfaces without relearning its lifetime, its observation calls or its
records. This document is the contract; the [CLI](native-api.md) and
[serve protocol](serve-protocol.md) references give the exact syntax.

## Two axes

Every child has a **lifetime** (who owns it) and an **I/O mode** (how you talk to it).

| Lifetime | Owner | Ends when | CLI | serve | Pi Fabric |
| --- | --- | --- | --- | --- | --- |
| `foreground` | the calling request | it exits or its deadline passes | `exec` | `exec` | `pi.bash({cmd})` |
| `session` | one live owner: a `serve` connection or a host session | the owner ends, it exits, or it is stopped | none | `spawn` | `pi.bash({background:true})`, `sessions.open` |
| `durable` | the storage home | it exits, its deadline passes, or it is stopped | `start` | `start` | `pi.bash({durable:true})`, `sessions.open({durable:true})` |

| I/O mode | stdin | Output | Available for |
| --- | --- | --- | --- |
| `batch` | closed, or buffered input written once | receipts, events, `watch`, `follow` | every lifetime |
| `interactive` | open: `write`, then `closeInput` | the above plus `read` by byte offset | `session`, `durable` |

A `session` child is the low-latency choice: its stdin is a pipe held by the
owner and a write reaches it immediately (a `serve` echo round trip, write then
read, takes a few milliseconds). A `durable` interactive child is fed
through a private input queue that its worker drains every tick (25 ms), so it
trades latency for surviving its launcher. Realtime control loops use
`session` children; long-lived services that must outlive a harness use `durable`.
A durable interactive child starts with `start --input pipe`; its queue holds at
most 1 MiB not yet read, and it is not replayed if the worker crashes.

Ending an owner stops its `session` children (process group, then force) and
never touches `durable` jobs; if the owner is killed outright, each child's
worker notices within 25 ms and stops it. No lifetime is restart-durable across
a reboot.

Any child may start in a working directory of its own: `cwd` in `serve`,
`--cwd` for `exec` and `start`. It never moves the storage home.

## One set of verbs

The same names and meanings everywhere. Timers are always ceilings, never delays;
waiting or reading never cancels, renews or stops anything.

| Verb | Meaning | Record |
| --- | --- | --- |
| `status` | current state, or the final receipt | state or receipt |
| `wait` | until final, or the ceiling | receipt, or running state |
| `events` | retained events after a sequence cursor; optional long-poll (`waitMs`) | event array |
| `follow` | live stream of events until final or the ceiling (CLI) | event lines, `follow.loss`, `follow.end` |
| `watch` | filtered, deduplicated line batches | `monitor.batch`, `monitor.loss`, `monitor.end` |
| `read` | raw bytes of one stream from a byte offset; optional long-poll (`read` CLI, `read` op) | read record |
| `write` | append text to an interactive child's stdin (`write` CLI, `write` op) | write record |
| `closeInput` | send EOF; idempotent (`close-input` CLI, `closeInput` op) | write record |
| `stop` | stop by ID, never by PID: `SIGTERM` to the process group, then `SIGKILL` after 500 ms; idempotent | receipt or state |
| `list` | jobs in the store; in `serve` with `scope: "session"`, this owner's children | list record |

### Records

States: `starting`, `running`, `exited`, `failed`, `timed_out`, `cancelled`.
`exited` means exit code zero, not that the task succeeded.

Receipts, events (`job.started`, `process.output`, `process.spool_limit`,
`job.finished`), `follow.loss`/`follow.end` and `list` keep their 0.4 shapes.
Session children use the same receipt and event shapes, with `"lifetime":"session"`
and an `s-` prefixed ID; durable jobs report `"lifetime":"durable"`. The store's
`list` never includes session children; a session listing marks each entry
`"lifetime":"session"`.

A **read record** is:

```json
{"id":"s-3f…","stream":"stdout","offset":4096,"bytes":512,"omittedBytes":0,
 "text":"…","next":4608,"eof":false,"state":"running"}
```

- Offsets count bytes the child wrote to that stream since launch; they never reset.
- Each interactive stream retains a **rolling window** of the latest 1 MiB. Reading
  below the window returns the oldest retained bytes with `omittedBytes` set: loss
  is disclosed, never joined silently. Batch spools keep their first-1 MiB rule.
- `max` is at most 65536 bytes (the default); `offset` defaults to 0.
- `text` is decoded UTF-8; a partial character at the end is held for the next
  read. `encoding: "base64"` returns `data` instead, byte-exact.
- With `waitMs`, a read returns as soon as bytes past `offset` exist, the stream
  ends (`eof`), or the ceiling passes (`bytes: 0`).
- `eof` is true once the child has finished and nothing past `next` remains.

A **write record** is `{"id":…,"written":N,"closed":false}`, `N` counting UTF-8
bytes; `closeInput` answers `{"id":…,"written":0,"closed":true}`. A write to a
finished child or a closed stdin is an error, not a silent drop.

## Capabilities

Hosts must not guess from a version string.

```sh
jev-fabric -- capabilities
```

```json
{"version":"0.5.0-native","protocol":2,"store":1,"platform":"darwin-arm64",
 "features":["follow","list","label","start-24h","serve-24h","serve-concurrent",
             "sessions","cwd","durable-input","read","jev-request-credential"]}
```

`platform` is one of `darwin-arm64`, `darwin-x64`, `linux-x64` and `linux-arm64`.

The `serve` banner carries the same `protocol`, `store` and `features`. A host
requires a protocol major and a feature set, accepts newer binaries that satisfy
them, and reports which binary it chose. Features are only ever added within a
protocol major.

## Storage compatibility

A storage home records its format in `.jev-fabric-store.json` (`{"store":1}`),
written when the home is created and adopted for pre-0.5 homes that lack it by
the first verb that writes to them.
Within one store version, changes are additive: readers ignore unknown fields,
and no writer removes or changes the meaning of an existing one. A binary
refuses a home whose store version is newer than its own, with a clear error,
and never rewrites it (exit code 22, like other unsafe job access). Different
jev-fabric versions, and different harnesses, can therefore share one home safely.

## Credentials

Jev credentials never enter argv, environment of children, logs, receipts or
events. Besides the provider variables and `JEV_CREDENTIAL_COMMAND`, a `serve`
client may pass `provider` and `credential` on an individual `jev` request over
the private pipe; that credential is used for that request only and never
cached or echoed. This lets an embedding host keep its own login state authoritative.

## Budgets and deadlines

Budgets are explicit and never renewed implicitly: a `serve` connection owns one
Jev call/token budget and one deadline (up to 24 hours); a Bend program threads
an affine client and a shared `Scope`. A `session` child's lifetime is capped by
its own `timeoutMs` (up to 24 hours) and by its owner. Durable jobs accept
lifetimes up to 24 hours.

## Boundaries

Trusted native execution, not a sandbox. Bounded observations with disclosed
loss, not a lossless transport beyond the retained windows. No exactly-once
execution, rollback, or recovery across a reboot. Nothing calls Jev implicitly.
