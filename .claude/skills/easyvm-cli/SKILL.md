---
name: easyvm-cli
description: |
  Use this skill when the user wants to create, run, stop, clone, push/pull,
  SSH into, or otherwise manage EasyVM virtual machines via the `easyvm` CLI.
  Triggers include any mention of EasyVM + "VM", the commands `easyvm create`,
  `easyvm run`, `easyvm pull`, `easyvm ssh`, "linux VM on mac", "macOS VM via
  CLI", or requests to automate VM lifecycle (CI, scripting, batch clones).

  Do NOT use this skill for: the SwiftUI app (open Xcode instead), non-EasyVM
  VM tools (UTM/VirtualBuddy/tart have their own CLIs), or questions about the
  Virtualization.framework itself.
---

# EasyVM CLI

EasyVM ships a single binary `easyvm` that creates and runs Apple
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
     --entitlements Sources/EasyVMCLI/EasyVMCLI.entitlements \
     ./.build/debug/easyvm
   ```
   Bridged networking and Rosetta share need the CLI entitlements file
   specifically — not the App one.
3. For bridged mode: `easyvm network list` should print at least one
   interface. If empty, re-check codesigning.

## Command map (when to reach for each)

| Intent | Command |
| --- | --- |
| Create a Linux VM bundle | `easyvm create NAME --os linux [--image ISO.iso] [--bridged-interface en0] [--rosetta]` |
| Create a macOS VM bundle skeleton (GUI completes install) | `easyvm create NAME --os macOS` |
| List bundles in a directory | `easyvm list --storage /tmp/easyvm [--output json]` |
| Start a VM in the background | `easyvm run /path/to/bundle` |
| Start in foreground (logs to stdout) | `easyvm run /path/to/bundle --foreground` |
| Boot macOS recovery | `easyvm run /path/to/bundle --recovery` |
| Restore from a VZ snapshot (macOS 14+) | `easyvm run /path/to/bundle --restore state.vzstate` |
| Save state on clean shutdown (macOS 14+) | `easyvm run /path/to/bundle --save-on-stop state.vzstate` |
| Stop a VM (SIGTERM, then SIGKILL if stuck) | `easyvm stop /path/to/bundle --timeout 20` |
| Clone a bundle (APFS clonefile when possible) | `easyvm clone SRC DST` |
| Show Linux ARM64 ISO catalog | `easyvm image list` |
| Show host bridged interfaces | `easyvm network list` |
| Look up VM's NAT IP | `easyvm ip /path/to/bundle [--output json]` |
| SSH into running VM (NAT) | `easyvm ssh /path/to/bundle --user root` |
| Push bundle to OCI registry | `easyvm push /path/to/bundle ghcr.io/you/name:tag` |
| Pull bundle from OCI registry | `easyvm pull ghcr.io/you/name:tag --storage /tmp/easyvm` |
| Check guest agent heartbeat | `easyvm agent status /path/to/bundle` |
| Ping guest agent | `easyvm agent ping /path/to/bundle` |

## Key workflows

### Spin up a disposable Ubuntu VM

```bash
ISO=~/Downloads/ubuntu-24.04-live-server-arm64.iso
easyvm create demo --os linux --storage /tmp/easyvm --image "$ISO" \
  --cpu 4 --memory-gb 8 --disk-gb 64
easyvm run /tmp/easyvm/demo
easyvm ip /tmp/easyvm/demo       # needs VM to have booted + DHCP'd
easyvm ssh /tmp/easyvm/demo      # after cloud-init / user setup
easyvm stop /tmp/easyvm/demo
```

### Distribute a pre-baked VM through GHCR

```bash
# Push (requires a PAT with write:packages)
export EASYVM_REGISTRY_USER=youruser
export EASYVM_REGISTRY_PASSWORD=ghp_xxx
easyvm push /tmp/easyvm/base-ubuntu ghcr.io/youruser/base-ubuntu:24.04

# Pull on another machine (anonymous if package is public)
easyvm pull ghcr.io/youruser/base-ubuntu:24.04 --storage /tmp/easyvm
easyvm run /tmp/easyvm/base-ubuntu
```

### Fast fork of a golden image for CI

```bash
easyvm clone /tmp/easyvm/golden /tmp/easyvm/job-$CI_JOB_ID
easyvm run   /tmp/easyvm/job-$CI_JOB_ID
trap "easyvm stop /tmp/easyvm/job-$CI_JOB_ID && rm -rf /tmp/easyvm/job-$CI_JOB_ID" EXIT
```

`clone` uses APFS `clonefile(2)` on the same volume so it's O(directory
entries), not O(disk image size).

## Non-obvious behaviors

- **NAT IP only** works for VMs using the default NAT attachment. Bridged
  VMs don't land in `/var/db/dhcpd_leases`; users must pass `--host <ip>` to
  `easyvm ssh` or use their router's DHCP view.
- **`--rosetta` is Linux only** and requires
  `softwareupdate --install-rosetta --agree-to-license` before first run.
  The CLI warns but doesn't block.
- **macOS guests created via CLI are skeletons.** `HardwareModel` and
  `AuxiliaryStorage` are only created by the GUI's install flow. If the
  user asks for a fully installed macOS VM from CLI, redirect them to
  open `EasyVM.app` → `File > New VM`.
- **Config JSON format** starts at `schemaVersion: 1`. Old bundles without
  the field still load — tolerant decoding treats missing as 1. When
  adding new fields, make them optional in Core.swift decoding.
- **`easyvm stop` requires a running pid.** If `easyvm list` shows `stopped`
  but stale files exist, just re-run `easyvm run`; the CLI cleans stale
  PID files on the next list.
- **`--output json` is available on `create`, `list`, `ip`, `agent status`.**
  Output is one JSON object/array per command invocation (not JSONL).
- **Guest agent is a scaffold.** Only `ping` is implemented. Don't promise
  clipboard/shutdown/script execution yet.

## Error exit codes (for scripting)

```
1  EasyVMError.message          Generic failure (legacy path)
2  EasyVMError.notFound         Bundle or file missing
3  EasyVMError.alreadyExists    Destination already exists
4  EasyVMError.invalidState     VM running when it should be stopped (or vice versa)
5  EasyVMError.hostUnsupported  macOS version / hardware capability missing
5  EasyVMError.rosettaNotInstalled
```

## When the user is stuck

- `run` silently exits: check `.easyvm-run.log` in the bundle root.
- "No bridged interfaces available": CLI is not signed with
  `com.apple.vm.networking`. Re-run the codesign command from the top.
- "Rosetta is not supported on this host": CPU doesn't expose VMX for
  Rosetta translation. Not fixable in software.
- `push` returns HTTP 401: set `EASYVM_REGISTRY_USER` / `EASYVM_REGISTRY_PASSWORD`
  (a PAT for GHCR, a Docker token for Docker Hub).
- `ssh` hangs: VM hasn't DHCP'd yet (`easyvm ip` returns empty). Wait 10-30s
  after `easyvm run` for first-boot initialization.

## When NOT to use the CLI

Redirect to the GUI app for:
- Completing a macOS guest install (needs IPSW download + interactive setup)
- Changing graphics resolution / audio config (GUI has device editors)
- First-time users who want a wizard

## What's new vs older guides

Commands added recently (mention when relevant):
- `push` / `pull` (OCI registry support, tart-style)
- `network list`, `image list` (host introspection)
- `ip`, `ssh` (NAT convenience)
- `agent status`, `agent ping` (guest-agent channel, scaffold)
- `create --rosetta`, `create --bridged-interface`
- `run --restore` / `run --save-on-stop` (macOS 14+ snapshots)
