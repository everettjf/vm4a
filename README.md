# EasyVM

EasyVM is a lightweight virtual machine application for macOS, built on top of Apple's powerful [Virtualization framework](https://developer.apple.com/documentation/virtualization). It allows you to run macOS and Linux virtual machines on Apple Silicon hardware with ease.

> **Note:** The project is functional but currently in an optimization phase.

[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)](https://www.apple.com/macos)
[![Discord](https://img.shields.io/badge/Discord-Join%20Chat-7289DA)](https://discord.gg/uxuy3vVtWs)

## Table of Contents

- [Features](#features)
- [Screenshots](#screenshots)
- [Prerequisites](#prerequisites)
- [Installation & Build](#installation--build)
- [Usage](#usage)
  - [Running macOS VMs](#running-macos-vms)
  - [Running Linux VMs](#running-linux-vms)
- [Contributing](#contributing)
- [License](#license)
- [Star History](#star-history)

## Features

- **Native Performance:** Utilizes Apple's Virtualization.framework for near-native performance.
- **macOS Guests:** Create and run macOS virtual machines.
- **Linux Guests:** Create and run Linux virtual machines (ARM64).
- **Clean UI:** Built with SwiftUI for a modern macOS experience.

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

## Usage

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

## Contributing

Contributions are welcome! Whether it's reporting bugs, suggesting features, or submitting pull requests, your input is valued.

- **Community:** Join the discussion on [Discord](https://discord.gg/uxuy3vVtWs).

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=everettjf/EasyVM&type=Date)](https://star-history.com/#everettjf/EasyVM&Date)
