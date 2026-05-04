# VM4A — Virtual Machines for Agents

**Spin up isolated macOS or Linux VMs on Apple Silicon for AI agents to safely run code in.** Built on Apple's [Virtualization framework](https://developer.apple.com/documentation/virtualization), packaged for the way coding agents actually work in 2026.

> 中文文档：[README.zh-CN.md](README.zh-CN.md)

[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)](https://www.apple.com/macos)
[![Latest release](https://img.shields.io/github/v/release/everettjf/VM4A?label=release)](https://github.com/everettjf/VM4A/releases/latest)
[![Discord](https://img.shields.io/badge/Discord-Join%20Chat-7289DA)](https://discord.gg/uxuy3vVtWs)

---

## Why VM4A

Coding agents — Claude Code, Cursor, OpenAI Codex, your custom agent loop — keep needing one thing: **a fresh, isolated machine to try things in**. Most existing answers are Linux-only cloud sandboxes (E2B, modal) or generic VM tools that never thought about agent ergonomics.

VM4A is local-first, runs on your Mac, and is the only tool in this lane that gives you:

- 🖥 **Both macOS and Linux guests** — test iOS/macOS app builds, not just `pip install`
- 📸 **VZ snapshots (macOS 14+)** — `--save-on-stop` / `--restore` for sub-second try → fail → reset loops
- 📦 **OCI registry push/pull** — distribute pre-baked agent environments through GHCR / Docker Hub / Harbor like container images
- 🚀 **Apple Silicon native** — `Virtualization.framework`, near-native performance, no QEMU emulation tax
- 🪟 **GUI as a debugger, not the main UI** — when an agent run fails, open the snapshot in the app and see exactly what happened

VM4A is the codename **"VM for Agent"** — pronounced *"VM-for-A"*. The CLI is `vm4a`.

---

## Status — v2.1 (Agent primitives + MCP + HTTP API + Python SDK)

The agent-first CLI primitives are **in**, plus three programmatic surfaces over the same core:

| Shipped | What it does |
|---|---|
| `vm4a spawn` | One-shot create+start from an OCI image (`--from`) or local ISO (`--image`), with `--wait-ip` / `--wait-ssh` |
| `vm4a exec` | SSH into the guest, run a command, return `{exit_code, stdout, stderr, duration_ms, timed_out}` |
| `vm4a cp` | Bidirectional file transfer over SCP — `:` prefix marks the guest path |
| `vm4a fork` | APFS clonefile a bundle and optionally auto-start it (with snapshot restore) |
| `vm4a reset` | Stop + restore from a `.vzstate` snapshot — for try → fail → reset → retry loops |
| `vm4a mcp` | Stdio JSON-RPC 2.0 MCP server — drop-in tool for any MCP-aware client |
| `vm4a serve` | HTTP REST API on localhost — `/v1/spawn`, `/v1/exec`, … |
| `pip install vm4a` | Python SDK that wraps the HTTP API (zero deps, stdlib only) |

Still designing for later milestones: GUI Time Machine, curated OCI templates, pre-warmed VM pools. See the [roadmap](#roadmap).

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

> ⚠️ The CLI **must** be codesigned with `Sources/VM4ACLI/VM4ACLI.entitlements`. Bridged networking and some Rosetta paths silently fail without it.

**Requirements:** Apple Silicon Mac (M1+), macOS 13+, macOS 14+ for snapshots.

---

## How agents use VM4A

The recommended flow uses the v2 primitives — a parallel agent harness needs three calls (spawn, exec, fork) and one rollback path (reset).

```bash
# 1. One-shot pull + start (arm save-on-stop) + wait-for-SSH.
vm4a spawn dev --from ghcr.io/yourorg/python-dev-arm64:latest \
  --storage /tmp/vm4a \
  --save-on-stop /tmp/vm4a/dev/clean.vzstate \
  --wait-ssh --output json
# → {"id":"vm-…","name":"dev","ip":"192.168.64.7","ssh_ready":true,…}

# 2. Install whatever the agent needs, then stop — VM saves state on shutdown.
vm4a exec /tmp/vm4a/dev -- bash -lc "apt-get install -y ripgrep"
vm4a stop /tmp/vm4a/dev

# 3. Per-task: fork from the golden bundle and run code in it.
vm4a fork /tmp/vm4a/dev /tmp/vm4a/task-$JOB_ID \
  --auto-start --from-snapshot /tmp/vm4a/dev/clean.vzstate --wait-ssh
vm4a cp   /tmp/vm4a/task-$JOB_ID ./agent_step.py :/work/step.py
vm4a exec /tmp/vm4a/task-$JOB_ID --output json --timeout 120 \
  -- python3 /work/step.py
# → {"exit_code":0,"stdout":"…","stderr":"","duration_ms":3142,"timed_out":false}

# 4. If the task corrupted state, reset back to the golden snapshot in <1s.
vm4a reset /tmp/vm4a/task-$JOB_ID --from /tmp/vm4a/dev/clean.vzstate --wait-ip
```

Every command supports `--output json` for clean parsing — no text wrangling required.

`fork` uses APFS `clonefile(2)` so creating a fresh per-task VM is **O(directory entries), not O(disk image size)**. Combined with `--from-snapshot`, agents go from "I want a clean machine" to "VM is up and ready" in roughly a second per task.

---

## CLI reference

```
Agent-first primitives (v2.0 P0)
vm4a spawn             Create+start a VM in one shot, optionally wait for IP/SSH
vm4a exec              Run a command inside a running VM via SSH; returns JSON
vm4a cp                Copy files between host and guest via SCP (':' prefix = guest)
vm4a fork              Clone a VM bundle (APFS clonefile) and optionally auto-start
vm4a reset             Stop + restore from a .vzstate snapshot — for retry loops

Classic lifecycle
vm4a create            Create a VM bundle
vm4a list              List VM bundles in a directory
vm4a run               Run a VM (detached by default; --foreground to stay attached)
vm4a stop              Stop a running VM (SIGTERM, escalates to SIGKILL after timeout)
vm4a clone             Clone a VM bundle (APFS clonefile when possible)
vm4a network list      List host bridged interfaces available to VMs
vm4a image list        List curated Linux ARM64 ISO URLs
vm4a push              Push a VM bundle to an OCI registry
vm4a pull              Pull a VM bundle from an OCI registry
vm4a ip                Resolve a NAT VM's IP from Apple's DHCP leases
vm4a ssh               SSH into a NAT VM
vm4a agent status      Read the last heartbeat from the in-guest agent (scaffold)
vm4a agent ping        Send a ping command to the in-guest agent (scaffold)

Agent integrations (v2.0 P1, v2.1)
vm4a mcp               Run as an MCP server over stdio (Claude Code / Cursor / Cline)
vm4a serve             Run an HTTP API server on localhost
```

Run `vm4a <subcommand> --help` for the full option list.

### Spawn

```bash
vm4a spawn <name> [--os linux|macOS] [--storage <dir>] \
  (--from <oci-ref> | --image <iso-or-ipsw>) \
  [--cpu <n>] [--memory-gb <n>] [--disk-gb <n>] \
  [--bridged-interface <bsdName>] [--rosetta] \
  [--restore <state.vzstate>] [--save-on-stop <state.vzstate>] \
  [--wait-ip] [--wait-ssh] [--ssh-user <name>] [--ssh-key <path>] \
  [--host <ip>] [--wait-timeout <seconds>] [--output text|json]
```

If `<storage>/<name>` already exists, `spawn` just (re)starts it. Otherwise `--from` pulls an OCI bundle, or `--image` creates a fresh VM from an ISO/IPSW. With `--output json` and `--wait-ssh`, agents get a single call that returns `{ip, ssh_ready: true}` or fails fast.

### Exec

```bash
vm4a exec <vm-path> [--user <name>] [--key <path>] [--host <ip>] \
  [--timeout <seconds>] [--output text|json] -- <command...>
```

Without `--output json`, stdout/stderr stream and the exit code becomes this process's exit code. With `--output json`, returns `{exit_code, stdout, stderr, duration_ms, timed_out}` so the agent can decide whether to retry, escalate, or move on. Default user is `root` for Linux guests, the current user for macOS guests.

### Cp

```bash
vm4a cp <vm-path> [-r] [--user <name>] [--key <path>] [--host <ip>] \
  [--timeout <seconds>] [--output text|json] <source> <destination>
```

The `:` prefix on a path marks it as the guest side; otherwise it's a host path. Exactly one side must be a guest path.

```bash
vm4a cp /tmp/vm4a/dev ./local.py :/work/script.py        # host → guest
vm4a cp /tmp/vm4a/dev :/var/log/syslog ./syslog.txt      # guest → host
vm4a cp /tmp/vm4a/dev -r ./project :/srv/code            # recursive
```

### Fork

```bash
vm4a fork <source-path> <destination-path> \
  [--auto-start] [--from-snapshot <state.vzstate>] \
  [--wait-ip] [--wait-ssh] [--ssh-user <name>] [--ssh-key <path>] \
  [--wait-timeout <seconds>] [--output text|json]
```

APFS `clonefile(2)` from the source bundle, then re-randomises `MachineIdentifier` so the fork boots as a distinct machine. With `--auto-start --from-snapshot`, you get a parallel-ready VM in roughly a second.

### Reset

```bash
vm4a reset <vm-path> --from <state.vzstate> \
  [--wait-ip] [--stop-timeout <seconds>] [--wait-timeout <seconds>] \
  [--output text|json]
```

For `try → fail → reset → retry` agent loops. Stops the VM (SIGTERM → SIGKILL) and restarts it from the supplied snapshot. Requires macOS 14+ and a previously saved `.vzstate` (see `--save-on-stop` on `run`).

### Create

```bash
vm4a create <name> --os <macOS|linux> \
  [--storage <dir>] [--image <iso-or-ipsw>] \
  [--cpu <n>] [--memory-gb <n>] [--disk-gb <n>] \
  [--bridged-interface <bsdName>] [--rosetta] \
  [--output text|json]
```

- `--bridged-interface` takes a `bsdName` from `vm4a network list` (e.g. `en0`).
- `--rosetta` enables Linux x86_64 translation via a `rosetta` virtiofs share (macOS 13+).
- `--output json` prints a machine-readable summary.
- macOS VMs created via CLI are **skeletons** — finish the install in the GUI for now.

### Run

```bash
vm4a run <vm-path> [--foreground] [--recovery]
                   [--restore <state.vzstate>] [--save-on-stop <state.vzstate>]
```

- Default `run` spawns a `_run-worker` child process; the shell returns immediately. Logs go to `<vm-path>/.vm4a-run.log`.
- `--foreground` streams VZ logs to stdout and blocks until the VM exits.
- `--restore` / `--save-on-stop` require macOS 14+.

### List, IP, SSH

```bash
vm4a list --storage /tmp/vm4a --output json
vm4a ip   /tmp/vm4a/demo
vm4a ssh  /tmp/vm4a/demo --user ubuntu -- -L 8080:localhost:8080
```

Arguments after `--` pass through to `/usr/bin/ssh` for port-forward, key-pin, etc.

### Clone

Uses `clonefile(2)` on APFS volumes (same volume → instantaneous, zero extra disk). Falls back to byte copy across volumes. Re-randomises `MachineIdentifier` so the clone boots as a distinct machine.

```bash
vm4a clone /tmp/vm4a/golden /tmp/vm4a/job-$CI_JOB_ID
```

---

## Use with Claude Code / Cursor / Cline (MCP)

Register `vm4a` as an MCP server and the assistant gets every agent primitive as a callable tool — no glue code, no spawning shell commands.

**Claude Code** — add to `.mcp.json` at the project or user level:

```json
{
  "mcpServers": {
    "vm4a": {
      "command": "vm4a",
      "args": ["mcp"]
    }
  }
}
```

**Cursor** — add the same block to `~/.cursor/mcp.json`. **Cline** — add it to the Cline settings panel under "MCP Servers".

Once registered, the assistant sees the following tools:

| Tool | Returns |
|---|---|
| `spawn` | `{id, name, path, os, pid, ip, ssh_ready}` |
| `exec` | `{exit_code, stdout, stderr, duration_ms, timed_out}` |
| `cp` | Same shape as `exec` (uses scp under the hood) |
| `fork` | `{path, name, started, pid, ip}` |
| `reset` | `{path, restored, pid, ip}` |
| `list` | Array of `{id, name, path, os, status, pid, ip}` |
| `ip` | Array of `{ip, mac, name?}` |
| `stop` | `{stopped, pid, forced, reason?}` |

The protocol is JSON-RPC 2.0 framed by newlines (the standard MCP stdio transport, protocol version `2024-11-05`). Run `printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n' | vm4a mcp` to inspect the tool catalog manually.

---

## HTTP API + Python SDK

For non-MCP clients (CI runners, custom Python harnesses, language bindings), `vm4a` also exposes the same operations as a localhost HTTP server.

```bash
# Server
vm4a serve --port 7777
# Optional bearer-token auth: export VM4A_AUTH_TOKEN=...
```

```bash
# Smoke test
curl -s http://127.0.0.1:7777/v1/health
curl -s http://127.0.0.1:7777/v1/vms?storage=/tmp/vm4a
```

| Endpoint | Body | Response |
|---|---|---|
| `GET /v1/health` | — | `{status, version}` |
| `POST /v1/spawn` | SpawnOptions JSON | SpawnOutcome |
| `POST /v1/exec` | `{vm_path, command, ...}` | ExecResult |
| `POST /v1/cp` | `{vm_path, source, destination, ...}` | ExecResult |
| `POST /v1/fork` | `{source_path, destination_path, ...}` | ForkOutcome |
| `POST /v1/reset` | `{vm_path, from, ...}` | ResetOutcome |
| `GET /v1/vms` | `?storage=/path` | VMSummary array |
| `GET /v1/vms/ip` | `?path=/bundle` | Lease array |
| `POST /v1/vms/stop` | `{vm_path, timeout?}` | StopOutcome |

The Python SDK is a thin wrapper over the HTTP API — stdlib-only, no `requests`/`httpx` dependency:

```python
from vm4a import Client

c = Client()  # http://127.0.0.1:7777
vm = c.spawn(name="dev", from_="ghcr.io/yourorg/python-dev:latest", wait_ssh=True)
out = c.exec(vm.path, ["python3", "-c", "print(1+1)"])
print(out.exit_code, out.stdout)
```

Full SDK README and example agent loop in [`sdk/python/`](sdk/python/).

---

## Distribution via OCI registries

Bundles pack into a single `tar.gz` layer with media type `application/vnd.vm4a.bundle.v1.tar+gzip`, plus a small JSON config blob. Any Docker Registry v2 compatible registry works (GHCR, Docker Hub, ECR, Harbor, in-house).

```bash
# Public pull (no credentials needed)
vm4a pull ghcr.io/someone/ubuntu-arm:24.04 --storage /tmp/vm4a

# Authenticated push (GHCR example)
export VM4A_REGISTRY_USER=yourname
export VM4A_REGISTRY_PASSWORD=ghp_xxx     # PAT with write:packages
vm4a push /tmp/vm4a/my-vm ghcr.io/yourname/my-vm:v1
```

Both Bearer-token (GHCR-style) and HTTP Basic auth are supported.

---

## Networking

**NAT (default)** — works with zero setup. VMs live on `192.168.64.0/24`. Look up the guest's IP with `vm4a ip`.

**Bridged** — VM gets an IP from your LAN's DHCP:

```bash
vm4a network list                              # find bsdNames
vm4a create web --os linux --bridged-interface en0 …
```

Bridged mode requires the CLI carry `com.apple.vm.networking`. The bundled entitlement file has it — re-run the codesign step from [Install](#install) if you change binaries.

---

## Rosetta (x86 binaries in Linux guests)

```bash
softwareupdate --install-rosetta --agree-to-license
vm4a create linux-dev --os linux --rosetta --image ubuntu-arm64.iso …
```

Inside the guest, mount the virtiofs share named `rosetta` and register it with `binfmt_misc`. Apple's [official guide](https://developer.apple.com/documentation/virtualization/running_intel_binaries_in_linux_vms_with_rosetta) walks through the in-guest steps.

---

## Snapshots (macOS 14+)

Save and restore the VM's full execution state, not just disk:

```bash
vm4a run  /tmp/vm4a/demo --save-on-stop /tmp/vm4a/demo/state.vzstate
vm4a stop /tmp/vm4a/demo                      # pause + save before exit

vm4a run  /tmp/vm4a/demo --restore /tmp/vm4a/demo/state.vzstate
```

For agent loops: save once after first boot, then every task starts in <1s instead of paying boot cost.

---

## GUI: VM4A.app

The SwiftUI app handles two things well:

1. **Initial macOS guest install** — pick a macOS version, watch it provision, end up with a snapshottable bundle. macOS guest installs require interactive setup that doesn't fit the CLI.
2. **Inspecting state** — open any bundle, browse its config, run it interactively, watch the framebuffer.

> **Roadmap (v2):** the GUI becomes a Time Machine-style debugger — sessions of agent runs, snapshot timeline scrubbing, filesystem-diff between snapshots, one-click "fork from this snapshot to inspect manually." Today it's still the v1 management UI.

---

## Bundle layout

```
demo/
├── config.json           # device/CPU/memory config (schemaVersion: 1)
├── state.json            # runtime state pointer
├── Disk.img              # qcow-less raw disk
├── MachineIdentifier     # VZ platform identity
├── NVRAM                 # (Linux) EFI variable store
├── HardwareModel         # (macOS) VZ hardware identity
├── AuxiliaryStorage      # (macOS) OS boot bits
├── console.log           # (Linux) serial console log, rotated each run
└── guest-agent/          # virtiofs rendezvous for the optional guest agent
```

A bundle made by the CLI runs in the GUI and vice versa.

---

## Architecture

```
┌───────────────────────┐     ┌───────────────────────┐
│   VM4A.app (GUI)      │     │     vm4a (CLI)        │
│   SwiftUI, Xcode      │     │     SwiftPM           │
└──────────┬────────────┘     └───────────┬───────────┘
           │                              │
           │     import VM4ACore          │
           ▼                              ▼
   ┌───────────────────────────────────────────────┐
   │              VM4ACore (shared)                │
   │  • VMConfigModel / VMStateModel (schema v1)   │
   │  • VZVirtualMachineConfiguration builder      │
   │  • DispatchSource-driven runner               │
   │  • macOS 14 snapshot save/restore             │
   │  • OCI Docker Registry v2 client              │
   │  • DHCP lease parser                          │
   │  • Guest-agent protocol types                 │
   └───────────────────────────────────────────────┘
```

---

## Exit codes (for scripting)

| Code | Case | Meaning |
| --- | --- | --- |
| `0` | — | Success |
| `1` | `message` | Generic failure |
| `2` | `notFound` | Bundle / file / interface not found |
| `3` | `alreadyExists` | Destination already exists |
| `4` | `invalidState` | VM running when it shouldn't be (or vice versa) |
| `5` | `hostUnsupported` / `rosettaNotInstalled` | Host capability missing |

Branch on these without parsing stderr.

---

## Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| `run` exits silently | Check `<bundle>/.vm4a-run.log` |
| `network list` is empty | CLI not signed with `com.apple.vm.networking` |
| `ssh` / `ip` returns nothing | VM still booting / DHCP'ing — wait 10–30 s |
| `push` returns HTTP 401 | Set `VM4A_REGISTRY_USER` / `VM4A_REGISTRY_PASSWORD` |
| `--rosetta` fails with "not installed" | `softwareupdate --install-rosetta --agree-to-license` |
| Linux guest hangs at boot | Confirm ISO is ARM64; verify `MachineIdentifier` and `NVRAM` exist |
| CLI `macOS` VM fails to start | Expected — CLI creates skeletons, finish install in GUI |
| Snapshot flags refused | Requires macOS 14+ |

---

## Roadmap

| Phase | Goal | Status |
| --- | --- | --- |
| v1.1 | Solid VM lifecycle + OCI distribution + snapshots (the EasyVM foundation) | ✅ shipped |
| v2.0 P0 | Agent CLI primitives (`spawn`, `exec`, `cp`, `fork`, `reset`) over the v1 commands | ✅ shipped |
| v2.0 P1 | MCP server — drop-in tool for Claude Code / Cursor / Cline | ✅ shipped |
| v2.1 | HTTP API + Python SDK | ✅ shipped |
| v2.2 | Curated OCI templates (`vm4a/python-dev`, `vm4a/xcode-dev`, `vm4a/ubuntu-base`) | planned |
| v2.3 | GUI Time Machine — session/timeline/diff viewer for agent runs | planned |
| v2.4 | Pre-warmed VM pools, network sandbox policies, resource caps | planned |

Open an issue with your use case if you want to weigh in on prioritization.

---

## Release workflow

Self-hosted Homebrew tap (`everettjf/homebrew-tap`):

```bash
./deploy.sh                 # bump patch + build + dmg + push formula/cask
./deploy.sh --only-cli      # CLI only
./deploy.sh --only-app      # App only
./deploy.sh --skip-tests    # skip swift test
./deploy.sh --minor         # minor version bump
./deploy.sh --major         # major version bump
```

---

## Contributing

```bash
swift test
xcodebuild -project VM4A/VM4A.xcodeproj -scheme VM4A \
  -destination 'platform=macOS,arch=arm64' build
```

Issues and PRs welcome. If you're using Claude Code, the project ships a local skill at `.claude/skills/vm4a-cli/SKILL.md` that teaches Claude how to drive every subcommand.

---

## License

MIT. See [LICENSE](LICENSE).

## Star history

[![Star History Chart](https://api.star-history.com/svg?repos=everettjf/VM4A&type=Date)](https://star-history.com/#everettjf/VM4A&Date)
