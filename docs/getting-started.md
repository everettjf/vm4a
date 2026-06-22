---
title: Getting started
layout: default
nav_order: 2
description: "Install vm4a, verify it runs, and boot your first VM."
---

# Getting started
{: .no_toc }

Install `vm4a`, make sure it actually runs, and understand the moving parts before the tutorials.
{: .fs-5 .fw-300 }

<details open markdown="block">
  <summary>On this page</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Requirements

- **Apple Silicon Mac** (M1+). Intel Macs are not supported — VM4A uses `Virtualization.framework`.
- **macOS 13+**. VZ snapshots (`--save-on-stop` / `--restore`) need macOS 14+.
- For building from source: a **Swift 6 toolchain** (Xcode 16+).

## Install

### Homebrew (recommended)

```bash
brew tap everettjf/tap
brew install vm4a              # the CLI
brew install --cask vm4a       # optional GUI app
```

### Build from source

```bash
git clone https://github.com/everettjf/vm4a.git
cd vm4a
swift build -c release
codesign --force --sign - \
    --entitlements Sources/VM4ACLI/VM4ACLI.entitlements \
    ./.build/release/vm4a
cp ./.build/release/vm4a /usr/local/bin/
```

{: .warning }
> **The CLI must be codesigned** with `Sources/VM4ACLI/VM4ACLI.entitlements`. Without the `com.apple.security.virtualization` entitlement, VM operations fail.

{: .warning }
> **macOS 26 (Tahoe) + ad-hoc signing.** `com.apple.vm.networking` (the bridged-mode entitlement) is a *restricted* entitlement. On macOS 26, ad-hoc signing (`--sign -`) a binary that carries it makes **AMFI kill the process at launch** — every `vm4a` command exits `137` with no output. If you hit that, re-sign **NAT-only** (drop just that key):
>
> ```bash
> cp Sources/VM4ACLI/VM4ACLI.entitlements /tmp/nat.entitlements
> /usr/libexec/PlistBuddy -c "Delete :com.apple.vm.networking" /tmp/nat.entitlements
> codesign --force --sign - --entitlements /tmp/nat.entitlements ./.build/release/vm4a
> ./.build/release/vm4a --version   # must print a version, not get killed
> ```
>
> NAT covers `spawn`/`exec`/`run-code`/`expose-port`/snapshots/OCI. Bridged mode needs a real Apple Developer signing identity that can carry the managed entitlement.

## Verify it runs

```bash
vm4a --version          # → 2.5.0
vm4a --help             # lists every subcommand
```

If `vm4a --version` prints nothing and exits non-zero, re-read the codesigning warnings above.

## Mental model: a VM is a folder

Everything `vm4a` does revolves around a **bundle** — a directory holding the VM's config, disk, and identity:

```
dev/
├── config.json      # CPU / memory / devices (schemaVersion: 1)
├── state.json       # runtime state pointer
├── Disk.img         # the disk
├── MachineIdentifier
├── NVRAM            # EFI variable store (Linux)
├── console.log      # serial console (Linux)
└── .vm4a-run.log    # detached worker log
```

A bundle made by the CLI opens in the GUI app and vice-versa. You point commands at the bundle path: `vm4a exec /tmp/vm4a/dev -- …`.

## Your first VM in 30 seconds

The simplest possible start needs no arguments at all — `vm4a spawn` auto-names
the VM and boots a default Linux image (`ubuntu-24.04-arm64`) with sensible
CPU / memory / disk / NAT defaults:

```bash
# Zero flags: a default Linux VM, auto-named.
vm4a spawn
```

For agents and automation, the fastest path is pulling a pre-baked image from an
OCI registry that boots straight to SSH:

```bash
# 1. Pull, start, wait for SSH.
vm4a spawn dev \
    --from ghcr.io/yourorg/python-dev:latest \
    --storage /tmp/vm4a --wait-ssh

# 2. Run code. JSON is machine-readable.
vm4a exec /tmp/vm4a/dev --output json -- python3 -c 'print(1+1)'
# → {"exit_code":0,"stdout":"2\n","stderr":"","duration_ms":312,"timed_out":false}

# 3. Done.
vm4a stop /tmp/vm4a/dev
```

{: .note }
> No registry image handy? `vm4a create demo` builds from an ISO — `--image` is optional and defaults to `ubuntu-24.04-arm64` (pass one to pick another distro). ISO installs are interactive, though; for automation, a pre-baked OCI bundle that boots straight to SSH is the way. The [first-VM tutorial](tutorials/01-first-vm) covers both.

## JSON everywhere

Every agent primitive accepts `--output json` and returns a single object per call. The shapes are **snake_case**:

- `exec` / `run-code` → `{exit_code, stdout, stderr, duration_ms, timed_out}`
- `spawn` → `{id, name, path, os, pid, ip, ssh_ready}`

This is what makes `vm4a` scriptable from an agent loop. Next: the [Tutorials](tutorials).
