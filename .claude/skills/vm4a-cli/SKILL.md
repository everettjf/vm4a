---
name: vm4a-cli
description: |
  Use this skill when the user wants to create, run, stop, clone, push/pull,
  SSH into, or otherwise manage VM4A Linux virtual machines via the `vm4a` CLI.
  Triggers include any mention of VM4A + "VM", the commands `vm4a create`,
  `vm4a run`, `vm4a pull`, `vm4a ssh`, "linux VM on mac", or requests to
  automate Linux VM lifecycle (CI, scripting, batch clones).

  Do NOT use this skill for: macOS guest install (the CLI is Linux-only;
  redirect to the SwiftUI app), the SwiftUI app itself (open Xcode instead),
  non-VM4A VM tools (UTM/VirtualBuddy/tart have their own CLIs), or questions
  about the Virtualization.framework itself.
---

# VM4A CLI

VM4A ships a single binary `vm4a` that creates and runs Apple
`Virtualization.framework` VMs on Apple Silicon from the command line. Each
VM is a directory ("bundle") containing `config.json`, `state.json`, a disk
image, and platform identity files. One binary handles the lifecycle, OCI
distribution, and agent channel.

## Prerequisites (check first, don't assume)

Before running anything:

1. **Apple Silicon + macOS 13+**. x86 Macs are not supported.
2. **CLI must be codesigned** with the CLI entitlements, otherwise `run`
   fails silently:
   ```bash
   swift build
   codesign --force --sign - \
     --entitlements Sources/VM4ACLI/VM4ACLI.entitlements \
     ./.build/debug/vm4a
   ```
   Bridged networking and Rosetta share need the CLI entitlements file
   specifically — not the App one.
3. For bridged mode: `vm4a network list` should print at least one
   interface. If empty, re-check codesigning.

## Command map (when to reach for each)

**Agent-first primitives (prefer these for any agent-driven flow):**

| Intent | Command |
| --- | --- |
| One-shot create+start, wait for SSH | `vm4a spawn NAME --from ghcr.io/you/img:tag --wait-ssh --output json` |
| Run a command in the guest, get JSON | `vm4a exec /path/to/bundle --output json -- python3 -c 'print(1+1)'` |
| Copy a file host→guest | `vm4a cp /path/to/bundle ./local.txt :/work/remote.txt` |
| Copy a file guest→host | `vm4a cp /path/to/bundle :/var/log/syslog ./syslog.txt` |
| Fork a bundle, auto-start, wait for SSH | `vm4a fork SRC DST --auto-start --from-snapshot clean.vzstate --wait-ssh` |
| Reset to a saved snapshot for retry | `vm4a reset /path/to/bundle --from clean.vzstate --wait-ip` |

**Classic lifecycle:**

| Intent | Command |
| --- | --- |
| Create a Linux VM bundle | `vm4a create NAME [--image ISO.iso] [--network bridged --bridged-interface en0] [--rosetta]` |
| List bundles in a directory | `vm4a list --storage /tmp/vm4a [--output json]` |
| Start a VM in the background | `vm4a run /path/to/bundle` |
| Start in foreground (logs to stdout) | `vm4a run /path/to/bundle --foreground` |
| Boot macOS recovery | `vm4a run /path/to/bundle --recovery` |
| Restore from a VZ snapshot (macOS 14+) | `vm4a run /path/to/bundle --restore state.vzstate` |
| Save state on clean shutdown (macOS 14+) | `vm4a run /path/to/bundle --save-on-stop state.vzstate` |
| Stop a VM (SIGTERM, then SIGKILL if stuck) | `vm4a stop /path/to/bundle --timeout 20` |
| Clone a bundle (APFS clonefile when possible) | `vm4a clone SRC DST` |
| Show Linux ARM64 ISO catalog | `vm4a image list` |
| Show host bridged interfaces | `vm4a network list` |
| Look up VM's NAT IP | `vm4a ip /path/to/bundle [--output json]` |
| SSH into running VM (NAT) | `vm4a ssh /path/to/bundle --user root` |
| Push bundle to OCI registry | `vm4a push /path/to/bundle ghcr.io/you/name:tag` |
| Pull bundle from OCI registry | `vm4a pull ghcr.io/you/name:tag --storage /tmp/vm4a` |
| Check guest agent heartbeat | `vm4a agent status /path/to/bundle` |
| Ping guest agent | `vm4a agent ping /path/to/bundle` |
| Run as MCP server (stdio JSON-RPC) | `vm4a mcp` |
| Run HTTP API server on localhost | `vm4a serve --port 7777` |
| Tag operations into a session for replay/inspection | `vm4a exec ... --session run-42` |
| List/show recorded sessions | `vm4a session list`, `vm4a session show <id>` |
| Define a per-task spawn template | `vm4a pool create py --base /path/to/golden --snapshot clean.vzstate` |
| Mint a fresh task VM from a pool | `vm4a pool spawn py --wait-ssh` |

## Key workflows

### Agent loop (recommended — uses v2 primitives)

```bash
# 1. First-time bootstrap: pull, start (arm save-on-stop), wait for SSH.
vm4a spawn dev --from ghcr.io/yourorg/python-dev-arm64:latest \
  --storage /tmp/vm4a \
  --save-on-stop /tmp/vm4a/dev/clean.vzstate \
  --wait-ssh --output json

# 2. Install whatever, then stop — VM saves state on shutdown.
vm4a exec /tmp/vm4a/dev -- bash -lc "apt-get install -y ripgrep"
vm4a stop /tmp/vm4a/dev

# 3. Per-task: fork the golden bundle, push code, run, parse JSON.
vm4a fork /tmp/vm4a/dev /tmp/vm4a/task-$JOB_ID \
  --auto-start --from-snapshot /tmp/vm4a/dev/clean.vzstate --wait-ssh
vm4a cp   /tmp/vm4a/task-$JOB_ID ./step.py :/work/step.py
vm4a exec /tmp/vm4a/task-$JOB_ID --output json --timeout 120 \
  -- python3 /work/step.py

# 4. Bad task state? Reset back to the snapshot in <1s.
vm4a reset /tmp/vm4a/task-$JOB_ID --from /tmp/vm4a/dev/clean.vzstate --wait-ip
```

### Spin up a disposable Ubuntu VM (manual / classic flow)

```bash
ISO=~/Downloads/ubuntu-24.04-live-server-arm64.iso
vm4a create demo --storage /tmp/vm4a --image "$ISO" \
  --cpu 4 --memory-gb 8 --disk-gb 64
vm4a run /tmp/vm4a/demo
vm4a ip /tmp/vm4a/demo       # needs VM to have booted + DHCP'd
vm4a ssh /tmp/vm4a/demo      # after cloud-init / user setup
vm4a stop /tmp/vm4a/demo
```

### Distribute a pre-baked VM through GHCR

```bash
# Push (requires a PAT with write:packages)
export VM4A_REGISTRY_USER=youruser
export VM4A_REGISTRY_PASSWORD=ghp_xxx
vm4a push /tmp/vm4a/base-ubuntu ghcr.io/youruser/base-ubuntu:24.04

# Pull on another machine (anonymous if package is public)
vm4a pull ghcr.io/youruser/base-ubuntu:24.04 --storage /tmp/vm4a
vm4a run /tmp/vm4a/base-ubuntu
```

### Fast fork of a golden image for CI

```bash
vm4a clone /tmp/vm4a/golden /tmp/vm4a/job-$CI_JOB_ID
vm4a run   /tmp/vm4a/job-$CI_JOB_ID
trap "vm4a stop /tmp/vm4a/job-$CI_JOB_ID && rm -rf /tmp/vm4a/job-$CI_JOB_ID" EXIT
```

`clone` uses APFS `clonefile(2)` on the same volume so it's O(directory
entries), not O(disk image size).

## Non-obvious behaviors

- **NAT IP only** works for VMs using the default NAT attachment. Bridged
  VMs don't land in `/var/db/dhcpd_leases`; users must pass `--host <ip>` to
  `vm4a ssh` or use their router's DHCP view.
- **`--rosetta` is Linux only** and requires
  `softwareupdate --install-rosetta --agree-to-license` before first run.
  The CLI warns but doesn't block.
- **The CLI is Linux-only.** macOS guests would need interactive Setup
  Assistant + a manual Remote Login toggle, neither of which can be
  driven headlessly. If the user asks for a macOS VM, redirect them
  to open `VM4A.app` → `File > New macOS VM` (the SwiftUI app handles
  that flow). The CLI's `create` and `spawn` no longer accept `--os`.
- **Config JSON format** starts at `schemaVersion: 1`. Old bundles without
  the field still load — tolerant decoding treats missing as 1. When
  adding new fields, make them optional in Core.swift decoding.
- **`vm4a stop` requires a running pid.** If `vm4a list` shows `stopped`
  but stale files exist, just re-run `vm4a run`; the CLI cleans stale
  PID files on the next list.
- **`--output json` is available on `create`, `list`, `ip`, `agent status`,
  and on every v2 primitive (`spawn`, `exec`, `cp`, `fork`, `reset`).**
  Output is one JSON object/array per command invocation (not JSONL).
- **`vm4a exec` returns JSON with `exit_code`, `stdout`, `stderr`,
  `duration_ms`, `timed_out`.** The exit code is also the process exit code
  (so `if vm4a exec ... ; then ...` works in shell). With `--timeout` and a
  timed-out command, the agent gets `timed_out: true` and a non-zero exit.
- **`vm4a cp` uses `:` to mark guest paths**, not `host:` like docker cp. So
  `./local.txt :/work/file.txt` is host→guest. Both sides being host or
  both being guest is rejected.
- **`vm4a fork` re-randomises `MachineIdentifier` automatically.** Don't
  hand-roll a clone+identity flow — `fork` is what `clone` should have been
  for agent loops, with optional `--auto-start` and `--from-snapshot`.
- **`vm4a reset` requires a `.vzstate` file**, which means macOS 14+. On
  older hosts the agent has to fall back to `clone` + reinstall.
- **Guest agent is a scaffold.** Only `ping` is implemented. Don't promise
  clipboard/shutdown/script execution yet.

## Error exit codes (for scripting)

```
1  VM4AError.message          Generic failure (legacy path)
2  VM4AError.notFound         Bundle or file missing
3  VM4AError.alreadyExists    Destination already exists
4  VM4AError.invalidState     VM running when it should be stopped (or vice versa)
5  VM4AError.hostUnsupported  macOS version / hardware capability missing
5  VM4AError.rosettaNotInstalled
```

## When the user is stuck

- `run` silently exits: check `.vm4a-run.log` in the bundle root.
- "No bridged interfaces available": CLI is not signed with
  `com.apple.vm.networking`. Re-run the codesign command from the top.
- "Rosetta is not supported on this host": CPU doesn't expose VMX for
  Rosetta translation. Not fixable in software.
- `push` returns HTTP 401: set `VM4A_REGISTRY_USER` / `VM4A_REGISTRY_PASSWORD`
  (a PAT for GHCR, a Docker token for Docker Hub).
- `ssh` hangs: VM hasn't DHCP'd yet (`vm4a ip` returns empty). Wait 10-30s
  after `vm4a run` for first-boot initialization.

## When NOT to use the CLI

Redirect to the GUI app for:
- Anything to do with macOS *guests* (CLI is Linux-only; the GUI app handles macOS guest install end-to-end)
- Changing graphics resolution / audio config (GUI has device editors)
- First-time users who want a wizard

## What's new vs older guides

Most recent:

**v2.0 P1 — MCP server:**
- `mcp` (stdio JSON-RPC 2.0 server; register in `.mcp.json` to expose
  every primitive as an MCP tool to Claude Code / Cursor / Cline)

**v2.0 P0 — agent-first primitives:**
- `spawn` (one-shot create+start with optional `--from <oci-ref>`, `--wait-ssh`)
- `exec` (SSH-driven command runner with structured JSON return)
- `cp` (SCP host ↔ guest with `:` prefix convention)
- `fork` (clone + re-identify + optional auto-start with snapshot restore)
- `reset` (stop + restart from snapshot for retry loops)

For any agent / scripted flow, prefer these over the manual
`create` → `run` → `ssh` chain. They handle PID management,
snapshot wiring, and JSON output by default.

Earlier additions (still relevant):
- `push` / `pull` (OCI registry support, tart-style)
- `network list`, `image list` (host introspection)
- `ip`, `ssh` (NAT convenience)
- `agent status`, `agent ping` (guest-agent channel, scaffold)
- `create --rosetta`, `create --bridged-interface`
- `run --restore` / `run --save-on-stop` (macOS 14+ snapshots)
