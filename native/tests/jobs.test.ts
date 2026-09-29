import { afterAll, describe, expect, test } from 'bun:test';
import {
  chmodSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync,
  unlinkSync, writeFileSync,
} from 'node:fs';
import { join, resolve } from 'node:path';
import { capture, jsonLines, processGone as gone, tempRoot } from './helpers.ts';

// Dev-only harness. The fixture is stock Bend: bend native/tests/jobs.bend -o build/test-jobs.
// Deliberately do not invoke build scripts or use Node/Bun inside a runtime job.
const root = tempRoot('jobs-test-');
const bin = resolve(process.env.JEV_JOBS_BIN ?? 'build/test-jobs');
const env = { PATH: '/usr/bin:/bin', JEV_FABRIC_HOME: root };
const active = new Set<string>();
const privateMode = (path: string) => statSync(path).mode & 0o777;

async function command(args: string[], overrides: Record<string, string> = {}) {
  const argv = [bin, '--threads', '2', '--', ...args];
  const options = { env: { ...env, ...overrides }, stdin: 'ignore' } as const;
  const { out, err, code } = await capture(argv, options);
  return { stdout: out, stderr: err, code };
}
async function json(args: string[], overrides: Record<string, string> = {}) {
  const result = await command(args, overrides);
  expect(result.code, result.stderr).toBe(0);
  return JSON.parse(result.stdout);
}
async function start(argv: string[], ms = 5000, overrides: Record<string, string> = {}) {
  const result = await json(['start', String(ms), ...argv], overrides);
  expect(result.id).toMatch(/^[a-f0-9]{32}$/);
  active.add(result.id);
  return result.id as string;
}
async function wait(id: string, ms = 5000) {
  const result = await json(['wait', id, String(ms)]);
  if (result.state !== 'running') active.delete(id);
  return result;
}
async function events(id: string, after?: number) {
  const result = await command(['events', id, ...(after === undefined ? [] : [String(after)])]);
  expect(result.code, result.stderr).toBe(0);
  return jsonLines(result.stdout);
}
async function eventually<T>(get: () => Promise<T>, check: (value: T) => boolean): Promise<T> {
  for (let i = 0; i < 100; i++) {
    const value = await get();
    if (check(value)) return value;
    await Bun.sleep(20);
  }
  throw new Error('condition not observed');
}
function streamText(items: any[], stream = 'stdout') {
  return items
    .filter(e => e.type === 'process.output' && e.data.stream === stream)
    .map(e => e.data.text)
    .join('');
}
afterAll(async () => {
  await Promise.all([...active].map(id => command(['stop', id])));
  rmSync(root, { recursive: true, force: true });
});

describe('durable native command jobs', () => {
  test('launcher exits; running state and real stdout/stderr are live before release; wait does not cancel', async () => {
    const release = join(root, 'release');
    const script = 'printf live; printf warning >&2; '
      + 'while [ ! -f "$1" ]; do /bin/sleep 0.02; done; printf done';
    const id = await start(['/bin/sh', '-c', script, 'sh', release]);
    expect((await json(['status', id])).state).toBe('running');
    expect((await wait(id, 30)).state).toBe('running');
    const live = await eventually(
      () => events(id),
      xs => streamText(xs) === 'live' && streamText(xs, 'stderr') === 'warning',
    );
    expect(live.some(e => e.type === 'job.finished')).toBe(false);
    const last = live.at(-1).sequence;
    writeFileSync(release, 'release');
    const receipt = await wait(id);
    expect(receipt).toMatchObject({
      id,
      state: 'exited',
      stdout: 'livedone',
      stderr: 'warning',
      exitCode: 0,
    });
    const all = await events(id);
    expect(all.at(-1).type).toBe('job.finished');
    expect(await events(id, last)).toEqual(all.filter(e => e.sequence > last));
    expect(await events(id, all.at(-1).sequence)).toEqual([]);
    expect(await json(['stop', id])).toEqual(receipt);
    expect(await events(id)).toEqual(all);
  });

  test('private directory and every persisted file use private permissions', async () => {
    const id = await start(['/bin/echo', 'private']);
    await wait(id);
    expect(privateMode(root)).toBe(0o700);
    const dir = join(root, id);
    expect(privateMode(dir)).toBe(0o700);
    for (const name of readdirSync(dir)) expect(privateMode(join(dir, name))).toBe(0o600);
  });

  test('literal argv, Unicode and JSON escaping never gain shell interpretation', async () => {
    const marker = join(root, 'not-executed');
    const value = `🙂\n\t"\\ $(touch ${marker}); $HOME`;
    const id = await start(['/bin/sh', '-c', 'printf "%s" "$1"', 'sh', value]);
    const receipt = await wait(id);
    expect(receipt.stdout).toBe(value);
    expect(streamText(await events(id))).toBe(value);
    expect(existsSync(marker)).toBe(false);
  });

  test('native executable self-spawns with no node, bun, or native launcher on PATH', async () => {
    const id = await start(['/bin/echo', 'native'], 5000, { PATH: join(root, 'no-tools') });
    expect((await wait(id)).stdout).toBe('native\n');
  });

  test('failed command launch and nonzero exit persist sanitized failed receipts', async () => {
    const id = await start(['/nonexistent/SYNTHETIC_NOT_A_REAL_SECRET']);
    const receipt = await wait(id);
    expect(receipt.state).toBe('failed');
    expect(JSON.stringify(receipt)).not.toContain('SYNTHETIC');
    expect((await events(id)).at(-1).type).toBe('job.finished');
    const nonzero = await start(['/bin/sh', '-c', 'printf error >&2; exit 7']);
    expect(await wait(nonzero)).toMatchObject({ state: 'failed', exitCode: 7, stderr: 'error' });
  });

  test('deadline kills and reaps its owned child', async () => {
    const id = await start(['/bin/sh', '-c', 'printf "%s" "$$"; exec /bin/sleep 60'], 150);
    const receipt = await wait(id);
    expect(receipt).toMatchObject({ state: 'timed_out', timedOut: true, exitCode: 124 });
    expect(gone(Number(receipt.stdout))).toBe(true);
  });

  test('stop is cooperative, cleans up owned group, concurrent/idempotent and terminal states are stable', async () => {
    const marker = join(root, 'escaped-descendant');
    // A backgrounded descendant would write the marker after 1s unless its group is killed.
    const script = '(/bin/sleep 1; printf leaked > "$1") & printf "%s" "$$"; exec /bin/sleep 60';
    const id = await start(['/bin/sh', '-c', script, 'sh', marker], 10000);
    await eventually(() => events(id), xs => /^\d+$/.test(streamText(xs)));
    const stopped = await Promise.all([json(['stop', id]), json(['stop', id])]);
    expect(stopped[0].state).toBe('cancelled');
    expect(stopped[1]).toEqual(stopped[0]);
    expect(gone(Number(stopped[0].stdout))).toBe(true);
    expect(await json(['status', id])).toEqual(stopped[0]);
    expect(await json(['stop', id])).toEqual(stopped[0]);
    active.delete(id);
    await Bun.sleep(1200);
    expect(existsSync(marker)).toBe(false);
  });

  test('spool and replay stay bounded under output flood', async () => {
    const flood = '/usr/bin/head -c 1400000 /dev/zero';
    const id = await start(['/bin/sh', '-c', `${flood}; ${flood} >&2`], 5000);
    const receipt = await wait(id, 10000);
    expect(receipt.state).toBe('exited');
    expect(receipt.stdout.length).toBe(32768);
    expect(receipt.stderr.length).toBe(32768);
    expect(receipt.truncated).toEqual({ stdout: true, stderr: true });
    const dir = join(root, id);
    expect(statSync(join(dir, 'stdout.bin')).size).toBe(1048576);
    expect(statSync(join(dir, 'stderr.bin')).size).toBe(1048576);
    expect(statSync(join(dir, 'events.jsonl')).size).toBeLessThan(1048576);
    const xs = await events(id);
    expect(xs.length).toBeLessThanOrEqual(64);
    expect(xs.some(e => e.type === 'process.output' && e.data.omittedBytes > 0)).toBe(true);
    expect(xs.filter(e => e.type === 'process.spool_limit').length).toBe(2);
    for (let i = 1; i < xs.length; i++) expect(xs[i].sequence).toBe(xs[i - 1].sequence + 1);
    expect(xs.at(-1).type).toBe('job.finished');
    expect(await events(id, xs.at(-2).sequence)).toEqual([xs.at(-1)]);
  }, 30000);

  test('replay retention evicts oldest entries and preserves strictly increasing cursor', async () => {
    const script = 'n=0; while [ "$n" -lt 90 ]; do printf x; /bin/sleep 0.05; n=$((n+1)); done';
    const id = await start(['/bin/sh', '-c', script], 20000);
    expect((await wait(id, 20000)).state).toBe('exited');
    const xs = await events(id);
    expect(xs.length).toBe(64);
    expect(xs[0].sequence).toBeGreaterThan(1);
    expect(xs.at(-1).type).toBe('job.finished');
    for (let i = 1; i < xs.length; i++) expect(xs[i].sequence).toBe(xs[i - 1].sequence + 1);
  }, 30000);

  test('continuous output keeps publishing live snapshots whose chunks match the spool', async () => {
    const script = 'i=0; while [ "$i" -lt 60 ]; do printf "line %s\\n" "$i"; /bin/sleep 0.02; '
      + 'i=$((i+1)); done';
    const id = await start(['/bin/sh', '-c', script], 20000);
    const live = new Set<number>();
    for (let i = 0; i < 300 && live.size < 3; i++) {
      const xs = await events(id);
      if (xs.some(e => e.type === 'job.finished')) break;
      live.add(xs.at(-1).sequence);
      await Bun.sleep(20);
    }
    expect(live.size).toBeGreaterThanOrEqual(3);
    expect((await wait(id, 20000)).state).toBe('exited');
    const dir = join(root, id);
    const replay = await command(['events', id]);
    expect(replay.stdout).toBe(readFileSync(join(dir, 'events.jsonl'), 'utf8'));
    const xs = jsonLines(replay.stdout);
    expect(xs.length).toBeLessThanOrEqual(64);
    for (let i = 1; i < xs.length; i++) expect(xs[i].sequence).toBe(xs[i - 1].sequence + 1);
    expect(xs.at(-1).type).toBe('job.finished');
    const spool = readFileSync(join(dir, 'stdout.bin'), 'utf8');
    const chunks = xs.filter(e => e.type === 'process.output' && e.data.stream === 'stdout');
    expect(chunks.length).toBeGreaterThan(1);
    for (const { data } of chunks) {
      expect(data.text).toBe(spool.slice(data.offset, data.offset + data.bytes));
    }
    for (let i = 1; i < chunks.length; i++) {
      const [before, after] = [chunks[i - 1].data, chunks[i].data];
      expect(after.offset).toBe(before.offset + before.bytes + after.omittedBytes);
    }
  }, 30000);

  test('split UTF-8 survives multiple live reads; partial EOF and malformed bytes are explicit replacement text', async () => {
    // U+1F642 split across two writes, then a truncated lead pair at EOF.
    const script = "printf '\\360\\237'; /bin/sleep 0.15; printf '\\231\\202'; "
      + "/bin/sleep 0.1; printf '\\360\\237'";
    const id = await start(['/bin/sh', '-c', script]);
    await wait(id);
    expect(streamText(await events(id))).toBe('🙂�');
    const invalid = await start(['/bin/sh', '-c', "printf '\\377A\\355\\240\\200B'"]);
    await wait(invalid);
    expect(streamText(await events(invalid))).toBe('�A�B');
  });

  test('rejects traversal, malformed IDs, invalid numeric arguments and absent jobs', async () => {
    for (const id of ['../outside', '.', '/etc', 'A'.repeat(32), 'a'.repeat(31), 'b'.repeat(32)]) {
      expect((await command(['status', id])).code).not.toBe(0);
      expect((await command(['stop', id])).code).not.toBe(0);
    }
    // A detached job may live a day; nothing else may exceed an hour.
    for (const ms of ['0', '-1', 'oops', '86400001']) {
      expect((await command(['start', ms, '/bin/echo'])).code).not.toBe(0);
    }
    expect((await command(['wait', 'a'.repeat(32), '3600001'])).code).toBe(2);
    expect((await command(['follow', '3600001', 'a'.repeat(32)])).code).toBe(2);
    expect((await command(['start'])).code).toBe(2);
    expect((await command(['events', 'a'.repeat(32), 'oops'])).code).toBe(2);
  });

  test('an orphan lease becomes a stable failed receipt without trusting stale PID metadata', async () => {
    const id = 'd'.repeat(32);
    const dir = join(root, id);
    mkdirSync(dir, { mode: 0o700 });
    writeFileSync(join(dir, 'ready'), 'ready', { mode: 0o600 });
    writeFileSync(join(dir, 'pid'), String(process.pid), { mode: 0o600 });
    const receipt = await json(['status', id]);
    expect(receipt.state).toBe('failed');
    expect(await json(['stop', id])).toEqual(receipt);
    expect(await json(['status', id])).toEqual(receipt);
    expect(JSON.parse(readFileSync(join(dir, 'receipt.json'), 'utf8'))).toEqual(receipt);
    expect((await command(['__job-worker', id, '1000', '/bin/echo'])).code).not.toBe(0);
  });

  test('root and job-directory symlinks are rejected without reading targets', async () => {
    const target = join(root, 'target');
    mkdirSync(target, { mode: 0o700 });
    const alias = join(root, 'root-alias');
    symlinkSync(target, alias);
    const aliased = await command(['start', '1000', '/bin/echo'], { JEV_FABRIC_HOME: alias });
    expect(aliased.code).not.toBe(0);
    const id = 'c'.repeat(32);
    symlinkSync(target, join(root, id));
    expect((await command(['status', id])).code).not.toBe(0);
    expect(readdirSync(target)).toEqual([]);
  });

  test('receipt symlinks, overlarge reads, world-readable files and duplicate workers fail closed', async () => {
    const id = await start(['/bin/echo', 'safe']);
    const receipt = await wait(id);
    const path = join(root, id, 'receipt.json');
    const text = readFileSync(path, 'utf8');
    const marker = join(root, 'untouched');
    writeFileSync(marker, 'unchanged', { mode: 0o600 });
    unlinkSync(path);
    symlinkSync(marker, path);
    expect((await command(['status', id])).code).not.toBe(0);
    expect((await command(['stop', id])).code).not.toBe(0);
    expect(readFileSync(marker, 'utf8')).toBe('unchanged');
    unlinkSync(path);
    writeFileSync(path, 'x'.repeat(1048577), { mode: 0o600 });
    expect((await command(['status', id])).code).not.toBe(0);
    writeFileSync(path, text);
    chmodSync(path, 0o644);
    expect((await command(['status', id])).code).not.toBe(0);
    chmodSync(path, 0o600);
    expect((await command(['__job-worker', id, '1000', '/bin/echo', 'changed'])).code).not.toBe(0);
    expect(await json(['status', id])).toEqual(receipt);
  });

  test('stop-marker symlink cannot mutate unrelated files or signal an arbitrary metadata PID', async () => {
    const id = await start(['/bin/sh', '-c', '/bin/sleep 0.6'], 2000);
    const marker = join(root, 'outside-marker');
    writeFileSync(marker, 'unchanged', { mode: 0o600 });
    symlinkSync(marker, join(root, id, 'stop'));
    const stopped = await command(['stop', id]);
    // If the controller observes the bad marker first, its fail-closed cleanup
    // wins this race and stop legitimately returns the recovered failed receipt.
    if (stopped.code === 0) expect(JSON.parse(stopped.stdout).state).toBe('failed');
    expect(readFileSync(marker, 'utf8')).toBe('unchanged');
    unlinkSync(join(root, id, 'stop'));
    // The controller may fail closed upon seeing the unsafe marker, or finish.
    const receipt = await wait(id);
    expect(['exited', 'failed']).toContain(receipt.state);
  });
});

// Runs last: the store now holds orphans, symlinks and stray files from above.
test('list survives every hostile entry above and reports recovered orphans', async () => {
  const listing = await json(['list']);
  expect(listing.truncated).toBe(false);
  const ids = listing.jobs.map((job: any) => job.id);
  expect(new Set(ids).size).toBe(ids.length);
  for (const id of ids) expect(id).toMatch(/^[0-9a-f]{32}$/);
  // The symlinked id-shaped directory is never followed.
  expect(ids).not.toContain('c'.repeat(32));
  // The orphan lease was recovered as failed by `status` and stays so.
  expect(listing.jobs.find((job: any) => job.id === 'd'.repeat(32))).toMatchObject({ state: 'failed', exitCode: null });
  const states = new Set(listing.jobs.map((job: any) => job.state));
  for (const state of states) expect(['running', 'starting', 'exited', 'failed', 'timed_out', 'cancelled']).toContain(state);
  // Nothing is left running by the suite except what afterAll stops.
  expect(listing.jobs.filter((job: any) => job.state === 'running').every((job: any) => active.has(job.id))).toBe(true);
});
