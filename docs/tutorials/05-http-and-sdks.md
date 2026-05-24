---
title: 5 · HTTP API & SDKs
layout: default
parent: Tutorials
nav_order: 5
description: "Drive VMs over a localhost HTTP API from Python or JavaScript/TypeScript."
---

# HTTP API & SDKs
{: .no_toc }

**Goal:** drive VMs from a custom harness in Python or JS/TS over HTTP.
{: .fs-5 .fw-300 }

- TOC
{:toc}

---

## Start the server

```bash
vm4a serve --port 7777
# Optional bearer auth:  export VM4A_AUTH_TOKEN=secret  before starting
# Remote/cluster use:    vm4a serve --bind 0.0.0.0 --port 7777   (pair with a token)
```

It binds to `127.0.0.1` by default.

## Endpoints

| Endpoint | Body | Returns |
|---|---|---|
| `GET /v1/health` | — | `{status, version}` *(unauthenticated)* |
| `POST /v1/spawn` | SpawnOptions | SpawnOutcome |
| `POST /v1/run_code` | `{vm_path, language, code, …}` | ExecResult |
| `POST /v1/expose_port` | `{vm_path, port, scheme?, host?}` | `{url, host, port, scheme}` |
| `POST /v1/exec` | `{vm_path, command, …}` | ExecResult |
| `POST /v1/cp` | `{vm_path, source, destination, …}` | ExecResult |
| `POST /v1/fork` | `{source_path, destination_path, …}` | ForkOutcome |
| `POST /v1/reset` | `{vm_path, from, …}` | ResetOutcome |
| `GET /v1/vms` | `?storage=/path` | `[VMSummary]` |
| `GET /v1/vms/ip` | `?path=/bundle` | `[Lease]` |
| `POST /v1/vms/stop` | `{vm_path, timeout?}` | StopOutcome |

With `VM4A_AUTH_TOKEN` set, every endpoint **except** `GET /v1/health` requires `Authorization: Bearer <token>` (else `401`).

```bash
curl -s localhost:7777/v1/health
# → {"status":"ok","version":"2.5.0"}
```

{: .note }
> Response JSON is **snake_case** (`exit_code`, `duration_ms`, `timed_out`, `ssh_ready`). The SDKs below mirror that.

## Python SDK

Stdlib-only (no `requests`/`httpx`):

```python
from vm4a import Client

c = Client()                       # http://127.0.0.1:7777, or Client(token="…")
vm = c.spawn(name="dev", from_="ghcr.io/yourorg/python-dev:latest", wait_ssh=True)

out = c.run_code(vm.path, "python", "print(1+1)")
print(out.exit_code, out.stdout)   # 0  "2\n"

url = c.expose_port(vm.path, 8000).url   # http://192.168.64.7:8000
```

`pip install vm4a` once published; before that, run from source with `PYTHONPATH=sdk/python/src`.

## JavaScript / TypeScript SDK

Dependency-free, uses the built-in global `fetch` (Node 18+):

```ts
import { Client } from "vm4a";

const c = new Client();             // or new Client({ token: "…" })
const vm = await c.spawn("dev", { from: "ghcr.io/yourorg/python-dev:latest", waitSsh: true });

const out = await c.runCode(vm.path, "python", "print(1+1)");
console.log(out.exit_code, out.stdout);   // 0  "2\n"

const { url } = await c.exposePort(vm.path, 8000);
```

`npm install vm4a` once published; before that, `cd sdk/typescript && npm install && npm run build`.

{: .tip }
> Field names follow the wire: `out.exit_code` (not `exitCode`). A worked agent loop ships at `sdk/typescript/examples/agent_loop.ts`.

## What you learned

- `vm4a serve` exposes every primitive as a localhost REST API, with optional bearer auth.
- Python and JS/TS SDKs mirror the same operations and the snake_case wire shapes.

**Next:** [Cluster scheduling](06-cluster) — pool several Macs behind one scheduler.
