# serve clients

Single-file clients for [`jev-fabric -- serve`](../docs/serve-protocol.md), the
JSONL session protocol. Each one starts a `serve` child, writes one request line
per call and returns the matching response. Neither holds policy: budgets,
deadlines, credentials and validation stay in the executable.

| Client | Requires | Import |
| --- | --- | --- |
| [`python/jev_fabric.py`](python/jev_fabric.py) | Python 3.9+, stdlib only | `from jev_fabric import Fabric` |
| [`typescript/jev-fabric.ts`](typescript/jev-fabric.ts) | Bun, Deno or Node 22.6+, `node:` built-ins only | `import { Fabric } from './jev-fabric.ts'` |

Copy the file into your project, or import it from
`~/.local/share/jev-fabric/current/clients/` after installing a release. Both
find the executable through `binary`, then `$JEV_FABRIC_BIN`, then `jev-fabric`
on PATH, and require protocol 2 in the banner.

Both expose the same operations: `exec`, `start`, `spawn`, `write`,
`closeInput` (`close_input` in Python), `read`, `status`, `events`, `wait`,
`stop`, `watch`, `list`, `capabilities`, `validate`, `jev` and `close`. A refused
request raises `FabricError` with the protocol's `code` and `message`. Examples:
[`examples/clients/`](../examples/clients/).

Requests overlap. Each client keeps a table of requests in flight and hands
every response to the request with the same id, so a long-poll `read` or `wait`
never holds up another call: in TypeScript, await several promises at once; in
Python, call from several threads (one background thread reads responses).
Writes, closes and stops of one session child still apply in the order they
were sent, and `jev` calls run one at a time. `jev` takes `provider` and
`credential` for one request; the clients pass them through and keep nothing.

Tests run against the real executable as part of `bun run test:native`
(`native/tests/clients.test.ts` runs `python/test_jev_fabric.py` too).
