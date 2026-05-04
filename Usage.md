# Usage

How to actually drive `vm4a` — every command, every integration, with worked examples.

> 中文：[Usage.zh-CN.md](Usage.zh-CN.md)

## Contents

- [Quickstart](#quickstart)
- [The agent loop](#the-agent-loop)
- [Agent primitives](#agent-primitives) — `spawn`, `exec`, `cp`, `fork`, `reset`
- [Classic lifecycle](#classic-lifecycle) — `create`, `list`, `run`, `stop`, `clone`, `ip`, `ssh`
- [MCP — Claude Code, Cursor, Cline](#mcp-claude-code-cursor-cline)
- [HTTP API and Python SDK](#http-api-and-python-sdk)
- [Sessions — recording agent runs](#sessions-recording-agent-runs)
- [Pools — minting per-task VMs](#pools-minting-per-task-vms)
- [OCI templates and registries](#oci-templates-and-registries)
- [Networking](#networking)
- [Rosetta (x86 in Linux guests)](#rosetta-x86-in-linux-guests)
- [Snapshots (macOS 14+)](#snapshots-macos-14)
- [Bundle layout](#bundle-layout)
- [Exit codes](#exit-codes)
- [Troubleshooting](#troubleshooting)

---

## Quickstart

```bash
brew tap everettjf/tap && brew install vm4a
```

Three ways to get a VM running, in order of "least typing":

```bash
# 1. Pull a pre-baked image (fastest — no install cost)
vm4a spawn dev \
    --from ghcr.io/everettjf/vm4a-templates/python-dev:latest \
    --storage /tmp/vm4a --wait-ssh

# 2. Use a curated catalog id — vm4a downloads + caches the ISO/IPSW for you
vm4a create demo --image ubuntu-24.04-arm64 --storage /tmp/vm4a --memory-gb 4
vm4a create mac  --os macOS                  # auto-fetches latest macOS IPSW

# 3. Pass a local path or any https URL — also auto-cached
vm4a create demo --image ~/Downloads/ubuntu-24.04-arm64.iso
vm4a create demo --image https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04.1-live-server-arm64.iso

vm4a exec /tmp/vm4a/dev -- python3 -c 'print(1+1)'
vm4a stop /tmp/vm4a/dev
```

`vm4a image list` shows what catalog ids exist; `vm4a image pull <id>` prefetches without creating a VM; `vm4a image where` prints the cache directory (`~/.cache/vm4a/images/`).

Every command supports `--output json` for machine-readable output. The `--help` of any subcommand is the canonical reference for its options.

---

## The agent loop

Most agent flows fit one of two shapes. **Disposable per-task VM** is the recommended pattern — a golden bundle plus an APFS-cloned fork per task:

```bash
# 1. First run: pull the base image, install whatever tooling, save a clean snapshot.
vm4a spawn dev \
    --from ghcr.io/yourorg/python-dev-arm64:latest \
    --storage /tmp/vm4a \
    --save-on-stop /tmp/vm4a/dev/clean.vzstate \
    --wait-ssh --output json

vm4a exec /tmp/vm4a/dev -- bash -lc "apt-get install -y ripgrep"
vm4a stop /tmp/vm4a/dev          # save_on_stop saves the .vzstate during shutdown

# 2. Per-task: APFS-clone the bundle, restart from the snapshot, run code, throw away.
JOB_ID="task-$(date +%s)"
vm4a fork /tmp/vm4a/dev "/tmp/vm4a/$JOB_ID" \
    --auto-start --from-snapshot /tmp/vm4a/dev/clean.vzstate --wait-ssh

vm4a cp   "/tmp/vm4a/$JOB_ID" ./step.py :/work/step.py
vm4a exec "/tmp/vm4a/$JOB_ID" --output json --timeout 120 -- python3 /work/step.py
# → {"exit_code":0,"stdout":"…","stderr":"","duration_ms":3142,"timed_out":false}

# 3. Bad task state? Reset back to the snapshot in <1s.
vm4a reset "/tmp/vm4a/$JOB_ID" --from /tmp/vm4a/dev/clean.vzstate --wait-ip

# 4. Done. Stop and remove.
vm4a stop "/tmp/vm4a/$JOB_ID"
rm -rf "/tmp/vm4a/$JOB_ID"
```

`fork` uses APFS `clonefile(2)` — creating a per-task VM is **O(directory entries), not O(disk image size)**. Combined with `--from-snapshot`, agents go from "I want a clean machine" to "VM is up and SSH-ready" in roughly a second.

The other shape — **long-lived persistent VM** — is just `vm4a spawn` once, then `vm4a exec` repeatedly. Use this when state must accumulate across tasks (e.g. an interactive Jupyter session).

---

## Agent primitives

### spawn — create+start in one call

```
vm4a spawn <name> [--os linux|macOS] [--storage <dir>]
                  (--from <oci-ref> | --image <iso-or-ipsw>)
                  [--cpu <n>] [--memory-gb <n>] [--disk-gb <n>]
                  [--bridged-interface <bsdName>] [--rosetta]
                  [--restore <state.vzstate>] [--save-on-stop <state.vzstate>]
                  [--wait-ip] [--wait-ssh]
                  [--ssh-user <name>] [--ssh-key <path>]
                  [--host <ip>] [--wait-timeout <seconds>]
                  [--output text|json] [--session <id>]
```

Behavior:
- If `<storage>/<name>` exists, just (re)start it.
- Else `--from <oci-ref>` pulls a bundle, or `--image <iso/ipsw>` creates from scratch.
- `--wait-ssh` (implies `--wait-ip`) blocks until SSH responds or the timeout elapses.
- With `--output json`, returns `{id, name, path, os, pid, ip, ssh_ready}` — one allocation for an agent.

### exec — run a command via SSH

```
vm4a exec <vm-path> [--user <name>] [--key <path>] [--host <ip>]
                    [--timeout <seconds>] [--output text|json]
                    [--session <id>] -- <command...>
```

Default user is `root` (Linux) or the current user (macOS). Without `--output json`, stdout/stderr stream and the exit code becomes this process's exit code. With `--output json`, returns `{exit_code, stdout, stderr, duration_ms, timed_out}`.

```bash
vm4a exec /tmp/vm4a/dev -- python3 -c 'print(1+1)'
vm4a exec /tmp/vm4a/dev --output json --timeout 30 -- bash -lc 'pip install numpy'
```

### cp — bidirectional SCP

```
vm4a cp <vm-path> [-r] [--user <name>] [--key <path>] [--host <ip>]
                  [--timeout <seconds>] [--output text|json]
                  [--session <id>] <source> <destination>
```

Path convention: a leading `:` marks the guest side; otherwise it's a host path. Exactly one side must be guest.

```bash
vm4a cp /tmp/vm4a/dev ./local.py :/work/script.py        # host → guest
vm4a cp /tmp/vm4a/dev :/var/log/syslog ./syslog.txt      # guest → host
vm4a cp /tmp/vm4a/dev -r ./project :/srv/code            # recursive
```

### fork — APFS clone + optional auto-start

```
vm4a fork <source-path> <destination-path>
          [--auto-start] [--from-snapshot <state.vzstate>]
          [--wait-ip] [--wait-ssh]
          [--ssh-user <name>] [--ssh-key <path>]
          [--wait-timeout <seconds>]
          [--output text|json] [--session <id>]
```

`fork` is what `clone` should have been for agent loops — it APFS-clonefiles the bundle, re-randomises `MachineIdentifier` so the fork boots as a distinct host, and (with `--auto-start`) starts the worker immediately.

### reset — stop and restart from a snapshot

```
vm4a reset <vm-path> --from <state.vzstate>
           [--wait-ip] [--stop-timeout <seconds>] [--wait-timeout <seconds>]
           [--output text|json] [--session <id>]
```

For try → fail → reset → retry agent loops. Stops the VM (SIGTERM → SIGKILL) and restarts it from the supplied `.vzstate`. Requires macOS 14+ and a previously saved snapshot (see `--save-on-stop` on `run` and `spawn`).

---

## Classic lifecycle

| Command | What it does |
|---|---|
| `vm4a create <name> [--os linux\|macOS] [--image <path>] [...]` | Create a VM bundle. Linux from ISO; macOS from IPSW (drives full install). |
| `vm4a list [--storage <dir>]` | List bundles in a directory with status, pid, IP. |
| `vm4a run <vm-path> [--foreground]` | Start a VM in the background (default) or attached. |
| `vm4a stop <vm-path> [--timeout <s>]` | Send SIGTERM, escalate to SIGKILL if needed. |
| `vm4a clone <src> <dst>` | APFS-clonefile a bundle. (`fork` is the agent-friendly equivalent.) |
| `vm4a network list` | Enumerate host bridged interfaces. |
| `vm4a image list` | Curated list of Linux ARM64 ISO URLs. |
| `vm4a push <vm> <ref>` | Push a bundle to an OCI registry. |
| `vm4a pull <ref> [--storage <dir>]` | Pull a bundle from an OCI registry. |
| `vm4a ip <vm>` | Resolve a NAT VM's IP from Apple's DHCP leases. |
| `vm4a ssh <vm> [--user <name>] -- <ssh args>` | SSH in, with arguments after `--` passed through. |

`run` defaults to a detached worker — the shell returns immediately and logs go to `<vm>/.vm4a-run.log`. Use `--foreground` to stream VZ output directly. For macOS guests, the first run after `vm4a create --os macOS --image foo.ipsw` boots into Setup Assistant; complete that interactively in VM4A.app once, then enable Remote Login (System Settings → General → Sharing) so subsequent vm4a commands can SSH in.

---

## MCP — Claude Code, Cursor, Cline

Register `vm4a` as an MCP server and the assistant gets every agent primitive as a callable tool — no glue code, no shell-out wrapping.

**Claude Code** — add to `.mcp.json` at project or user level:

```json
{
  "mcpServers": {
    "vm4a": { "command": "vm4a", "args": ["mcp"] }
  }
}
```

**Cursor** — same JSON to `~/.cursor/mcp.json`. **Cline** — paste into the Cline settings panel under "MCP Servers".

The server speaks JSON-RPC 2.0 framed by newlines (standard MCP stdio transport, protocol version `2024-11-05`). Eight tools are exposed:

| Tool | Returns |
|---|---|
| `spawn` | `{id, name, path, os, pid, ip, ssh_ready}` |
| `exec` | `{exit_code, stdout, stderr, duration_ms, timed_out}` |
| `cp` | Same shape as `exec` |
| `fork` | `{path, name, started, pid, ip}` |
| `reset` | `{path, restored, pid, ip}` |
| `list` | Array of `{id, name, path, os, status, pid, ip}` |
| `ip` | Array of `{ip, mac, name?}` |
| `stop` | `{stopped, pid, forced, reason?}` |

Manually inspect the catalog:

```bash
printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n' | vm4a mcp
```

In addition to tools, the server exposes:

**Resources** — read-only views of vm4a state:

| URI | Returns |
|---|---|
| `vm4a://vms?storage=/path` | VM bundles in a directory (defaults to cwd) |
| `vm4a://sessions?bundle=/path` | Recorded sessions discoverable from a bundle + `~/.vm4a/sessions` |
| `vm4a://session/<id>?bundle=/path` | Every JSONL event in a specific session |
| `vm4a://pools` | All saved pool definitions |

**Prompts** — canned templates the AI client can invoke:

| Prompt | Arguments | Purpose |
|---|---|---|
| `agent-loop` | `image`, `task_command` | Idiomatic spawn → fork → exec → reset pattern |
| `debug-failed-task` | `session_id`, `bundle_path?` | Triage a recorded session, identify the first failure, suggest a fix |
| `triage-vm` | `vm_path` | Quick VM health check (uptime, disk, memory, dmesg) |

---

## HTTP API and Python SDK

For non-MCP clients (CI runners, custom Python harnesses, language bindings beyond Python), `vm4a` exposes the same operations as a localhost HTTP server.

```bash
# Server
vm4a serve --port 7777
# Optional bearer auth: export VM4A_AUTH_TOKEN=... before starting
```

| Endpoint | Body | Returns |
|---|---|---|
| `GET /v1/health` | — | `{status, version}` |
| `POST /v1/spawn` | SpawnOptions JSON | SpawnOutcome |
| `POST /v1/exec` | `{vm_path, command, ...}` | ExecResult |
| `POST /v1/cp` | `{vm_path, source, destination, ...}` | ExecResult |
| `POST /v1/fork` | `{source_path, destination_path, ...}` | ForkOutcome |
| `POST /v1/reset` | `{vm_path, from, ...}` | ResetOutcome |
| `GET /v1/vms` | `?storage=/path` | `[VMSummary]` |
| `GET /v1/vms/ip` | `?path=/bundle` | `[Lease]` |
| `POST /v1/vms/stop` | `{vm_path, timeout?}` | StopOutcome |

The Python SDK ([`sdk/python/`](sdk/python/)) is a stdlib-only wrapper (no `requests`/`httpx`):

```python
from vm4a import Client

c = Client()  # http://127.0.0.1:7777
vm = c.spawn(name="dev", from_="ghcr.io/yourorg/python-dev:latest", wait_ssh=True)
out = c.exec(vm.path, ["python3", "-c", "print(1+1)"])
print(out.exit_code, out.stdout)
```

`pip install vm4a` once it's published; before that, run from source via `PYTHONPATH=sdk/python/src`.

---

## Sessions — recording agent runs

Pass `--session <id>` to any of `spawn` / `exec` / `cp` / `fork` / `reset` and `vm4a` appends a JSONL event to `<bundle>/.vm4a-sessions/<id>.jsonl`. Each event is `{seq, timestamp, kind, vmPath, success, durationMs, summary, args, outcome}`.

```bash
SID="run-$(date +%s)"
vm4a fork /tmp/vm4a/dev /tmp/vm4a/task-1 \
    --auto-start --from-snapshot /tmp/vm4a/dev/clean.vzstate \
    --wait-ssh --session $SID
vm4a exec /tmp/vm4a/task-1 --session $SID -- python3 /work/step.py

vm4a session show $SID --bundle /tmp/vm4a/task-1
# ✓ #1  2026-05-03T19:45:00Z  3142ms  fork /tmp/vm4a/dev → /tmp/vm4a/task-1 (started)
# ✓ #2  2026-05-03T19:45:08Z   712ms  exec python3 → exit 0

vm4a session list --bundle /tmp/vm4a/task-1
```

The events are append-only JSONL; you can `tail -f` the file during a long run.

For a graphical timeline view, run `vm4a-sessions` (built alongside `vm4a`):

```bash
swift run vm4a-sessions       # or: ./.build/release/vm4a-sessions
```

A SwiftUI window opens listing every discovered session in the sidebar; clicking one shows the events as a timeline with expandable args/outcome panels. Cmd-R refreshes after a fresh agent run.

> Today the CLI only writes events on the success path. A throwing call leaves no log entry — set things up so a missing session file means "the agent didn't reach the recorder", not "everything succeeded".

---

## Pools — minting per-task VMs

Define how to mint a fresh per-task VM once, then call `pool spawn` per task:

```bash
# Once, after your golden VM is set up:
vm4a pool create py \
    --base /tmp/vm4a/python-dev \
    --snapshot /tmp/vm4a/python-dev/clean.vzstate \
    --prefix task --storage /tmp/vm4a-tasks

# Per task:
vm4a pool spawn py --wait-ssh
# → mints /tmp/vm4a-tasks/task-<unix-timestamp>
```

Definitions are stored as JSON at `~/.vm4a/pools/<name>.json`. Inspect or remove:

```bash
vm4a pool list
vm4a pool show py
vm4a pool destroy py
```

For latency-sensitive workloads, run a warm-pool daemon. It keeps `--size N` VMs idle and ready, refills on consumption, and `pool acquire` is an atomic filesystem rename — millisecond-fast hand-out:

```bash
# Create a sized pool definition
vm4a pool create py \
    --base /tmp/vm4a/python-dev \
    --snapshot /tmp/vm4a/python-dev/clean.vzstate \
    --prefix task --storage /tmp/vm4a-tasks \
    --size 4

# Run the daemon (foreground; restart-safe — picks up existing warm VMs)
vm4a pool serve py &

# Per task: acquire (instant), exec, release
VM=$(vm4a pool acquire py --output json | jq -r .path)
vm4a exec "$VM" -- python3 /work/step.py
vm4a pool release "$VM"
```

Layout on disk:
- `<storage>/<prefix>-warm-<n>` — idle, owned by the daemon, ready to hand out
- `<storage>/<prefix>-leased-<label>` — claimed; agent owns it until `release`

`pool spawn <name>` is the on-demand path (no daemon, equivalent to `fork --auto-start`); `pool acquire/release` is the warm path. Mix freely depending on what each workload needs.

---

## OCI templates and registries

Pre-baked bundles live at `ghcr.io/everettjf/vm4a-templates/*`:

| Template | Pull |
|---|---|
| `ubuntu-base` | `ghcr.io/everettjf/vm4a-templates/ubuntu-base:24.04` |
| `python-dev` | `ghcr.io/everettjf/vm4a-templates/python-dev:latest` |
| `xcode-dev` (macOS, post-Setup-Assistant) | `ghcr.io/everettjf/vm4a-templates/xcode-dev:latest` |

Build scripts and the CI pipeline that rebuilds them monthly live in [`templates/`](templates/).

Bundles pack into a single `tar.gz` layer (media type `application/vnd.vm4a.bundle.v1.tar+gzip`) plus a JSON config blob. Any Docker Registry v2 compatible registry works (GHCR, Docker Hub, ECR, Harbor, in-house).

```bash
# Authenticated push (GHCR example)
export VM4A_REGISTRY_USER=yourname
export VM4A_REGISTRY_PASSWORD=ghp_xxx     # PAT with write:packages
vm4a push /tmp/vm4a/my-vm ghcr.io/yourname/my-vm:v1

# Public pull (no credentials needed)
vm4a pull ghcr.io/someone/ubuntu-arm:24.04 --storage /tmp/vm4a
```

Bearer-token (GHCR-style) and HTTP Basic auth are both supported.

---

## Networking

`--network <mode>` selects how the VM gets a NIC. Valid modes:

| Mode | What it does |
|---|---|
| `nat` (default) | NAT on `192.168.64.0/24`, look up IP with `vm4a ip` |
| `bridged` | VM gets an IP from your LAN's DHCP. Pair with `--bridged-interface <bsdName>`; if omitted, the first available interface is used. |
| `host` | Alias for `bridged` (VZ has no separate host-networking mode) |
| `none` | No NIC at all. Use this for offline workloads or where the agent only needs filesystem I/O. |

```bash
vm4a network list                              # find bsdNames
vm4a spawn web --image ubuntu-arm64.iso --network bridged --bridged-interface en0
vm4a spawn airgap --image ubuntu-arm64.iso --network none
```

Bridged mode requires the CLI carry `com.apple.vm.networking`. The bundled entitlement file has it — re-run the codesign step from [Install](README.md#install) if you change binaries. For bridged VMs, `vm4a ip` returns nothing (no Apple DHCP lease); pass `--host <ip>` to `ssh`/`exec`/`cp` directly. For `none` mode, host ↔ guest communication has to go through `cp` over… nothing — there's no SSH; this mode is mostly useful for boot-only validation or workloads that talk through virtiofs only.

> Back-compat: passing `--bridged-interface en0` without `--network` still implies bridged mode, matching the old CLI surface.

---

## Rosetta (x86 in Linux guests)

```bash
softwareupdate --install-rosetta --agree-to-license
vm4a create linux-dev --rosetta --image ubuntu-arm64.iso …
```

Inside the guest, mount the virtiofs share named `rosetta` and register it with `binfmt_misc`. Apple's [official guide](https://developer.apple.com/documentation/virtualization/running_intel_binaries_in_linux_vms_with_rosetta) walks through the in-guest steps.

---

## Snapshots (macOS 14+)

Save and restore the VM's full execution state, not just disk:

```bash
vm4a run  /tmp/vm4a/demo --save-on-stop /tmp/vm4a/demo/state.vzstate
vm4a stop /tmp/vm4a/demo                       # pauses + saves on exit

vm4a run  /tmp/vm4a/demo --restore /tmp/vm4a/demo/state.vzstate
```

`spawn` accepts the same `--save-on-stop` and `--restore` flags so a single command both starts and arms snapshot saving.

For agent loops: save once after first boot, then every task starts in <1s instead of paying boot cost.

---

## Bundle layout

```
demo/
├── config.json           # device/CPU/memory config (schemaVersion: 1)
├── state.json            # runtime state pointer
├── Disk.img              # raw disk
├── MachineIdentifier     # VZ platform identity
├── NVRAM                 # (Linux) EFI variable store
├── HardwareModel         # (macOS) VZ hardware identity
├── AuxiliaryStorage      # (macOS) OS boot bits
├── console.log           # (Linux) serial console log, rotated each run
├── .vm4a-run.pid         # worker pid while running
├── .vm4a-run.log         # detached worker stdout+stderr
├── .vm4a-sessions/       # one <session-id>.jsonl per recorded session
└── guest-agent/          # virtiofs rendezvous for the optional guest agent
```

A bundle made by the CLI runs in the GUI and vice versa.

---

## Exit codes

| Code | Case | Meaning |
|---|---|---|
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
|---|---|
| `run` exits silently | Check `<bundle>/.vm4a-run.log` |
| `network list` is empty | CLI not signed with `com.apple.vm.networking` |
| `ssh` / `ip` returns nothing | VM still booting / DHCP'ing — wait 10–30 s |
| `push` returns HTTP 401 | Set `VM4A_REGISTRY_USER` / `VM4A_REGISTRY_PASSWORD` |
| `--rosetta` fails with "not installed" | `softwareupdate --install-rosetta --agree-to-license` |
| Linux guest hangs at boot | Confirm ISO is ARM64; verify `MachineIdentifier` and `NVRAM` exist |
| macOS guest stays black after install | Expected — it's at Setup Assistant. Open in VM4A.app to interact. |
| `vm4a exec /macos-vm` returns "Connection refused" | macOS guest hasn't enabled Remote Login yet. Open in VM4A.app: System Settings → General → Sharing → Remote Login. |
| Snapshot flags refused | Requires macOS 14+ host |
| `vm4a serve` returns 401 | Set the same `VM4A_AUTH_TOKEN` on the client |
| Bridged VM has no IP via `vm4a ip` | Bridged mode doesn't use Apple's DHCP server; pass `--host <ip>` |
