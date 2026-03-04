# EasyVM

EasyVM is a lightweight virtual machine application for macOS, built on top of Apple's powerful [Virtualization framework](https://developer.apple.com/documentation/virtualization). It allows you to run macOS and Linux virtual machines on Apple Silicon hardware with ease.

> **Note:** The project is functional but currently in an optimization phase.
>
> 中文文档: [README.zh-CN.md](README.zh-CN.md)

[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)](https://www.apple.com/macos)
[![Discord](https://img.shields.io/badge/Discord-Join%20Chat-7289DA)](https://discord.gg/uxuy3vVtWs)

## Table of Contents

- [Quick Start](#quick-start)
- [Features](#features)
- [Architecture](#architecture)
- [Screenshots](#screenshots)
- [Prerequisites](#prerequisites)
- [Installation & Build](#installation--build)
- [CLI Usage](#cli-usage)
- [GUI Usage](#gui-usage)
- [Troubleshooting](#troubleshooting)
- [Homebrew Release](#homebrew-release)
- [Contributing](#contributing)
- [License](#license)
- [Star History](#star-history)

## Quick Start

If you want to use EasyVM right away, follow this path:

1. Build CLI:
   ```bash
   swift build
   ```
2. Sign CLI with virtualization entitlement:
   ```bash
   codesign --force --sign - \
     --entitlements EasyVM/EasyVM/EasyVM.entitlements \
     ./.build/debug/easyvm
   ```
3. Create and run a Linux VM bundle:
   ```bash
   ./.build/debug/easyvm create demo-linux --os linux --storage /tmp/easyvm --image ~/Downloads/linux-arm64.iso
   ./.build/debug/easyvm run /tmp/easyvm/demo-linux
   ```
4. Stop VM:
   ```bash
   ./.build/debug/easyvm stop /tmp/easyvm/demo-linux
   ```

## Features

- **Native Performance:** Utilizes Apple's Virtualization.framework for near-native performance.
- **macOS Guests:** Create and run macOS virtual machines.
- **Linux Guests:** Create and run Linux virtual machines (ARM64).
- **Clean UI:** Built with SwiftUI for a modern macOS experience.

## Architecture

EasyVM uses a dual-track structure:

- **App (Xcode):** `EasyVM/EasyVM.xcodeproj` builds the GUI app.
- **CLI (SwiftPM):** `easyvm` is built from `Package.swift`.
- **Shared core:** both tracks depend on `EasyVMCore` (`Sources/EasyVMCore`).

Current shared scope:

- VM model load/write (`config.json`, `state.json`)
- VM configuration building (`VZVirtualMachineConfiguration`)
- PID/process helpers and VM run loop
- Disk image provisioning helpers

Bridge layer:

- App-only model types are bridged to core types in `EasyVM/EasyVM/Core/VMKit/Model/CoreBridge.swift`.

## Screenshots

![EasyVM Screenshot 1](./Assets/screenshot1.png)
![EasyVM Screenshot 2](./Assets/screenshot2.png)

## Prerequisites

- **Hardware:** Mac with Apple Silicon (M1/M2/M3 chips).
- **Operating System:** macOS 13 (Ventura) or later.

## Installation & Build

Currently, EasyVM is available by building from source.

1. **Clone the repository:**
   ```bash
   git clone https://github.com/everettjf/EasyVM.git
   cd EasyVM
   ```

2. **Open the project in Xcode:**
   ```bash
   open EasyVM/EasyVM.xcodeproj
   ```

3. **Build and Run:**
   - Select the `EasyVM` target.
   - Press `Cmd + R` to build and run the application.

### Optional: Standalone CLI (`easyvm`)

This repository includes a standalone Swift CLI with:

- `create`
- `list`
- `run`
- `stop`
- `clone`

Implementation note:

- Shared VM core logic lives in the SwiftPM module `EasyVMCore` (`Sources/EasyVMCore`).
- CLI command wiring lives in `Sources/EasyVMCLI`.

Build the CLI:

```bash
swift build
```

Run help:

```bash
./.build/debug/easyvm --help
```

Because the CLI directly uses Apple's Virtualization framework, it must be signed with the virtualization entitlement before `run` works:

```bash
codesign --force --sign - \
  --entitlements EasyVM/EasyVM/EasyVM.entitlements \
  ./.build/debug/easyvm
```

## CLI Usage

### `create`

Create a VM bundle:

```bash
./.build/debug/easyvm create <name> --os <macOS|linux> [--storage <dir>] [--image <path>] [--cpu <n>] [--memory-gb <n>] [--disk-gb <n>]
```

Examples:

```bash
./.build/debug/easyvm create demo-linux --os linux --storage /tmp/easyvm
./.build/debug/easyvm create demo-linux --os linux --storage /tmp/easyvm --image ~/Downloads/linux-arm64.iso --cpu 4 --memory-gb 8 --disk-gb 64
```

Notes:

- `--image` is typically a Linux ISO path.
- `macOS` bundles created via CLI are skeleton bundles. Complete installation in GUI flow.
- `--memory-gb` and `--disk-gb` must be greater than `0`.

### `list`

```bash
./.build/debug/easyvm list --storage /tmp/easyvm
```

### `run`

```bash
./.build/debug/easyvm run /tmp/easyvm/demo-linux
```

Foreground mode:

```bash
./.build/debug/easyvm run /tmp/easyvm/demo-linux --foreground
```

macOS recovery mode:

```bash
./.build/debug/easyvm run /path/to/macos-vm --recovery
```

### `stop`

```bash
./.build/debug/easyvm stop /tmp/easyvm/demo-linux
./.build/debug/easyvm stop /tmp/easyvm/demo-linux --timeout 30
```

### `clone`

```bash
./.build/debug/easyvm clone /tmp/easyvm/demo-linux /tmp/easyvm/demo-linux-clone
```

## GUI Usage

### Running macOS VMs
1. Launch EasyVM.
2. Select the option to create a new macOS VM.
3. You can either:
   - Use the **Download Latest** option within the app.
   - Or manually provide a valid `.ipsw` file. You can find these at [ipsw.me](https://ipsw.me/product/Mac).

### Running Linux VMs
1. Launch EasyVM.
2. Select the option to create a new Linux VM.
3. Provide an ARM64 Linux ISO. Supported distributions include:
   - **Fedora:** Download the "Fedora 37 aarch64 Live ISO" (or newer) from [Fedora Workstation](https://getfedora.org/en/workstation/download/).
   - **Ubuntu:** Download the "64-bit ARM (ARMv8/AArch64) desktop image" from [Ubuntu Daily Live](https://cdimage.ubuntu.com/focal/daily-live/current/) or [Ubuntu Desktop](https://ubuntu.com/download/desktop).

## Troubleshooting

- `run` fails with permission/entitlement errors:
  - Re-run `codesign` command on `./.build/debug/easyvm`.
- `run` says VM already running:
  - Check process status via `easyvm list`.
  - Stop with `easyvm stop <vm-path>`.
- Linux VM fails to boot:
  - Confirm ISO is ARM64.
  - Confirm bundle contains `MachineIdentifier` and `NVRAM` files.
- macOS VM fails from CLI-created bundle:
  - Expected for fresh skeleton bundle. Open and complete installation in GUI flow.

## Homebrew Release

EasyVM provides a unified release script for self-hosted tap publishing:

- CLI via Formula (`Formula/easyvm.rb`)
- App via Cask (`Casks/easyvm.rb`)
- Can publish both in one run

Script:

```bash
scripts/release_homebrew_tap.sh --help
```

Publish both CLI + App:

```bash
scripts/release_homebrew_tap.sh \
  --version 0.2.0 \
  --tap-repo everettjf/homebrew-tap \
  --app-dmg /absolute/path/to/EasyVM.dmg
```

Publish only CLI:

```bash
scripts/release_homebrew_tap.sh --version 0.2.0 --only-cli
```

Publish only App:

```bash
scripts/release_homebrew_tap.sh --version 0.2.0 --only-app --app-dmg /absolute/path/to/EasyVM.dmg
```

### Auto Deploy

You can use one command to bump patch version, build, and publish:

```bash
./deploy.sh
```

What `deploy.sh` does:

1. Runs `swift test` (unless `--skip-tests`)
2. Bumps patch version in `VERSION`
3. Builds CLI (`swift build -c release`)
4. Builds app with Xcode and packages `EasyVM.dmg`
5. Commits and pushes `VERSION`
6. Calls `scripts/release_homebrew_tap.sh` for Homebrew tap publishing

Or publish only one track:

```bash
./deploy.sh --only-cli
./deploy.sh --only-app
```

Version helper scripts (adapted from RepoRead style):

```bash
./inc_patch_version.sh
./inc_minor_version.sh
./inc_major_version.sh
```

## Contributing

Contributions are welcome! Whether it's reporting bugs, suggesting features, or submitting pull requests, your input is valued.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=everettjf/EasyVM&type=Date)](https://star-history.com/#everettjf/EasyVM&Date)
