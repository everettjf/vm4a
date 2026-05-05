<div align="center">

# VM4A — Virtual Machines for Agents

**Spin up isolated macOS or Linux VMs on Apple Silicon for AI agents to safely run code in.**

Built on Apple's [Virtualization framework](https://developer.apple.com/documentation/virtualization), packaged for the way coding agents actually work in 2026.

[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)](https://www.apple.com/macos)
[![Apple Silicon](https://img.shields.io/badge/arch-Apple%20Silicon-black?logo=apple)](https://www.apple.com/mac/)
[![Latest release](https://img.shields.io/github/v/release/everettjf/vm4a?label=release)](https://github.com/everettjf/vm4a/releases/latest)
[![Discord](https://img.shields.io/badge/Discord-Join%20Chat-7289DA?logo=discord&logoColor=white)](https://discord.gg/uxuy3vVtWs)

[**Why VM4A**](#why-vm4a) · [**30s demo**](#30-second-demo) · [**Install**](#install) · [**Cookbook**](Cookbook.md) · [**Usage**](Usage.md) · [**Developer**](Developer.md) · [中文](README.zh-CN.md)

</div>

---

## Why VM4A

Coding agents — Claude Code, Cursor, OpenAI Codex, your own loop — keep needing one thing: **a fresh, isolated machine to try things in**. VM4A is local-first, runs on your Mac, and is the only tool in this lane that gives you all of:

| | |
|---|---|
| 🖥 **macOS *and* Linux guests** | Test iOS/macOS app builds, not just `pip install` |
| 📸 **VZ snapshots** *(macOS 14+)* | `--save-on-stop` / `--restore` for sub-second try → fail → reset loops |
| 📦 **OCI registry push/pull** | Distribute pre-baked agent environments via GHCR / Docker Hub / Harbor |
| 🚀 **Apple Silicon native** | `Virtualization.framework`, near-native performance, no QEMU emulation |
| 🪟 **GUI as a debugger, not the main UI** | When an agent run fails, open the snapshot in the app |

> **macOS guest install flow.** `vm4a create --os macOS --image foo.ipsw` drives Apple's `VZMacOSInstaller` end-to-end (10–20 min). The resulting VM boots into Setup Assistant on first run; complete that once interactively (account + Remote Login → on), then every other vm4a operation — `run`, `exec`, `cp`, `fork`, `reset`, `pool`, the OCI push/pull, the MCP tools — works on the macOS bundle just like on Linux. Pulling a pre-baked macOS bundle from a registry skips Setup Assistant entirely.

VM4A is **"VM for Agent"** — pronounced *"VM-for-A"*. The CLI is `vm4a`.

---

## 30-second demo

```bash
# 1. Pull a pre-baked Python dev image, start it, wait for SSH.
vm4a spawn dev \
    --from ghcr.io/everettjf/vm4a-templates/python-dev:latest \
    --storage /tmp/vm4a --wait-ssh

# 2. Run code in the guest. JSON output is machine-readable.
vm4a exec /tmp/vm4a/dev --output json -- python3 -c 'print(1+1)'
# → {"exit_code":0,"stdout":"2\n","stderr":"","duration_ms":312,"timed_out":false}

# 3. Per-task pattern: APFS-clone in a second, run a step, throw away.
vm4a fork /tmp/vm4a/dev /tmp/vm4a/task-42 --auto-start --wait-ssh
vm4a exec /tmp/vm4a/task-42 -- bash /work/agent_step.sh
```

```
   golden bundle           per-task fork           per-task fork
   ┌───────────┐  fork →   ┌───────────┐           ┌───────────┐
   │   /dev    │  ──────►  │ /task-42  │           │ /task-43  │  ...
   └───────────┘           └───────────┘           └───────────┘
   pull once               APFS clonefile, ~1s     throwaway after exec
```

---

## Three ways to drive VM4A

| Surface | Use when | Entry point |
|---|---|---|
| 🐚 **CLI** | Shell scripts, CI, manual exploration | `vm4a <command>` |
| 🤖 **MCP** | Claude Code, Cursor, Cline, any MCP-aware AI | `vm4a mcp` (stdio JSON-RPC) |
| 🌐 **HTTP + Python SDK** | Custom Python harnesses, language bindings | `vm4a serve` + `pip install vm4a` |

All three share the same agent primitives: `spawn`, `exec`, `cp`, `fork`, `reset`, `list`, `ip`, `stop`. Pick whichever surface fits the consumer.

---

## Install

```bash
brew tap everettjf/tap
brew install vm4a              # CLI
brew install --cask vm4a       # GUI (drag-install)
```

<details>
<summary>Build from source</summary>

```bash
git clone https://github.com/everettjf/vm4a.git
cd vm4a
swift build -c release
codesign --force --sign - \
    --entitlements Sources/VM4ACLI/VM4ACLI.entitlements \
    ./.build/release/vm4a
cp ./.build/release/vm4a /usr/local/bin/
```

> ⚠️ The CLI **must** be codesigned with `Sources/VM4ACLI/VM4ACLI.entitlements`. Bridged networking and Rosetta paths silently fail without it.

</details>

**Requirements:** Apple Silicon Mac (M1+), macOS 13+ (snapshots need macOS 14+).

---

## What's shipped

**Latest — v2.4** · warm-pool runtime + network sandbox

- `vm4a pool serve / acquire / release` — keep N idle VMs warm, hand one out in milliseconds.
- `--network none | nat | bridged | host` — explicit isolation level per VM.

<details>
<summary>Full release history</summary>

| Phase | Goal | Status |
|---|---|---|
| v1.1 | VM lifecycle + OCI distribution + snapshots | ✅ shipped |
| v2.0 P0 | Agent CLI primitives (`spawn`/`exec`/`cp`/`fork`/`reset`) | ✅ shipped |
| v2.0 P1 | MCP server (`vm4a mcp`) — Claude Code / Cursor / Cline | ✅ shipped |
| v2.1 | HTTP API (`vm4a serve`) + Python SDK | ✅ shipped |
| v2.2 | Curated OCI templates (`ubuntu-base`, `python-dev`, `xcode-dev`) | ✅ shipped *(macOS template needs one-time Setup Assistant click-through)* |
| v2.3 | Time Machine viewer (`vm4a-sessions` SwiftUI app + `vm4a session` CLI) | ✅ shipped *(standalone; main-app integration pending)* |
| v2.4 | Warm-pool runtime + `--network` sandbox | ✅ shipped |

See [CHANGELOG.md](CHANGELOG.md) for per-version detail.

</details>

---

## Where to go next

| If you want to… | Read |
|---|---|
| Get hands-on with end-to-end recipes | [**Cookbook.md**](Cookbook.md) — macOS / Linux guests, agent loops, sessions, pools, MCP/HTTP setup |
| See full scenarios (golden image + parallel forks, etc.) | [**UseCases/**](UseCases/) |
| Look up a flag or JSON shape | [**Usage.md**](Usage.md) — per-command reference |
| Hack on VM4A itself | [**Developer.md**](Developer.md) — repo layout, architecture, build, tests, release flow |
| See what changed | [**CHANGELOG.md**](CHANGELOG.md) |
| Use the Python SDK | [**sdk/python/README.md**](sdk/python/README.md) |
| Pull / rebuild a template | [**templates/README.md**](templates/README.md) |

> Using **Claude Code**? The repo ships a local skill at `.claude/skills/vm4a-cli/SKILL.md` that teaches Claude how to drive every subcommand.

---

## License

MIT. See [LICENSE](LICENSE).

## Star history

[![Star History Chart](https://api.star-history.com/svg?repos=everettjf/vm4a&type=Date)](https://star-history.com/#everettjf/vm4a&Date)
