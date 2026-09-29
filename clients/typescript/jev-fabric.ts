/**
 * A thin client for `jev-fabric -- serve`, the JSONL session protocol.
 *
 * One file, Node built-ins only, erasable TypeScript: Bun, Deno, Node 22.6+
 * (type stripping) or any bundler.
 * Copy it next to your code, or import it from
 * `~/.local/share/jev-fabric/current/clients/typescript`.
 *
 * The client starts one `serve` child, writes one request line per call and
 * resolves each promise with the response that carries the same id. Requests
 * may overlap: serve answers them concurrently, in any order. Budgets,
 * deadlines, credentials and Jev validation all live in the executable; this
 * module only frames JSON.
 *
 * ```ts
 * import { Fabric } from './jev-fabric.ts';
 *
 * const fabric = await Fabric.open({ maxEvaluations: 10 });
 * const job = await fabric.start(['/bin/sh', '-c', 'npm run dev']);
 * await fabric.watch(job, 'ready', { timeoutMs: 30000 });
 *
 * const repl = await fabric.spawn(['python3', '-i']);   // a session child
 * await fabric.write(repl.id, 'print(6 * 7)\n');
 * const out = await fabric.read(repl.id, 'stdout', { waitMs: 5000 });
 * await fabric.close();                                   // stops repl
 * ```
 */
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { createInterface } from 'node:readline';

/** The protocol major this client speaks; features are only added within it. */
export const PROTOCOL = 2;

export interface FabricOptions {
  /** Defaults to `$JEV_FABRIC_BIN` or `jev-fabric` on PATH. */
  binary?: string;
  /** Bounds the whole session; defaults to the CLI work default (one hour). */
  timeoutMs?: number;
  /** Jev evaluations for the whole session; defaults to 1, as for `jev`. */
  maxEvaluations?: number;
  /** Reported Jev tokens for the whole session; defaults to 100000. */
  maxTokens?: number;
  env?: NodeJS.ProcessEnv;
  cwd?: string;
}

export interface Ready {
  protocol: number;
  version: string;
  timeoutMs: number;
  maxEvaluations: number;
  maxTokens: number;
  /** The storage format this binary reads and writes. */
  store: number;
  /** For example `darwin-arm64` or `linux-x64`. */
  platform: string;
  /** Implemented features, such as `sessions` or `serve-concurrent`. */
  features: string[];
}

/** What `jev-fabric -- capabilities` prints. */
export interface Capabilities {
  version: string;
  protocol: number;
  store: number;
  platform: string;
  features: string[];
}

export interface Receipt {
  schemaVersion: number;
  state: 'exited' | 'failed' | 'timed_out' | 'cancelled';
  exitCode: number | null;
  timedOut: boolean;
  cancelled: boolean;
  stdout: string;
  stderr: string;
  truncated: { stdout: boolean; stderr: boolean };
}

/** `durable` for `start` jobs, `session` for children of this connection (`s-` ids). */
export type Lifetime = 'durable' | 'session';

/** `label` is present only when the job was started with one. */
export type JobState =
  | (Receipt & { id: string; label?: string; lifetime: Lifetime; spoolLimitBytes: number })
  | { schemaVersion: number; id: string; label?: string; lifetime: Lifetime; state: 'running'; spoolLimitBytes: number }
  | {
      schemaVersion: number;
      id: string;
      label?: string;
      lifetime: Lifetime;
      state: 'failed';
      exitCode: null;
      error: string;
      spoolLimitBytes: number;
    };

/**
 * Raw bytes of one stream from a byte offset. Offsets count every byte the
 * child wrote and never reset; `omittedBytes` discloses bytes that fell out of
 * the retained window before this read. `text` holds decoded UTF-8 (a partial
 * character at the end waits for the next read); with `encoding: 'base64'`,
 * `data` holds the exact bytes instead.
 */
export interface ReadRecord {
  id: string;
  stream: 'stdout' | 'stderr';
  offset: number;
  bytes: number;
  omittedBytes: number;
  text?: string;
  data?: string;
  next: number;
  eof: boolean;
  state: string;
}

/** `written` counts UTF-8 bytes; `closed` is true once stdin has ended. */
export interface WriteRecord {
  id: string;
  written: number;
  closed: boolean;
}

/**
 * One retained job event. Known types: `job.started`, `process.output`
 * (`stream`, `offset`, `bytes`, `omittedBytes`, `text`), `process.spool_limit`
 * and, last, `job.finished`.
 */
export interface JobEvent {
  sequence: number;
  type: string;
  data: unknown;
}

/** One job directory under the storage root, as `list` reports it. */
export interface JobSummary {
  id: string;
  /** `running`, `starting` (worker not yet announced) or a receipt state. */
  state: 'running' | 'starting' | Receipt['state'];
  label?: string;
  /** Present, as `session`, only in a `scope: 'session'` listing. */
  lifetime?: 'session';
  /** Wall-clock start, epoch milliseconds; absent for jobs from before 0.4. */
  startedAt?: number;
  exitCode?: number | null;
}

export interface JobList {
  /** Newest first, at most 1024. */
  jobs: JobSummary[];
  truncated: boolean;
}

export interface MonitorRecord {
  type: 'monitor.batch' | 'monitor.loss' | 'monitor.end';
  [field: string]: unknown;
}

export type JevRequest = Record<string, unknown>;
export type JevAnswer = {
  model?: string;
  answers: Record<string, Record<string, unknown>>;
  usage?: { input_tokens: number; output_tokens: number };
};

/**
 * A request the session refused or could not complete. `code` follows the
 * CLI's exit codes: 2 for a malformed request, 22 for a rejected value, 124 for
 * an expired deadline, 1 otherwise.
 */
export class FabricError extends Error {
  readonly code: number;
  readonly op?: string;

  constructor(code: number, message: string, op?: string) {
    super(op ? `${op}: ${message}` : message);
    this.name = 'FabricError';
    this.code = code;
    this.op = op;
  }
}

interface Pending {
  op: string;
  resolve(value: any): void;
  reject(error: FabricError): void;
}

/**
 * One `jev-fabric -- serve` session. Requests may be issued concurrently and
 * are answered as they complete, matched by id. Writes, closes and stops of
 * one session child apply in the order they were sent; `jev` requests run one
 * at a time. Closing the session stops its session children.
 */
export class Fabric {
  readonly ready: Ready;
  private readonly child: ChildProcessWithoutNullStreams;
  private readonly pending = new Map<number, Pending>();
  private nextId = 1;
  private readonly exited: Promise<number | null>;
  private readonly log: { text: string };
  private ended?: FabricError;

  private constructor(
    child: ChildProcessWithoutNullStreams,
    ready: Ready,
    lines: AsyncIterator<string>,
    exited: Promise<number | null>,
    log: { text: string },
  ) {
    this.child = child;
    this.ready = ready;
    this.exited = exited;
    this.log = log;
    void this.pump(lines);
  }

  static async open(options: FabricOptions = {}): Promise<Fabric> {
    const binary = options.binary ?? process.env.JEV_FABRIC_BIN ?? 'jev-fabric';
    const argv = ['--', 'serve'];
    if (options.timeoutMs !== undefined) argv.push('--timeout-ms', String(options.timeoutMs));
    const maxEvaluations = options.maxEvaluations ?? (options.maxTokens !== undefined ? 1 : undefined);
    if (maxEvaluations !== undefined) argv.push(String(maxEvaluations));
    if (options.maxTokens !== undefined) argv.push(String(options.maxTokens));
    const child = spawn(binary, argv, { env: options.env, cwd: options.cwd, stdio: 'pipe' });
    // serve writes to stderr only when it exits abnormally; keep it for the error.
    const log = { text: '' };
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', chunk => (log.text += chunk));
    const exited = new Promise<number | null>(done => child.once('close', code => done(code)));
    await new Promise<void>((resolve, reject) => {
      child.once('spawn', resolve);
      child.once('error', error => reject(new FabricError(1, `could not start ${binary}: ${error.message}`)));
    });
    const lines = createInterface({ input: child.stdout, crlfDelay: Infinity })[Symbol.asyncIterator]();
    const first = await lines.next();
    if (first.done) {
      const code = await exited;
      throw new FabricError(code || 1, log.text.trim() || `serve exited with code ${code}`);
    }
    const banner = JSON.parse(first.value);
    if (banner?.ready?.protocol !== PROTOCOL) {
      child.stdin.end();
      throw new FabricError(1, `unsupported serve protocol: ${first.value}`);
    }
    return new Fabric(child, banner.ready, lines, exited, log);
  }

  // -- processes -------------------------------------------------------------

  /**
   * Runs literal argv to completion. A nonzero exit is a receipt, not an error.
   * `cwd` is an absolute directory the command starts in.
   */
  exec(argv: string[], options: { stdin?: string; timeoutMs?: number; cwd?: string } = {}): Promise<Receipt> {
    return this.call('exec', { argv, stdin: options.stdin, timeoutMs: options.timeoutMs, cwd: options.cwd });
  }

  /**
   * Starts a detached job that outlives this session; resolves to its id.
   * `timeoutMs` is the job's own lifetime, up to 86400000 (24 hours).
   * `label` is 1..120 printable characters on one line. With `input: 'pipe'`
   * its stdin stays open for `write` (fed through a queue drained every 25 ms).
   */
  async start(
    argv: string[],
    options: { timeoutMs?: number; label?: string; cwd?: string; input?: 'pipe' | 'null' } = {},
  ): Promise<string> {
    const started = await this.call<{ id: string }>('start', {
      argv,
      timeoutMs: options.timeoutMs,
      label: options.label,
      cwd: options.cwd,
      input: options.input,
    });
    return started.id;
  }

  /**
   * Starts a session child: an `s-` id that lives until it exits, its own
   * `timeoutMs` (up to 24 hours) passes, it is stopped, or this session ends.
   * With `stdin: 'pipe'` (the default) its stdin stays open for `write`.
   */
  spawn(
    argv: string[],
    options: { stdin?: 'pipe' | 'null'; timeoutMs?: number; label?: string; cwd?: string } = {},
  ): Promise<JobState> {
    return this.call('spawn', {
      argv,
      stdin: options.stdin,
      timeoutMs: options.timeoutMs,
      label: options.label,
      cwd: options.cwd,
    });
  }

  /** Appends up to 65536 characters to an interactive child's stdin, in order. */
  write(job: string, text: string): Promise<WriteRecord> {
    return this.call('write', { job, text });
  }

  /** Ends an interactive child's stdin. Idempotent. */
  closeInput(job: string): Promise<WriteRecord> {
    return this.call('closeInput', { job });
  }

  /**
   * Up to `max` (default and limit 65536) bytes of one stream from `offset`.
   * With `waitMs` (1..300000), a long poll: it answers as soon as bytes past
   * `offset` exist, the stream ends, or `waitMs` passes.
   */
  read(
    job: string,
    stream: 'stdout' | 'stderr',
    options: { offset?: number; max?: number; waitMs?: number; encoding?: 'text' | 'base64' } = {},
  ): Promise<ReadRecord> {
    return this.call('read', {
      job,
      stream,
      offset: options.offset,
      max: options.max,
      waitMs: options.waitMs,
      encoding: options.encoding,
    });
  }

  status(job: string): Promise<JobState> {
    return this.call('status', { job });
  }

  /**
   * Retained events with a sequence above `after` (a bounded snapshot). With
   * `waitMs` (1..300000), a long poll: it answers once such an event exists or
   * the job is terminal, or with the (possibly empty) array once `waitMs` passes.
   */
  events(job: string, options: { after?: number; waitMs?: number } = {}): Promise<JobEvent[]> {
    return this.call('events', { job, after: options.after, waitMs: options.waitMs });
  }

  /**
   * Job directories under the session's storage root, newest first; with
   * `scope: 'session'`, this session's children instead.
   */
  list(options: { scope?: 'store' | 'session' } = {}): Promise<JobList> {
    return this.call('list', { scope: options.scope });
  }

  /** The version, protocol, store format, platform and features of the binary. */
  capabilities(): Promise<Capabilities> {
    return this.call('capabilities', {});
  }

  /** The final receipt, or the running state once `timeoutMs` passes. */
  wait(job: string, options: { timeoutMs?: number } = {}): Promise<JobState> {
    return this.call('wait', { job, timeoutMs: options.timeoutMs });
  }

  stop(job: string): Promise<JobState> {
    return this.call('stop', { job });
  }

  /** Live output lines containing `literal`, as monitor records. */
  watch(job: string, literal: string, options: { timeoutMs?: number } = {}): Promise<MonitorRecord[]> {
    return this.call('watch', { job, literal, timeoutMs: options.timeoutMs });
  }

  // -- Jev -------------------------------------------------------------------

  /** Strictly validates a Jev request offline, without credentials. */
  validate(request: JevRequest): Promise<JevRequest> {
    return this.call('validate', { request });
  }

  /**
   * One explicit, billed evaluation against the session budget. `provider` and
   * `credential` apply to this request only: the credential travels over the
   * private pipe and is never cached, echoed or logged.
   */
  jev(
    request: JevRequest,
    options: { timeoutMs?: number; provider?: 'typesafe' | 'openrouter' | 'vercel'; credential?: string } = {},
  ): Promise<JevAnswer> {
    return this.call('jev', {
      request,
      timeoutMs: options.timeoutMs,
      provider: options.provider,
      credential: options.credential,
    });
  }

  // -- session ---------------------------------------------------------------

  /**
   * Ends the session by closing its input; resolves to the exit code once
   * every request in flight has answered and the session children are stopped.
   */
  close(): Promise<number | null> {
    if (!this.child.stdin.destroyed) this.child.stdin.end();
    return this.exited;
  }

  // -- framing ---------------------------------------------------------------

  private call<T>(op: string, fields: Record<string, unknown>): Promise<T> {
    if (this.ended) return Promise.reject(this.ended);
    const id = this.nextId++;
    const request: Record<string, unknown> = { id, op };
    for (const [key, value] of Object.entries(fields)) {
      if (value !== undefined) request[key] = value;
    }
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { op, resolve, reject });
      this.child.stdin.write(JSON.stringify(request) + '\n', error => {
        if (error && this.pending.delete(id)) reject(new FabricError(1, `serve input closed: ${error.message}`, op));
      });
    });
  }

  private async pump(lines: AsyncIterator<string>) {
    try {
      for (let next = await lines.next(); !next.done; next = await lines.next()) {
        const response = JSON.parse(next.value);
        const waiting = this.pending.get(response.id);
        if (!waiting) continue;
        this.pending.delete(response.id);
        if (response.ok) waiting.resolve(response.result);
        else waiting.reject(new FabricError(response.error?.code ?? 1, response.error?.message ?? 'request failed', waiting.op));
      }
    } finally {
      const code = await this.exited;
      this.ended = new FabricError(code || 1, this.log.text.trim() || `serve exited with code ${code}`);
      for (const [, waiting] of this.pending) {
        waiting.reject(new FabricError(this.ended.code, this.ended.message, waiting.op));
      }
      this.pending.clear();
    }
  }
}
