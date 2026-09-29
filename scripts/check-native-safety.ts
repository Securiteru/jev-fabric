import { readdirSync, readFileSync, lstatSync } from 'node:fs';
import { posix, resolve } from 'node:path';
import { execFile } from 'node:child_process';
import { availableParallelism } from 'node:os';

export interface Manifest {
  schemaVersion: number;
  compiler: string;
  pure: string[];
  proofs: string[];
  drivers: string[];
  foreign: Record<string, Record<string, string>>;
}
interface Token { value: string; literal: boolean; line: number }

const REVIEWED_COMPILER = 'bend 2.0.34';
const WORD_CHAR = /[A-Za-z0-9_./-]/;
const FOREIGN_IMPORT = /^"[A-Za-z0-9_./-]+\.c"$/;
const EFFECT_CAPABILITY = /(^|[.])(IO|File|Socket|Listener|Window|Audio|Chan)([.]|$)/;
// Bend 2.0.32+ prints one verdict. A clean check exits 0 with exactly this text.
const CLEAN_VERDICT = 'ALL PROOFS CHECK\nUse --verdict for mathematical validity.';
// The only non-clean verdict accepted, and only for driver modules: it exits 1
// and lists nothing but the defs that rely on (allowlisted) foreign code.
const DRIVER_VERDICT =
  /^SOME PROOFS FAIL\nError: [0-9]+ defs? rel(?:y|ies) on unsafe or foreign code:\n(?:- [A-Za-z0-9_./-]+\n?)+$/;

// Strip line comments, preserve literals for imports, and do not interpret
// quoted/commented '?' or '@unsafe' text as code. This is not a typechecker.
export function tokens(source: string): Token[] {
  const result: Token[] = [];
  let at = 0;
  let line = 1;
  while (at < source.length) {
    const c = source[at];
    if (/\s/.test(c)) {
      if (c === '\n') line++;
      at++;
      continue;
    }
    if (c === '#') {
      while (at < source.length && source[at] !== '\n') at++;
      continue;
    }
    if (c === '"' || c === "'") {
      const start = at++;
      const startLine = line;
      let closed = false;
      while (at < source.length) {
        const next = source[at++];
        if (next === '\n') line++;
        if (next === '\\') {
          if (source[at] === '\n') line++;
          at++;
        } else if (next === c) {
          closed = true;
          break;
        }
      }
      if (!closed) throw new Error(`unterminated literal at line ${startLine}`);
      result.push({ value: source.slice(start, at), literal: true, line: startLine });
      continue;
    }
    if (WORD_CHAR.test(c)) {
      const start = at++;
      while (at < source.length && WORD_CHAR.test(source[at])) at++;
      result.push({ value: source.slice(start, at), literal: false, line });
    } else {
      result.push({ value: c, literal: false, line });
      at++;
    }
  }
  return result;
}

function localPath(file: string, specifier: string): string {
  if (!specifier.startsWith('./') && !specifier.startsWith('../')) {
    throw new Error(`${file}: nonlocal import ${specifier}`);
  }
  const target = posix.normalize(posix.join(posix.dirname(file), specifier));
  if (target.startsWith('../') || target.startsWith('/')) {
    throw new Error(`${file}: escaping import ${specifier}`);
  }
  return target;
}

function isUnclassified(file: string, production: Set<string>): boolean {
  return file.startsWith('native/')
    && !file.startsWith('native/tests/')
    && !file.startsWith('native/probes/')
    && !production.has(file);
}

export function auditSources(sources: Map<string, string>, manifest: Manifest) {
  if (manifest.schemaVersion !== 1 || manifest.compiler !== REVIEWED_COMPILER) {
    throw new Error('unknown trust manifest/compiler');
  }
  const pure = new Set([...manifest.pure, ...manifest.proofs]);
  const production = new Set([...manifest.pure, ...manifest.drivers]);
  const declared = [...manifest.pure, ...manifest.proofs, ...manifest.drivers];
  if (new Set(declared).size !== declared.length) throw new Error('duplicate trust classification');
  for (const path of declared) {
    if (!sources.has(path)) throw new Error(`missing classified module ${path}`);
  }
  const imports = new Map<string, string[]>();
  const effects = new Set<string>();
  const scanned = new Map<string, Token[]>();
  for (const [file, source] of sources) {
    if (isUnclassified(file, production)) throw new Error(`unclassified production module ${file}`);
    const ts = tokens(source);
    scanned.set(file, ts);
    const dependencies: string[] = [];
    const laws = new Set<string>();
    const bodies = new Set<string>();
    // The most recent `def`/`type` name: a foreign import belongs to it.
    let definition = '';
    for (let i = 0; i < ts.length; i++) {
      const token = ts[i];
      if (token.literal) continue;
      const value = token.value;
      if (value === '?' || (value === '@' && ts[i + 1]?.value === 'unsafe')) {
        throw new Error(`${file}:${token.line}: unsafe definition or proof hole`);
      }
      if (value === 'law') laws.add(ts[i + 1]?.value);
      if (value === 'def' || value === 'type') {
        definition = ts[i + 1]?.value;
        bodies.add(definition);
      }
      if (value !== 'import') continue;
      const spec = ts[++i];
      if (!spec) throw new Error(`${file}: incomplete import`);
      if (spec.literal) {
        if (!FOREIGN_IMPORT.test(spec.value)) {
          throw new Error(`${file}: unsupported foreign import`);
        }
        const target = localPath(file, spec.value.slice(1, -1));
        if (manifest.foreign[file]?.[definition] !== target) {
          throw new Error(`${file}: unapproved foreign effect ${definition} -> ${target}`);
        }
        effects.add(`${file}:${definition}`);
      } else if (spec.value !== 'Base') {
        const target = localPath(file, spec.value);
        if (!sources.has(target)) throw new Error(`${file}: unresolved import ${target}`);
        dependencies.push(target);
      }
    }
    for (const law of laws) {
      if (!bodies.has(law)) throw new Error(`${file}: unimplemented law ${law}`);
    }
    imports.set(file, dependencies);
  }
  for (const [file, definitions] of Object.entries(manifest.foreign)) {
    if (!manifest.drivers.includes(file)) {
      throw new Error(`${file}: foreign effects outside a driver`);
    }
    for (const name of Object.keys(definitions)) {
      if (!effects.has(`${file}:${name}`)) {
        throw new Error(`missing declared foreign effect ${file}:${name}`);
      }
    }
  }
  const seen = new Set<string>();
  function visit(file: string) {
    if (seen.has(file)) return;
    if (!pure.has(file)) throw new Error(`pure closure reaches non-pure module ${file}`);
    seen.add(file);
    for (const t of scanned.get(file)!) {
      if (!t.literal && EFFECT_CAPABILITY.test(t.value)) {
        throw new Error(`${file}:${t.line}: effect capability in pure core`);
      }
    }
    for (const effect of effects) {
      if (effect.startsWith(file + ':')) throw new Error(`${file}: foreign effect in pure closure`);
    }
    for (const next of imports.get(file)!) visit(next);
  }
  for (const file of pure) visit(file);
  return { pure: seen, files: sources.size, foreign: effects.size };
}

export function acceptVerdict(file: string, output: string, pure: boolean, exitCode = 0) {
  const verdict = output.trim();
  if (exitCode === 0 && verdict === CLEAN_VERDICT) return;
  if (!pure && exitCode === 1 && DRIVER_VERDICT.test(verdict)) return;
  throw new Error(`${file}: unacceptable compiler trust verdict (exit ${exitCode})\n${verdict}`);
}

export function collect(root: string): Map<string, string> {
  const result = new Map<string, string>();
  function walk(dir: string) {
    for (const name of readdirSync(resolve(root, dir)).sort()) {
      const path = posix.join(dir, name);
      const info = lstatSync(resolve(root, path));
      if (info.isSymbolicLink()) throw new Error(`symlink in native source tree: ${path}`);
      if (info.isDirectory()) walk(path);
      else if (name.endsWith('.bend')) result.set(path, readFileSync(resolve(root, path), 'utf8'));
    }
  }
  walk('native');
  walk('examples/native');
  return result;
}

interface CompilerRun { output: string; exitCode: number; failure?: string }

// Deadline for one compiler run that has the machine to itself.
const COMPILER_TIMEOUT_MS = 30000;

// Never rejects: a failure is returned so that runs finishing out of order stay unobserved
// until the in-order consumer reaches them.
function compile(
  root: string,
  args: string[],
  timeout = COMPILER_TIMEOUT_MS,
  signal?: AbortSignal,
): Promise<CompilerRun> {
  const options = {
    cwd: root,
    encoding: 'utf8' as const,
    timeout,
    maxBuffer: 1048576,
    env: { ...process.env, BEND_NO_TELEMETRY: '1' },
    signal,
  };
  return new Promise(done => {
    execFile('bend', args, options, (error, stdout, stderr) => {
      if (!error) {
        done({ output: stdout + stderr, exitCode: 0 });
        return;
      }
      // A compiler that exited with a status reports its verdict, which acceptVerdict
      // judges; one killed by a signal, and harness errors (spawn failure, timeout,
      // output limit, abort), are failures.
      if (typeof error.code === 'number') {
        done({ output: stdout + stderr, exitCode: error.code });
        return;
      }
      const ended = error.signal && !error.killed;
      const detail = ended ? stderr + stdout : String(error);
      done({ output: '', exitCode: -1, failure: `bend ${args.join(' ')}: ${detail}` });
    });
  });
}

// Runs at most `limit` tasks at once, starting them in call order.
function limiter(limit: number) {
  let active = 0;
  const waiting: (() => void)[] = [];
  return async function <T>(task: () => Promise<T>): Promise<T> {
    if (active >= limit) await new Promise<void>(wake => waiting.push(wake));
    active++;
    try {
      return await task();
    } finally {
      active--;
      waiting.shift()?.();
    }
  };
}

// Large modules take up to ~2 GB and 15-25 s to check, so run half the CPUs, at most 4.
// JEV_CHECK_JOBS overrides this; 1 checks sequentially.
function checkConcurrency(): number {
  const configured = process.env.JEV_CHECK_JOBS;
  if (configured === undefined || configured === '') {
    return Math.max(1, Math.min(Math.floor(availableParallelism() / 2), 4));
  }
  if (!/^[1-9][0-9]*$/.test(configured)) {
    throw new Error(`JEV_CHECK_JOBS must be a positive integer, got: ${configured}`);
  }
  return Number(configured);
}

export async function check(root: string) {
  const manifest = JSON.parse(readFileSync(resolve(root, 'native/trust.json'), 'utf8')) as Manifest;
  const sources = collect(root);
  const audit = auditSources(sources, manifest);
  const version = await compile(root, ['version']);
  if (version.failure) throw new Error(version.failure);
  if (version.exitCode !== 0) throw new Error(`bend version exited ${version.exitCode}`);
  if (version.output.trim() !== manifest.compiler) {
    throw new Error('unreviewed compiler version');
  }
  // Modules compile concurrently but are judged in source order, so the log and the first
  // rejected module match a sequential run. A rejection cancels the checks still pending.
  // Each run shares the CPU with up to `concurrency - 1` others, so its hang deadline is
  // scaled to match; a run that still times out is rejected.
  const concurrency = checkConcurrency();
  const timeout = COMPILER_TIMEOUT_MS * concurrency;
  const cancel = new AbortController();
  const slot = limiter(concurrency);
  const checks = [...sources.keys()].map(path => ({
    path,
    run: slot(() => {
      if (cancel.signal.aborted) return Promise.resolve({ output: '', exitCode: -1, failure: 'cancelled' });
      return compile(root, [path, '--check-only'], timeout, cancel.signal);
    }),
  }));
  try {
    for (const { path, run } of checks) {
      console.error(`Checking Bend: ${path}`);
      const verdict = await run;
      if (verdict.failure) throw new Error(verdict.failure);
      acceptVerdict(path, verdict.output, audit.pure.has(path), verdict.exitCode);
    }
  } finally {
    cancel.abort();
  }
  console.log(
    `Native safety: ${audit.files} modules checked; ${manifest.pure.length} pure modules, `
    + `${manifest.proofs.length} proof roots, ${audit.foreign} explicit foreign effects. `
    + 'No unsafe definitions or proof holes.',
  );
}

if (import.meta.main) {
  try {
    await check(resolve(import.meta.dir, '..'));
  } catch (error) {
    console.error(String(error));
    process.exitCode = 1;
  }
}
