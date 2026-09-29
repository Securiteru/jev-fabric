import { afterAll, describe, expect, test } from 'bun:test';
import { mkdtempSync, rmSync, existsSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { capture, processGone as gone } from './helpers.ts';

const root = mkdtempSync(join(tmpdir(), 'jev-native-'));
const bin = resolve(process.env.JEV_NATIVE_BIN ?? 'build/jev-fabric');
afterAll(() => rmSync(root, { recursive: true, force: true }));

type Env = Record<string, string | undefined>;
async function command(args: string[], input = '', env: Env = process.env) {
  const { out, err, code } = await capture([bin, '--', ...args], { env, input });
  return { stdout: out, stderr: err, code };
}
async function exec(args: string[], options: { ms?: number; input?: string } = {}) {
  const r = await command(['exec', String(options.ms ?? 2000), ...args], options.input);
  return { ...r, report: JSON.parse(r.stdout) };
}

describe('native Bend/POSIX boundary', () => {
  test('help, version, rejected commands and timeout syntax', async () => {
    expect((await command(['--help'])).stdout).toContain('native Bend');
    expect((await command(['--version'])).stdout).toContain('Bend 2.0.34');
    expect((await command(['start'])).code).toBe(2);
    expect((await command(['exec', 'oops', '/bin/echo'])).code).toBe(2);
    expect((await command(['exec', '0', '/bin/echo'])).code).not.toBe(0);
    expect((await command(['exec', '3600001', '/bin/echo'])).code).not.toBe(0);
  });
  test('literal argv, Unicode and JSON escaping', async () => {
    const marker = join(root, 'not-executed');
    const text = `🙂\n\t"\\ $(touch ${marker}); $HOME`;
    const r = await exec(['/bin/sh', '-c', 'printf "%s" "$1"', 'sh', text]);
    expect(r.code).toBe(0);
    expect(r.report.stdout).toBe(text);
    expect(r.report.state).toBe('exited'); // Dispatch is not verified task completion.
    expect(existsSync(marker)).toBe(false);
  });
  test('explicit shells support heredocs and pipelines', async () => {
    const r = await exec(['/bin/sh', '-c', "cat <<'TEXT' | tr a-z A-Z\nhello native\nTEXT"]);
    expect(r.report.stdout).toBe('HELLO NATIVE\n');
  });
  test('stdin passes directly through a pipe, including data larger than the capture cap', async () => {
    const r = await exec(['--stdin', '/bin/sh', '-c', 'wc -c'], { input: 'x'.repeat(200_000) });
    expect(r.code).toBe(0);
    expect(Number(r.report.stdout.trim())).toBe(200_000);
  });
  test('separate stderr and a nonzero exit remain receipts', async () => {
    const r = await exec(['/bin/sh', '-c', 'printf out; printf err >&2; exit 7']);
    expect(r.code).toBe(7);
    expect(r.report).toMatchObject({ state: 'failed', exitCode: 7, stdout: 'out', stderr: 'err' });
  });
  test('output tails disclose truncation', async () => {
    const r = await exec(['/bin/sh', '-c', "head -c 100000 /dev/zero | tr '\\000' x; printf END"]);
    expect(r.report.stdout.length).toBe(32768);
    expect(r.report.stdout.endsWith('END')).toBe(true);
    expect(r.report.truncated).toEqual({ stdout: true, stderr: false });
  });
  test('a deadline kills and reaps the direct child', async () => {
    const r = await exec(['/bin/sh', '-c', 'printf "%s\\n" "$$"; exec sleep 60'], { ms: 100 });
    expect(r.code).toBe(124);
    expect(r.report).toMatchObject({ state: 'timed_out', timedOut: true });
    expect(gone(Number(r.report.stdout.trim()))).toBe(true);
  });
  test('SIGINT cancels owned work without exposing a live child', async () => {
    const marker = join(root, 'started');
    const script = 'printf "%s\\n" "$$"; : > "$1"; exec sleep 60';
    const p = Bun.spawn([bin, 'exec', '60000', '/bin/sh', '-c', script, 'sh', marker], {
      stdout: 'pipe',
      stderr: 'pipe',
    });
    for (let i = 0; i < 100 && !existsSync(marker); i++) await Bun.sleep(10);
    if (!existsSync(marker)) {
      p.kill();
      throw new Error('native child did not start');
    }
    p.kill('SIGINT');
    const [stdout, , code] = await Promise.all([
      new Response(p.stdout).text(),
      new Response(p.stderr).text(),
      p.exited,
    ]);
    const r = JSON.parse(stdout);
    expect(code).toBe(130);
    expect(r).toMatchObject({ state: 'cancelled', cancelled: true });
    expect(gone(Number(r.stdout.trim()))).toBe(true);
  });
  test('failed launch is sanitized and argv is bounded', async () => {
    const secretLike = 'SYNTHETIC_NOT_A_REAL_SECRET';
    const missing = await command(['exec', '1000', `/nonexistent/${secretLike}`]);
    expect(missing.code).not.toBe(0);
    expect(missing.stdout + missing.stderr).not.toContain(secretLike);
    expect((await command(['exec', '1000', '/bin/echo', 'x'.repeat(4097)])).code).not.toBe(0);
    expect((await command(['exec', '1000', '/bin/echo', ...Array(64).fill('x')])).code).not.toBe(0);
  });
  test('Bend IO forks actually overlap and buffered stdin works', async () => {
    const { out, err, code } = await capture([resolve('build/test-io'), join(root, 'overlap')]);
    expect({ code, err }).toEqual({ code: 0, err: '' });
    expect(out).toContain('native IO assertions: 3');
  });
  test('a foreign failure reaps other owned work before native exit', async () => {
    const marker = join(root, 'abort-child');
    const { err, code } = await capture([resolve('build/test-fail-fast'), marker]);
    expect(code).not.toBe(0);
    expect(err).toContain('native subprocess request failed');
    expect(gone(Number(readFileSync(marker, 'utf8').trim()))).toBe(true);
  });
  test('the executable runs with no Node or Bun on PATH', async () => {
    const env = {
      PATH: join(root, 'no-tools'),
      ASAN_OPTIONS: process.env.ASAN_OPTIONS ?? '',
      UBSAN_OPTIONS: process.env.UBSAN_OPTIONS ?? '',
    };
    const r = await command(['exec', '1000', '/bin/echo', 'native'], '', env);
    expect(r.code).toBe(0);
    expect(JSON.parse(r.stdout).stdout).toBe('native\n');
  });
});
