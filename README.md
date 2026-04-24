# EasyVM

**EasyVM is a macOS virtualization suite for Apple Silicon, built on Apple's [Virtualization framework](https://developer.apple.com/documentation/virtualization).** One install gives you:

- 🖱 **EasyVM.app** — a SwiftUI app for point-and-click VM management.
- ⌨️ **`easyvm` CLI** — a single-binary CLI for scripting, CI, and batch operations.
- 📦 **OCI-compatible distribution** — push/pull VM images like container images (any Docker Registry v2 host: GHCR, Docker Hub, ECR, Harbor, …).

The app and the CLI share one core (`EasyVMCore`). A VM bundle produced by either runs unchanged in the other.

> 中文文档：[README.zh-CN.md](README.zh-CN.md)

[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)](https://www.apple.com/macos)
[![Discord](https://img.shields.io/badge/Discord-Join%20Chat-7289DA)](https://discord.gg/uxuy3vVtWs)

---

## How to use — pick a path

### Path A · GUI (easiest, best for first-timers)

```bash
brew tap everettjf/tap
brew install --cask easyvm
open -a EasyVM
```

Then in the app: **File → New VM → pick macOS or Linux → follow the wizard.**

### Path B · CLI (best for automation, CI, scripting)

```bash
# 1. Install
brew install everettjf/tap/easyvm   # or build from source, see below

# 2. Create and run a Linux VM
easyvm create demo --os linux --storage /tmp/easyvm \
  --image ~/Downloads/ubuntu-24.04-arm64.iso \
  --cpu 4 --memory-gb 8 --disk-gb 64
easyvm run /tmp/easyvm/demo

# 3. Talk to it (after the guest finishes boot + DHCP)
easyvm ip  /tmp/easyvm/demo
easyvm ssh /tmp/easyvm/demo --user ubuntu

# 4. Clean up
easyvm stop /tmp/easyvm/demo
```

### Path C · Pull a pre-built VM from a registry

```bash
easyvm pull ghcr.io/someone/ubuntu-arm:24.04 --storage /tmp/easyvm
easyvm run  /tmp/easyvm/ubuntu-arm
```

Both Path A and Path B produce the same on-disk bundle layout. You can create a VM in the CLI and open it in the app, or vice versa.

---

## Table of Contents

- [What's in the box](#whats-in-the-box)
- [Requirements](#requirements)
- [Installation](#installation)
- [GUI usage](#gui-usage)
- [CLI reference](#cli-reference)
- [Distribution via OCI registries](#distribution-via-oci-registries)
- [Networking](#networking)
- [Rosetta (x86 binaries in Linux guests)](#rosetta-x86-binaries-in-linux-guests)
- [Snapshots (macOS 14+)](#snapshots-macos-14)
- [Guest agent (scaffold)](#guest-agent-scaffold)
- [Architecture](#architecture)
- [Exit codes](#exit-codes)
- [Troubleshooting](#troubleshooting)
- [Homebrew release workflow](#homebrew-release-workflow)
- [Contributing](#contributing)
- [License](#license)

---

## What's in the box

| Component | Location | Purpose |
| --- | --- | --- |
| `EasyVM.app` | `EasyVM/EasyVM.xcodeproj` | SwiftUI GUI for creating, running, and editing VMs |
| `easyvm` | `Sources/EasyVMCLI` | CLI: lifecycle, OCI push/pull, SSH, snapshots, agent |
| `easyvm-guest` | `Sources/EasyVMGuest` | Agent that runs **inside** a macOS guest (scaffold) |
| `EasyVMCore` | `Sources/EasyVMCore` | Shared Swift library — models, VZ configuration, OCI, networking |

A VM bundle is a directory that looks like this:

```
demo/
├── config.json           # device/memory/CPU config (with schemaVersion)
├── state.json            # runtime state pointer
├── Disk.img              # qcow-less raw disk
├── MachineIdentifier     # VZ platform identity
├── NVRAM                 # (Linux) EFI variable store
├── HardwareModel         # (macOS) VZ hardware identity
├── AuxiliaryStorage      # (macOS) OS boot bits
├── console.log           # (Linux) serial console log, rotated on each run
└── guest-agent/          # virtiofs rendezvous for the optional guest agent
```

## Requirements

- Apple Silicon Mac (M1 / M2 / M3 / M4).
- **macOS 13 Ventura** or later.
- macOS 14 Sonoma or later for **snapshots** (`--restore` / `--save-on-stop`).
- Bridged networking requires the CLI to be codesigned with the `com.apple.vm.networking` entitlement. The Homebrew bottle and `./deploy.sh` pipeline handle this automatically; for source builds follow [Build from source](#build-from-source).

## Installation

### Homebrew (recommended)

```bash
brew tap everettjf/tap
brew install --cask easyvm    # GUI app (drag-install)
brew install easyvm           # CLI
```

### Build from source

```bash
git clone https://github.com/everettjf/EasyVM.git
cd EasyVM

# Build the CLI
swift build -c release

# Sign it so it can use Virtualization + bridged networking
codesign --force --sign - \
  --entitlements Sources/EasyVMCLI/EasyVMCLI.entitlements \
  ./.build/release/easyvm

# (Optional) Install to PATH
cp ./.build/release/easyvm /usr/local/bin/

# Build the GUI app
open EasyVM/EasyVM.xcodeproj  # then Cmd+R
```

> ⚠️ The CLI **must** be codesigned with `Sources/EasyVMCLI/EasyVMCLI.entitlements` (not `EasyVM.entitlements`). Bridged networking and some Rosetta paths silently fail without it.

## GUI usage

1. Launch **EasyVM**.
2. **Create a macOS VM**: choose *macOS* and either tap **Download Latest** (fetched from Apple) or provide a local `.ipsw` (grab one from [ipsw.me](https://ipsw.me/product/Mac)).
3. **Create a Linux VM**: choose *Linux* and provide an ARM64 ISO. Supported out of the box: Ubuntu 24.04 (ARM64), Fedora 40, Debian 12, Alpine 3.20 (see `easyvm image list` for current URLs).
4. After the guest is installed, VMs live under your chosen storage folder. Use the sidebar to start/stop/clone/edit.

## CLI reference

```
easyvm create            Create a VM bundle
easyvm list              List VM bundles in a directory
easyvm run               Run a VM (detached by default; --foreground to stay attached)
easyvm stop              Stop a running VM (SIGTERM, escalates to SIGKILL after timeout)
easyvm clone             Clone a VM bundle (APFS clonefile when possible)
easyvm network list      List host bridged interfaces available to VMs
easyvm image list        List curated Linux ARM64 ISO URLs
easyvm push              Push a VM bundle to an OCI registry
easyvm pull              Pull a VM bundle from an OCI registry
easyvm ip                Resolve a NAT VM's IP from Apple's DHCP leases
easyvm ssh               SSH into a NAT VM
easyvm agent status      Read the last heartbeat from the in-guest agent
easyvm agent ping        Send a ping command to the in-guest agent
```

Run `easyvm <subcommand> --help` for the full option list. The most useful flags:

### `create`

```bash
easyvm create <name> --os <macOS|linux> \
  [--storage <dir>] [--image <iso-or-ipsw>] \
  [--cpu <n>] [--memory-gb <n>] [--disk-gb <n>] \
  [--bridged-interface <bsdName>] [--rosetta] \
  [--output text|json]
```

- `--bridged-interface` takes a `bsdName` from `easyvm network list` (e.g. `en0`).
- `--rosetta` enables Linux x86_64 translation via a `rosetta` virtiofs share (macOS 13+).
- `--output json` prints a machine-readable summary for scripting.
- macOS VMs created via CLI are skeletons — finish the install in the GUI.

### `run`

```bash
easyvm run <vm-path> [--foreground] [--recovery]
                     [--restore <state.vzstate>] [--save-on-stop <state.vzstate>]
```

- By default `run` spawns a `_run-worker` child process; the shell returns immediately. Logs go to `<vm-path>/.easyvm-run.log`.
- `--foreground` streams VZ logs to stdout and blocks until the VM exits.
- `--recovery` (macOS only) boots to Recovery.
- `--restore` / `--save-on-stop` require macOS 14+ (see [Snapshots](#snapshots-macos-14)).

### `list`, `ip`, `ssh`

```bash
easyvm list --storage /tmp/easyvm --output json
easyvm ip   /tmp/easyvm/demo
easyvm ssh  /tmp/easyvm/demo --user ubuntu -- -L 8080:localhost:8080
```

Arguments after `--` are passed through to `/usr/bin/ssh` so you can forward ports, pin keys, etc.

### `clone`

Uses `clonefile(2)` on APFS volumes (same volume → instantaneous, no extra disk). Falls back to byte copy across volumes. Also re-randomises the `MachineIdentifier` so the clone boots as a distinct machine.

```bash
easyvm clone /tmp/easyvm/golden /tmp/easyvm/job-$CI_JOB_ID
```

## Distribution via OCI registries

VM bundles pack into a single `tar.gz` layer with media type `application/vnd.easyvm.bundle.v1.tar+gzip`, plus a small JSON config blob. Any Docker Registry v2 compatible registry works.

```bash
# Public pull (no credentials needed)
easyvm pull ghcr.io/someone/ubuntu-arm:24.04 --storage /tmp/easyvm

# Authenticated push (GHCR example)
export EASYVM_REGISTRY_USER=yourname
export EASYVM_REGISTRY_PASSWORD=ghp_xxx    # PAT with write:packages
easyvm push /tmp/easyvm/my-vm ghcr.io/yourname/my-vm:v1
```

Credentials come from the `EASYVM_REGISTRY_USER` / `EASYVM_REGISTRY_PASSWORD` environment variables. Bearer-token auth (GHCR-style challenge response) and HTTP Basic are both supported.

## Networking

**NAT (default)** — works with zero setup. VMs live on `192.168.64.0/24`. Look up the guest's IP with `easyvm ip` (parses `/var/db/dhcpd_leases`).

**Bridged** — VM gets an IP from your LAN's DHCP:

```bash
easyvm network list                            # find bsdNames
easyvm create web --os linux --bridged-interface en0 ...
```

Bridged mode needs the CLI to carry `com.apple.vm.networking`. The bundled entitlements file (`Sources/EasyVMCLI/EasyVMCLI.entitlements`) has it — just re-run the `codesign` command from [Build from source](#build-from-source) if you ever change binaries.

## Rosetta (x86 binaries in Linux guests)

Run x86_64 Linux binaries inside an ARM64 Linux VM via Apple's Rosetta:

```bash
# 1. Install Rosetta on the host
softwareupdate --install-rosetta --agree-to-license

# 2. Create the VM with --rosetta
easyvm create linux-dev --os linux --rosetta --image ubuntu-arm64.iso ...
```

Inside the guest, mount the virtiofs share named `rosetta` and register it with `binfmt_misc`. Apple's [official guide](https://developer.apple.com/documentation/virtualization/running_intel_binaries_in_linux_vms_with_rosetta) walks through the in-guest steps.

## Snapshots (macOS 14+)

Save and restore the VM's execution state (not just disk state):

```bash
# Run and arrange to save on clean stop
easyvm run  /tmp/easyvm/demo --save-on-stop /tmp/easyvm/demo/state.vzstate
# ...later...
easyvm stop /tmp/easyvm/demo                     # pause + save before exit

# Next time, start from that state instead of booting cold
easyvm run  /tmp/easyvm/demo --restore /tmp/easyvm/demo/state.vzstate
```

Handy for "always-on" dev environments: save on shutdown → restore in < 1s next day.

## Guest agent (scaffold)

An optional in-guest helper that rendezvous with the host through a shared folder. **Current status: scaffold — only `ping` is implemented.**

```bash
# On the host
easyvm agent status /tmp/easyvm/demo             # read heartbeat
easyvm agent ping   /tmp/easyvm/demo             # round-trip test

# Inside a macOS guest, after mounting the host's guest-agent/ folder
./easyvm-guest /Volumes/easyvm-agent
```

Roadmap: clipboard sync, host→guest command execution, resolution auto-resize, Linux cross-compiled builds. See `Sources/EasyVMGuest/EasyVMGuestMain.swift`.

## Architecture

```
┌───────────────────────┐     ┌───────────────────────┐
│   EasyVM.app (GUI)    │     │    easyvm (CLI)       │
│   SwiftUI, Xcode      │     │    SwiftPM executable │
└──────────┬────────────┘     └───────────┬───────────┘
           │                              │
           │   import EasyVMCore          │
           │                              │
           ▼                              ▼
   ┌───────────────────────────────────────────────┐
   │               EasyVMCore (shared)             │
   │  • VMConfigModel / VMStateModel (schema v1)   │
   │  • VZVirtualMachineConfiguration builder      │
   │  • Runner (DispatchSource-driven, macOS 14    │
   │    snapshot restore/save hooks)               │
   │  • OCI Docker Registry v2 client              │
   │  • DHCP lease parser                          │
   │  • Guest-agent protocol types                 │
   └───────────────────────────────────────────────┘
```

The app's own model types live in `EasyVM/EasyVM/Core/VMKit/Model/` and bridge to Core through `CoreBridge.swift`.

## Exit codes

| Code | Case | Meaning |
| --- | --- | --- |
| `0` | — | Success |
| `1` | `message` | Generic failure |
| `2` | `notFound` | Bundle / file / interface not found |
| `3` | `alreadyExists` | Destination already exists |
| `4` | `invalidState` | VM already running / not running when expected |
| `5` | `hostUnsupported` / `rosettaNotInstalled` | Host capability missing |

Scripts can branch on these without parsing stderr.

## Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| `run` exits silently | Check `<bundle>/.easyvm-run.log` |
| `network list` prints nothing | CLI not signed with `com.apple.vm.networking` — re-run the codesign step |
| `ssh` or `ip` returns nothing | VM still booting / DHCP'ing — wait 10-30s |
| `push` returns HTTP 401 | Set `EASYVM_REGISTRY_USER` / `EASYVM_REGISTRY_PASSWORD` |
| `--rosetta` fails with "not installed" | `softwareupdate --install-rosetta --agree-to-license` |
| Linux guest hangs at boot | Confirm ISO is ARM64; verify `<bundle>/MachineIdentifier` and `NVRAM` exist |
| CLI `macOS` VM fails to start | Expected — CLI creates skeletons. Finish the install in GUI |
| Snapshot flags refused | Requires macOS 14+ |

For the macOS App Store submission path, run `scripts/prepare_mas.sh` for an automated pre-flight check of entitlements, Info.plist keys, and remaining manual steps.

## Homebrew release workflow

Self-hosted tap (`everettjf/homebrew-tap`):

```bash
scripts/release_homebrew_tap.sh --help
scripts/release_homebrew_tap.sh \
  --version 1.0.2 \
  --tap-repo everettjf/homebrew-tap \
  --app-dmg /absolute/path/to/EasyVM.dmg
```

One-shot release:

```bash
./deploy.sh                 # bump patch + build + dmg + push formula/cask
./deploy.sh --only-cli      # CLI only
./deploy.sh --only-app      # App only
./deploy.sh --skip-tests    # skip swift test
```

Version helpers (RepoRead-style):

```bash
./inc_patch_version.sh
./inc_minor_version.sh
./inc_major_version.sh
```

## Contributing

Issues and PRs welcome. Before opening a PR:

```bash
swift test                                                     # core + OCI + runner tests
xcodebuild -project EasyVM/EasyVM.xcodeproj -scheme EasyVM \
  -destination 'platform=macOS,arch=arm64' build               # app build
```

If you're using Claude Code, a project-local skill is checked in at `.claude/skills/easyvm-cli/SKILL.md` — it teaches Claude how to drive every subcommand.

## License

MIT. See [LICENSE](LICENSE).

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=everettjf/EasyVM&type=Date)](https://star-history.com/#everettjf/EasyVM&Date)
