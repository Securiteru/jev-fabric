import { test, expect, afterAll } from 'bun:test';
import { mkdirSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import manifest from '../../package.json';
import { capture, jsonLines, nativeBin, tempRoot } from './helpers.ts';

const root = tempRoot('native-cli-');
afterAll(() => rmSync(root, { recursive: true, force: true }));

type Options = { input?: string; path?: string; home?: string };
function run(args: string[], options: Options = {}) {
  const env = {
    PATH: options.path ?? process.env.PATH!,
    BEND_NO_TELEMETRY: '1',
    JEV_FABRIC_HOME: options.home ?? join(root, 'jobs'),
  };
  return capture([nativeBin, '--', ...args], { env, input: options.input ?? '' });
}
const privateMode = (path: string) => statSync(path).mode & 0o777;

const echoProgram = `import Base
import ../../native/Process.bend as Process
def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    IO.print(List.show(&1, String, text => text, args))
    result : Process.Report <- Process.run_stdin(["/bin/cat"], 1000)
    IO.print(Process.show(result))
`;

// Unbounded @unsafe recursion: only the outside deadline can stop it.
const spinProgram = `import Base
@unsafe def spin(n: U32) -> U32:
  spin(U32.add(n, 1))
def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    IO.print("entered-runtime")
    IO.print(U32.show(spin(U32.from_nat(List.length(&1, String, args)))))
`;

test('public native help registers execution, source, validation, Jev, job and session verbs', async () => {
  const r = await run(['--help']);
  expect(r.code).toBe(0);
  const verbs = ['exec', 'run', 'validate', 'jev', 'start', 'status', 'events', 'wait', 'stop', 'watch', 'follow', 'list', 'serve', 'capabilities', 'update'];
  for (const cmd of verbs) expect(r.out).toContain(cmd);
  expect((await run(['--version'])).out).toContain(`${manifest.version}-native`);
  expect(manifest.version).toBe('0.5.0');
  expect(manifest.bin['jev-fabric']).toBe('build/jev-fabric');
  expect(Object.keys(manifest.bin)).toEqual(['jev-fabric']);
  expect(manifest.scripts.demo).toContain('examples/native/pipeline.bend');
});

test('strict request file validation runs with no Node/Bun on PATH', async () => {
  const r = await run(['validate', 'examples/native/request.json'], { path: '/nonexistent' });
  expect(r.code, r.out + r.err).toBe(0);
  expect(JSON.parse(r.out).questions.healthy.type).toBe('noul');
  const file = join(root, 'invalid.json');
  // Deliberately raw: a duplicate key must be rejected.
  await Bun.write(file, '{"state":"x","state":"y","questions":{}}');
  const bad = await run(['validate', file]);
  expect(bad.code).not.toBe(0);
  await Bun.write(file, new Uint8Array([0xff, 0xfe]));
  expect((await run(['validate', file])).code).not.toBe(0);
  expect((await run(['validate', join(root, 'absent')])).code).not.toBe(0);
});

test('compiled native program executes in a private directory with literal argv and inherited stdin', async () => {
  const file = join(root, 'echo.bend');
  await Bun.write(file, echoProgram);
  const r = await run(['run', '20000', file, 'literal ; $(nope)'], { input: 'native input 🙂\n' });
  expect(r.code, r.out + r.err).toBe(0);
  const receipt = JSON.parse(r.out);
  expect(receipt.stdout).toContain('literal ; $(nope)');
  expect(receipt.stdout).toContain('native input 🙂');
  const home = join(root, 'jobs');
  expect(privateMode(home)).toBe(0o700);
  for (const id of readdirSync(home).filter(name => !name.startsWith('.'))) {
    expect(privateMode(join(home, id))).toBe(0o700);
  }
});

test('compiler failures and option injection fail closed; outside deadline bounds compile', async () => {
  const file = join(root, 'bad.bend');
  await Bun.write(file, 'not a valid Bend program');
  const bad = await run(['run', '5000', file]);
  expect(bad.code).not.toBe(0);
  for (const args of [['run', '0', file], ['run', '2000', '--evil.bend'], ['run', '2000', 'file.ts']]) {
    expect((await run(args)).code).not.toBe(0);
  }
  const start = Date.now();
  const tiny = await run(['run', '1', 'examples/native/pipeline.bend']);
  expect(tiny.code).toBe(124);
  expect(Date.now() - start).toBeLessThan(1500);
});

test('native source loop cannot suppress outside execution deadline', async () => {
  const file = join(root, 'spin.bend');
  await Bun.write(file, spinProgram);
  const home = join(root, 'spin-jobs');
  const start = Date.now();
  const r = await run(['run', '6000', file], { home });
  expect(r.code, r.out + r.err).toBe(124);
  expect(Date.now() - start).toBeLessThan(8000);
  const program = join(home, readdirSync(home).filter(name => !name.startsWith('.'))[0]!, 'program');
  expect(statSync(program).size).toBeGreaterThan(0);
  const compiled = await run(['exec', '300', program, '--', 'dynamic']);
  expect(compiled.code, compiled.out + compiled.err).toBe(124);
  expect(JSON.parse(compiled.out).timedOut).toBe(true);
});

test('shipped executable owns background workers and private replay with no JS runtime', async () => {
  const script = 'printf "hello\\n"; sleep 0.2; printf "done\\n"';
  const start = await run(['start', '3000', '/bin/sh', '-c', script], { path: '/usr/bin:/bin' });
  expect(start.code, start.err).toBe(0);
  const { id } = JSON.parse(start.out);
  const noRuntime = { path: '/nonexistent' };
  const waited = await run(['wait', id, '3000'], noRuntime);
  expect(JSON.parse(waited.out).state).toBe('exited');
  const events = await run(['events', id], noRuntime);
  const rows = jsonLines(events.out);
  expect(rows.some(x => x.type === 'process.output')).toBe(true);
  expect((await run(['stop', id], noRuntime)).code).toBe(0);
  expect((await run(['status', '../escape'])).code).not.toBe(0);
});

test('update shows and runs the curl installer, relaying its output and status', async () => {
  // A fake curl on PATH stands in for the network: it records its argv and
  // "downloads" a script that the real sh then runs.
  const bin = join(root, 'update-bin');
  const record = join(root, 'update-curl-args');
  mkdirSync(bin, { recursive: true });
  const fakeCurl = [
    '#!/bin/sh',
    `printf '%s\\n' "$@" > '${record}'`,
    `printf '%s\\n' 'echo "installed $FAKE_RELEASE"' 'echo "installer note" >&2' 'exit "$FAKE_EXIT"'`,
  ].join('\n');
  writeFileSync(join(bin, 'curl'), fakeCurl, { mode: 0o755 });
  const path = `${bin}:/usr/bin:/bin`;
  const command = 'curl -fsSL https://raw.githubusercontent.com/monotykamary/jev-fabric/main/install.sh | sh';

  const ok = await capture([nativeBin, '--', 'update'], {
    env: { PATH: path, FAKE_RELEASE: 'v9.9.9', FAKE_EXIT: '0' },
  });
  expect(ok.code, ok.err).toBe(0);
  expect(ok.out).toBe('installed v9.9.9\n');
  expect(ok.err).toBe(`${command}\ninstaller note\n`);
  expect(readFileSync(record, 'utf8')).toBe(
    '-fsSL\nhttps://raw.githubusercontent.com/monotykamary/jev-fabric/main/install.sh\n',
  );

  const failed = await capture([nativeBin, '--', 'update'], {
    env: { PATH: path, FAKE_RELEASE: 'v9.9.9', FAKE_EXIT: '3' },
  });
  expect(failed.code).toBe(3);
  expect(failed.out).toBe('installed v9.9.9\n');

  const extra = await run(['update', 'now']);
  expect(extra.code).not.toBe(0);
});

// ---------------------------------------------------------------------------
// Durable-backend primitives: labels, follow, list and the events long poll.

const durableHome = join(root, 'durable');
const durable = (args: string[]) => run(args, { home: durableHome, path: '/usr/bin:/bin' });
const started = new Set<string>();
afterAll(async () => {
  await Promise.all([...started].map(id => durable(['stop', id])));
});

async function startJob(args: string[]) {
  const r = await durable(['start', ...args]);
  expect(r.code, r.err).toBe(0);
  const { id } = JSON.parse(r.out);
  expect(id).toMatch(/^[0-9a-f]{32}$/);
  started.add(id);
  return id as string;
}

/** A streaming child with a line reader, for commands that print as they go. */
function stream(args: string[], home = durableHome) {
  const child = Bun.spawn([nativeBin, '--', ...args], {
    env: { PATH: '/usr/bin:/bin', BEND_NO_TELEMETRY: '1', JEV_FABRIC_HOME: home },
    stdin: 'ignore',
    stdout: 'pipe',
    stderr: 'pipe',
  });
  const reader = child.stdout.getReader();
  const decoder = new TextDecoder();
  let buffered = '';
  const seen: any[] = [];
  async function next(): Promise<any> {
    for (;;) {
      const at = buffered.indexOf('\n');
      if (at >= 0) {
        const line = JSON.parse(buffered.slice(0, at));
        buffered = buffered.slice(at + 1);
        seen.push(line);
        return line;
      }
      const { value, done } = await reader.read();
      if (done) return undefined;
      buffered += decoder.decode(value, { stream: true });
    }
  }
  async function until(check: (line: any) => boolean) {
    for (let line = await next(); line !== undefined; line = await next()) {
      if (check(line)) return line;
    }
    return undefined;
  }
  return { child, next, until, seen };
}

test('start --label is validated, stored privately and reported by status, wait and stop', async () => {
  const label = 'dev server 🙂 "quoted"';
  const id = await startJob(['--label', label, '--timeout-ms', '86400000', '/bin/sleep', '30']);
  const running = JSON.parse((await durable(['status', id])).out);
  expect(running).toEqual({ schemaVersion: 1, id, label, lifetime: 'durable', state: 'running', spoolLimitBytes: 1048576 });
  expect(JSON.parse((await durable(['wait', '--timeout-ms', '50', id])).out)).toEqual(running);
  const meta = JSON.parse(readFileSync(join(durableHome, id, 'meta.json'), 'utf8'));
  expect(meta).toMatchObject({ schemaVersion: 1, label });
  expect(Math.abs(meta.startedAt - Date.now())).toBeLessThan(60000);
  expect(privateMode(join(durableHome, id, 'meta.json'))).toBe(0o600);

  const stopped = JSON.parse((await durable(['stop', id])).out);
  expect(stopped).toMatchObject({ id, label, state: 'cancelled' });
  started.delete(id);
  expect(JSON.parse((await durable(['status', id])).out)).toEqual(stopped);

  const unlabelled = await startJob(['/bin/echo', 'plain']);
  const receipt = JSON.parse((await durable(['wait', unlabelled])).out);
  expect(receipt.state).toBe('exited');
  expect('label' in receipt).toBe(false);

  const rejected = ['', 'x'.repeat(121), 'two\nlines', 'tab\there', 'bell\u0007', 'c1\u0085', 'sep '];
  for (const bad of rejected) {
    const r = await durable(['start', '--label', bad, '/bin/echo']);
    expect(r.code, bad).toBe(2);
  }
  expect((await durable(['start', '--label', 'a', '--label', 'b', '/bin/echo'])).code).toBe(2);
  expect((await durable(['exec', '--label', 'a', '/bin/echo'])).code).toBe(2);
  expect((await durable(['start', '--label'])).code).toBe(2);
  expect((await durable(['start', '--timeout-ms', '86400001', '/bin/echo'])).code).toBe(2);
  expect((await durable(['exec', '--timeout-ms', '86400000', '/bin/echo'])).code).toBe(2);
  expect((await durable(['wait', '--timeout-ms', '3600001', unlabelled])).code).toBe(2);

  // A command named like an option after -- stays literal, label or not.
  const literal = await startJob(['--label', 'x'.repeat(120), '--', '/bin/echo', '--label']);
  expect(JSON.parse((await durable(['wait', literal])).out)).toMatchObject({
    label: 'x'.repeat(120),
    stdout: '--label\n',
  });
}, 30000);

test('follow streams events live, then ends finished with the final receipt', async () => {
  const release = join(root, 'follow-release');
  const script = 'printf "first\\n"; while [ ! -f "$1" ]; do /bin/sleep 0.02; done; printf "second\\n"';
  const id = await startJob(['--label', 'follow me', '/bin/sh', '-c', script, 'sh', release]);
  const follow = stream(['follow', '--timeout-ms', '20000', id]);

  // The first output arrives while the job is still running.
  const first = await follow.until(line => line.type === 'process.output');
  expect(first.data).toMatchObject({ stream: 'stdout', offset: 0, text: 'first\n' });
  expect(JSON.parse((await durable(['status', id])).out).state).toBe('running');
  expect(follow.seen.some(line => line.type === 'follow.end')).toBe(false);

  writeFileSync(release, 'go');
  const end = await follow.until(line => line.type === 'follow.end');
  expect(await follow.child.exited).toBe(0);
  started.delete(id);
  expect(end).toMatchObject({ type: 'follow.end', reason: 'finished' });
  expect(end.receipt).toMatchObject({ id, label: 'follow me', state: 'exited', stdout: 'first\nsecond\n' });

  // Every retained event was printed once, in order, before follow.end.
  const events = jsonLines((await durable(['events', id])).out);
  const printed = follow.seen.filter(line => typeof line.sequence === 'number');
  expect(printed).toEqual(events);
  expect(printed.at(-1).type).toBe('job.finished');
  expect(end.next).toBe(printed.at(-1).sequence);

  // A cursor at the end of a finished job prints only follow.end, at once.
  const after = await durable(['follow', id, String(end.next)]);
  expect(after.code).toBe(0);
  expect(jsonLines(after.out)).toEqual([{ ...end }]);
  // A cursor in the middle replays only what follows it.
  const middle = await durable(['follow', id, String(printed[1].sequence)]);
  expect(jsonLines(middle.out).slice(0, -1)).toEqual(printed.slice(2));
}, 30000);

test('follow times out without stopping or renewing the job', async () => {
  const id = await startJob(['--label', 'sleeper', '/bin/sleep', '30']);
  const begin = Date.now();
  const r = await durable(['follow', '--timeout-ms', '400', id]);
  expect(r.code, r.err).toBe(0);
  expect(Date.now() - begin).toBeLessThan(5000);
  const lines = jsonLines(r.out);
  expect(lines[0]).toMatchObject({ sequence: 1, type: 'job.started', data: { id } });
  expect(lines.at(-1)).toEqual({
    type: 'follow.end',
    reason: 'timeout',
    next: 1,
    receipt: { schemaVersion: 1, id, label: 'sleeper', lifetime: 'durable', state: 'running', spoolLimitBytes: 1048576 },
  });
  expect(JSON.parse((await durable(['status', id])).out).state).toBe('running');
  await durable(['stop', id]);
  started.delete(id);
}, 20000);

test('follow discloses events evicted before its cursor with a loss record', async () => {
  // Over 64 ticks of output: the ring keeps only the latest 64 events.
  const script = 'i=0; while [ "$i" -lt 80 ]; do printf x; /bin/sleep 0.03; i=$((i+1)); done';
  const id = await startJob(['/bin/sh', '-c', script]);
  expect(JSON.parse((await durable(['wait', '--timeout-ms', '30000', id])).out).state).toBe('exited');
  started.delete(id);
  const retained = jsonLines((await durable(['events', id])).out);
  expect(retained.length).toBe(64);
  expect(retained[0].sequence).toBeGreaterThan(1);

  const r = await durable(['follow', id]);
  const lines = jsonLines(r.out);
  expect(lines[0]).toEqual({ type: 'follow.loss', after: 0, next: retained[0].sequence });
  expect(lines.slice(1, -1)).toEqual(retained);
  expect(lines.at(-1)).toMatchObject({ reason: 'finished', next: retained.at(-1).sequence });
  // No loss when the cursor is inside the retained window.
  const inside = jsonLines((await durable(['follow', id, String(retained[0].sequence)])).out);
  expect(inside.some(line => line.type === 'follow.loss')).toBe(false);
}, 40000);

test('follow and events reject unknown jobs and bad cursors like the other controls', async () => {
  const unknown = 'e'.repeat(32);
  expect((await durable(['follow', unknown])).code).toBe(2);
  expect((await durable(['status', unknown])).code).toBe(2);
  expect((await durable(['follow', '--timeout-ms', '100', '../escape'])).code).not.toBe(0);
  expect((await durable(['follow', unknown, 'oops'])).code).toBe(2);
  expect((await durable(['follow', '--timeout-ms', '0', unknown])).code).toBe(2);
  expect((await durable(['follow', '--timeout-ms', '3600001', unknown])).code).toBe(2);
  expect((await durable(['events', '--timeout-ms', '300001', unknown])).code).toBe(2);
  expect((await durable(['events', '--timeout-ms', '100', unknown])).code).toBe(2);
});

test('events --timeout-ms long-polls for a later event and never waits on a terminal job', async () => {
  const release = join(root, 'events-release');
  const script = 'while [ ! -f "$1" ]; do /bin/sleep 0.02; done; printf late';
  const id = await startJob(['/bin/sh', '-c', script, 'sh', release]);
  const snapshot = jsonLines((await durable(['events', id])).out);
  const cursor = snapshot.at(-1).sequence;

  // Nothing new within 150 ms: an empty answer at the ceiling.
  let begin = Date.now();
  const empty = await durable(['events', '--timeout-ms', '150', id, String(cursor)]);
  expect(empty.code, empty.err).toBe(0);
  expect(empty.out).toBe('');
  expect(Date.now() - begin).toBeGreaterThanOrEqual(140);

  // Returns once the late output is published, well before its ceiling.
  setTimeout(() => writeFileSync(release, 'go'), 300);
  begin = Date.now();
  const later = jsonLines((await durable(['events', '--timeout-ms', '20000', id, String(cursor)])).out);
  expect(Date.now() - begin).toBeLessThan(10000);
  expect(later.length).toBeGreaterThan(0);
  expect(later.every(e => e.sequence > cursor)).toBe(true);

  JSON.parse((await durable(['wait', id])).out);
  started.delete(id);
  const all = jsonLines((await durable(['events', id])).out);
  begin = Date.now();
  const done = await durable(['events', '--timeout-ms', '20000', id, String(all.at(-1).sequence)]);
  expect(done.out).toBe('');
  expect(Date.now() - begin).toBeLessThan(3000);
}, 30000);

test('list reports labelled jobs newest first, skipping foreign and unsafe entries', async () => {
  const home = join(root, 'listing');
  const listed = (args: string[] = ['list']) => run(args, { home, path: '/usr/bin:/bin' });
  const empty = await listed();
  expect(empty.code, empty.err).toBe(0);
  expect(JSON.parse(empty.out)).toEqual({ jobs: [], truncated: false });

  const done = JSON.parse((await listed(['start', '--label', 'done', '/bin/sh', '-c', 'exit 3'])).out).id;
  await listed(['wait', done]);
  await Bun.sleep(5);
  const live = JSON.parse((await listed(['start', '--label', 'live', '/bin/sleep', '30'])).out).id;
  started.add(live);
  await Bun.sleep(5);
  const plain = JSON.parse((await listed(['start', '/bin/echo', 'plain'])).out).id;
  await listed(['wait', plain]);

  // Entries that are not jobs: a stray file, a foreign id-shaped directory (as
  // `run` and sessions create), a world-readable one and a symlinked one.
  writeFileSync(join(home, 'notes.txt'), 'x', { mode: 0o600 });
  mkdirSync(join(home, 'f'.repeat(32)), { mode: 0o700 });
  mkdirSync(join(home, '1'.repeat(32)), { mode: 0o755 });
  writeFileSync(join(home, '1'.repeat(32), 'receipt.json'), '{}', { mode: 0o600 });
  symlinkSync(join(home, done), join(home, '2'.repeat(32)));

  const r = await listed();
  expect(r.code, r.err).toBe(0);
  const { jobs, truncated } = JSON.parse(r.out);
  expect(truncated).toBe(false);
  expect(jobs.map((job: any) => job.id)).toEqual([plain, live, done]);
  expect(jobs[0]).toEqual({ id: plain, state: 'exited', startedAt: jobs[0].startedAt, exitCode: 0 });
  expect(jobs[1]).toEqual({ id: live, state: 'running', label: 'live', startedAt: jobs[1].startedAt });
  expect(jobs[2]).toEqual({ id: done, state: 'failed', label: 'done', startedAt: jobs[2].startedAt, exitCode: 3 });
  for (const job of jobs) expect(Math.abs(job.startedAt - Date.now())).toBeLessThan(60000);
  expect(jobs[0].startedAt).toBeGreaterThanOrEqual(jobs[1].startedAt);

  await listed(['stop', live]);
  started.delete(live);
  const after = JSON.parse((await listed()).out).jobs;
  expect(after.find((job: any) => job.id === live)).toMatchObject({ state: 'cancelled', label: 'live' });
}, 30000);

test('a default storage root is created with a .gitignore that list and start ignore', async () => {
  const cwd = join(root, 'fresh-project');
  mkdirSync(cwd);
  const env = { PATH: '/usr/bin:/bin', BEND_NO_TELEMETRY: '1' };
  const inCwd = (args: string[]) => {
    const child = Bun.spawn([nativeBin, '--', ...args], { cwd, env, stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' });
    return Promise.all([new Response(child.stdout).text(), child.exited]);
  };
  const [listing, code] = await inCwd(['list']);
  expect(code).toBe(0);
  expect(JSON.parse(listing)).toEqual({ jobs: [], truncated: false });
  const store = join(cwd, '.jev-fabric-native');
  expect(privateMode(store)).toBe(0o700);
  expect(readFileSync(join(store, '.gitignore'), 'utf8')).toBe('*\n');
  expect(privateMode(join(store, '.gitignore'))).toBe(0o600);

  const [out] = await inCwd(['start', '/bin/echo', 'ignored']);
  const { id } = JSON.parse(out);
  await inCwd(['wait', id]);
  const [again] = await inCwd(['list']);
  expect(JSON.parse(again).jobs.map((job: any) => job.id)).toEqual([id]);

  // An existing root is never given one, and neither is JEV_FABRIC_HOME.
  rmSync(join(store, '.gitignore'));
  await inCwd(['list']);
  // The store marker was written when the root was created; it is not a job.
  expect(readdirSync(store).sort()).toEqual(['.jev-fabric-store.json', id]);
  expect(readdirSync(durableHome)).not.toContain('.gitignore');
});
