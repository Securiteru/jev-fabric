import { afterAll, expect, test } from 'bun:test';
import { readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { nativeBin, processGone, tempRoot } from './helpers.ts';

// Durable interactive jobs (`start --input pipe`), `write`, `close-input` and
// `read`, through the CLI and through serve (docs/composition.md).
const root = tempRoot('native-interactive-');
const home = join(root, 'jobs');
const started = new Set<string>();
afterAll(async () => {
  await Promise.all([...started].map(id => cli(['stop', id])));
  rmSync(root, { recursive: true, force: true });
});

async function cli(args: string[], input?: string, dir = home) {
  const child = Bun.spawn([nativeBin, '--', ...args], {
    env: { PATH: '/usr/bin:/bin', BEND_NO_TELEMETRY: '1', JEV_FABRIC_HOME: dir },
    stdin: input === undefined ? 'ignore' : 'pipe',
    stdout: 'pipe',
    stderr: 'pipe',
  });
  if (input !== undefined) {
    child.stdin!.write(input);
    child.stdin!.end();
  }
  const [out, err, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  return { out, err, code };
}
async function json(args: string[], input?: string) {
  const r = await cli(args, input);
  expect(r.code, `${args.join(' ')}: ${r.err}`).toBe(0);
  return JSON.parse(r.out);
}
async function start(args: string[]) {
  const { id } = await json(['start', '--input', 'pipe', ...args]);
  started.add(id);
  return id as string;
}
/** Reads from `offset` until `want` appears, following `next`. */
async function readUntil(id: string, want: string, offset = 0) {
  let text = '';
  for (let i = 0; i < 100 && !text.includes(want); i++) {
    const r = await json(['read', '--wait-ms', '2000', id, 'stdout', String(offset)]);
    text += r.text;
    offset = r.next;
    if (r.eof) break;
  }
  return { text, offset };
}

test('an interactive job keeps state across writes from separate processes', async () => {
  const script = 'i=0; while IFS= read -r value; do i=$((i+1)); printf \'{"count":%s,"value":"%s"}\\n\' "$i" "$value"; done; echo bye';
  const id = await start(['--label', 'counter', '/bin/sh', '-c', script]);
  expect(await json(['status', id])).toMatchObject({ id, label: 'counter', lifetime: 'durable', state: 'running' });

  expect(await json(['write', id, '--', 'one', 'two\n'])).toEqual({ id, written: 8, closed: false });
  let { text, offset } = await readUntil(id, '\n');
  expect(JSON.parse(text)).toEqual({ count: 1, value: 'one two' });

  expect(await json(['write', id, '--stdin'], 'héllo\n')).toEqual({ id, written: 7, closed: false });
  ({ text, offset } = await readUntil(id, '\n', offset));
  expect(JSON.parse(text)).toEqual({ count: 2, value: 'héllo' });

  // Writes land in the order they were made.
  for (let n = 0; n < 20; n++) await json(['write', id, '--', `${n}\n`]);
  ({ text, offset } = await readUntil(id, '"value":"19"', offset));
  expect(text.trim().split('\n').map(line => JSON.parse(line).value)).toEqual(Array.from({ length: 20 }, (_, n) => String(n)));

  expect(await json(['close-input', id])).toEqual({ id, written: 0, closed: true });
  expect(await json(['close-input', id])).toEqual({ id, written: 0, closed: true });
  const late = await cli(['write', id, '--', 'late\n']);
  expect(late.code).toBe(1);
  expect(late.err).toMatch(/job input is closed|job has finished/);

  const receipt = await json(['wait', '--timeout-ms', '5000', id]);
  expect(receipt).toMatchObject({ id, lifetime: 'durable', state: 'exited', exitCode: 0 });
  expect(receipt.stdout).toContain('bye\n');
  const end = await json(['read', id, 'stdout', String(offset)]);
  expect(end).toMatchObject({ id, stream: 'stdout', bytes: 4, text: 'bye\n', eof: true, state: 'exited' });
  const after = await cli(['write', id, '--', 'x']);
  expect([after.code, after.err.trim()]).toEqual([1, 'job has finished']);
  started.delete(id);
}, 60000);

test('the input queue is bounded and a job that is not reading fills it', async () => {
  const id = await start(['/bin/sleep', '60']);
  const chunk = 'x'.repeat(65536);
  let refused: { code: number; err: string } | undefined;
  for (let i = 0; i < 40 && !refused; i++) {
    const r = await cli(['write', id, '--stdin'], chunk);
    if (r.code !== 0) refused = r;
  }
  expect(refused?.code).toBe(1);
  expect(refused?.err).toContain('job input queue is full');
  const stopped = await json(['stop', id]);
  expect(stopped.state).toBe('cancelled');
  started.delete(id);
  const late = await cli(['write', id, '--', 'x']);
  expect(late.err.trim()).toBe('job has finished');
}, 60000);

test('read returns raw bytes of a batch job from any offset, and refuses writes to it', async () => {
  const { id } = await json(['start', '/bin/sh', '-c', 'printf "héllo wörld"; printf oops >&2']);
  await json(['wait', id]);
  const all = await json(['read', id, 'stdout']);
  expect(all).toEqual({ id, stream: 'stdout', offset: 0, bytes: 13, omittedBytes: 0, text: 'héllo wörld', next: 13, eof: true, state: 'exited' });
  const middle = await json(['read', '--base64', id, 'stdout', '1', '2']);
  expect(middle).toMatchObject({ offset: 1, bytes: 2, data: Buffer.from('é').toString('base64'), next: 3, eof: false });
  expect((await json(['read', id, 'stderr'])).text).toBe('oops');
  const past = await json(['read', '--wait-ms', '50', id, 'stdout', '13']);
  expect(past).toMatchObject({ offset: 13, bytes: 0, next: 13, eof: true });

  const refused = await cli(['write', id, '--', 'x']);
  expect([refused.code, refused.err.trim()]).toEqual([22, 'job was not started with --input pipe']);
  for (const [args, message] of [
    [['read', id], 'usage: read'],
    [['read', id, 'stdin'], 'stream must be stdout or stderr'],
    [['read', id, 'stdout', 'x'], 'offset must be a byte offset'],
    [['read', id, 'stdout', '0', '65537'], 'max must be an integer from 1 to 65536'],
    [['read', '--wait-ms', '0', id, 'stdout'], '--wait-ms must be an integer from 1 to 300000'],
    [['start', '--input', 'file', '/bin/cat'], '--input takes pipe'],
    [['exec', '--input', 'pipe', '/bin/cat'], '--input is supported for start only'],
    [['write', id, '--', 'x'.repeat(65537)], 'write takes at most 65536 characters'],
  ] as [string[], string][]) {
    const r = await cli(args);
    expect(r.code, args.join(' ')).toBe(r.err.includes('not started') ? 22 : 2);
    expect(r.err).toContain(message);
  }
});

test('a crashed worker is reported, and its input is not replayed', async () => {
  const id = await start(['/bin/cat']);
  const worker = Number(
    Bun.spawnSync(['/usr/bin/pgrep', '-f', `__job-worker ${id}`]).stdout.toString().trim().split('\n')[0],
  );
  expect(worker).toBeGreaterThan(0);
  process.kill(worker, 'SIGKILL');
  for (let i = 0; i < 100 && !processGone(worker); i++) await Bun.sleep(20);
  const failed = await json(['status', id]);
  expect(failed).toMatchObject({ state: 'failed', exitCode: null, error: 'worker exited without a terminal receipt' });
  const r = await cli(['write', id, '--', 'x']);
  expect([r.code, r.err.trim()]).toEqual([1, 'job has finished']);
  started.delete(id);
});

test('serve starts, writes, closes and reads durable jobs; a newer store refuses them', async () => {
  const child = Bun.spawn([nativeBin, '--', 'serve'], {
    env: { PATH: '/usr/bin:/bin', BEND_NO_TELEMETRY: '1', JEV_FABRIC_HOME: home },
    stdin: 'pipe',
    stdout: 'pipe',
    stderr: 'pipe',
  });
  const reader = child.stdout.getReader();
  let buffered = '';
  const next = async () => {
    for (;;) {
      const at = buffered.indexOf('\n');
      if (at >= 0) {
        const line = buffered.slice(0, at);
        buffered = buffered.slice(at + 1);
        return JSON.parse(line);
      }
      const { value } = await reader.read();
      buffered += new TextDecoder().decode(value);
    }
  };
  await next();
  child.stdin.write(JSON.stringify({ id: 0, op: 'start', argv: ['/bin/cat'], input: 'pipe' }) + '\n');
  child.stdin.flush();
  const id = (await next()).result.id;
  child.stdin.write(JSON.stringify({ id: 1, op: 'write', job: id, text: 'durable\n' }) + '\n');
  child.stdin.write(JSON.stringify({ id: 2, op: 'read', job: id, stream: 'stdout', waitMs: 5000 }) + '\n');
  child.stdin.write(JSON.stringify({ id: 3, op: 'closeInput', job: id }) + '\n');
  child.stdin.write(JSON.stringify({ id: 4, op: 'wait', job: id, timeoutMs: 5000 }) + '\n');
  child.stdin.end();
  const lines = [await next(), await next(), await next(), await next()];
  expect(await child.exited).toBe(0);
  const byId = new Map(lines.map((l: any) => [l.id, l]));
  expect(byId.get(1).result).toEqual({ id, written: 8, closed: false });
  expect(byId.get(2).result).toMatchObject({ id, offset: 0, text: 'durable\n', next: 8 });
  expect(byId.get(3).result).toEqual({ id, written: 0, closed: true });
  expect(byId.get(4).result).toMatchObject({ id, state: 'exited', stdout: 'durable\n' });
  started.delete(id);

  const marker = join(home, '.jev-fabric-store.json');
  const saved = readFileSync(marker, 'utf8');
  writeFileSync(marker, '{"store":2}\n');
  try {
    for (const args of [['write', id, '--', 'x'], ['close-input', id], ['read', id, 'stdout']]) {
      const r = await cli(args);
      expect(r.code, args.join(' ')).toBe(22);
      expect(r.err).toContain('store format 2');
    }
  } finally {
    writeFileSync(marker, saved);
  }
}, 30000);
