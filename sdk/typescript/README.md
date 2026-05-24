# vm4a — JavaScript / TypeScript client

Thin client for the local **vm4a** HTTP API. Zero runtime dependencies; uses the
global `fetch` (Node 18+, Deno, Bun, browsers).

```bash
# Start the server (one-time, in another terminal)
vm4a serve --port 7777

# Install the SDK
npm install vm4a
```

```ts
import { Client } from "vm4a";

const c = new Client(); // http://127.0.0.1:7777, no auth

// Pull-and-start an OCI bundle, wait until SSH responds.
const vm = await c.spawn("dev", {
  from: "ghcr.io/yourorg/python-dev:latest",
  storage: "/tmp/vm4a",
  waitSsh: true,
});
console.log("VM ready:", vm.id, vm.ip);

// Run a snippet directly — no manual cp + exec.
const out = await c.runCode(vm.path, "python", "print(1 + 1)");
console.log("exit", out.exit_code, "stdout:", out.stdout);

// Resolve a host-reachable URL for a guest port.
const { url } = await c.exposePort(vm.path, 8000);
console.log("service at", url);

// Per-task fork.
await c.fork("/tmp/vm4a/dev", "/tmp/vm4a/task-42", {
  fromSnapshot: "/tmp/vm4a/dev/clean.vzstate",
  autoStart: true,
  waitSsh: true,
});
```

## Auth

If the server was started with `VM4A_AUTH_TOKEN`, pass it to the client:

```ts
const c = new Client({ baseUrl: "http://127.0.0.1:7777", token: process.env.VM4A_TOKEN });
```

## Surface

`health`, `spawn`, `exec`, `runCode`, `exposePort`, `cp`, `fork`, `reset`,
`list`, `ip`, `stop` — the same operations as the Python SDK and MCP server,
backed by `vm4a serve`'s `/v1/*` endpoints.

## Build

```bash
npm install
npm run build      # emits dist/
npm run typecheck  # tsc --noEmit
```
