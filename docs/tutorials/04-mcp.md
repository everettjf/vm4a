---
title: 4 · MCP integration
layout: default
parent: Tutorials
nav_order: 4
description: "Expose every VM4A primitive to Claude Code / Cursor / Cline as MCP tools."
---

# MCP integration
{: .no_toc }

**Goal:** let an AI assistant spawn VMs and run code in them directly — no glue code.
{: .fs-5 .fw-300 }

- TOC
{:toc}

---

## What this gives you

`vm4a mcp` runs a [Model Context Protocol](https://modelcontextprotocol.io) server over stdio. Register it and the assistant gets every VM4A primitive as a callable tool, returning the same JSON shapes as the CLI.

## Register the server

**Claude Code** — add to `.mcp.json` at the project or user level:

```json
{
  "mcpServers": {
    "vm4a": { "command": "vm4a", "args": ["mcp"] }
  }
}
```

**Cursor** — the same JSON in `~/.cursor/mcp.json`.
**Cline** — paste into the Cline settings panel under "MCP Servers".

The server speaks JSON-RPC 2.0 over newline-framed stdio (protocol version `2024-11-05`).

## The ten tools

| Tool | Returns |
|---|---|
| `spawn` | `{id, name, path, os, pid, ip, ssh_ready}` |
| `run_code` | `{exit_code, stdout, stderr, duration_ms, timed_out}` |
| `expose_port` | `{url, host, port, scheme}` |
| `exec` | `{exit_code, stdout, stderr, duration_ms, timed_out}` |
| `cp` | same shape as `exec` |
| `fork` | `{path, name, started, pid, ip}` |
| `reset` | `{path, restored, pid, ip}` |
| `list` | array of `{id, name, path, os, status, pid, ip}` |
| `ip` | array of `{ip, mac, name?}` |
| `stop` | `{stopped, pid, forced, reason?}` |

## Try it without an AI client

The server is just stdio JSON-RPC, so you can drive it from the shell:

```bash
printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n' | vm4a mcp
```

```bash
# initialize, then call a tool
printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"demo","version":"1"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list","arguments":{"storage":"/tmp/vm4a"}}}' \
  | vm4a mcp
```

## Beyond tools: resources & prompts

The server also exposes read-only **resources**:

| URI | Returns |
|---|---|
| `vm4a://vms?storage=/path` | VM bundles in a directory |
| `vm4a://sessions?bundle=/path` | recorded sessions for a bundle |
| `vm4a://session/<id>?bundle=/path` | every event in a session |
| `vm4a://pools` | saved pool definitions |

…and canned **prompts**: `agent-loop`, `debug-failed-task`, `triage-vm`.

## What you learned

- `vm4a mcp` exposes all ten primitives to any MCP-aware assistant via one line of config.
- The wire is plain stdio JSON-RPC — easy to test and debug from a shell.

**Next:** [HTTP API & SDKs](05-http-and-sdks) — the same operations for non-MCP clients.
