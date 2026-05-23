/**
 * Dependency-free client for the local vm4a HTTP API.
 *
 * Mirrors the Python SDK. Uses the global `fetch` (Node 18+, Deno, Bun,
 * browsers). The CLI must be running: `vm4a serve --port 7777`.
 */

export class VM4AHTTPError extends Error {
  readonly status: number;
  readonly body: string;
  constructor(status: number, message: string, body = "") {
    super(`vm4a HTTP ${status}: ${message}`);
    this.name = "VM4AHTTPError";
    this.status = status;
    this.body = body;
  }
}

// Response shapes (camelCase, matching what `vm4a serve` emits).

export interface SpawnOutcome {
  id: string;
  name: string;
  path: string;
  os: string;
  pid: number | null;
  ip: string | null;
  sshReady: boolean;
}

export interface ExecResult {
  exitCode: number;
  stdout: string;
  stderr: string;
  durationMs: number;
  timedOut: boolean;
}

export interface ForkOutcome {
  path: string;
  name: string;
  started: boolean;
  pid: number | null;
  ip: string | null;
}

export interface ResetOutcome {
  path: string;
  restored: string;
  pid: number | null;
  ip: string | null;
}

export interface StopOutcome {
  stopped: boolean;
  pid: number;
  forced: boolean | null;
  reason: string | null;
}

export interface VMSummary {
  id: string;
  name: string;
  path: string;
  os: string;
  status: string;
  pid: number | null;
  ip: string | null;
}

export interface Lease {
  ip: string;
  mac: string;
  name: string | null;
}

export interface ExposeResult {
  url: string;
  host: string;
  port: number;
  scheme: string;
}

export interface ClientOptions {
  baseUrl?: string;
  token?: string;
  timeoutMs?: number;
}

export interface SpawnArgs {
  os?: string;
  storage?: string;
  from?: string;
  image?: string;
  cpu?: number;
  memoryGb?: number;
  diskGb?: number;
  network?: string;
  bridgedInterface?: string;
  rosetta?: boolean;
  restore?: string;
  saveOnStop?: string;
  waitIp?: boolean;
  waitSsh?: boolean;
  sshUser?: string;
  sshKey?: string;
  host?: string;
  waitTimeout?: number;
  allowDomains?: string[];
  timeoutMs?: number;
}

export interface ExecArgs {
  user?: string;
  key?: string;
  host?: string;
  timeoutSeconds?: number;
  timeoutMs?: number;
}

export interface CpArgs extends ExecArgs {
  recursive?: boolean;
}

export interface RunCodeArgs extends ExecArgs {}

export interface ForkArgs {
  fromSnapshot?: string;
  autoStart?: boolean;
  waitIp?: boolean;
  waitSsh?: boolean;
  sshUser?: string;
  sshKey?: string;
  waitTimeout?: number;
  keepIdentity?: boolean;
  timeoutMs?: number;
}

export interface ResetArgs {
  waitIp?: boolean;
  stopTimeout?: number;
  waitTimeout?: number;
  timeoutMs?: number;
}

function dropEmpty(obj: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(obj)) {
    if (v !== undefined && v !== null && v !== "") out[k] = v;
  }
  return out;
}

export class Client {
  readonly baseUrl: string;
  readonly token?: string;
  readonly defaultTimeoutMs: number;

  constructor(opts: ClientOptions = {}) {
    this.baseUrl = (opts.baseUrl ?? "http://127.0.0.1:7777").replace(/\/+$/, "");
    this.token = opts.token;
    this.defaultTimeoutMs = opts.timeoutMs ?? 30_000;
  }

  private async request<T>(
    method: string,
    path: string,
    opts: { body?: Record<string, unknown>; query?: Record<string, string>; timeoutMs?: number } = {},
  ): Promise<T> {
    let url = this.baseUrl + path;
    if (opts.query) {
      const qs = new URLSearchParams(opts.query).toString();
      if (qs) url += "?" + qs;
    }
    const headers: Record<string, string> = { Accept: "application/json" };
    let body: string | undefined;
    if (opts.body !== undefined) {
      body = JSON.stringify(opts.body);
      headers["Content-Type"] = "application/json";
    }
    if (this.token) headers["Authorization"] = `Bearer ${this.token}`;

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), opts.timeoutMs ?? this.defaultTimeoutMs);
    let resp: Response;
    try {
      resp = await fetch(url, { method, headers, body, signal: controller.signal });
    } finally {
      clearTimeout(timer);
    }

    const text = await resp.text();
    if (!resp.ok) {
      let message = resp.statusText;
      try {
        const parsed = JSON.parse(text);
        message = String(parsed.error ?? text);
      } catch {
        if (text) message = text;
      }
      throw new VM4AHTTPError(resp.status, message, text);
    }
    return (text ? JSON.parse(text) : null) as T;
  }

  health(): Promise<{ status: string; version: string }> {
    return this.request("GET", "/v1/health");
  }

  spawn(name: string, args: SpawnArgs = {}): Promise<SpawnOutcome> {
    const waitTimeout = args.waitTimeout ?? 90;
    const body = dropEmpty({
      name,
      os: args.os,
      storage: args.storage,
      from: args.from,
      image: args.image,
      cpu: args.cpu,
      memory_gb: args.memoryGb,
      disk_gb: args.diskGb,
      network: args.network,
      bridged_interface: args.bridgedInterface,
      rosetta: args.rosetta,
      restore: args.restore,
      save_on_stop: args.saveOnStop,
      wait_ip: args.waitIp,
      wait_ssh: args.waitSsh,
      ssh_user: args.sshUser,
      ssh_key: args.sshKey,
      host: args.host,
      wait_timeout: waitTimeout,
      allow_domains: args.allowDomains,
    });
    const timeoutMs = args.timeoutMs ?? Math.max(this.defaultTimeoutMs, (waitTimeout + 5) * 1000);
    return this.request("POST", "/v1/spawn", { body, timeoutMs });
  }

  exec(vmPath: string, command: string[], args: ExecArgs = {}): Promise<ExecResult> {
    const timeoutSeconds = args.timeoutSeconds ?? 60;
    const body = dropEmpty({
      vm_path: vmPath,
      command,
      user: args.user,
      key: args.key,
      host: args.host,
      timeout: timeoutSeconds,
    });
    const timeoutMs = args.timeoutMs ?? Math.max(this.defaultTimeoutMs, (timeoutSeconds + 5) * 1000);
    return this.request("POST", "/v1/exec", { body, timeoutMs });
  }

  runCode(vmPath: string, language: string, code: string, args: RunCodeArgs = {}): Promise<ExecResult> {
    const timeoutSeconds = args.timeoutSeconds ?? 60;
    const body = dropEmpty({
      vm_path: vmPath,
      language,
      code,
      user: args.user,
      key: args.key,
      host: args.host,
      timeout: timeoutSeconds,
    });
    const timeoutMs = args.timeoutMs ?? Math.max(this.defaultTimeoutMs, (timeoutSeconds + 5) * 1000);
    return this.request("POST", "/v1/run_code", { body, timeoutMs });
  }

  exposePort(vmPath: string, port: number, opts: { scheme?: string; host?: string } = {}): Promise<ExposeResult> {
    const body = dropEmpty({ vm_path: vmPath, port, scheme: opts.scheme ?? "http", host: opts.host });
    return this.request("POST", "/v1/expose_port", { body });
  }

  cp(vmPath: string, source: string, destination: string, args: CpArgs = {}): Promise<ExecResult> {
    const timeoutSeconds = args.timeoutSeconds ?? 300;
    const body = dropEmpty({
      vm_path: vmPath,
      source,
      destination,
      recursive: args.recursive,
      user: args.user,
      key: args.key,
      host: args.host,
      timeout: timeoutSeconds,
    });
    const timeoutMs = args.timeoutMs ?? Math.max(this.defaultTimeoutMs, (timeoutSeconds + 5) * 1000);
    return this.request("POST", "/v1/cp", { body, timeoutMs });
  }

  fork(sourcePath: string, destinationPath: string, args: ForkArgs = {}): Promise<ForkOutcome> {
    const waitTimeout = args.waitTimeout ?? 90;
    const body = dropEmpty({
      source_path: sourcePath,
      destination_path: destinationPath,
      from_snapshot: args.fromSnapshot,
      auto_start: args.autoStart,
      wait_ip: args.waitIp,
      wait_ssh: args.waitSsh,
      ssh_user: args.sshUser,
      ssh_key: args.sshKey,
      wait_timeout: waitTimeout,
      keep_identity: args.keepIdentity,
    });
    const timeoutMs = args.timeoutMs ?? Math.max(this.defaultTimeoutMs, (waitTimeout + 5) * 1000);
    return this.request("POST", "/v1/fork", { body, timeoutMs });
  }

  reset(vmPath: string, from: string, args: ResetArgs = {}): Promise<ResetOutcome> {
    const waitTimeout = args.waitTimeout ?? 60;
    const body = dropEmpty({
      vm_path: vmPath,
      from,
      wait_ip: args.waitIp,
      stop_timeout: args.stopTimeout,
      wait_timeout: waitTimeout,
    });
    const timeoutMs = args.timeoutMs ?? Math.max(this.defaultTimeoutMs, (waitTimeout + 5) * 1000);
    return this.request("POST", "/v1/reset", { body, timeoutMs });
  }

  async list(storage?: string): Promise<VMSummary[]> {
    const query = storage ? { storage } : undefined;
    return (await this.request<VMSummary[]>("GET", "/v1/vms", { query })) ?? [];
  }

  async ip(vmPath: string): Promise<Lease[]> {
    return (await this.request<Lease[]>("GET", "/v1/vms/ip", { query: { path: vmPath } })) ?? [];
  }

  stop(vmPath: string, timeoutSeconds = 20): Promise<StopOutcome> {
    return this.request("POST", "/v1/vms/stop", { body: { vm_path: vmPath, timeout: timeoutSeconds } });
  }
}
