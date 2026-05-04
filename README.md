# VM4A — Virtual Machines for Agents

**Spin up isolated macOS or Linux VMs on Apple Silicon for AI agents to safely run code in.** Built on Apple's [Virtualization framework](https://developer.apple.com/documentation/virtualization), packaged for the way coding agents actually work in 2026.

> 中文文档：[README.zh-CN.md](README.zh-CN.md)

[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)](https://www.apple.com/macos)
[![Latest release](https://img.shields.io/github/v/release/everettjf/VM4A?label=release)](https://github.com/everettjf/VM4A/releases/latest)
[![Discord](https://img.shields.io/badge/Discord-Join%20Chat-7289DA)](https://discord.gg/uxuy3vVtWs)

---

## Why VM4A

Coding agents — Claude Code, Cursor, OpenAI Codex, your own loop — keep needing one thing: **a fresh, isolated machine to try things in**. VM4A is local-first, runs on your Mac, and is the only tool in this lane that gives you:

- 🖥 **macOS and Linux guests** — test iOS/macOS app builds, not just `pip install`
- 📸 **VZ snapshots (macOS 14+)** — `--save-on-stop` / `--restore` for sub-second try → fail → reset loops
- 📦 **OCI registry push/pull** — distribute pre-baked agent environments through GHCR / Docker Hub / Harbor
- 🚀 **Apple Silicon native** — `Virtualization.framework`, near-native performance, no QEMU emulation
- 🪟 **GUI as a debugger, not the main UI** — when an agent run fails, open the snapshot in the app

> **macOS guest install flow.** `vm4a create --os macOS --image foo.ipsw` drives Apple's `VZMacOSInstaller` end-to-end (10–20 min). The resulting VM boots into Setup Assistant on first run; complete that once interactively (account + Remote Login → on), then every other vm4a operation — `run`, `exec`, `cp`, `fork`, `reset`, `pool`, the OCI push/pull, the MCP tools — works on the macOS bundle just like on Linux. Pulling a pre-baked macOS bundle from a registry skips Setup Assistant entirely. **Host requirement: Apple Silicon Mac running macOS 13+.**

VM4A is **"VM for Agent"** — pronounced *"VM-for-A"*. The CLI is `vm4a`.

---

## 30-second demo

```bash
# Pull a pre-baked Python dev image, start it, wait for SSH, run code.
vm4a spawn dev \
    --from ghcr.io/everettjf/vm4a-templates/python-dev:latest \
    --storage /tmp/vm4a --wait-ssh

vm4a exec /tmp/vm4a/dev --output json -- python3 -c 'print(1+1)'
# → {"exit_code":0,"stdout":"2\n","stderr":"","duration_ms":312,"timed_out":false}

# Per-task pattern: APFS-clone in a second, run a step, throw away.
vm4a fork /tmp/vm4a/dev /tmp/vm4a/task-42 --auto-start --wait-ssh
vm4a exec /tmp/vm4a/task-42 -- bash /work/agent_step.sh
```

---

## Three ways to drive VM4A

| Path | Use when | Entry point |
|---|---|---|
| **CLI** | Shell scripts, CI, manual exploration | `vm4a <command>` |
| **MCP** | Claude Code, Cursor, Cline, any MCP-aware AI | `vm4a mcp` (stdio JSON-RPC) |
| **HTTP + Python SDK** | Custom Python harnesses, language bindings | `vm4a serve` + `pip install vm4a` |

All three share the same agent primitives: `spawn`, `exec`, `cp`, `fork`, `reset`, `list`, `ip`, `stop`. Pick whichever surface fits the consumer.

---

## Install

```bash
brew tap everettjf/tap
brew install vm4a              # CLI
brew install --cask vm4a       # GUI (drag-install)
```

Or build from source:

```bash
git clone https://github.com/everettjf/VM4A.git
cd VM4A
swift build -c release
codesign --force --sign - \
    --entitlements Sources/VM4ACLI/VM4ACLI.entitlements \
    ./.build/release/vm4a
cp ./.build/release/vm4a /usr/local/bin/
```

> ⚠️ The CLI **must** be codesigned with `Sources/VM4ACLI/VM4ACLI.entitlements`. Bridged networking and Rosetta paths silently fail without it.

**Requirements:** Apple Silicon Mac (M1+), macOS 13+, macOS 14+ for snapshots.

---

## Status — v2.4 (warm-pool runtime + network sandbox shipped)

| Phase | Goal | Status |
|---|---|---|
| v1.1 | VM lifecycle + OCI distribution + snapshots | ✅ shipped |
| v2.0 P0 | Agent CLI primitives (`spawn`/`exec`/`cp`/`fork`/`reset`) | ✅ shipped |
| v2.0 P1 | MCP server (`vm4a mcp`) — Claude Code / Cursor / Cline | ✅ shipped |
| v2.1 | HTTP API (`vm4a serve`) + Python SDK | ✅ shipped |
| v2.2 | Curated OCI templates (`ubuntu-base`, `python-dev`, `xcode-dev`) | ✅ shipped (Linux templates auto, macOS template needs one-time Setup Assistant click-through) |
| v2.3 | Time Machine viewer (`vm4a-sessions` SwiftUI app + `vm4a session` CLI) | ✅ shipped (standalone; main-app integration pending) |
| v2.4 | Warm-pool runtime (`vm4a pool serve/acquire/release`), `--network none\|nat\|bridged\|host` | ✅ shipped (resource caps beyond CPU/memory/disk-size + ISO read-only intentionally limited by what VZ exposes) |

---

## Where to go next

- **[Usage.md](Usage.md)** — every command, agent loops, MCP/HTTP integration, sessions, pools, templates, troubleshooting
- **[Developer.md](Developer.md)** — repo layout, architecture, build, tests, how to add a new tool, release workflow
- **[sdk/python/README.md](sdk/python/README.md)** — Python SDK quickstart
- **[templates/README.md](templates/README.md)** — pre-baked OCI templates and how to rebuild them

If you're using Claude Code, the project ships a local skill at `.claude/skills/vm4a-cli/SKILL.md` that teaches Claude how to drive every subcommand.

---

## License

MIT. See [LICENSE](LICENSE).

## Star history

[![Star History Chart](https://api.star-history.com/svg?repos=everettjf/VM4A&type=Date)](https://star-history.com/#everettjf/VM4A&Date)
