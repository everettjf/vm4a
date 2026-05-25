---
title: Home
layout: home
nav_order: 1
description: "VM4A — Virtual Machines for Agents. Isolated macOS and Linux VMs on Apple Silicon for AI agents."
permalink: /
---

# VM4A — Virtual Machines for Agents
{: .fs-9 }

Spin up isolated **macOS or Linux** VMs on Apple Silicon for AI agents to safely run code in. Built on Apple's [Virtualization framework](https://developer.apple.com/documentation/virtualization), driven by a single CLI — `vm4a`.
{: .fs-6 .fw-300 }

[Get started](getting-started){: .btn .btn-primary .fs-5 .mb-4 .mb-md-0 .mr-2 }
[Start the tutorials](tutorials){: .btn .fs-5 .mb-4 .mb-md-0 .mr-2 }
[中文文档](zh/){: .btn .fs-5 .mb-4 .mb-md-0 .mr-2 }
[View on GitHub](https://github.com/everettjf/vm4a){: .btn .fs-5 .mb-4 .mb-md-0 }

---

## What is VM4A?

Coding agents — Claude Code, Cursor, OpenAI Codex, your own loop — keep needing one thing: **a fresh, isolated machine to try things in**. VM4A is local-first, runs on your Mac, and gives a coding agent a real VM it can spawn, run code in, snapshot, fork, and throw away — in about a second per task.

One binary, `vm4a`, handles the whole lifecycle: create, run, snapshot, fork, OCI push/pull, plus the agent surfaces (CLI, MCP, HTTP API, SDKs, and a cluster scheduler).

```bash
# Pull a pre-baked image, boot it, wait for SSH, run code — one line each.
vm4a spawn dev --from ghcr.io/yourorg/python-dev:latest --storage /tmp/vm4a --wait-ssh
vm4a run-code /tmp/vm4a/dev --lang python --code 'print(1 + 1)'
```

## Four ways to drive it

| Surface | Use when | Entry point |
|---|---|---|
| 🐚 **CLI** | Shell scripts, CI, manual exploration | `vm4a <command>` |
| 🤖 **MCP** | Claude Code, Cursor, Cline, any MCP-aware AI | `vm4a mcp` |
| 🌐 **HTTP + SDKs** | Custom harnesses, language bindings | `vm4a serve` + Python / JS-TS |
| 🛰 **Cluster** | Many Macs as one pool | `vm4a cluster …` |

## Where to go next

<div class="code-example" markdown="1">

- **New here?** → [Getting started](getting-started) installs `vm4a` and boots your first VM.
- **Learning by doing?** → The [Tutorials](tutorials) walk every feature, start to finish.
- **Looking up a flag or JSON shape?** → The repo's [`Usage.md`](https://github.com/everettjf/vm4a/blob/main/Usage.md) is the per-command reference.
- **Stuck?** → [Troubleshooting](troubleshooting).

</div>

---

## Requirements

- Apple Silicon Mac (M1 or newer)
- macOS 13+ (VZ snapshots need macOS 14+)
- For building from source: Swift 6 toolchain (Xcode 16+)

{: .note }
> VM4A is **"VM for Agent"** — pronounced *"VM-for-A"*. The CLI binary is `vm4a`.
