---
name: vm4a-cli
description: |
  Use this skill when the user wants to create, run, stop, clone, push/pull,
  SSH into, or otherwise manage VM4A virtual machines via the `vm4a` CLI.
  Triggers include any mention of VM4A + "VM", the commands `vm4a create`,
  `vm4a run`, `vm4a pull`, `vm4a ssh`, "linux VM on mac", "macOS VM via
  CLI", or requests to automate VM lifecycle (CI, scripting, batch clones).

  Do NOT use this skill for: the SwiftUI app (open Xcode instead), non-VM4A
  VM tools (UTM/VirtualBuddy/tart have their own CLIs), or questions about the
  Virtualization.framework itself.
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

| Intent | Command |
| --- | --- |
| Create a Linux VM bundle | `vm4a create NAME --os linux [--image ISO.iso] [--bridged-interface en0] [--rosetta]` |
| Create a macOS VM bundle skeleton (GUI completes install) | `vm4a create NAME --os macOS` |
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

## Key workflows

### Spin up a disposable Ubuntu VM

```bash
ISO=~/Downloads/ubuntu-24.04-live-server-arm64.iso
vm4a create demo --os linux --storage /tmp/vm4a --image "$ISO" \
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
- **macOS guests created via CLI are skeletons.** `HardwareModel` and
  `AuxiliaryStorage` are only created by the GUI's install flow. If the
  user asks for a fully installed macOS VM from CLI, redirect them to
  open `VM4A.app` → `File > New VM`.
- **Config JSON format** starts at `schemaVersion: 1`. Old bundles without
  the field still load — tolerant decoding treats missing as 1. When
  adding new fields, make them optional in Core.swift decoding.
- **`vm4a stop` requires a running pid.** If `vm4a list` shows `stopped`
  but stale files exist, just re-run `vm4a run`; the CLI cleans stale
  PID files on the next list.
- **`--output json` is available on `create`, `list`, `ip`, `agent status`.**
  Output is one JSON object/array per command invocation (not JSONL).
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
