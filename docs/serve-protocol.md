# The serve protocol

`jev-fabric -- serve` is a JSONL session over stdin and stdout for callers in any
language. One session holds one affine Jev client (its call and token budget, its
cached credential and its warm pooled HTTPS connection), one deadline, and the
session children it spawned. Every other operation reuses the CLI's contracts:
the receipts, job records and monitor records are the same JSON the CLI prints.

The protocol is the contract. [`clients/python/jev_fabric.py`](../clients/python/jev_fabric.py)
and [`clients/typescript/jev-fabric.ts`](../clients/typescript/jev-fabric.ts) are
thin convenience wrappers around it, and `native/tests/serve.test.ts` and
`native/tests/sessions.test.ts` check it against the executable. The shared
vocabulary (lifetimes, verbs, records) is in [Shell composition](composition.md).

## Session

```sh
jev-fabric -- serve [--timeout-ms N] [max-evaluations [max-tokens]]
```

| Option | Default | Meaning |
| --- | --- | --- |
| `--timeout-ms N` | `JEV_FABRIC_TIMEOUT_MS`, else 1 hour | Deadline for the whole session, 1..86400000 ms (24 hours) |
| `max-evaluations` | 1 | Jev calls for the whole session, as `Jev.connect`. `0` disables Jev |
| `max-tokens` | 100000 | Reported Jev tokens for the whole session |

The budgets are explicit and session-wide. They are not renewed per request, and
failed dispatches still count. Invalid options, a malformed timer environment or
an invalid provider configuration exit (code 2 or 1) before the banner.

The first output line is the banner. Read it before sending requests:

```json
{"ready":{"protocol":2,"version":"0.5.0-native","timeoutMs":3600000,"maxEvaluations":1,"maxTokens":100000,
 "store":1,"platform":"darwin-arm64","features":["follow","list","label","start-24h","serve-24h",
 "serve-concurrent","sessions","cwd","durable-input","read","jev-request-credential"]}}
```

`protocol`, `store`, `platform` and `features` are what `jev-fabric -- capabilities`
prints. A client requires a protocol major and the features it uses; features are
only ever added within a major.

The session ends when stdin closes (exit 0). It also ends when its deadline has
passed (exit 124), when a partial line grows beyond 1 MiB (exit 2), or after
16,777,216 reads of stdin (exit 1). Ending waits for every request in flight to
answer and stops the session children (see [Session children](#session-children)).
Jobs started with `start` keep running after it ends.

## Requests and responses

Each request is one line of strict JSON (UTF-8, at most 1 MiB, no duplicate keys),
terminated by `\n`. A trailing `\r` is ignored, blank lines are skipped, and an
unterminated last line is answered at end of input.

```json
{"id":1,"op":"exec","argv":["/bin/echo","hi"]}
```

`id` is optional: a string of at most 128 characters or a number, echoed verbatim.
`op` selects the operation. **Unknown fields are rejected**, so a misspelled option
never goes unnoticed.

Each request gets exactly one response line:

```json
{"id":1,"ok":true,"result":{...}}
{"id":2,"ok":false,"error":{"code":2,"message":"unknown request field: timeout"}}
```

A line that is not strict JSON is answered with `"id":null`. A failed request
never ends the session. Only the deadline, an oversized line or end of input do.

### Ordering

Protocol 2 answers requests concurrently. **Responses may arrive in any order;
match them by `id`.** Give every request that is in flight at the same time a
distinct `id`.

- Every response is written as one whole line, however long (up to the 1 MiB
  capture bound); lines never interleave.
- A request that blocks (`wait`, `watch`, `events` or `read` with `waitMs`, `exec`,
  `jev`, a slow `start` or `spawn`) never holds up another request.
- `write` and `closeInput` for an interactive durable job are queued by the
  session as they arrive, so they too apply in arrival order; the job's worker
  drains its queue every 25 ms.
- `write` and `closeInput` for one session child are applied in the order they
  arrived: a write starts only after the previous write to that child has been
  accepted by its stdin. A `stop` of that child takes effect after every write and
  close that arrived before it has started, without waiting for a write the child
  is not reading (that write then fails).
- `jev` requests share the session's one client, so they run one at a time, in
  arrival order. Other requests do not wait for them.
- `validate` and `capabilities` are answered at once, in arrival order.
- There is no other ordering between requests. A client that sends one request
  and waits for its response before the next sees exactly the protocol 1 behaviour.

A session child accepts at most 64 queued writes, closes and stops; more are
refused (code 1) until earlier ones complete. Output is backpressured: if the
client stops reading stdout, serve stops answering once the pipe is full.

Error codes follow the CLI:

| Code | Meaning |
| --- | --- |
| 2 | Malformed request: unknown op or field, missing field, out-of-range value |
| 22 | Rejected value: invalid JSON limits, invalid Jev request, unsafe job access, unknown session child, storage home of a newer format |
| 124 | The session deadline has passed |
| 1 | Anything else, for example `Jev budget exhausted` or a write to a finished child |
| other | The exit code of a failing CLI step |

## Operations

| `op` | Fields | Result |
| --- | --- | --- |
| `exec` | `argv`, `stdin?`, `timeoutMs?`, `cwd?` | Process receipt, as `exec` |
| `start` | `argv`, `timeoutMs?`, `label?`, `cwd?`, `input?` | `{"id": job}`, as `start` |
| `spawn` | `argv`, `stdin?`, `timeoutMs?`, `label?`, `cwd?` | The session child's running state |
| `write` | `job`, `text` | Write record |
| `closeInput` | `job` | Write record |
| `read` | `job`, `stream`, `offset?`, `max?`, `waitMs?`, `encoding?` | Read record |
| `status` | `job` | Running state or final receipt |
| `events` | `job`, `after?`, `waitMs?` | Array of retained events with a sequence above `after` |
| `wait` | `job`, `timeoutMs?` | Final receipt, or the running state once `timeoutMs` passes |
| `stop` | `job` | Receipt or running state after a cooperative stop |
| `watch` | `job`, `literal`, `timeoutMs?` | Array of `monitor.batch`, `monitor.loss` and `monitor.end` records |
| `list` | `scope?` | `{"jobs": [...], "truncated": bool}` |
| `capabilities` | none | As `jev-fabric -- capabilities` |
| `validate` | `request` | The validated Jev request, offline |
| `jev` | `request`, `timeoutMs?`, `provider?`, `credential?` | The validated Jev answer: `model`, `answers`, `usage` |

- `argv` is a literal array of 1..57 strings (the 64-entry process limit less the
  CLI prefix). Each entry is at most 4096 UTF-8 bytes. `argv[0]` must be non-empty.
  No shell is involved unless you name one.
- `stdin` is buffered input for `exec`, at most 128 KiB, closed after writing. For
  `spawn` it is `"pipe"` (the default: stdin stays open for `write`) or `"null"`.
- `input` is `"null"` (the default) or `"pipe"`, as `start --input pipe`: the
  job's stdin stays open for `write`, fed through its private queue.
- `cwd` is an absolute directory, at most 4096 bytes, in which the command starts.
  It must exist (code 2 otherwise). It never moves the storage home, which stays
  `JEV_FABRIC_HOME` or `.jev-fabric-native` in serve's own directory.
- `timeoutMs` is an integer. `watch` accepts 1..300000, `start` and `spawn`
  1..86400000 (24 hours, the child's own lifetime), the others 1..3600000.
  Defaults: `exec` runs until the session deadline; `start` uses the work
  default (1 hour) for the job's own lifetime; `spawn` lives until the session
  ends; `wait` and `watch` use `JEV_FABRIC_WAIT_MS` (30 s) and
  `JEV_FABRIC_WATCH_MS` (5 s); `jev` uses the client's `JEV_FABRIC_JEV_TIMEOUT_MS`
  (30 s).
- `label` is 1..120 printable Unicode characters on one line, as `start --label`.
  It is reported as `"label"` by `status`, `wait`, `stop` and `list`.
- `job` is an id returned by `start`, or an `s-` id returned by `spawn` on this
  connection. It must not be empty or start with `-`. Every job operation accepts
  both. `write` and `closeInput` need a session child or a job started with
  `"input":"pipe"`. Another connection's `s-` id is refused (code 22).
- `after` is an event sequence number, default 0.
- `waitMs` makes `events` or `read` a long poll, 1..300000 ms: the response comes
  as soon as there is something to return (an event above `after` or a terminal
  receipt; bytes past `offset` or the end of the stream), and otherwise once
  `waitMs` passes, empty. Without it, both answer at once. The CLI's streaming
  `follow` has no serve op, since a request gets exactly one response; loop
  `events` with `after` set to the last sequence seen and `waitMs` instead. A
  skipped sequence means the ring evicted events.
- `text` is at most 65536 Unicode characters, written to the child's stdin as UTF-8.
- `stream` is `"stdout"` or `"stderr"`; `offset` is a byte offset (default 0);
  `max` is 1..65536 bytes (default 65536); `encoding` is `"text"` (default) or
  `"base64"`.
- `scope` is `"store"` (the default: the storage root's jobs, as the CLI's `list`)
  or `"session"` (this connection's session children, each with
  `"lifetime":"session"`). The store listing never includes session children.
- `request` is a Jev request object, validated exactly as `jev-fabric -- validate`.
- `provider` (`"typesafe"`, `"openrouter"` or `"vercel"`) and `credential` (a
  non-empty string) apply to one `jev` request only; see [Jev](#jev).

A nonzero exit is a receipt with `"state":"failed"`, not an error. Errors mean the
operation itself could not run, for example a missing executable or an unknown job.

## Session children

`spawn` starts a child whose lifetime is `"session"`: it belongs to this
connection and ends with it. Its id is `s-` followed by 32 hex digits. It uses
the same receipt and event shapes as a job, with `"lifetime":"session"`:

```json
→ {"id":1,"op":"spawn","argv":["/bin/cat"],"label":"echo"}
← {"id":1,"ok":true,"result":{"schemaVersion":1,"id":"s-9c…","label":"echo","lifetime":"session","state":"running","spoolLimitBytes":1048576}}
→ {"id":2,"op":"read","job":"s-9c…","stream":"stdout","waitMs":5000}
→ {"id":3,"op":"write","job":"s-9c…","text":"hello\n"}
← {"id":3,"ok":true,"result":{"id":"s-9c…","written":6,"closed":false}}
← {"id":2,"ok":true,"result":{"id":"s-9c…","stream":"stdout","offset":0,"bytes":6,"omittedBytes":0,"text":"hello\n","next":6,"eof":false,"state":"running"}}
```

- Its stdin is a pipe held by the connection: a write reaches the child at once.
  `written` counts UTF-8 bytes. `closeInput` sends end of input and is
  idempotent; a write after it, or to a child that has exited, is an error.
- Each stream keeps a **rolling window** of the latest 1 MiB. Offsets count every
  byte the child wrote and never reset. A read below the window returns the
  oldest retained bytes and discloses the gap in `omittedBytes`. `text` is
  decoded UTF-8 (malformed bytes become U+FFFD), and a partial character at the
  end is held for the next read; with `"encoding":"base64"`, `data` holds the
  exact bytes instead. `eof` is true once the child has finished and nothing
  past `next` remains. A read never moves anything: any number of readers can
  read the same bytes.
- `status`, `wait`, `events` and `watch` work as for jobs; `stop` stops the
  child's process group (`SIGTERM`, then `SIGKILL` after 500 ms) and answers its
  receipt.
- A connection may have 16 running session children. Each is supervised by a
  worker process, which the connection starts with its own executable; a child's
  receipt stays readable until the connection ends.
- When the connection ends (end of input, its deadline, an oversized line, the
  read limit), serve closes the children's stdin and stops their process groups,
  then forces any that remain after 3 seconds, and finally removes their
  directories. If serve itself is killed, each worker notices that its owner has
  gone within 25 ms and stops its child.

`timeoutMs` bounds a session child's own lifetime, and the connection bounds it
too: a child never outlives the session deadline less the two-second receipt grace.

## Deadlines

The session deadline is checked before each request. Once less than two seconds
remain, requests are refused with code 124 and the session ends. The two seconds
are a receipt grace: `exec`, `wait`, `watch`, and `events` and `read` with
`waitMs` get the requested (or default) time, cut to the remaining session time
less that grace, so their child always has time to report. `status`, `events`,
`stop`, `list` and `start`'s readiness handshake each get at most 15 seconds. A
job's own lifetime is not bounded by the session.

A request that is running is never interrupted by later input. Timers are
ceilings, not delays: completion returns immediately.

## How requests run

The session's reader frames stdin into lines and hands them to one coordinating
fiber, which owns the Jev client and the session children. It answers
`validate` and `capabilities` itself and starts a fiber for every other
request; each fiber prints its own response. Only Bend's event loop prints, so
a response line is always written whole.

`jev` runs inside the session process, threading one affine `Jev.Client`
through every call, as a Bend program does. Its credential is resolved on the
first call and cached in that client, and HTTPS keeps its pooled TLS connection
between calls.

`read`, `write`, `closeInput`, `list` with `"scope":"session"` and `spawn` run in
process (for durable jobs as for session children): `read` opens its own reader on the child's rolling spool, so it never
shares a handle with the writer. Every other process and job operation runs the
same executable as a child (`jev-fabric -- exec …`, `-- start …`, …) under a
deadline, and relays its JSON output. So a command that cannot launch costs one
error response, never the session. It also means those operations pay one extra
process start (tens of milliseconds). Children inherit the session's
environment, including `JEV_FABRIC_HOME`, so job ids work across sessions and
the CLI. One serve process runs at most 32 supervised children at once, session
workers included; a request beyond that fails with an error response.

## Jev

`provider` and `credential` let a host keep its own login state authoritative.
They apply to that request only: the credential is used for that evaluation and
then dropped, never cached in the session's client, echoed in a response,
written to a log, or passed to a child. `provider` alone uses that provider's
key variable (or `JEV_CREDENTIAL_COMMAND`); `credential` alone uses the
session's provider. The request is validated before the credential is used, the
call and token budget stay session-wide, and a malformed credential is refused
with the same fixed message as any other (`Invalid private credential`).

## Boundaries

- Trusted native execution, not a sandbox. `serve` runs commands with the
  caller's privileges, like the CLI.
- Nothing calls Jev implicitly: only a `jev` request does.
- Output is bounded exactly as in the CLI (32 KiB receipt tails, 64 retained
  events, `watch` limits, 1 MiB rolling windows for session children). Each CLI
  step's stdout is also capped at 1 MiB.
- stdin may be a pipe, a socket (as Node, Bun and libuv children get), a
  terminal or a file: `serve` reads a duplicate of its inherited descriptor.
