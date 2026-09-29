# Native API and execution contract

Use stock Bend 2.0.34 native compilation. Imports below are relative to your
source file; see `examples/native/`. Native code, PATH executables and imported
modules are trusted. Affine ownership is a programming discipline, not secret
isolation from the program that owns the client.

## CLI

All commands follow `build/jev-fabric --`:

| Command | Meaning |
| --- | --- |
| `exec [--timeout-ms N] [--stdin] [--cwd DIR] [--] <command> [args...]` | Literal argv, owned process group, bounded final receipt |
| `run [--timeout-ms N] [--] <program.bend> [args...]` | Compile into a private directory, then run with inherited stdin; one outside deadline covers both |
| `validate <request.json>` | Strict UTF-8/JSON plus typed Jev request validation; no credentials/network |
| `jev [--timeout-ms N] <request.json> [max-tokens]` | One explicit evaluation; default 100000 reported tokens |
| `start [--timeout-ms N] [--label TEXT] [--cwd DIR] [--input pipe] [--] <command> [args...]` | Native detached worker; returns private job ID. Lifetime 1..86400000 ms. `--input pipe` keeps stdin open for `write` |
| `write <id> (--stdin \| -- text...)` | Queue text (standard input, or the words joined by spaces) for an interactive job's stdin; prints a write record |
| `close-input <id>` | End an interactive job's stdin after what is queued; idempotent |
| `read [--wait-ms N] [--base64] <id> <stdout\|stderr> [offset] [max]` | Raw bytes of one stream from a byte offset, as a read record; with `--wait-ms`, a long poll of 1..300000 ms |
| `status <id>` | Running state or stable final receipt |
| `events [--timeout-ms N] <id> [after-sequence]` | Snapshot of bounded retained JSONL events; with a timeout, a long poll of 1..300000 ms |
| `follow [--timeout-ms N] <id> [after-sequence]` | Live JSONL events as the worker publishes them, loss records, then one `follow.end` |
| `list` | One JSON summary of the job directories under the storage root, newest first |
| `wait [--timeout-ms N] <id>` | Poll until final receipt or client deadline; timeout returns running state |
| `stop <id>` | Idempotent cooperative stop through a private marker, never arbitrary PID signalling |
| `serve [--timeout-ms N] [max-evaluations [max-tokens]]` | JSONL session on stdin/stdout: concurrent requests matched by id, one Jev client, one deadline (1..86400000 ms) and the session's children. See [the serve protocol](serve-protocol.md) |
| `capabilities` | One JSON line: `version`, `protocol`, `store`, `platform`, `features` |
| `update` | Print and run `curl -fsSL …/install.sh \| sh`, like `bend update`; exits with the installer's status. `JEV_FABRIC_PREFIX`/`JEV_FABRIC_VERSION` pass through |
| `watch [--timeout-ms N] <id> <literal>` | Live bounded line batches, loss records and a final observation summary; duration 1..300000 ms |

Timers may be omitted. Defaults and configuration:

| Operations | Default maximum | Environment override |
| --- | --- | --- |
| `exec`, `run`, `start`, `serve` sessions, timer-free Process/Session APIs, `Scope.open` | 1 hour | `JEV_FABRIC_TIMEOUT_MS` |
| `jev`, `Jev.connect` | 30 seconds | `JEV_FABRIC_JEV_TIMEOUT_MS` |
| CLI `wait`, `follow` | 30 seconds | `JEV_FABRIC_WAIT_MS` |
| CLI `watch` | 5 seconds | `JEV_FABRIC_WATCH_MS` |

Defaults are ceilings, not sleeps: completion returns immediately. Empty/unset
configuration uses the default; malformed values fail closed. Explicit limits
replace configuration for that call (even when that default is malformed).
`wait`, `watch`, `follow` and `events --timeout-ms` only bound observation: they
neither cancel nor renew a job.
The calling harness still has its own shell-tool limits; a CLI default does not
extend those. Use `start` and subsequent controls for work that should outlive
a foreground tool call.
There is no unlimited/zero timeout mode. Limits are 1..3600000 ms, except `watch`
and `events --timeout-ms`, which permit 1..300000 ms, and `start` and `serve`,
whose lifetime may be 1..86400000 ms (24 hours). The work default and
`JEV_FABRIC_TIMEOUT_MS` stay within one hour, so a day is always explicit.

`--cwd DIR` (`exec` and `start` only) starts the command in an existing absolute
directory. It changes nothing else: the storage home is still resolved from the
caller's directory or `JEV_FABRIC_HOME`, and relative command names are still
looked up on PATH.

`capabilities` prints what a host needs to choose a binary without parsing a
version string:

```json
{"version":"0.5.0-native","protocol":2,"store":1,"platform":"darwin-arm64",
 "features":["follow","list","label","start-24h","serve-24h","serve-concurrent","sessions","cwd",
             "durable-input","read","jev-request-credential"]}
```

`features` lists only what this binary implements; within a protocol major,
features are only added.

Place `--timeout-ms N`, `--stdin`, `--label` and `--cwd` before the executable/source. Parsing stops
there: all subsequent arguments are literal child arguments, including strings
such as `--timeout-ms`. A command-local `--` ends option and legacy-number
parsing: `exec -- 123` executes a numeric command named `123` from PATH. It is
distinct from the initial Bend runtime `--`.

Legacy forms remain supported: `exec/run/start/jev <ms> ...`,
`exec <ms> --stdin ...`, `wait <id> <ms>`, `watch <id> <ms> <literal>`.
Do not specify both a timeout flag and a positional timeout.

`run` timeouts are 1..3600000 ms. Source compilation consumes the same `run` deadline
as execution. `run` returns a **process receipt**: stdout may contain your
program's JSON result. It does not
interpret that output as a verified task outcome. Compile once yourself and use
`exec` or `start` to avoid repeated compilation.

The compiler can read arbitrary native source/imports and run arbitrary native
code. Private output paths do not make compilation sandboxed. Compiled artifacts
remain inside the checked storage root and count towards its directory cap.

## Scope.bend: shared deadline budgets

Use `examples/native/scoped.bend` as a complete timer-free composition example.

- `Scope.open() -> IO(Scope.Budget)` starts one configured work budget.
- `Scope.with_timeout(ms)` explicitly overrides that budget when needed.
- `Scope.exec(scope, argv)` / `Scope.run(scope, argv, input)` return process reports.
- `Scope.start(scope, argv) -> IO(Result<..., Session.Session>)` starts a session
  with the remaining budget. Close/wait the returned handle normally.
- `Scope.evaluate(scope, client, request)` returns the threaded affine Jev client
  and evaluation result, like `Jev.evaluate`.
- `run_for(scope, argv, input, cap_ms)`, `start_for(scope, argv, cap_ms)` and
  `evaluate_for(scope, client, request, cap_ms)` add optional shorter local caps.

Pass the **same** budget to successive or concurrent calls. Each operation uses
remaining time, capped by any local limit; Jev additionally retains its client's
per-request maximum. Creating a new budget for each call defeats this sharing.
Session reads/writes do not refresh its lifetime. Jev credential acquisition and
HTTP share the capped request deadline; the original client settings and updated
credential cache/call accounting are preserved afterward.

Expired process calls return a timed-out report (124) without launching.
Expired session/evaluation calls return recoverable errors (124); Jev does not
retrieve credentials, reserve a call or dispatch HTTP in this case.

**A budget is not an isolated resource/cancellation group.** `Process.cancel`
still cancels the owning executable's entire native process scope. Budgets are
sampled at dispatch; validation/scheduling/launch latency is not a real-time
theorem. They are explicitly passed, not ambient: `run`'s external compile/
execution limit is **not automatically inherited** by a new budget inside the
program. Cross-process hierarchical cancellation and cleanup after a native
crash or SIGKILL are not promised. Low-level explicit-time APIs remain available
to trusted programs. An outer timeout is not proof of cleanup of nested groups.

## Process.bend

- `Process.exec(argv) -> IO(Process.Report)` uses the configured work default.
- `Process.exec_input(argv, buffered_stdin)` uses the same default with input.
- `Process.exec_stdin(argv)` inherits fd 0 with the configured default.
- `Process.run_input(argv, buffered_stdin, timeout_ms) -> IO(Process.Report)`.
  Before 0.4.0 this was `Process.run`; Bend 2.0.28+ Base owns that name.
- `Process.run_stdin(argv, timeout_ms) -> IO(Process.Report)` inherits fd 0.
- `Process.run_in(argv, buffered_stdin, timeout_ms, inherit_stdin, cwd)` is either
  of the above, started in the absolute directory `cwd` (`""` inherits).
- `Process.capture(argv, buffered_stdin, timeout_ms, cap) -> IO(Result<..., RawBytes>)`
  is recoverable and byte-preserving. Used for private HTTP and credentials;
  it does not emit events or public receipts.
- `Process.run_logged(argv, timeout_ms, stdout_file, stderr_file)` consumes
  owned file descriptors and writes bounded raw spools while returning a report.
  It accepts 1..3600000 ms; only the detached job worker uses the underlying
  effect's 24-hour ceiling.
- `Process.cancel(signal)` cancels the **whole owning native process scope**,
  not an independently addressable child. The cancellation flag is sticky;
  the current effect marks scope cancellation as SIGTERM regardless of that
  argument. Each supervisor sends SIGTERM to its owned group, then SIGKILL once
  500 ms have passed; this is not a graceful-shutdown guarantee.
- `Process.show(report)` serializes a receipt; `Process.exit_code(report)`
  preserves nonzero/timeout/cancel outcomes.

32 concurrent child commands per native process, 64 argv entries (including
executable), 4096 UTF-8 bytes per entry, no embedded NUL. Normal buffered input
is 128 KiB; inherited input streams through the OS. Private capture permits a
larger bounded buffer for HTTP. Reports retain 32 KiB tails per stream and flag
truncation; text receipts may replace malformed UTF-8. Binary consumers must use
capture or raw spool reads instead. Spools preserve the **first** 1 MiB; overflow
is disclosed and draining continues so a full log does not deadlock its child.

`IO.fork`/`IO.join` compose native effects. Shells, pipelines and heredocs are
ordinary explicitly invoked executables; there is no hidden shell expansion.
SIGINT/SIGTERM stop owned groups (SIGTERM, then SIGKILL after 500 ms); deadlines
and foreign failures kill them at once; direct children are reaped. Intentionally escaped daemons, SIGKILL/native crashes or overridden
signal handlers are outside the guarantee. Side effects are never rolled back.

## Session.bend: interactive native handles

- `open(argv) -> IO(Session)` chooses the configured default once at startup.
- `start(argv, timeout_ms) -> IO(Session)` explicitly sets that lifetime. Both
  return before completion; neither refreshes the clock on reads/writes.
- `write(session, text) -> IO(Session & Result<..., Unit>)` preserves ownership
  even on EPIPE; at most 65536 Unicode characters per write.
- `close_input(session) -> IO(Session)` sends EOF and is idempotent.
- `read_stdout` / `read_stderr(session, offset, max)` return the updated session
  and recoverable raw bytes; offset <= 1048576 and max <= 65536.
- `status(session)` returns the session and current stdout/stderr spool sizes.
- `wait(session)` closes stdin, joins the owned supervisor, closes readers and
  returns a recoverable process report or launch error.
- `cancel_scope()` cancels **all** native children in the owning process, not
  just one session; cancellation is sticky.

Use returned handles in subsequent calls. Empty live reads are not EOF. Each
spool retains only its first 1 MiB; a size at `spool_limit()` means it may be
clipped. Correlate/validate protocol replies and stop/restart before that cap if
you need lossless protocol semantics. Final tails and truncation are separate.
Start uses checked private storage and the same 1024-directory retention cap.
A write may be buffered before an asynchronous launch failure becomes visible;
`wait` remains authoritative. Child deadlines unblock a writer if its peer is
not reading. Always close/wait sessions; affine ownership alone is not an
implicit join or destructor. `examples/native/persistent.bend` keeps one child
alive across three stateful JSONL requests, with no JS runtime.

The only additional primitive is a CLOEXEC pipe returned as stock Base File
handles (`native/pipe.c`); the existing process supervisor consumes its reader.
`Process.Native.exec_pipe` also takes `rolling` and `cwd`: the library Session
passes `False{}` and `""`, keeping first-byte spools; session children and
interactive jobs use rolling spools, which keep the latest 1 MiB per stream
behind a header (the bytes written so far and whether the stream has ended) and
may live for a day.
`Process.stdin()` likewise returns a CLOEXEC duplicate of fd 0 as a File, which
reads a pipe, socket, terminal or file alike; closing it leaves fd 0 open.
Launch validation, quota and spawn failure paths close transferred descriptors.

## Monitor.bend: explicit bounded observations

`Monitor.command` exposes `watch <id> <duration-ms> <literal>`; literal length is
1..256 characters. It polls retained job events every 25 ms, preserves partial
lines separately by stream, trims/filters/deduplicates, emits at most 32 lines
per batch and clips partial lines at 4096 characters. A 1024-line combined
stopping threshold is checked after each snapshot; hard caps of 1024 per stream
bound a single snapshot overshoot to **2048 total lines maximum**.

Output is JSONL: `monitor.batch`, `monitor.loss`, `monitor.end`. Sequence gaps,
omitted bytes and spool caps reset framing and disclose loss instead of joining
unrelated partial lines. `outputLimitReached` warns that output may be omitted,
including when a terminal receipt arrives in the same snapshot. Finishing a
watch at its deadline does not stop the job; matches are observations, not
semantic completion. There are no automatic Jev calls or host-agent wakeups.
Stock Bend IO parking flushes live records; no monitor-specific C is required.

## Pure policy and trust

`TimeCore` and `Cli` hold timer/configuration/argument policy.
`MonitorCore`, `HttpCore`, `CredentialCore`, `JevCore` and `ServeCore` hold the other pure policies;
the original module names remain effectful entrypoints. `Jev.Client` and
`Jev.Returned` remain public affine type aliases; their constructors live in
`JevCore`. `Http.post`, `Credentials.resolve` and `Monitor.command` retain their
interfaces. The pure monitor helpers are now imported from `MonitorCore`.

Every native build checks `native/trust.json`, including transitive pure imports,
unsafe spellings and proof holes. Pure roots have no trust warnings; foreign IO
drivers still do. See [exact proof coverage and assumptions](safe-bend.md).

## Codec.bend and Wire.bend

`Codec.Value() -> Data` aliases the pinned strict JSON AST. `read`, `read_bytes`,
`decode_utf8`, and `encode` return recoverable `Result` values. `field`, `text`,
and `array` are typed accessors. `Wire.request`, `body`, `response`, and `usage`
implement Jev's complete typed wire contract.

The boundary rejects malformed UTF-8, duplicate object keys, unknown request
fields, incomplete JSON, malformed numbers, invalid IDs, missing answers,
extra answer/probability keys and non-finite/out-of-range values. JSON limits:
1 MiB encoded UTF-8, depth 64, 32768 AST/work units, 256 keys/object and Unicode
scalars/key, and 1 MiB cumulative key-comparison charge. Requests require
Choice criteria objects (1..255), Noul instructions, or Score criteria arrays
(2..10), not a `choices` or `scale` field. See `examples/native/request.json`.

Numbers retain their original lexemes. Wire validation uses **exact decimal
arithmetic**, not F32: probability bounds and mass tolerance [0.98,1.02] include
long fractions and tiny exponents without rounding invalid values into range.
Numeric lexemes are capped at 1024 characters, exponent magnitude 4096, and
usage counts at the native 48-bit Nat maximum (281474976710655). These limits
intentionally differ from JavaScript numbers. Generic bounded JSON can preserve
larger numeric lexemes; wire numeric operations impose the tighter bounds.

Vendoring, patches, license and hashes: `native/vendor/PROVENANCE.md`.

## Jev.bend

```text
Jev.connect(max_evaluations, max_tokens)
  -> IO(Result<..., Jev.Client>)  # configured request-time default
Jev.from_env(timeout_ms, max_evaluations, max_tokens)
  -> IO(Result<..., Jev.Client>)
Jev.evaluate(client, request_json)
  -> IO(Jev.Client & Result<..., Codec.Value>)
```

Thread the returned client into the next call. The affine type prevents
accidental overlapping evaluations of the same client. Trusted native code can
construct additional clients; budgets are not a security policy against it.

Provider configuration:

| JEV_PROVIDER | Key environment variable | Default model |
| --- | --- | --- |
| `typesafe` (default) | `TYPESAFE_API_KEY` | `jev-latest` |
| `openrouter` | `OPENROUTER_API_KEY` | `typesafe/jev-1.13` |
| `vercel` | `AI_GATEWAY_API_KEY` | `typesafe-ai/jev` |

Routes are fixed in `Jev.route`; `JEV_MODEL` overrides the default. A request's
explicit model takes precedence. `JEV_CREDENTIAL_COMMAND` is a JSON argv array,
not a shell fragment. It has a 5-second maximum (or the shorter request time),
16 KiB output bound, strict UTF-8 and printable single-line credential checks.
Resolver failures are sanitized. Successful credentials cache only in the
threaded affine client; nothing writes them into job metadata.

The request is validated before resolution. Exhausted budgets prevent even the
credential command. Invalid requests/credentials consume no call; dispatched
HTTP failures do consume a call and are not retried. Credential time is deducted
from the same monotonic HTTP deadline. Reported token overshoot blocks later
calls with overflow-safe accounting; missing usage counts as zero. The final
request may still be billed above the token limit. Use call limits as well.

`Http.post` is a lower-level explicit URL API for trusted programs. It validates
HTTPS, disables proxies, rejects redirects, verifies TLS, bounds the response
to 1 MiB and never retries. `JEV_FABRIC_HTTP` selects the transport:

| Value | Transport |
| --- | --- |
| `auto` (default, or unset) | `pooled`, falling back to `exec` only if libcurl cannot be loaded |
| `pooled` | System libcurl in-process (`native/http.c`). One process-wide share keeps DNS, TLS sessions and connections warm, so later calls skip the TCP/TLS handshake. Fails if libcurl is unavailable |
| `exec` | A fresh `curl` process per request; key/body travel in escaped private stdin config and curl startup config is disabled |

Any other value fails closed before network access. Both transports honour
`CURL_CA_BUNDLE` for trust anchors, as the curl tool does. The pooled transport
keeps the key only in process memory and zeroes its request buffers; the
connection cache lives as long as the process. Process cancellation (SIGINT,
SIGTERM, `Process.cancel`) aborts in-flight pooled transfers.
System libcurl/curl, CA configuration and PATH remain trusted deployment
dependencies.

## Durable observations

`Jobs.command` owns native lifecycle/control flow; `Host.bend` wraps the checked
filesystem boundary. Storage root is `JEV_FABRIC_HOME` or `.jev-fabric-native`.
Roots/job directories require owner-only permissions. Directory traversal,
symlink components, unsafe marker files and non-private files fail closed.
Writes are atomic and bounded. Workers hold a live advisory lease; no persisted
PID is treated as authority. A dead worker can be reported failed, but execution
is not resumed after a crash/reboot.

### Storage format

A storage home records its format in `.jev-fabric-store.json`, `{"store":1}`,
private and written atomically. A home created by this release gets it at once;
a home from an earlier release gets it from the first verb that writes to it
(`start`, `status`, `wait`, `stop`, `run`, a session spawn), while verbs that
only read (`list`, `events`, `follow`, `watch`, `read`) leave such a home as they
found it. A home whose marker names a newer format, or an unreadable marker, is
refused by every verb that touches the store with exit code 22 (for example
`storage home uses store format 2; this jev-fabric supports store format 1`),
and is never rewritten. Within a store version, changes are additive: readers
ignore unknown fields. The marker is not a job: `list` never shows it and it
does not count toward the directory cap. `StoreCore` holds the decision and its
laws; `Host` reads and writes the file.

### Job records

`start` writes a private `meta.json` (`schemaVersion`, wall-clock `startedAt` in
epoch milliseconds, optional `label`, `lifetime`) before it spawns the worker. A label is 1..120
Unicode scalars on one line; control characters (C0, DEL, C1) and U+2028/U+2029
are rejected with code 2. It appears as `"label"` after `"id"` in the running
state, in every receipt (including recovered and launch-failure receipts) and in
`list`; a job without one has no `label` member. The running state and every
receipt then carry `"lifetime"`: `"durable"` for a job, `"session"` for a serve
session child (whose id is `s-` followed by its directory).

When the default root `.jev-fabric-native` is created, a private `.gitignore`
containing `*` is written into it (best effort, never read back). An existing
root, or one named by `JEV_FABRIC_HOME`, is left as it is. Hidden entries (the
`.gitignore`, the store marker) count toward neither the directory cap nor `list`.

Each job retains 64 events, at most two 1 MiB first-byte raw spools, and final
32 KiB tails. Output previews coalesce to the latest 2048 available bytes per
stream/tick, reporting `offset`, `bytes`, `omittedBytes`, and decoded `text`.
UTF-8 partial characters carry across adjacent chunks and reset across loss.
`process.spool_limit` discloses the hard spool cap. The worker atomically rewrites
the event file at most every four 25 ms ticks: new events after an idle period
publish on the next tick, continuous output publishes about every 100 ms, and
the final replay is written before the receipt. Cursors are monotonically
increasing within a job; if the first returned sequence skips your cursor,
older events were evicted. `events` is a snapshot, not a lossless subscriber.
A recovered crash receipt does not synthesize a missing final replay event.

Event lines, as `events` and `follow` print them:

```json
{"sequence":1,"type":"job.started","data":{"id":"<job>"}}
{"sequence":2,"type":"process.output","data":{"stream":"stdout","offset":0,"bytes":6,"omittedBytes":0,"text":"ready\n"}}
{"sequence":3,"type":"process.spool_limit","data":{"stream":"stderr","limitBytes":1048576,"mayBeTruncated":true}}
{"sequence":4,"type":"job.finished","data":{"receiptAvailable":true}}
```

`events --timeout-ms N` is a long poll: it prints the snapshot as soon as an
event past the cursor exists or the job has a terminal receipt, and otherwise
prints nothing once N ms pass.

`follow` polls the event file every 25 ms and prints each event past the cursor
once, in order, as soon as the worker publishes it. If the first available
sequence skips the cursor, `{"type":"follow.loss","after":A,"next":B}` comes
first. It ends with exactly one line:

```json
{"type":"follow.end","reason":"finished","next":4,"receipt":{"id":"<job>",...}}
```

`reason` is `finished` only after the terminal receipt exists and the final
replay has been printed (the receipt is read before the events, and the worker
publishes the replay before the receipt). On `timeout`, `receipt` is the running
state. `next` is the last sequence printed, or the input cursor. `follow` exits 0
in both cases and fails like the other controls (code 2, 22) for an unknown or
invalid job. It never cancels, renews or signals the job.

`list` prints one object, newest `startedAt` first (jobs from before 0.4.0 have
none and sort last):

```json
{"jobs":[{"id":"<job>","state":"running","label":"dev","startedAt":1790640000000},
  {"id":"<job>","state":"exited","startedAt":1790630000000,"exitCode":0}],"truncated":false}
```

`state` is `running` while the worker holds its lease, `starting` before the
worker has announced itself, and otherwise the receipt state (`exited`,
`failed`, `timed_out`, `cancelled`); a dead worker without a receipt is
`failed` with a null `exitCode`, as `status` reports it, but `list` does not
write the recovery receipt. Directories that are not jobs (`run` and Session
storage), serve session children, unsafe entries and unreadable job files are
left out. At most 1024 jobs are reported; `truncated` discloses more.

### Interactive jobs, `write`, `close-input` and `read`

`start --input pipe` starts a job whose stdin stays open. Writers never touch the
child directly: `write` appends to a private input queue in the job directory
(`input.queue`, under an advisory lock), and the worker drains the queue into
the child's stdin every tick (25 ms), in arrival order. The queue holds at most
1 MiB not yet handed to the child; a write that would pass it fails (code 1,
`job input queue is full`) and changes nothing, so a child that stops reading
pushes back on its writers. `close-input` ends input after everything queued
before it. A write to a job without `--input pipe` is refused (code 22), and a
write after `close-input` or after the child has finished is an error (code 1),
never a silent drop.

```sh
id=$(jev-fabric -- start --input pipe -- python3 -u -i | jq -r .id)
jev-fabric -- write "$id" -- 'print(6 * 7)'        # words, joined by spaces
printf 'print(1)\n' | jev-fabric -- write "$id" --stdin
jev-fabric -- read --wait-ms 5000 "$id" stdout 0   # → {"offset":0,"bytes":3,"text":"42\n","next":3,...}
jev-fabric -- close-input "$id"
```

`write` adds nothing to the text: include the newline a line-oriented child
expects (`--stdin` passes bytes as they are). A write takes at most 65536
characters of UTF-8 text and reports `{"id":…,"written":N,"closed":false}`, `N`
counting bytes; `close-input` reports `"written":0,"closed":true`.

An interactive job's streams keep the latest 1 MiB each (a rolling spool)
instead of the first 1 MiB; `events`, `follow` and `watch` work as for any
job, and loss shows as `omittedBytes`, not as `process.spool_limit`.

`read` returns raw bytes of any job's stream by byte offset: the read record of
[Shell composition](composition.md) (`offset`, `bytes`, `omittedBytes`, `text`
or with `--base64` `data`, `next`, `eof`, `state`). Offsets count every byte the
child wrote. A batch job's spool keeps the first 1 MiB, so a read past it returns
nothing; an interactive job's keeps the latest 1 MiB, so a read below it starts
at the oldest byte kept and discloses the gap. A partial UTF-8 character at the
end is held for the next read until the stream ends. `read` never writes to the
store.

If an interactive job's worker crashes, `status` reports it failed as for any
job. Its queued input is not replayed: nothing resumes the child, and writes
fail with `job has finished`.

Deleting old directories is an explicit user retention decision. Never delete
an active job's directory. There is a 1024-directory cap, not automatic GC.
