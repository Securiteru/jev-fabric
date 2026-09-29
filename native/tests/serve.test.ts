import { test, expect, beforeAll, afterAll } from 'bun:test';
import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { capture, nativeBin, tempRoot } from './helpers.ts';

// Conformance tests for `serve`, the JSONL session protocol (docs/serve-protocol.md).
const root = tempRoot('native-serve-');
const home = join(root, 'jobs');
const bin = join(root, 'bin');
mkdirSync(bin);
afterAll(() => rmSync(root, { recursive: true, force: true }));

const secret = 'SYNTHETIC_KEY_FOR_SERVE_TESTS';
const requestKey = 'SYNTHETIC_REQUEST_KEY_FOR_SERVE_TESTS';
const noul = {
  state: 'synthetic',
  questions: { ok: { type: 'noul', instructions: 'Is two plus two four?' } },
};
const reply = {
  model: 'jev-test',
  answers: { ok: { type: 'noul', noul: 0.99 } },
  usage: { input_tokens: 4, output_tokens: 2 },
};

// Fake curl: stands in for the network and records one letter per dispatch:
// x for the session's credential, r for a per-request one, o for OpenRouter.
const fakeCurl = `
import { appendFileSync } from 'node:fs';
const config = await Bun.stdin.text();
const session = config.includes('Authorization: Bearer ${secret}');
const request = config.includes('Authorization: Bearer ${requestKey}');
if (!session && !request) process.exit(9);
appendFileSync(process.env.CURL_RECORD!, (request ? 'r' : 'x') + (config.includes('openrouter.ai') ? 'o' : ''));
process.stdout.write(process.env.FAKE_RESPONSE! + '\\n200');
`;

beforeAll(async () => {
  await Bun.write(join(root, 'curl.ts'), fakeCurl);
  const curl = join(bin, 'curl');
  await Bun.write(curl, `#!/bin/sh\nexec '${process.execPath}' '${join(root, 'curl.ts')}' "$@"\n`);
  chmodSync(curl, 0o700);
  const credential = join(root, 'credential.sh');
  await Bun.write(credential, `#!/bin/sh\nprintf x >> "$CREDENTIAL_RECORD"\nprintf '%s\\n' '${secret}'\n`);
  chmodSync(credential, 0o700);
});

type Env = Record<string, string>;

/** One serve child with a line reader over its stdout. */
class Session {
  readonly child;
  private buffered = '';
  private readonly reader;
  private readonly decoder = new TextDecoder();

  constructor(args: string[] = [], env: Env = {}) {
    this.child = Bun.spawn([nativeBin, '--', 'serve', ...args], {
      env: { PATH: process.env.PATH!, BEND_NO_TELEMETRY: '1', JEV_FABRIC_HOME: home, ...env },
      stdin: 'pipe',
      stdout: 'pipe',
      stderr: 'pipe',
    });
    this.reader = this.child.stdout.getReader();
  }

  send(line: string) {
    this.child.stdin.write(line);
    this.child.stdin.flush();
  }

  async line(): Promise<any> {
    for (;;) {
      const at = this.buffered.indexOf('\n');
      if (at >= 0) {
        const text = this.buffered.slice(0, at);
        this.buffered = this.buffered.slice(at + 1);
        return JSON.parse(text);
      }
      const { value, done } = await this.reader.read();
      if (done) return undefined;
      this.buffered += this.decoder.decode(value, { stream: true });
    }
  }

  async ask(request: unknown): Promise<any> {
    this.send(JSON.stringify(request) + '\n');
    return this.line();
  }

  async close() {
    this.child.stdin.end();
    const [code, err] = await Promise.all([this.child.exited, new Response(this.child.stderr).text()]);
    return { code, err };
  }
}

async function session(args: string[] = [], env: Env = {}) {
  const s = new Session(args, env);
  const banner = await s.line();
  return { s, banner };
}

test('serve announces its protocol, version, deadline, budgets and capabilities', async () => {
  const { s, banner } = await session(['--timeout-ms', '60000', '3', '500']);
  expect(banner.ready).toMatchObject({
    protocol: 2, version: '0.5.0-native', timeoutMs: 60000, maxEvaluations: 3, maxTokens: 500, store: 1,
  });
  expect(Object.keys(banner.ready)).toEqual([
    'protocol', 'version', 'timeoutMs', 'maxEvaluations', 'maxTokens', 'store', 'platform', 'features',
  ]);
  expect(await s.close()).toEqual({ code: 0, err: '' });

  const defaults = await session();
  expect(defaults.banner.ready).toMatchObject({ timeoutMs: 3600000, maxEvaluations: 1, maxTokens: 100000 });
  await defaults.s.close();
});

// Node, Bun and libuv give children a socketpair, not a pipe, and Linux cannot
// reopen /dev/stdin on a socket; serve must read its inherited descriptor.
test('serve reads a socket stdin, as Node and Bun children have', async () => {
  const script = `
import json, socket, subprocess, sys
a, b = socket.socketpair()
p = subprocess.Popen([sys.argv[1], '--', 'serve'], stdin=b, stdout=subprocess.PIPE)
b.close()
banner = json.loads(p.stdout.readline())
a.sendall(b'{"id":1,"op":"exec","argv":["/bin/echo","socket"]}\\n')
reply = json.loads(p.stdout.readline())
a.shutdown(socket.SHUT_WR)
print(json.dumps({"protocol": banner["ready"]["protocol"], "stdout": reply["result"]["stdout"], "code": p.wait()}))
`;
  const r = await capture(['python3', '-c', script, nativeBin], {
    env: { PATH: process.env.PATH!, BEND_NO_TELEMETRY: '1', JEV_FABRIC_HOME: home },
  });
  expect(r.code, r.out + r.err).toBe(0);
  expect(JSON.parse(r.out)).toEqual({ protocol: 2, stdout: 'socket\n', code: 0 });
});

test('invalid session options fail before the banner', async () => {
  for (const args of [['x'], ['1', '2', '3'], ['--timeout-ms', '0'], ['--timeout-ms', '86400001'], ['--stdin']]) {
    const s = new Session(args);
    expect(await s.line()).toBeUndefined();
    const { code } = await s.close();
    expect(code).toBe(2);
  }
});

test('exec returns receipts; a failing command never ends the session', async () => {
  const { s } = await session();
  const echo = await s.ask({ id: 1, op: 'exec', argv: ['/bin/echo', 'hi'] });
  expect(echo).toMatchObject({ id: 1, ok: true, result: { state: 'exited', exitCode: 0, stdout: 'hi\n' } });

  const piped = await s.ask({ id: 2, op: 'exec', argv: ['/bin/cat'], stdin: 'piped\n' });
  expect(piped.result.stdout).toBe('piped\n');

  const failed = await s.ask({ id: 3, op: 'exec', argv: ['/bin/sh', '-c', 'echo no >&2; exit 3'] });
  expect(failed).toMatchObject({ ok: true, result: { state: 'failed', exitCode: 3, stderr: 'no\n' } });

  const missing = await s.ask({ id: 4, op: 'exec', argv: [join(root, 'missing')] });
  expect(missing).toMatchObject({ id: 4, ok: false, error: { code: 2 } });

  const slow = await s.ask({ id: 5, op: 'exec', argv: ['/bin/sleep', '5'], timeoutMs: 200 });
  expect(slow).toMatchObject({ ok: true, result: { state: 'timed_out', exitCode: 124, timedOut: true } });

  // Literal argv: nothing is parsed as a jev-fabric option or a shell word.
  const literal = await s.ask({ id: 6, op: 'exec', argv: ['/bin/echo', '--timeout-ms', '$HOME', '--'] });
  expect(literal.result.stdout).toBe('--timeout-ms $HOME --\n');

  expect((await s.ask({ id: 7, op: 'exec', argv: ['/bin/echo', 'still here'] })).result.stdout).toBe('still here\n');
  expect((await s.close()).code).toBe(0);
});

test('requests are strict: bad lines get a correlated error and the session continues', async () => {
  const { s } = await session();
  s.send('not json\n');
  const bad = await s.line();
  expect(bad).toMatchObject({ id: null, ok: false, error: { code: 1 } });
  expect(bad.error.message).toContain('not strict JSON');

  const cases: [unknown, number, string][] = [
    [{ id: 'a', op: 'launch' }, 2, 'unknown op'],
    [{ id: 'b', op: 'exec', argv: ['/bin/echo'], timeout: 5 }, 2, 'unknown request field: timeout'],
    [{ id: 'c', op: 'exec' }, 2, 'missing field: argv'],
    [{ id: 'd', op: 'exec', argv: [] }, 2, 'argv must be an array of 1 to 57 strings'],
    [{ id: 'e', op: 'exec', argv: [''] }, 2, 'argv[0] must name a command'],
    [{ id: 'f', op: 'exec', argv: ['/bin/echo', 1] }, 2, 'argv entries must be a string'],
    [{ id: 'g', op: 'exec', argv: Array(58).fill('/bin/echo') }, 2, 'argv must be an array of 1 to 57 strings'],
    [{ id: 'h', op: 'exec', argv: ['/bin/echo'], timeoutMs: 0 }, 2, 'timeoutMs must be an integer from 1 to 3600000'],
    [{ id: 'i', op: 'watch', job: 'x', literal: 'y', timeoutMs: 300001 }, 2, 'from 1 to 300000'],
    [{ id: 'j', op: 'status', job: '--help' }, 2, 'job must be an id returned by start'],
    [{ id: 'k', op: 'events', job: 'x', after: -1 }, 2, 'after must be an event sequence number'],
    [{ id: 'l', op: 'events', job: 'x', waitMs: 0 }, 2, 'waitMs must be an integer from 1 to 300000'],
    [{ id: 'm', op: 'events', job: 'x', waitMs: 300001 }, 2, 'waitMs must be an integer from 1 to 300000'],
    [{ id: 'n', op: 'start', argv: ['/bin/echo'], timeoutMs: 86400001 }, 2, 'from 1 to 86400000'],
    [{ id: 'o', op: 'wait', job: 'x', timeoutMs: 3600001 }, 2, 'from 1 to 3600000'],
    [{ id: 'p', op: 'start', argv: ['/bin/echo'], label: '' }, 2, 'label must be 1..120 printable characters'],
    [{ id: 'q', op: 'start', argv: ['/bin/echo'], label: 'a\nb' }, 2, 'label must be 1..120 printable characters'],
    [{ id: 'r', op: 'start', argv: ['/bin/echo'], label: 7 }, 2, 'label must be a string'],
    [{ id: 's', op: 'list', job: 'x' }, 2, 'unknown request field: job'],
    [{ id: { nested: true }, op: 'status', job: 'x' }, 2, 'id must be a string or number'],
    [[1, 2], 2, 'request must be a JSON object'],
  ];
  for (const [request, code, message] of cases) {
    const response = await s.ask(request);
    const id = (request as any)?.id;
    expect(response.id).toEqual(typeof id === 'string' ? id : null);
    expect(response.ok).toBe(false);
    expect(response.error.code).toBe(code);
    expect(response.error.message).toContain(message);
  }
  // Duplicate keys are rejected by the strict JSON boundary.
  s.send('{"id":1,"id":2,"op":"status","job":"x"}\n');
  expect((await s.line()).ok).toBe(false);
  expect((await s.ask({ id: 99, op: 'exec', argv: ['/bin/echo', 'ok'] })).ok).toBe(true);
  expect((await s.close()).code).toBe(0);
});

test('framing: blank lines are skipped, CRLF is accepted, a final unterminated line is answered', async () => {
  const { s } = await session();
  s.send('\n\r\n{"id":1,"op":"exec","argv":["/bin/echo","crlf"]}\r\n');
  expect((await s.line()).result.stdout).toBe('crlf\n');
  // Two requests in one write are both answered, matched by id: protocol 2 runs
  // them concurrently, so either may finish first.
  s.send('{"id":2,"op":"exec","argv":["/bin/echo","a"]}\n{"id":3,"op":"exec","argv":["/bin/echo","b"]}\n');
  const pair = [await s.line(), await s.line()].sort((a, b) => a.id - b.id);
  expect(pair.map(r => [r.id, r.result.stdout])).toEqual([[2, 'a\n'], [3, 'b\n']]);
  s.send('{"id":4,"op":"exec","argv":["/bin/echo","last"]}');
  s.child.stdin.end();
  expect(await s.line()).toMatchObject({ id: 4, ok: true, result: { stdout: 'last\n' } });
  expect(await s.child.exited).toBe(0);
});

test('an oversized partial line ends the session instead of desynchronizing', async () => {
  const { s } = await session();
  s.send('{"id":1,"op":"exec","argv":["' + 'x'.repeat(1048600));
  expect(await s.line()).toMatchObject({ id: null, ok: false, error: { code: 2, message: 'request line exceeds 1 MiB' } });
  const { code, err } = await s.close();
  expect(code).toBe(2);
  expect(err).toContain('request line exceeds 1 MiB');
});

test('validate runs in process with the strict Jev request contract', async () => {
  const { s } = await session();
  const ok = await s.ask({ id: 1, op: 'validate', request: noul });
  expect(ok).toEqual({ id: 1, ok: true, result: noul });
  const bad = await s.ask({ id: 2, op: 'validate', request: { state: 'x', questions: {} } });
  expect(bad).toMatchObject({ id: 2, ok: false, error: { code: 22, message: 'invalid question count' } });
  const extra = await s.ask({ id: 3, op: 'validate', request: { ...noul, extra: 1 } });
  expect(extra.error.message).toBe('unknown request field');
  await s.close();
});

test('jobs: start, watch, wait, status, events and stop, with jobs outliving the session', async () => {
  const { s } = await session();
  const started = await s.ask({
    id: 1,
    op: 'start',
    argv: ['/bin/sh', '-c', 'echo booting; sleep 0.3; echo ready; sleep 0.3; echo done'],
  });
  expect(started.ok).toBe(true);
  const job = started.result.id;
  expect(job).toMatch(/^[0-9a-f]{32}$/);

  const watched = await s.ask({ id: 2, op: 'watch', job, literal: 'ready', timeoutMs: 5000 });
  expect(watched.ok).toBe(true);
  const lines = watched.result.filter((r: any) => r.type === 'monitor.batch').flatMap((r: any) => r.lines);
  expect(lines).toEqual([{ text: 'ready', clipped: false }]);
  expect(watched.result.at(-1).type).toBe('monitor.end');

  const waited = await s.ask({ id: 3, op: 'wait', job, timeoutMs: 5000 });
  expect(waited.result).toMatchObject({ id: job, state: 'exited', stdout: 'booting\nready\ndone\n' });
  expect((await s.ask({ id: 4, op: 'status', job })).result.state).toBe('exited');

  const events = await s.ask({ id: 5, op: 'events', job });
  expect(Array.isArray(events.result)).toBe(true);
  const sequences = events.result.map((e: any) => e.sequence);
  const after = await s.ask({ id: 6, op: 'events', job, after: sequences[1] });
  expect(after.result.map((e: any) => e.sequence)).toEqual(sequences.slice(2));

  expect((await s.ask({ id: 7, op: 'stop', job })).result.state).toBe('exited');
  const unknown = await s.ask({ id: 8, op: 'status', job: 'deadbeef' });
  expect(unknown).toMatchObject({ ok: false, error: { code: 22 } });

  // A job started in a session keeps running after that session ends.
  const long = (await s.ask({ id: 9, op: 'start', argv: ['/bin/sleep', '30'] })).result.id;
  await s.close();
  const next = await session();
  expect((await next.s.ask({ id: 1, op: 'status', job: long })).result.state).toBe('running');
  expect((await next.s.ask({ id: 2, op: 'stop', job: long })).ok).toBe(true);
  const stopped = await next.s.ask({ id: 3, op: 'wait', job: long, timeoutMs: 5000 });
  expect(stopped.result.state).toBe('cancelled');
  await next.s.close();
});

test('wait returns the running state when its own timeout passes', async () => {
  const { s } = await session();
  const job = (await s.ask({ id: 1, op: 'start', argv: ['/bin/sleep', '30'] })).result.id;
  const started = Date.now();
  const waited = await s.ask({ id: 2, op: 'wait', job, timeoutMs: 300 });
  expect(waited.result).toMatchObject({ id: job, state: 'running' });
  expect(Date.now() - started).toBeLessThan(3000);
  await s.ask({ id: 3, op: 'stop', job });
  await s.close();
});

test('the session deadline bounds requests, then ends the session with 124', async () => {
  const { s } = await session(['--timeout-ms', '2600']);
  // 600 ms of the session remain after the two-second receipt grace: a longer
  // exec is cut to fit and reports its own timeout.
  const cut = await s.ask({ id: 1, op: 'exec', argv: ['/bin/sleep', '5'], timeoutMs: 60000 });
  expect(cut).toMatchObject({ ok: true, result: { state: 'timed_out' } });
  const late = await s.ask({ id: 2, op: 'validate', request: noul });
  expect(late).toEqual({ id: 2, ok: false, error: { code: 124, message: 'serve deadline expired' } });
  const { code, err } = await s.close();
  expect(code).toBe(124);
  expect(err).toContain('serve deadline expired');
});

function jevEnv(extra: Env = {}): Env & { CURL_RECORD: string; CREDENTIAL_RECORD: string } {
  const n = Math.random().toString(16).slice(2);
  return {
    PATH: `${bin}:/usr/bin:/bin`,
    JEV_FABRIC_HTTP: 'exec',
    JEV_PROVIDER: 'typesafe',
    TYPESAFE_API_KEY: '',
    JEV_CREDENTIAL_COMMAND: JSON.stringify(['/bin/sh', join(root, 'credential.sh')]),
    CURL_RECORD: join(root, `curl-${n}`),
    CREDENTIAL_RECORD: join(root, `cred-${n}`),
    FAKE_RESPONSE: JSON.stringify(reply),
    ...extra,
  };
}
const record = (path: string) => (existsSync(path) ? readFileSync(path, 'utf8') : '');

test('jev threads one client: one credential lookup, a session-wide call budget', async () => {
  const env = jevEnv();
  const { s } = await session(['2', '1000'], env);
  const first = await s.ask({ id: 1, op: 'jev', request: noul });
  expect(first).toEqual({ id: 1, ok: true, result: reply });
  const second = await s.ask({ id: 2, op: 'jev', request: noul, timeoutMs: 5000 });
  expect(second.ok).toBe(true);
  const third = await s.ask({ id: 3, op: 'jev', request: noul });
  expect(third).toEqual({ id: 3, ok: false, error: { code: 1, message: 'Jev budget exhausted' } });
  const { code, err } = await s.close();
  expect(code).toBe(0);
  expect(err).not.toContain(secret);
  expect(record(env.CURL_RECORD)).toBe('xx');
  // The credential resolved once and stayed cached in the threaded client.
  expect(record(env.CREDENTIAL_RECORD)).toBe('x');
});

test('jev never dispatches invalid requests, and defaults to one evaluation', async () => {
  const env = jevEnv();
  const { s } = await session([], env);
  const invalid = await s.ask({ id: 1, op: 'jev', request: { state: 'x', questions: {} } });
  expect(invalid).toMatchObject({ ok: false, error: { code: 22, message: 'invalid question count' } });
  expect((await s.ask({ id: 2, op: 'jev', request: noul })).ok).toBe(true);
  expect((await s.ask({ id: 3, op: 'jev', request: noul })).error.message).toBe('Jev budget exhausted');
  await s.close();
  expect(record(env.CURL_RECORD)).toBe('x');

  const none = jevEnv({ JEV_CREDENTIAL_COMMAND: '' });
  const bare = await session(['0'], none);
  expect((await bare.s.ask({ id: 1, op: 'jev', request: noul })).error.message).toBe('Jev budget exhausted');
  await bare.s.close();
  expect(record(none.CURL_RECORD)).toBe('');
  expect(record(none.CREDENTIAL_RECORD)).toBe('');
});

test('start labels, a day-long lifetime, list and the events long poll', async () => {
  const { s } = await session();
  const release = join(root, 'long-poll-release');
  const labelled = await s.ask({
    id: 1,
    op: 'start',
    argv: ['/bin/sh', '-c', 'while [ ! -f "$1" ]; do sleep 0.02; done; echo late', 'sh', release],
    label: 'long poll',
    timeoutMs: 86400000,
  });
  expect(labelled.ok).toBe(true);
  const job = labelled.result.id;
  expect(labelled.result).toEqual({ id: job });
  expect((await s.ask({ id: 2, op: 'status', job })).result).toMatchObject({ id: job, label: 'long poll', state: 'running' });

  const snapshot = (await s.ask({ id: 3, op: 'events', job })).result;
  const cursor = snapshot.at(-1).sequence;
  // Without waitMs the answer is immediate, possibly empty.
  expect((await s.ask({ id: 4, op: 'events', job, after: cursor })).result).toEqual([]);
  // A short long poll that sees nothing answers [] once waitMs passes.
  let begin = Date.now();
  const quiet = await s.ask({ id: 5, op: 'events', job, after: cursor, waitMs: 100 });
  expect(quiet).toEqual({ id: 5, ok: true, result: [] });
  expect(Date.now() - begin).toBeGreaterThanOrEqual(90);
  // A long one returns as soon as the late output is published.
  setTimeout(() => writeFileSync(release, 'go'), 300);
  begin = Date.now();
  const later = await s.ask({ id: 6, op: 'events', job, after: cursor, waitMs: 20000 });
  expect(Date.now() - begin).toBeLessThan(10000);
  expect(later.result.length).toBeGreaterThan(0);
  expect(later.result.every((e: any) => e.sequence > cursor)).toBe(true);

  const receipt = (await s.ask({ id: 7, op: 'wait', job, timeoutMs: 5000 })).result;
  expect(receipt).toMatchObject({ id: job, label: 'long poll', state: 'exited', stdout: 'late\n' });
  const last = (await s.ask({ id: 8, op: 'events', job })).result.at(-1);
  expect(last.type).toBe('job.finished');
  // A terminal job never makes a long poll wait.
  begin = Date.now();
  expect((await s.ask({ id: 9, op: 'events', job, after: last.sequence, waitMs: 20000 })).result).toEqual([]);
  expect(Date.now() - begin).toBeLessThan(3000);

  const listed = await s.ask({ id: 10, op: 'list' });
  expect(listed.ok).toBe(true);
  expect(listed.result.truncated).toBe(false);
  const entry = listed.result.jobs.find((j: any) => j.id === job);
  expect(entry).toMatchObject({ id: job, state: 'exited', label: 'long poll', exitCode: 0 });
  expect(typeof entry.startedAt).toBe('number');
  const starts = listed.result.jobs.map((j: any) => j.startedAt ?? 0);
  expect(starts).toEqual([...starts].sort((a: number, b: number) => b - a));
  await s.close();
}, 30000);

test('jev takes a per-request provider and credential, never cached, echoed or logged', async () => {
  const env = jevEnv();
  const { s } = await session(['4', '1000'], env);
  const own = await s.ask({ id: 1, op: 'jev', request: noul, credential: requestKey });
  expect(own).toEqual({ id: 1, ok: true, result: reply });
  // The session's own credential was never resolved for that request.
  expect(record(env.CREDENTIAL_RECORD)).toBe('');
  const routed = await s.ask({ id: 2, op: 'jev', request: noul, provider: 'openrouter', credential: requestKey });
  expect(routed.ok).toBe(true);
  // Without them, the session's credential applies; the request key was not cached.
  expect((await s.ask({ id: 3, op: 'jev', request: noul })).ok).toBe(true);
  expect(record(env.CREDENTIAL_RECORD)).toBe('x');
  expect(record(env.CURL_RECORD)).toBe('rrox');

  const cases: [Record<string, unknown>, number, string][] = [
    [{ id: 4, op: 'jev', request: noul, provider: 'elsewhere' }, 2, 'provider must be typesafe, openrouter or vercel'],
    [{ id: 5, op: 'jev', request: noul, credential: '' }, 2, 'credential must be a non-empty string'],
    [{ id: 6, op: 'jev', request: noul, credential: 7 }, 2, 'credential must be a non-empty string'],
    [{ id: 7, op: 'jev', request: noul, credential: `${requestKey}\nsecond line` }, 1, 'Invalid private credential'],
    [{ id: 8, op: 'jev', request: { state: 'x', questions: {} }, credential: requestKey }, 22, 'invalid question count'],
  ];
  for (const [request, code, message] of cases) {
    const response = await s.ask(request);
    expect(response).toMatchObject({ ok: false, error: { code, message } });
    expect(JSON.stringify(response)).not.toContain(requestKey);
  }
  // Budgets stay session-wide: the fourth billed call is the last one.
  expect((await s.ask({ id: 9, op: 'jev', request: noul, credential: requestKey })).ok).toBe(true);
  expect((await s.ask({ id: 10, op: 'jev', request: noul, credential: requestKey })).error.message).toBe('Jev budget exhausted');
  const { code, err } = await s.close();
  expect(code).toBe(0);
  expect(err).not.toContain(requestKey);
  expect(record(env.CURL_RECORD)).toBe('rroxr');
});
