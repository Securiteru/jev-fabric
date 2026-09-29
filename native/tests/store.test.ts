import { afterAll, expect, test } from 'bun:test';
import { existsSync, mkdirSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { capture, nativeBin, tempRoot } from './helpers.ts';

// The storage format marker and `capabilities` (docs/composition.md).
const root = tempRoot('native-store-');
afterAll(() => rmSync(root, { recursive: true, force: true }));

let serial = 0;
function home() {
  return join(root, `home-${serial++}`);
}
async function cli(dir: string, args: string[], cwd?: string) {
  const env = { PATH: '/usr/bin:/bin', BEND_NO_TELEMETRY: '1', JEV_FABRIC_HOME: dir };
  const child = Bun.spawn([nativeBin, '--', ...args], { env, cwd, stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' });
  const [out, err, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  return { out, err, code };
}
const marker = (dir: string) => join(dir, '.jev-fabric-store.json');

test('capabilities is one JSON line naming the protocol, store, platform and features', async () => {
  const r = await capture([nativeBin, '--', 'capabilities']);
  expect(r.code, r.err).toBe(0);
  expect(r.out.trim().split('\n').length).toBe(1);
  const caps = JSON.parse(r.out);
  expect(caps).toMatchObject({ version: '0.5.0-native', protocol: 2, store: 1 });
  expect(caps.platform).toMatch(/^(darwin|linux)-(arm64|x64)$/);
  expect(Object.keys(caps)).toEqual(['version', 'protocol', 'store', 'platform', 'features']);
  expect(caps.features).toEqual(expect.arrayContaining(['follow', 'list', 'label', 'start-24h', 'sessions']));
});

test('a new home records its format; list never shows the marker', async () => {
  const dir = home();
  const started = await cli(dir, ['start', '/bin/echo', 'hi']);
  expect(started.code, started.err).toBe(0);
  expect(readFileSync(marker(dir), 'utf8')).toBe('{"store":1}\n');
  expect(statSync(marker(dir)).mode & 0o777).toBe(0o600);
  const listed = JSON.parse((await cli(dir, ['list'])).out);
  expect(listed.jobs.length).toBe(1);
  expect(listed.jobs[0].id).toBe(JSON.parse(started.out).id);
});

test('an existing home is adopted by its first writing verb, not by a read', async () => {
  const dir = home();
  mkdirSync(dir, { mode: 0o700 });
  expect((await cli(dir, ['list'])).code).toBe(0);
  expect(existsSync(marker(dir))).toBe(false);
  const started = await cli(dir, ['start', '/bin/echo', 'adopted']);
  expect(started.code, started.err).toBe(0);
  expect(readFileSync(marker(dir), 'utf8')).toBe('{"store":1}\n');
});

test('a home with a newer store is refused by every store verb and never rewritten', async () => {
  const dir = home();
  const first = await cli(dir, ['start', '/bin/echo', 'old']);
  const id = JSON.parse(first.out).id;
  await cli(dir, ['wait', id]);
  const newer = '{"store":2,"note":"written by a later release"}\n';
  writeFileSync(marker(dir), newer, { mode: 0o600 });
  const verbs = [
    ['start', '/bin/echo', 'x'],
    ['status', id],
    ['wait', id],
    ['stop', id],
    ['events', id],
    ['follow', '--timeout-ms', '100', id],
    ['watch', '--timeout-ms', '100', id, 'x'],
    ['list'],
    ['run', '--timeout-ms', '1000', 'missing.bend'],
  ];
  for (const args of verbs) {
    const r = await cli(dir, args);
    expect(r.code, args.join(' ')).toBe(22);
    expect(r.err).toContain('storage home uses store format 2');
  }
  expect(readFileSync(marker(dir), 'utf8')).toBe(newer);

  const unreadable = home();
  mkdirSync(unreadable, { mode: 0o700 });
  writeFileSync(marker(unreadable), 'not json', { mode: 0o600 });
  const r = await cli(unreadable, ['list']);
  expect(r.code).toBe(22);
  expect(r.err).toContain('not readable');
});

test('serve refuses a newer store per request, and the session continues', async () => {
  const dir = home();
  mkdirSync(dir, { mode: 0o700 });
  writeFileSync(marker(dir), '{"store":3}\n', { mode: 0o600 });
  const child = Bun.spawn([nativeBin, '--', 'serve'], {
    env: { PATH: '/usr/bin:/bin', BEND_NO_TELEMETRY: '1', JEV_FABRIC_HOME: dir },
    stdin: 'pipe',
    stdout: 'pipe',
    stderr: 'pipe',
  });
  child.stdin.write('{"id":1,"op":"list"}\n{"id":2,"op":"spawn","argv":["/bin/cat"]}\n{"id":3,"op":"exec","argv":["/bin/echo","ok"]}\n');
  child.stdin.end();
  const lines = (await new Response(child.stdout).text()).trim().split('\n').map(l => JSON.parse(l));
  expect(await child.exited).toBe(0);
  const byId = new Map(lines.slice(1).map((l: any) => [l.id, l]));
  expect(byId.get(1)).toMatchObject({ ok: false, error: { code: 22 } });
  expect(byId.get(1).error.message).toContain('store format 3');
  expect(byId.get(2)).toMatchObject({ ok: false, error: { code: 22 } });
  expect(byId.get(3)).toMatchObject({ ok: true, result: { stdout: 'ok\n' } });
});

test('exec and start take --cwd; the storage home stays where it was', async () => {
  const dir = home();
  const work = join(root, 'cwd');
  mkdirSync(work, { recursive: true });
  const real = realpathSync(work);
  const exec = await cli(dir, ['exec', '--cwd', work, '/bin/pwd']);
  expect(exec.code, exec.err).toBe(0);
  expect(JSON.parse(exec.out).stdout).toBe(`${real}\n`);
  const started = await cli(dir, ['start', '--cwd', work, '--label', 'here', '/bin/pwd']);
  expect(started.code, started.err).toBe(0);
  const receipt = JSON.parse((await cli(dir, ['wait', JSON.parse(started.out).id])).out);
  expect(receipt).toMatchObject({ stdout: `${real}\n`, label: 'here', lifetime: 'durable' });
  for (const [args, message] of [
    [['exec', '--cwd', 'relative', '/bin/pwd'], 'cwd must be an absolute path'],
    [['exec', '--cwd', join(root, 'missing'), '/bin/pwd'], 'cwd must be an existing directory'],
    [['start', '--cwd', join(root, 'missing'), '/bin/pwd'], 'cwd must be an existing directory'],
    [['wait', '--cwd', work, 'x'], '--cwd is supported for exec and start only'],
  ] as [string[], string][]) {
    const r = await cli(dir, args);
    expect(r.code, args.join(' ')).toBe(2);
    expect(r.err).toContain(message);
  }
});
