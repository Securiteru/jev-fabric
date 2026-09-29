import { afterAll, expect, test } from 'bun:test';
import { existsSync, mkdirSync, readdirSync, realpathSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { nativeBin, processGone, tempRoot } from './helpers.ts';

// Session children and protocol-2 concurrency, purely through `serve`
// (docs/composition.md, docs/serve-protocol.md).
const root = tempRoot('native-sessions-');
const home = join(root, 'jobs');
afterAll(() => rmSync(root, { recursive: true, force: true }));

/** A serve connection that matches responses by id, so requests may overlap. */
class Connection {
  readonly child;
  readonly banner: Promise<any>;
  private buffered = '';
  private nextId = 1;
  private readonly waiting = new Map<number | string, (value: any) => void>();
  private readonly lines: any[] = [];
  private ready!: (value: any) => void;

  constructor(args: string[] = [], env: Record<string, string> = {}) {
    this.child = Bun.spawn([nativeBin, '--', 'serve', ...args], {
      env: { PATH: process.env.PATH!, BEND_NO_TELEMETRY: '1', JEV_FABRIC_HOME: home, ...env },
      stdin: 'pipe',
      stdout: 'pipe',
      stderr: 'pipe',
    });
    this.banner = new Promise(resolve => (this.ready = resolve));
    void this.pump();
  }

  private async pump() {
    const reader = this.child.stdout.getReader();
    const decoder = new TextDecoder();
    let first = true;
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      this.buffered += decoder.decode(value, { stream: true });
      for (let at = this.buffered.indexOf('\n'); at >= 0; at = this.buffered.indexOf('\n')) {
        const line = JSON.parse(this.buffered.slice(0, at));
        this.buffered = this.buffered.slice(at + 1);
        if (first) {
          first = false;
          this.ready(line);
          continue;
        }
        this.lines.push(line);
        const resolve = this.waiting.get(line.id);
        if (resolve) {
          this.waiting.delete(line.id);
          resolve(line);
        }
      }
    }
  }

  /** Sends one request and resolves with its response, whenever it arrives. */
  send(request: Record<string, unknown>): Promise<any> {
    const id = this.nextId++;
    const response = new Promise(resolve => this.waiting.set(id, resolve));
    this.child.stdin.write(JSON.stringify({ id, ...request }) + '\n');
    this.child.stdin.flush();
    return response;
  }

  async ok(request: Record<string, unknown>): Promise<any> {
    const response = await this.send(request);
    expect(response.ok, JSON.stringify(response)).toBe(true);
    return response.result;
  }

  /** Response ids in the order they arrived. */
  order(): (number | string)[] {
    return this.lines.map(line => line.id);
  }

  async close() {
    this.child.stdin.end();
    const [code, err] = await Promise.all([this.child.exited, new Response(this.child.stderr).text()]);
    return { code, err };
  }
}

async function connect(args: string[] = [], env: Record<string, string> = {}) {
  const c = new Connection(args, env);
  await c.banner;
  return c;
}

/** Reads a stream from `from` until `want` appears or it ends, following `next`. */
async function readUntil(c: Connection, job: string, want: string, from = 0, stream = 'stdout') {
  let text = '';
  let offset = from;
  for (let i = 0; i < 200 && !text.includes(want); i++) {
    const r = await c.ok({ op: 'read', job, stream, offset, waitMs: 2000 });
    text += r.text;
    offset = r.next;
    if (r.eof) break;
  }
  return { text, offset };
}

test('banner and capabilities describe protocol 2', async () => {
  const c = await connect(['--timeout-ms', '86400000']);
  const { ready } = await c.banner;
  expect(ready).toMatchObject({ protocol: 2, version: '0.5.0-native', timeoutMs: 86400000, store: 1 });
  expect(ready.platform).toMatch(/^(darwin|linux)-(arm64|x64)$/);
  expect(ready.features).toEqual(expect.arrayContaining(['serve-concurrent', 'sessions', 'serve-24h', 'cwd']));
  const caps = await c.ok({ op: 'capabilities' });
  expect(caps).toEqual({ version: ready.version, protocol: 2, store: 1, platform: ready.platform, features: ready.features });
  expect((await c.close()).code).toBe(0);
});

test('a persistent child answers a request/response loop through serve alone', async () => {
  const c = await connect();
  const script = 'i=0; while IFS= read -r value; do i=$((i+1)); printf \'{"count":%s,"value":%s}\\n\' "$i" "$value"; done';
  const spawned = await c.ok({ op: 'spawn', argv: ['/bin/sh', '-c', script], label: 'counter' });
  expect(spawned).toMatchObject({ lifetime: 'session', state: 'running', label: 'counter' });
  const job = spawned.id;
  expect(job).toMatch(/^s-[0-9a-f]{32}$/);

  let offset = 0;
  for (const [n, value] of [[1, 10], [2, 20], [3, 30]]) {
    const wrote = await c.ok({ op: 'write', job, text: `${value}\n` });
    expect(wrote).toEqual({ id: job, written: String(value).length + 1, closed: false });
    const { text, offset: next } = await readUntil(c, job, '\n', offset);
    expect(JSON.parse(text)).toEqual({ count: n, value });
    offset = next;
  }
  expect(await c.ok({ op: 'closeInput', job })).toEqual({ id: job, written: 0, closed: true });
  // closeInput is idempotent; a write after it is an error, not a silent drop.
  expect(await c.ok({ op: 'closeInput', job })).toEqual({ id: job, written: 0, closed: true });
  const late = await c.send({ op: 'write', job, text: 'x\n' });
  expect(late).toMatchObject({ ok: false, error: { code: 1, message: 'session child stdin is closed' } });

  const receipt = await c.ok({ op: 'wait', job, timeoutMs: 5000 });
  expect(receipt).toMatchObject({ id: job, lifetime: 'session', label: 'counter', state: 'exited', exitCode: 0 });
  expect(receipt.stdout).toContain('{"count":3,"value":30}');
  const status = await c.ok({ op: 'status', job });
  expect(status).toEqual(receipt);
  const end = await c.ok({ op: 'read', job, stream: 'stdout', offset });
  expect(end).toMatchObject({ id: job, bytes: 0, eof: true, state: 'exited', next: offset });
  const events = await c.ok({ op: 'events', job });
  expect(events[0]).toEqual({ sequence: 1, type: 'job.started', data: { id: job } });
  expect(events.at(-1).type).toBe('job.finished');
  expect((await c.close()).code).toBe(0);
}, 30000);

test('responses come out of order: a long-poll read waits while writes and status proceed', async () => {
  const c = await connect();
  const job = (await c.ok({ op: 'spawn', argv: ['/bin/cat'] })).id;
  // The read is sent first and can only answer after the later write.
  const pending = c.send({ op: 'read', job, stream: 'stdout', waitMs: 20000 });
  const status = await c.ok({ op: 'status', job });
  expect(status).toMatchObject({ id: job, state: 'running', lifetime: 'session' });
  const wrote = await c.ok({ op: 'write', job, text: 'hello\n' });
  expect(wrote.written).toBe(6);
  const read = await pending;
  expect(read.result).toMatchObject({ id: job, stream: 'stdout', offset: 0, bytes: 6, omittedBytes: 0, text: 'hello\n', next: 6, eof: false, state: 'running' });
  // The read (id 2) was answered after the status (id 3) and the write (id 4).
  const order = c.order();
  expect(read.id).toBe(2);
  expect(order.indexOf(2)).toBeGreaterThan(order.indexOf(3));
  expect(order.indexOf(2)).toBeGreaterThan(order.indexOf(4));

  // Writes to one child apply in arrival order even when sent back to back.
  const writes = Array.from({ length: 20 }, (_, i) => c.send({ op: 'write', job, text: `${i}\n` }));
  expect((await Promise.all(writes)).every(r => r.ok)).toBe(true);
  const { text } = await readUntil(c, job, '19\n');
  expect(text).toBe('hello\n' + Array.from({ length: 20 }, (_, i) => `${i}\n`).join('').slice(0));
  await c.ok({ op: 'stop', job });
  expect((await c.close()).code).toBe(0);
}, 30000);

test('read returns base64 byte-exact, holds a partial character, and discloses loss', async () => {
  const c = await connect();
  const job = (await c.ok({ op: 'spawn', argv: ['/bin/cat'], stdin: 'pipe' })).id;
  await c.ok({ op: 'write', job, text: 'é' });
  const first = await c.ok({ op: 'read', job, stream: 'stdout', waitMs: 5000 });
  expect(first).toMatchObject({ bytes: 2, text: 'é', next: 2 });
  const b64 = await c.ok({ op: 'read', job, stream: 'stdout', encoding: 'base64' });
  expect(b64).toMatchObject({ bytes: 2, data: Buffer.from('é').toString('base64'), next: 2 });
  expect(b64.text).toBeUndefined();

  // 3 MiB through a 1 MiB rolling window: reading from 0 discloses the loss.
  const big = await c.ok({
    op: 'spawn',
    argv: ['/bin/sh', '-c', 'head -c 3145728 /dev/zero | tr "\\0" x; printf end'],
    stdin: 'null',
  });
  const done = await c.ok({ op: 'wait', job: big.id, timeoutMs: 20000 });
  expect(done.state).toBe('exited');
  const lost = await c.ok({ op: 'read', job: big.id, stream: 'stdout', offset: 0, max: 16 });
  expect(lost).toMatchObject({ offset: 3145731 - 1048576, bytes: 16, omittedBytes: 3145731 - 1048576, text: 'x'.repeat(16) });
  const tail = await c.ok({ op: 'read', job: big.id, stream: 'stdout', offset: 3145731 - 3 });
  expect(tail).toMatchObject({ bytes: 3, text: 'end', next: 3145731, eof: true, state: 'exited' });
  const input = await c.send({ op: 'write', job: big.id, text: 'x' });
  expect(input).toMatchObject({ ok: false, error: { message: 'session child stdin is closed' } });
  expect((await c.close()).code).toBe(0);
}, 60000);

test('list scope session, errors, and the store list never shows session children', async () => {
  const c = await connect();
  const a = (await c.ok({ op: 'spawn', argv: ['/bin/sleep', '30'], label: 'a' })).id;
  const b = (await c.ok({ op: 'spawn', argv: ['/bin/echo', 'b'], stdin: 'null' })).id;
  await c.ok({ op: 'wait', job: b, timeoutMs: 5000 });
  const listed = await c.ok({ op: 'list', scope: 'session' });
  expect(listed.truncated).toBe(false);
  expect(listed.jobs.map((j: any) => j.id).sort()).toEqual([a, b].sort());
  expect(listed.jobs.find((j: any) => j.id === a)).toMatchObject({ state: 'running', label: 'a', lifetime: 'session' });
  expect(listed.jobs.find((j: any) => j.id === b)).toMatchObject({ state: 'exited', exitCode: 0, lifetime: 'session' });
  const store = await c.ok({ op: 'list' });
  expect(store.jobs.some((j: any) => j.id === a.slice(2) || j.id === a)).toBe(false);

  const other = await connect();
  const foreign = await other.send({ op: 'status', job: a });
  expect(foreign).toMatchObject({ ok: false, error: { code: 22, message: 'unknown session child for this connection' } });
  await other.close();

  const cases: [Record<string, unknown>, string][] = [
    [{ op: 'write', job: 'deadbeef', text: 'x' }, 'native private job operation failed'],
    [{ op: 'read', job: a, stream: 'stdin' }, 'stream must be'],
    [{ op: 'read', job: a }, 'missing field: stream'],
    [{ op: 'read', job: a, stream: 'stdout', max: 65537 }, 'max must be'],
    [{ op: 'read', job: a, stream: 'stdout', encoding: 'hex' }, 'encoding must be'],
    [{ op: 'write', job: a, text: 'x'.repeat(65537) }, 'at most 65536 characters'],
    [{ op: 'spawn', argv: ['/bin/cat'], stdin: 'file' }, 'stdin must be'],
    [{ op: 'spawn', argv: ['/bin/cat'], cwd: 'relative' }, 'cwd must be an absolute path'],
    [{ op: 'list', scope: 'all' }, 'scope must be'],
  ];
  for (const [request, message] of cases) {
    const response = await c.send(request);
    expect(response.ok, JSON.stringify(request)).toBe(false);
    expect(response.error.message).toContain(message);
  }
  const missing = await c.send({ op: 'spawn', argv: ['/bin/pwd'], cwd: join(root, 'nope') });
  expect(missing).toMatchObject({ ok: false, error: { code: 2, message: 'cwd must be an existing directory' } });
  expect((await c.close()).code).toBe(0);
}, 30000);

test('cwd applies to exec, start and spawn without moving the storage home', async () => {
  const dir = join(root, 'work dir');
  mkdirSync(dir, { recursive: true });
  const real = realpathSync(dir);
  const c = await connect();
  expect((await c.ok({ op: 'exec', argv: ['/bin/pwd'], cwd: dir })).stdout).toBe(`${real}\n`);
  const job = (await c.ok({ op: 'start', argv: ['/bin/pwd'], cwd: dir })).id;
  expect((await c.ok({ op: 'wait', job, timeoutMs: 5000 })).stdout).toBe(`${real}\n`);
  expect(existsSync(join(home, job))).toBe(true);
  const child = (await c.ok({ op: 'spawn', argv: ['/bin/pwd'], cwd: dir, stdin: 'null' })).id;
  expect((await c.ok({ op: 'wait', job: child, timeoutMs: 5000 })).stdout).toBe(`${real}\n`);
  expect(existsSync(join(dir, '.jev-fabric-native'))).toBe(false);
  expect((await c.close()).code).toBe(0);
});

test('ending the connection stops its session children and removes their directories', async () => {
  const c = await connect();
  const job = (await c.ok({ op: 'spawn', argv: ['/bin/sh', '-c', 'trap "" TERM; echo $$; exec sleep 60'] })).id;
  const { text } = await readUntil(c, job, '\n');
  const pid = Number(text.trim());
  expect(processGone(pid)).toBe(false);
  const begin = Date.now();
  expect((await c.close()).code).toBe(0);
  expect(Date.now() - begin).toBeLessThan(5000);
  expect(processGone(pid)).toBe(true);
  expect(readdirSync(home).includes(job.slice(2))).toBe(false);
}, 20000);

test('write to a finished child is an error, and a killed connection still stops its children', async () => {
  const c = await connect();
  const job = (await c.ok({ op: 'spawn', argv: ['/bin/sh', '-c', 'read line; echo "$line"'] })).id;
  await c.ok({ op: 'write', job, text: 'one\n' });
  await c.ok({ op: 'wait', job, timeoutMs: 5000 });
  const late = await c.send({ op: 'write', job, text: 'two\n' });
  expect(late).toMatchObject({ ok: false, error: { code: 1, message: 'session child is no longer reading its input' } });

  const orphan = (await c.ok({ op: 'spawn', argv: ['/bin/sh', '-c', 'echo $$; exec sleep 60'] })).id;
  const pid = Number((await readUntil(c, orphan, '\n')).text.trim());
  c.child.kill('SIGKILL');
  await c.child.exited;
  for (let i = 0; i < 100 && !processGone(pid); i++) await Bun.sleep(20);
  expect(processGone(pid)).toBe(true);
}, 20000);

test('echo round trip through serve: a write then a long-poll read', async () => {
  const c = await connect();
  const job = (await c.ok({ op: 'spawn', argv: ['/bin/cat'] })).id;
  let offset = 0;
  const times: number[] = [];
  for (let i = 0; i < 60; i++) {
    const begin = performance.now();
    await c.ok({ op: 'write', job, text: `ping ${i}\n` });
    let text = '';
    while (!text.endsWith('\n')) {
      const r = await c.ok({ op: 'read', job, stream: 'stdout', offset, waitMs: 2000 });
      text += r.text;
      offset = r.next;
    }
    times.push(performance.now() - begin);
    expect(text).toBe(`ping ${i}\n`);
  }
  times.sort((a, b) => a - b);
  const p50 = times[Math.floor(times.length / 2)];
  console.log(`serve echo round trip: p50 ${p50.toFixed(2)} ms, p90 ${times[Math.floor(times.length * 0.9)].toFixed(2)} ms`);
  // The 10 ms target is for an idle machine; the assertion only catches a regression to polling.
  expect(p50).toBeLessThan(100);
  expect((await c.close()).code).toBe(0);
}, 30000);
