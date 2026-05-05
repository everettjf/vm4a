# VM4A Cookbook

Recipe-driven guide organised by *what you want to do*. `Usage.md` is the per-command reference; this is "I have a goal, how do I get there".

> 中文：[Cookbook.zh-CN.md](Cookbook.zh-CN.md)

## Contents

- [Install](#install)
- [Command index](#command-index)
- [macOS vs Linux — capability differences](#macos-vs-linux--capability-differences)
- [macOS guest workflow](#macos-guest-workflow)
- [Linux guest workflow](#linux-guest-workflow)
- [Cross-cutting features (macOS / Linux)](#cross-cutting-features-macos--linux)
- [Exit codes](#exit-codes)
- [Troubleshooting](#troubleshooting)
- [At a glance](#at-a-glance)

---

## Install

```bash
brew tap everettjf/tap && brew install vm4a
```

Building from source **must** be followed by codesigning with the entitlements file (otherwise bridged networking and Rosetta silently fail):

```bash
git clone https://github.com/everettjf/vm4a.git
cd vm4a
swift build -c release
codesign --force --sign - \
    --entitlements Sources/VM4ACLI/VM4ACLI.entitlements \
    ./.build/release/vm4a
cp ./.build/release/vm4a /usr/local/bin/
```

**Host requirement:** Apple Silicon Mac, macOS 13+ (snapshots need macOS 14+).

---

## Command index

```
Agent primitives (v2.0 P0)
  vm4a spawn     One-shot create+start; optionally wait for IP/SSH
  vm4a exec      SSH into the VM, run a command, return JSON
  vm4a cp        Bidirectional SCP (':' prefix marks the guest path)
  vm4a fork      APFS clonefile a bundle, optionally auto-start
  vm4a reset     Stop + restart from a .vzstate snapshot

Agent integrations (v2.0 P1, v2.1)
  vm4a mcp       Stdio JSON-RPC 2.0 MCP server
  vm4a serve     Localhost HTTP REST API

Sessions + pools (v2.3, v2.4)
  vm4a session list/show         Inspect agent run sessions
  vm4a pool create/show/list     Manage pool definitions
  vm4a pool spawn                On-demand fork from a pool
  vm4a pool serve                Warm-pool daemon (keeps N idle)
  vm4a pool acquire/release      Millisecond-fast hand-out / return
  vm4a pool destroy              Remove a pool definition

Classic lifecycle
  vm4a create    Create a VM bundle (Linux from ISO, macOS from IPSW)
  vm4a list      List bundles in a directory
  vm4a run       Start a VM (background by default; --foreground attaches)
  vm4a stop      Stop (SIGTERM, then SIGKILL after timeout)
  vm4a clone     Clone a bundle (APFS clonefile when possible)

Images / network
  vm4a image list/pull/where     Catalog list / prefetch / cache directory
  vm4a network list              Host bridged interfaces available to VMs
  vm4a push                      Push a bundle to an OCI registry
  vm4a pull                      Pull a bundle from an OCI registry
  vm4a ip                        Resolve a NAT VM's IP from DHCP leases
  vm4a ssh                       SSH into a NAT VM
  vm4a agent status/ping         In-guest agent heartbeat (scaffold)
```

Every command supports `--output text|json`. `vm4a <cmd> --help` is the canonical reference.

---

## macOS vs Linux — capability differences

The CLI surface (`spawn` / `exec` / `cp` / `fork` / `reset` / `pool` / `session` / `push` / `pull` / `mcp` / `serve`) is identical on both OSes — that's by design. But **the underlying implementation and first-time costs really do differ**. Read this once before picking which to use.

### First-time create / install

| Aspect | Linux | macOS |
|---|---|---|
| Image type | ISO (~1–3 GB) | IPSW (~12–15 GB) |
| Catalog entries | 4 fixed distros (Ubuntu / Fedora / Debian / Alpine) | 1 sentinel `macos-latest` (resolved at fetch time via Apple) |
| `--image` if omitted | **Required** | **Optional** — auto-fetches `macos-latest` |
| Install mechanism | ISO attached as USB; guest runs its own installer | `vm4a` drives `VZMacOSInstaller` end-to-end |
| Install duration | minutes (autoinstall) to ~10 min | 10–20 min |
| **First boot** | **Fully headless** (cloud-init / autoinstall / preseed finishes everything) | **One manual step** — Setup Assistant must be clicked through |
| SSH bootstrap | distro images come with sshd on, or autoinstall enables it | **Manually** enable Remote Login (System Settings → General → Sharing) |
| Total bring-up cost | minutes, zero human input | 20–30 min, plus one human click-through |

### Runtime flags

| Aspect | Linux | macOS |
|---|---|---|
| `--rosetta` | ✅ Supported (virtiofs share + binfmt_misc) | ❌ Not applicable (macOS guest is already native ARM) |
| `--recovery` (run/spawn) | ❌ Not applicable (VZ EFI has no recovery) | ✅ Supported (`VZMacOSBootLoader.startUpFromMacOSRecoveryMode`) |
| Minimum memory | distro-dependent, often a few hundred MB | IPSW-dictated, typically ≥ 4 GB (Sequoia ≥ 8 GB) |
| Minimum disk | 5–10 GB suffices for most distros | IPSW-dictated, typically ≥ 60 GB |
| Default SSH user | `root` | Current host username (NSUserName) |

### Bundle file layout

| File | Linux | macOS |
|---|---|---|
| `config.json` / `state.json` / `Disk.img` | ✅ | ✅ |
| `MachineIdentifier` (VZ platform identity) | ✅ Generic | ✅ Mac |
| `NVRAM` (EFI variables) | ✅ | ❌ |
| `HardwareModel` (VZ hardware identity) | ❌ | ✅ |
| `AuxiliaryStorage` (OS boot data) | ❌ | ✅ |

### Identical features (zero difference)

The following commands behave **exactly the same** on Linux and macOS, provided your base bundle is ready (macOS = post-Setup-Assistant, Remote Login enabled):

- `vm4a run` / `stop` / `list` / `clone`
- `vm4a fork` / `reset` (including `--auto-start`, `--from-snapshot`, `--wait-ssh`)
- `vm4a exec` / `cp` / `ssh` / `ip`
- `vm4a push` / `pull` (OCI bundle format is OS-agnostic)
- All of `vm4a session`
- All of `vm4a pool` (`create/show/list/serve/spawn/acquire/release/destroy`)
- Network modes `--network none|nat|bridged|host`
- Snapshots `--save-on-stop` / `--restore` (host needs macOS 14+ in both cases)
- MCP server (`vm4a mcp`) — `os` is an optional spawn-tool input
- HTTP REST API (`vm4a serve`) — `os` is an optional `/v1/spawn` body field
- Python SDK — `client.spawn(os_="macOS")` or `os_="linux"`
- Sessions JSONL format
- Image cache (`~/.cache/vm4a/images/`)

### Templates (official)

| Template | OS | Rebuild path |
|---|---|---|
| `ubuntu-base` | Linux | CI rebuilds monthly, fully unattended |
| `python-dev` | Linux | CI rebuilds monthly, fully unattended |
| `xcode-dev` | macOS | Manual Setup Assistant once; `build.sh` automates the rest |

Downstream usage of templates is identical: `vm4a spawn dev --from <ref> --wait-ssh` — Setup Assistant was already done at template-build time, so the pull is plug-and-play.

### One-line takeaway

**Linux is fully automated; macOS needs one manual Setup Assistant click-through per fresh IPSW; from then on, all agent operations behave identically across both OSes.** Think of Setup Assistant as the "someone has to build the image once" step before `docker pull` — a one-time cost, not a recurring one.

---

## macOS guest workflow

> **One unavoidable manual step.** After `vm4a create --os macOS --image foo.ipsw` finishes (10–20 minutes), the VM boots into Apple's Setup Assistant on first run. Apple does not expose a scriptable skip path. After you click through it once per fresh IPSW, every other vm4a command works on the macOS bundle exactly like on Linux. Once you push the post-Setup bundle to GHCR, downstream `vm4a pull` skips Setup Assistant entirely.

### First run: install macOS from IPSW

```bash
# No --image: vm4a auto-fetches the latest IPSW Apple says is supported
vm4a create mac-base --os macOS \
    --storage /tmp/vm4a \
    --cpu 4 --memory-gb 8 --disk-gb 80

# Or use a local IPSW you've already downloaded
vm4a create mac-base --os macOS --image ~/Downloads/macos-15.ipsw \
    --storage /tmp/vm4a --cpu 4 --memory-gb 8 --disk-gb 80
```

vm4a calls `VZMacOSRestoreImage.fetchLatestSupported`, downloads to `~/.cache/vm4a/images/`, then drives `VZMacOSInstaller` end-to-end. Takes 10–20 minutes.

### One-time: Setup Assistant

Open VM4A.app, pick `mac-base` from the sidebar, click Run. In the framebuffer:
1. Pick region and keyboard
2. Skip Apple ID
3. **Create a user account** — note the username
4. Once at the desktop, **System Settings → General → Sharing → Remote Login: ON**
5. Close the VM window in VM4A.app

### Then: same as Linux

```bash
# Start
vm4a run /tmp/vm4a/mac-base

# Wait for IP / SSH (usually within 30 seconds)
vm4a ip /tmp/vm4a/mac-base
vm4a ssh /tmp/vm4a/mac-base --user youruser

# Run a command, get JSON back
vm4a exec /tmp/vm4a/mac-base --user youruser --output json -- xcodebuild -version
# → {"exit_code":0,"stdout":"Xcode …\n","stderr":"","duration_ms":234,"timed_out":false}

# Copy files
vm4a cp /tmp/vm4a/mac-base --user youruser ./Project.xcodeproj :/Users/youruser/Project.xcodeproj -r

# Save a clean-state snapshot (host needs macOS 14+)
vm4a stop /tmp/vm4a/mac-base
vm4a run /tmp/vm4a/mac-base --save-on-stop /tmp/vm4a/mac-base/clean.vzstate
sleep 60
vm4a stop /tmp/vm4a/mac-base   # save_on_stop saves clean.vzstate at shutdown
```

### Per-task fork (recommended agent pattern)

```bash
# APFS-clone the base, restore from snapshot, auto-start, wait for SSH
vm4a fork /tmp/vm4a/mac-base /tmp/vm4a/task-$JOB_ID \
    --auto-start \
    --from-snapshot /tmp/vm4a/mac-base/clean.vzstate \
    --wait-ssh \
    --ssh-user youruser

# Run code
vm4a exec /tmp/vm4a/task-$JOB_ID --user youruser --timeout 600 --output json \
    -- xcodebuild -scheme MyApp test

# Bad task state? Reset back to the snapshot in <1s
vm4a reset /tmp/vm4a/task-$JOB_ID --from /tmp/vm4a/mac-base/clean.vzstate --wait-ip

# Done
vm4a stop /tmp/vm4a/task-$JOB_ID
rm -rf /tmp/vm4a/task-$JOB_ID
```

### Push to a registry

```bash
export VM4A_REGISTRY_USER=yourname
export VM4A_REGISTRY_PASSWORD=ghp_xxx          # PAT with write:packages
vm4a push /tmp/vm4a/mac-base ghcr.io/yourorg/macos-xcode:15
```

### Pull on another machine — **Setup Assistant skipped**

```bash
# One command: pull, start, wait for SSH. Setup Assistant already done.
vm4a spawn dev --os macOS \
    --from ghcr.io/yourorg/macos-xcode:15 \
    --storage /tmp/vm4a --wait-ssh --ssh-user youruser

vm4a exec /tmp/vm4a/dev --user youruser -- xcodebuild -version
```

Or pull the curated `xcode-dev` template:

```bash
vm4a spawn dev --os macOS \
    --from ghcr.io/everettjf/vm4a-templates/xcode-dev:latest \
    --storage /tmp/vm4a --wait-ssh
```

---

## Linux guest workflow

Fully headless. No Setup Assistant, no human in the loop. Agents run end-to-end.

### Three "least typing" forms

```bash
# Catalog id (auto-downloaded to ~/.cache/vm4a/images/)
vm4a image list                                    # see available ids
vm4a create demo --image ubuntu-24.04-arm64 \
    --storage /tmp/vm4a --memory-gb 4

# Local ISO
vm4a create demo --image ~/Downloads/ubuntu.iso

# Any https URL
vm4a create demo --image https://cdimage.ubuntu.com/.../ubuntu.iso
```

### Start + install

First boot enters the ISO installer (or runs cloud-init / autoinstall unattended):

```bash
vm4a run /tmp/vm4a/demo            # background
vm4a run /tmp/vm4a/demo --foreground   # stream VZ logs
```

Once installed, IP + SSH:

```bash
vm4a ip /tmp/vm4a/demo                       # find IP
vm4a ssh /tmp/vm4a/demo --user ubuntu       # SSH
vm4a exec /tmp/vm4a/demo --user ubuntu -- whoami
```

### Recommended: pre-baked template + one spawn

```bash
vm4a spawn dev \
    --from ghcr.io/everettjf/vm4a-templates/python-dev:latest \
    --storage /tmp/vm4a --wait-ssh --output json
# → {"id":"vm-…","name":"dev","ip":"192.168.64.7","ssh_ready":true,…}

vm4a exec /tmp/vm4a/dev -- python3 -c 'print(1+1)'
```

### Agent loop (fork-per-task pattern)

```bash
# 1. Bake the base once
vm4a spawn dev --from ghcr.io/yourorg/python-dev:latest \
    --storage /tmp/vm4a \
    --save-on-stop /tmp/vm4a/dev/clean.vzstate \
    --wait-ssh

vm4a exec /tmp/vm4a/dev -- bash -lc 'apt-get install -y ripgrep'
vm4a stop /tmp/vm4a/dev          # snapshot saved at shutdown

# 2. Per task
JOB=task-$(date +%s)
vm4a fork /tmp/vm4a/dev "/tmp/vm4a/$JOB" \
    --auto-start --from-snapshot /tmp/vm4a/dev/clean.vzstate --wait-ssh

vm4a cp   "/tmp/vm4a/$JOB" ./step.py :/work/step.py
vm4a exec "/tmp/vm4a/$JOB" --output json --timeout 120 -- python3 /work/step.py

# 3. Roll back on failure (<1s)
vm4a reset "/tmp/vm4a/$JOB" --from /tmp/vm4a/dev/clean.vzstate --wait-ip

# 4. Cleanup
vm4a stop "/tmp/vm4a/$JOB" && rm -rf "/tmp/vm4a/$JOB"
```

### Network mode

```bash
vm4a create demo --image ubuntu-24.04-arm64 --network nat        # default
vm4a create demo --image ubuntu-24.04-arm64 --network none       # no NIC
vm4a create demo --image ubuntu-24.04-arm64 --network bridged \
    --bridged-interface en0                                       # bridged

vm4a network list                       # find bsdNames
```

In bridged mode `vm4a ip` returns nothing (no Apple DHCP lease); pass `vm4a ssh --host <ip>` directly.

### Rosetta (run x86 binaries inside the Linux guest)

```bash
softwareupdate --install-rosetta --agree-to-license
vm4a create dev --image ubuntu-24.04-arm64 --rosetta
```

Inside the guest, mount the virtiofs share named `rosetta` and register it with `binfmt_misc` ([Apple's guide](https://developer.apple.com/documentation/virtualization/running_intel_binaries_in_linux_vms_with_rosetta)).

---

## Cross-cutting features (macOS / Linux)

### Images and cache

| Command | Purpose |
|---|---|
| `vm4a image list` | List the catalog (Linux ISOs + macos-latest) |
| `vm4a image pull <id>` | Explicit prefetch to `~/.cache/vm4a/images/`; prints local path |
| `vm4a image where` | Print the cache directory + cached files |

`--image` accepts four forms: catalog id / local file path / `https://` URL / `macos-latest` (macOS only).

### OCI registry distribution

```bash
export VM4A_REGISTRY_USER=yourname
export VM4A_REGISTRY_PASSWORD=ghp_xxx     # PAT with write:packages

vm4a push /tmp/vm4a/dev ghcr.io/you/python-dev:24.04
vm4a pull ghcr.io/you/python-dev:24.04 --storage /tmp/vm4a
```

Bearer-token (GHCR-style) and HTTP Basic auth are both supported.

### Snapshots (host needs macOS 14+)

```bash
vm4a run /tmp/vm4a/demo --save-on-stop /tmp/vm4a/demo/state.vzstate
vm4a stop /tmp/vm4a/demo                  # saves state.vzstate on shutdown
vm4a run /tmp/vm4a/demo --restore /tmp/vm4a/demo/state.vzstate
```

`spawn` supports the same flags.

### Sessions (recording agent runs)

Pass `--session <id>` to any agent command and an event is appended to `<bundle>/.vm4a-sessions/<id>.jsonl`:

```bash
SID=run-$(date +%s)
vm4a fork /tmp/vm4a/dev /tmp/vm4a/task-1 --auto-start --wait-ssh --session $SID
vm4a exec /tmp/vm4a/task-1 --session $SID -- python3 /work/step.py

vm4a session list --bundle /tmp/vm4a/task-1
vm4a session show $SID --bundle /tmp/vm4a/task-1
# ✓ #1  …  fork dev → task-1 (started)
# ✓ #2  …  exec python3 → exit 0
```

Or use the SwiftUI timeline viewer:

```bash
swift run vm4a-sessions
```

### Pools (on-demand vs warm)

**On-demand** — fork once per acquire:

```bash
vm4a pool create py --base /tmp/vm4a/dev \
    --snapshot /tmp/vm4a/dev/clean.vzstate \
    --prefix task --storage /tmp/vm4a-tasks --size 0

vm4a pool spawn py --wait-ssh --output json   # equivalent to fork
```

**Warm** (millisecond hand-out) — daemon keeps N idle:

```bash
vm4a pool create py ... --size 4
vm4a pool serve py &                           # daemon

VM=$(vm4a pool acquire py --output json | jq -r .path)   # atomic mv
vm4a exec "$VM" -- python3 /work/step.py
vm4a pool release "$VM"                                  # daemon refills
```

### Agent integrations

#### MCP (Claude Code / Cursor / Cline)

`.mcp.json`:

```json
{ "mcpServers": { "vm4a": { "command": "vm4a", "args": ["mcp"] } } }
```

Exposes 8 tools (`spawn`/`exec`/`cp`/`fork`/`reset`/`list`/`ip`/`stop`) + resources `vm4a://vms`, `vm4a://sessions`, `vm4a://session/<id>`, `vm4a://pools` + three prompts (`agent-loop`, `debug-failed-task`, `triage-vm`).

#### HTTP API + Python SDK

```bash
vm4a serve --port 7777          # optional: export VM4A_AUTH_TOKEN=xxx
```

```python
from vm4a import Client
c = Client()
vm = c.spawn(name="dev", os_="macOS", wait_ssh=True)        # or os_="linux"
out = c.exec(vm.path, ["python3", "-c", "print(1+1)"])
```

Endpoints: `/v1/{health,spawn,exec,cp,fork,reset,vms,vms/ip,vms/stop}`. Body shapes match SpawnOptions / ExecOptions / etc.

---

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Generic failure |
| `2` | Bundle / file / interface not found |
| `3` | Destination already exists |
| `4` | VM in wrong state (running when shouldn't be, or vice versa) |
| `5` | Host capability missing / Rosetta not installed |

Branch on these directly without parsing stderr.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `run` exits silently | Check `<bundle>/.vm4a-run.log` |
| `network list` is empty | CLI not signed with `com.apple.vm.networking` |
| `vm4a ip` returns nothing | VM still booting / DHCP'ing — wait 10–30 s |
| `push` returns HTTP 401 | Set `VM4A_REGISTRY_USER` / `VM4A_REGISTRY_PASSWORD` |
| `--rosetta` says not installed | `softwareupdate --install-rosetta --agree-to-license` |
| Linux guest hangs at boot | Confirm ISO is ARM64; verify `MachineIdentifier` and `NVRAM` exist |
| macOS guest stays black after install | Expected — it's at Setup Assistant. Open in VM4A.app to interact |
| `vm4a exec /macos-vm` returns Connection refused | macOS guest hasn't enabled Remote Login. VM4A.app: System Settings → General → Sharing → Remote Login |
| Snapshot flags refused | Host needs macOS 14+ |
| Bridged VM has no `vm4a ip` result | Bridged doesn't use Apple's DHCP; pass `--host <ip>` |
| `vm4a serve` returns 401 | Client must send the same `VM4A_AUTH_TOKEN` |

---

## At a glance

```
                                                ┌──────────────────────┐
                                                │  ~/.cache/vm4a/      │
                                                │   images/<id>.iso    │
                                                │   images/<id>.ipsw   │
                                                └─────────▲────────────┘
                                                          │ auto-download + cache
                                                          │
  ┌────────────────────────────────────────────────────────────────────┐
  │                          vm4a CLI                                  │
  │                                                                    │
  │  Linux:  create/spawn --image ubuntu-24.04-arm64                   │
  │          → download ISO → install → run/exec/cp/fork/reset         │
  │                                                                    │
  │  macOS:  create/spawn --os macOS  (or --image foo.ipsw)            │
  │          → download IPSW → VZMacOSInstaller → ⚠ Setup Assistant 1× │
  │          → run/exec/cp/fork/reset (= same API as Linux)            │
  │                                                                    │
  │  After: push to GHCR → others spawn --from <ref>, no install cost  │
  └────────────────────────────────────────────────────────────────────┘
                  │              │              │
              MCP server   HTTP REST API   Python SDK
              (Claude     (vm4a serve)    (pip install vm4a)
              Code etc.)
```

**Bottom line:** Linux is fully automated; macOS needs one manual Setup Assistant click-through per fresh IPSW. Push the post-Setup bundle once, and from then on agent operations behave identically across both OSes.
