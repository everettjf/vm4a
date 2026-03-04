# EasyVM

EasyVM 是一个基于 Apple [Virtualization framework](https://developer.apple.com/documentation/virtualization) 的轻量级 macOS 虚拟机应用，支持在 Apple Silicon 上运行 macOS 和 Linux 虚拟机。

> 项目当前可用，仍在持续优化中。  
> English: [README.md](README.md)

[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)](https://www.apple.com/macos)
[![Discord](https://img.shields.io/badge/Discord-Join%20Chat-7289DA)](https://discord.gg/uxuy3vVtWs)

## 目录

- [快速开始](#快速开始)
- [特性](#特性)
- [架构](#架构)
- [截图](#截图)
- [环境要求](#环境要求)
- [安装与构建](#安装与构建)
- [CLI 使用](#cli-使用)
- [GUI 使用](#gui-使用)
- [常见问题](#常见问题)
- [Homebrew 发布](#homebrew-发布)
- [贡献](#贡献)
- [许可证](#许可证)

## 快速开始

如果你想立刻用起来，推荐按下面流程：

1. 构建 CLI：
   ```bash
   swift build
   ```
2. 给 CLI 签名（虚拟化权限）：
   ```bash
   codesign --force --sign - \
     --entitlements EasyVM/EasyVM/EasyVM.entitlements \
     ./.build/debug/easyvm
   ```
3. 创建并启动 Linux VM：
   ```bash
   ./.build/debug/easyvm create demo-linux --os linux --storage /tmp/easyvm --image ~/Downloads/linux-arm64.iso
   ./.build/debug/easyvm run /tmp/easyvm/demo-linux
   ```
4. 停止 VM：
   ```bash
   ./.build/debug/easyvm stop /tmp/easyvm/demo-linux
   ```

## 特性

- 原生性能：基于 Virtualization.framework。
- 支持 macOS 来宾系统。
- 支持 Linux 来宾系统（ARM64）。
- SwiftUI 原生桌面界面。

## 架构

EasyVM 采用双轨结构：

- App（Xcode）：`EasyVM/EasyVM.xcodeproj`
- CLI（SwiftPM）：通过 `Package.swift` 构建 `easyvm`
- 共享核心：`EasyVMCore`（`Sources/EasyVMCore`），App/CLI 共同依赖

当前共享范围：

- 模型读写（`config.json` / `state.json`）
- VM 配置构建（`VZVirtualMachineConfiguration`）
- PID/进程状态与运行循环
- 磁盘镜像初始化

App 模型与核心模型的桥接代码在：

- `EasyVM/EasyVM/Core/VMKit/Model/CoreBridge.swift`

## 截图

![EasyVM Screenshot 1](./Assets/screenshot1.png)
![EasyVM Screenshot 2](./Assets/screenshot2.png)

## 环境要求

- 硬件：Apple Silicon（M1/M2/M3）
- 系统：macOS 13（Ventura）及以上

## 安装与构建

1. 克隆仓库：
   ```bash
   git clone https://github.com/everettjf/EasyVM.git
   cd EasyVM
   ```
2. 打开 Xcode 工程：
   ```bash
   open EasyVM/EasyVM.xcodeproj
   ```
3. 运行 App：
   - 选择 `EasyVM` target
   - 按 `Cmd + R`

## CLI 使用

先构建：

```bash
swift build
```

查看帮助：

```bash
./.build/debug/easyvm --help
```

### `create`

```bash
./.build/debug/easyvm create <name> --os <macOS|linux> [--storage <dir>] [--image <path>] [--cpu <n>] [--memory-gb <n>] [--disk-gb <n>]
```

示例：

```bash
./.build/debug/easyvm create demo-linux --os linux --storage /tmp/easyvm --image ~/Downloads/linux-arm64.iso --cpu 4 --memory-gb 8 --disk-gb 64
```

说明：

- `--memory-gb` 和 `--disk-gb` 必须大于 `0`
- CLI 创建的 `macOS` VM 是骨架，后续建议在 GUI 中完成安装流程

### `list`

```bash
./.build/debug/easyvm list --storage /tmp/easyvm
```

### `run`

```bash
./.build/debug/easyvm run /tmp/easyvm/demo-linux
```

前台运行：

```bash
./.build/debug/easyvm run /tmp/easyvm/demo-linux --foreground
```

macOS 恢复模式：

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

## GUI 使用

### 运行 macOS VM

1. 启动 EasyVM。
2. 选择创建 macOS VM。
3. 选择系统镜像来源：
   - App 内“Download Latest”
   - 或手动提供 `.ipsw`（可参考 [ipsw.me](https://ipsw.me/product/Mac)）

### 运行 Linux VM

1. 启动 EasyVM。
2. 选择创建 Linux VM。
3. 提供 ARM64 ISO。

## 常见问题

- `run` 报权限/entitlement 错误：
  - 重新执行 `codesign` 命令对 `./.build/debug/easyvm` 签名。
- `run` 报 VM 已在运行：
  - 先 `easyvm list` 查看状态，再 `easyvm stop <vm-path>`。
- Linux 无法启动：
  - 检查 ISO 是否 ARM64。
  - 检查 bundle 下是否存在 `MachineIdentifier` 与 `NVRAM`。
- CLI 创建的 macOS bundle 直接运行失败：
  - 这是预期，需在 GUI 中完成安装初始化步骤。

## Homebrew 发布

项目提供了一个统一发布脚本，可用于自建 tap：

- CLI：发布到 Formula（`Formula/easyvm.rb`）
- App：发布到 Cask（`Casks/easyvm.rb`）
- 支持一个脚本同时发布两个

脚本：

```bash
scripts/release_homebrew_tap.sh --help
```

同时发布 CLI + App：

```bash
scripts/release_homebrew_tap.sh \
  --version 0.2.0 \
  --tap-repo everettjf/homebrew-tap \
  --app-dmg /absolute/path/to/EasyVM.dmg
```

仅发布 CLI：

```bash
scripts/release_homebrew_tap.sh --version 0.2.0 --only-cli
```

仅发布 App：

```bash
scripts/release_homebrew_tap.sh --version 0.2.0 --only-app --app-dmg /absolute/path/to/EasyVM.dmg
```

### 自动发布（推荐）

可以一条命令完成：自动升 patch 版本、构建、发布：

```bash
./deploy.sh --tap-repo everettjf/homebrew-tap
```

`deploy.sh` 会执行：

1. 运行 `swift test`（可用 `--skip-tests` 跳过）
2. 自动 bump `VERSION` 的 patch
3. 构建 CLI（`swift build -c release`）
4. 用 Xcode 构建 App 并自动打包 `EasyVM.dmg`
5. 提交并 push `VERSION`
6. 调用 `scripts/release_homebrew_tap.sh` 更新 tap（formula + cask）

版本脚本（参考 RepoRead 风格，已迁移）：

```bash
./inc_patch_version.sh
./inc_minor_version.sh
./inc_major_version.sh
```

## 贡献

欢迎提交 Issue 和 PR。

## 许可证

MIT，详见 [LICENSE](LICENSE)。
