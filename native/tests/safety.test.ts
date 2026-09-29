import { test, expect } from 'bun:test';
import { resolve } from 'node:path';
import { auditSources, acceptVerdict, type Manifest } from '../../scripts/check-native-safety.ts';
import { expectFixture } from './helpers.ts';

function fixture(pure = 'import Base\ndef value() -> Nat:\n  0n\n') {
  const manifest: Manifest = {
    schemaVersion: 1,
    compiler: 'bend 2.0.34',
    pure: ['native/Pure.bend'],
    proofs: [],
    drivers: ['native/Driver.bend'],
    foreign: { 'native/Driver.bend': { 'Effect.call': 'native/bridge.c' } },
  };
  const sources = new Map([
    ['native/Pure.bend', pure],
    ['native/Driver.bend', 'import Base\ndef Effect.call() -> IO(Unit):\n  import "./bridge.c"\n'],
  ]);
  return { manifest, sources };
}
function rejected(source: string, message: RegExp) {
  const f = fixture(source);
  expect(() => auditSources(f.sources, f.manifest)).toThrow(message);
}

test('safe core accepts trusted driver segregation and ignores quoted/commented syntax', () => {
  const f = fixture(
    '# @unsafe ?TODO\n'
    + 'import Base\n'
    + 'def value() -> String:\n'
    + '  "@unsafe ?TODO def fake?() import IO"\n',
  );
  expect(auditSources(f.sources, f.manifest).foreign).toBe(1);
});
test('unsafe decorator, def sugar, and named/TODO proof holes fail closed', () => {
  const holes = [
    '@unsafe\ndef f() -> Nat:\n  0n',
    'def f?() -> Nat:\n  0n',
    'def f() -> Nat:\n  ?TODO',
    'def f() -> Nat:\n  ?unfinished',
  ];
  for (const source of holes) rejected(source, /unsafe definition or proof hole/);
});
test('unfilled laws are not accepted as proofs', () => {
  rejected('law fabricated: Empty', /unimplemented law/);
});
test('pure modules cannot depend on drivers, even through unused imports', () => {
  rejected('import ./Driver.bend as Driver\ndef value() -> Nat:\n  0n', /pure closure reaches/);
});
test('Base IO capabilities, including qualified aliases, are forbidden in the pure closure', () => {
  rejected('import Base\ndef f() -> IO(Unit):\n  IO.print("x")', /effect capability/);
  rejected(
    'import Base as Trusted\ndef f() -> Trusted.IO(Unit):\n  Trusted.IO.print("x")',
    /effect capability/,
  );
});
test('unapproved foreign entrypoints cannot hide in tests or pure modules', () => {
  rejected('def Bad() -> IO(Unit):\n  import "./bridge.c"', /unapproved foreign effect/);
});
test('out-of-tree imports, missing files and new unclassified modules fail closed', () => {
  rejected('import ../../elsewhere.bend as Hidden', /escaping import/);
  rejected('import ./Missing.bend as Hidden', /unresolved import/);
  const f = fixture();
  f.sources.set('native/New.bend', 'import Base');
  expect(() => auditSources(f.sources, f.manifest)).toThrow(/unclassified/);
});
test('transitive helper contamination is rejected rather than just scanning roots', () => {
  const f = fixture('import ./Helper.bend as H');
  f.sources.set('native/Helper.bend', 'import ./Driver.bend as D');
  f.manifest.pure.push('native/Helper.bend');
  expect(() => auditSources(f.sources, f.manifest)).toThrow(/pure closure reaches/);
});
test('native safe encoder fuel and pure effect gates execute as specified', () => {
  expectFixture('policy-core');
  const result = Bun.spawnSync([resolve('build/test-policy-core')], { stdout: 'pipe', stderr: 'pipe' });
  expect(result.exitCode, result.stderr.toString()).toBe(0);
  expect(result.stdout.toString()).toContain('native safe policy assertions: 10');
}, 100000);

test('compiler trust warnings and incomplete verdicts fail in the pure proof closure', () => {
  const clean = 'ALL PROOFS CHECK\nUse --verdict for mathematical validity.\n';
  acceptVerdict('pure', clean, true, 0);
  expect(() => acceptVerdict('pure', clean, true, 1)).toThrow(/trust verdict/);
  const warning = 'SOME PROOFS FAIL\nError: 1 def relies on unsafe or foreign code:\n- run\n';
  expect(() => acceptVerdict('pure', warning, true, 1)).toThrow(/trust verdict/);
  acceptVerdict('driver', warning, false, 1);
  expect(() => acceptVerdict('driver', warning, false, 0)).toThrow(/trust verdict/);
  const imported = 'SOME PROOFS FAIL\nError: 2 defs rely on unsafe or foreign code:\n- ../Host.jfh_os\n- run\n';
  acceptVerdict('driver', imported, false, 1);
  const incomplete = 'SOME PROOFS FAIL\nError: 1 TODO found.\nThe code is incomplete, and not a valid proof yet.';
  expect(() => acceptVerdict('pure', incomplete, true, 1)).toThrow(/trust verdict/);
  expect(() => acceptVerdict('driver', incomplete, false, 1)).toThrow(/trust verdict/);
  const typeError = 'SOME PROOFS FAIL\nError:\n- expected : Nat\n- observed : U32\nLocation: f';
  expect(() => acceptVerdict('driver', typeError, false, 1)).toThrow(/trust verdict/);
  // The pre-2.0.32 wording is no longer a clean verdict.
  expect(() => acceptVerdict('pure', 'All terms check.', true, 0)).toThrow(/trust verdict/);
});
