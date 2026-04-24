# EasyVM

**EasyVM 是一套面向 Apple Silicon 的 macOS 虚拟化工具集，基于 Apple 官方 [Virtualization framework](https://developer.apple.com/documentation/virtualization) 构建。** 一次安装，同时得到：

- 🖱 **EasyVM.app** — 用 SwiftUI 写的 GUI，鼠标点点就能管理虚拟机。
- ⌨️ **`easyvm` CLI** — 单一可执行文件，覆盖脚本化、CI 自动化、批量操作。
- 📦 **OCI 镜像分发** — 虚拟机镜像像容器一样 push/pull，兼容任意 Docker Registry v2（GHCR / Docker Hub / ECR / Harbor / 自建均可）。

App 与 CLI 共享同一个核心（`EasyVMCore`）。任一侧创建的 VM bundle 可以直接在另一侧运行。

> English: [README.md](README.md)

[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)](https://www.apple.com/macos)
[![Discord](https://img.shields.io/badge/Discord-Join%20Chat-7289DA)](https://discord.gg/uxuy3vVtWs)

---

## 怎么用 — 按场景选一条路

### 路径 A · GUI（最简单，适合第一次用）

```bash
brew tap everettjf/tap
brew install --cask easyvm
open -a EasyVM
```

打开后：**File → New VM → 选择 macOS 或 Linux → 按向导走完**。

### 路径 B · CLI（自动化、CI、脚本化首选）

```bash
# 1. 安装
brew install everettjf/tap/easyvm     # 或从源码构建（见下方）

# 2. 创建并启动一个 Linux VM
easyvm create demo --os linux --storage /tmp/easyvm \
  --image ~/Downloads/ubuntu-24.04-arm64.iso \
  --cpu 4 --memory-gb 8 --disk-gb 64
easyvm run /tmp/easyvm/demo

# 3. 访问（等 guest 启动并拿到 DHCP 地址）
easyvm ip  /tmp/easyvm/demo
easyvm ssh /tmp/easyvm/demo --user ubuntu

# 4. 停机
easyvm stop /tmp/easyvm/demo
```

### 路径 C · 从镜像仓库拉一个现成的 VM

```bash
easyvm pull ghcr.io/someone/ubuntu-arm:24.04 --storage /tmp/easyvm
easyvm run  /tmp/easyvm/ubuntu-arm
```

路径 A 和路径 B 产出的 VM 是完全一致的磁盘结构。CLI 建出来的 VM 可以在 App 里继续管理，反之亦然。

---

## 目录

- [项目都包含什么](#项目都包含什么)
- [环境要求](#环境要求)
- [安装](#安装)
- [GUI 使用](#gui-使用)
- [CLI 命令速查](#cli-命令速查)
- [通过 OCI 镜像仓库分发](#通过-oci-镜像仓库分发)
- [网络配置](#网络配置)
- [Rosetta（在 Linux 里跑 x86 二进制）](#rosetta在-linux-里跑-x86-二进制)
- [快照（macOS 14+）](#快照macos-14)
- [Guest Agent（脚手架）](#guest-agent脚手架)
- [架构](#架构)
- [退出码](#退出码)
- [常见问题排障](#常见问题排障)
- [Homebrew 发布流程](#homebrew-发布流程)
- [贡献](#贡献)
- [许可证](#许可证)

---

## 项目都包含什么

| 组件 | 位置 | 作用 |
| --- | --- | --- |
| `EasyVM.app` | `EasyVM/EasyVM.xcodeproj` | SwiftUI GUI，创建/运行/编辑虚拟机 |
| `easyvm` | `Sources/EasyVMCLI` | CLI：生命周期、OCI push/pull、SSH、快照、Agent |
| `easyvm-guest` | `Sources/EasyVMGuest` | 跑在 macOS 客户机里的 Agent（脚手架） |
| `EasyVMCore` | `Sources/EasyVMCore` | 共享 Swift 库 — 数据模型、VZ 配置、OCI 客户端、网络工具 |

一个 VM bundle 就是一个目录，布局如下：

```
demo/
├── config.json           # 设备 / 内存 / CPU 配置（带 schemaVersion）
├── state.json            # 运行时状态指针
├── Disk.img              # 无 qcow 包装的原始磁盘
├── MachineIdentifier     # VZ 机器标识
├── NVRAM                 # （Linux）EFI 变量存储
├── HardwareModel         # （macOS）VZ 硬件标识
├── AuxiliaryStorage      # （macOS）引导辅助存储
├── console.log           # （Linux）串口日志，每次启动追加写
└── guest-agent/          # 和 guest agent 通信的 virtiofs 挂载点
```

## 环境要求

- Apple Silicon Mac（M1 / M2 / M3 / M4）。
- **macOS 13 Ventura** 及以上。
- **快照**（`--restore` / `--save-on-stop`）需要 macOS 14 Sonoma 及以上。
- 桥接网络需要给 CLI 签上 `com.apple.vm.networking` entitlement。Homebrew bottle 和 `./deploy.sh` 已自动处理；从源码构建请走 [从源码构建](#从源码构建) 流程。

## 安装

### Homebrew（推荐）

```bash
brew tap everettjf/tap
brew install --cask easyvm    # GUI App
brew install easyvm           # CLI
```

### 从源码构建

```bash
git clone https://github.com/everettjf/EasyVM.git
cd EasyVM

# 构建 CLI
swift build -c release

# 签名（启用 Virtualization + 桥接网络）
codesign --force --sign - \
  --entitlements Sources/EasyVMCLI/EasyVMCLI.entitlements \
  ./.build/release/easyvm

# （可选）安装到 PATH
cp ./.build/release/easyvm /usr/local/bin/

# 构建 GUI App
open EasyVM/EasyVM.xcodeproj  # 然后 Cmd+R
```

> ⚠️ 签 CLI 一定要用 `Sources/EasyVMCLI/EasyVMCLI.entitlements`（不是 App 的 `EasyVM.entitlements`）。桥接网络和部分 Rosetta 路径会在没这个 entitlement 时静默失败。

## GUI 使用

1. 启动 **EasyVM**。
2. **创建 macOS VM**：选择 *macOS*，要么点 **Download Latest**（从 Apple 官方拉取），要么手动提供一个 `.ipsw`（可从 [ipsw.me](https://ipsw.me/product/Mac) 找）。
3. **创建 Linux VM**：选择 *Linux*，提供 ARM64 ISO。官方内置目录包含 Ubuntu 24.04（ARM64）、Fedora 40、Debian 12、Alpine 3.20（用 `easyvm image list` 可以看最新链接）。
4. 安装完成后，VM 存放在你选的存储目录里。用侧边栏启动/停止/克隆/编辑。

## CLI 命令速查

```
easyvm create            创建 VM bundle
easyvm list              列出指定目录下的 VM
easyvm run               启动 VM（默认后台运行；加 --foreground 前台）
easyvm stop              停止 VM（先 SIGTERM，超时后 SIGKILL）
easyvm clone             克隆 VM（同 APFS 卷上走 clonefile）
easyvm network list      列出可用桥接网卡
easyvm image list        列出精选的 Linux ARM64 ISO
easyvm push              推送 VM bundle 到 OCI 镜像仓库
easyvm pull              从 OCI 镜像仓库拉取 VM bundle
easyvm ip                从 Apple 的 DHCP 租约表解析 NAT VM 的 IP
easyvm ssh               SSH 到 NAT 模式的 VM
easyvm agent status      读取来自 guest agent 的最近一次心跳
easyvm agent ping        向 guest agent 发送 ping
```

详细参数用 `easyvm <子命令> --help` 查看。重点参数：

### `create`

```bash
easyvm create <name> --os <macOS|linux> \
  [--storage <目录>] [--image <iso/ipsw>] \
  [--cpu <n>] [--memory-gb <n>] [--disk-gb <n>] \
  [--bridged-interface <bsdName>] [--rosetta] \
  [--output text|json]
```

- `--bridged-interface` 传一个 bsdName（如 `en0`），用 `easyvm network list` 能看到列表。
- `--rosetta` 启用 Linux 下的 x86_64 翻译（通过 tag 为 `rosetta` 的 virtiofs 共享），需要 macOS 13+。
- `--output json` 输出机器可读的摘要，方便脚本消费。
- CLI 建出来的 macOS VM 是骨架，安装请在 GUI 里完成。

### `run`

```bash
easyvm run <vm-path> [--foreground] [--recovery]
                     [--restore <state.vzstate>] [--save-on-stop <state.vzstate>]
```

- 默认 `run` 会起一个 `_run-worker` 子进程，shell 立即返回，日志落在 `<vm-path>/.easyvm-run.log`。
- `--foreground` 把 VZ 日志直接打印到 stdout，并阻塞到 VM 退出为止。
- `--recovery`（仅 macOS）启动到 Recovery。
- `--restore` / `--save-on-stop` 需要 macOS 14+（参考 [快照](#快照macos-14)）。

### `list`、`ip`、`ssh`

```bash
easyvm list --storage /tmp/easyvm --output json
easyvm ip   /tmp/easyvm/demo
easyvm ssh  /tmp/easyvm/demo --user ubuntu -- -L 8080:localhost:8080
```

`--` 之后的参数原样传给 `/usr/bin/ssh`，可以用来端口转发、指定 identity、ProxyCommand 等。

### `clone`

同一个 APFS 卷上使用 `clonefile(2)`（瞬时完成，几乎不额外占空间），跨卷自动回退到字节拷贝。克隆时会重新随机 `MachineIdentifier`，保证克隆体作为独立机器启动。

```bash
easyvm clone /tmp/easyvm/golden /tmp/easyvm/job-$CI_JOB_ID
```

## 通过 OCI 镜像仓库分发

VM bundle 打成一个 `tar.gz` 层，media type 为 `application/vnd.easyvm.bundle.v1.tar+gzip`，配一个很小的 config JSON blob。任意 Docker Registry v2 兼容的仓库都能用。

```bash
# 公共仓库匿名拉取
easyvm pull ghcr.io/someone/ubuntu-arm:24.04 --storage /tmp/easyvm

# GHCR 带认证推送
export EASYVM_REGISTRY_USER=yourname
export EASYVM_REGISTRY_PASSWORD=ghp_xxx    # 带 write:packages 权限的 PAT
easyvm push /tmp/easyvm/my-vm ghcr.io/yourname/my-vm:v1
```

认证凭证从 `EASYVM_REGISTRY_USER` / `EASYVM_REGISTRY_PASSWORD` 环境变量读取，同时支持 Bearer token（GHCR 风格的 challenge-response）和 HTTP Basic。

## 网络配置

**NAT（默认）**：开箱即用，VM 在 `192.168.64.0/24` 网段。用 `easyvm ip` 可从 `/var/db/dhcpd_leases` 解析出客户机 IP。

**桥接**：VM 从所在局域网的 DHCP 拿地址。

```bash
easyvm network list                            # 看可用 bsdName
easyvm create web --os linux --bridged-interface en0 ...
```

桥接模式要求 CLI 带 `com.apple.vm.networking` entitlement。仓库里的 `Sources/EasyVMCLI/EasyVMCLI.entitlements` 已经配好，替换二进制后重跑 [从源码构建](#从源码构建) 里的 `codesign` 命令即可。

## Rosetta（在 Linux 里跑 x86 二进制）

通过 Apple Rosetta 在 ARM64 Linux VM 里执行 x86_64 二进制：

```bash
# 1. 在宿主机安装 Rosetta
softwareupdate --install-rosetta --agree-to-license

# 2. 带 --rosetta 创建 VM
easyvm create linux-dev --os linux --rosetta --image ubuntu-arm64.iso ...
```

在 guest 内挂载 tag 为 `rosetta` 的 virtiofs 共享，再注册到 `binfmt_misc`。具体 guest 内步骤参考 [Apple 官方文档](https://developer.apple.com/documentation/virtualization/running_intel_binaries_in_linux_vms_with_rosetta)。

## 快照（macOS 14+）

保存 / 恢复 VM 的执行状态（不只是磁盘）：

```bash
# 启动并在干净停机时保存
easyvm run  /tmp/easyvm/demo --save-on-stop /tmp/easyvm/demo/state.vzstate
# ...稍后...
easyvm stop /tmp/easyvm/demo                     # 停机前 pause + save

# 下次从状态恢复，不再冷启动
easyvm run  /tmp/easyvm/demo --restore /tmp/easyvm/demo/state.vzstate
```

长期开着的开发机特别合适：关机时存盘，第二天不到 1 秒恢复。

## Guest Agent（脚手架）

一个可选的"guest 内小助手"，通过共享目录与宿主机通信。**当前状态：脚手架，只实现了 `ping`。**

```bash
# 宿主机侧
easyvm agent status /tmp/easyvm/demo             # 读取心跳
easyvm agent ping   /tmp/easyvm/demo             # 发起一次往返探活

# 在 macOS guest 内，先把 host 的 guest-agent/ 目录挂载进来再运行
./easyvm-guest /Volumes/easyvm-agent
```

规划中：剪贴板同步、host→guest 执行命令、分辨率自适应、Linux 版交叉编译。源码在 `Sources/EasyVMGuest/EasyVMGuestMain.swift`。

## 架构

```
┌───────────────────────┐     ┌───────────────────────┐
│   EasyVM.app (GUI)    │     │    easyvm (CLI)       │
│   SwiftUI / Xcode     │     │    SwiftPM executable │
└──────────┬────────────┘     └───────────┬───────────┘
           │                              │
           │   import EasyVMCore          │
           │                              │
           ▼                              ▼
   ┌───────────────────────────────────────────────┐
   │               EasyVMCore（共享核心）          │
   │  • VMConfigModel / VMStateModel（schema v1） │
   │  • VZVirtualMachineConfiguration 构建器       │
   │  • Runner（DispatchSource 驱动，macOS 14      │
   │    快照 restore/save 钩子）                   │
   │  • OCI Docker Registry v2 客户端              │
   │  • DHCP 租约解析器                            │
   │  • Guest agent 协议类型                       │
   └───────────────────────────────────────────────┘
```

App 自己的模型类型住在 `EasyVM/EasyVM/Core/VMKit/Model/` 下，通过 `CoreBridge.swift` 和 Core 的类型互转。

## 退出码

| 码 | 错误分类 | 含义 |
| --- | --- | --- |
| `0` | — | 成功 |
| `1` | `message` | 通用失败 |
| `2` | `notFound` | 找不到 bundle / 文件 / 网卡 |
| `3` | `alreadyExists` | 目标已存在 |
| `4` | `invalidState` | VM 状态不符合预期（已运行 / 未运行） |
| `5` | `hostUnsupported` / `rosettaNotInstalled` | 宿主机能力缺失 |

脚本里可以直接根据码分支，不用去 grep stderr。

## 常见问题排障

| 现象 | 原因 / 解法 |
| --- | --- |
| `run` 静默退出 | 去看 `<bundle>/.easyvm-run.log` |
| `network list` 没输出 | CLI 没签 `com.apple.vm.networking`，重签一遍 |
| `ssh` 或 `ip` 无结果 | VM 还没启动 / DHCP，等 10-30s 再试 |
| `push` 返回 HTTP 401 | 设 `EASYVM_REGISTRY_USER` / `EASYVM_REGISTRY_PASSWORD` |
| `--rosetta` 报 not installed | 跑 `softwareupdate --install-rosetta --agree-to-license` |
| Linux guest 卡在启动 | 确认 ISO 是 ARM64；检查 `<bundle>/MachineIdentifier` 与 `NVRAM` 是否存在 |
| CLI 建的 macOS VM 跑不起来 | 预期行为 — CLI 只建骨架，安装在 GUI 完成 |
| 快照参数被拒 | 需要 macOS 14+ |

如果你打算提交到 Mac App Store，跑 `scripts/prepare_mas.sh` 可以自动检查 entitlements、Info.plist 字段，并列出还需手动完成的步骤。

## Homebrew 发布流程

自建 tap（`everettjf/homebrew-tap`）：

```bash
scripts/release_homebrew_tap.sh --help
scripts/release_homebrew_tap.sh \
  --version 1.0.2 \
  --tap-repo everettjf/homebrew-tap \
  --app-dmg /absolute/path/to/EasyVM.dmg
```

一条龙发布：

```bash
./deploy.sh                 # 升 patch + 构建 + 打 dmg + 更新 formula/cask
./deploy.sh --only-cli      # 只发 CLI
./deploy.sh --only-app      # 只发 App
./deploy.sh --skip-tests    # 跳过 swift test
```

版本辅助脚本（RepoRead 风格）：

```bash
./inc_patch_version.sh
./inc_minor_version.sh
./inc_major_version.sh
```

## 贡献

欢迎 Issue 和 PR。提交前请跑：

```bash
swift test                                                     # core + OCI + runner 测试
xcodebuild -project EasyVM/EasyVM.xcodeproj -scheme EasyVM \
  -destination 'platform=macOS,arch=arm64' build               # App 构建
```

如果你在用 Claude Code，仓库里带了一份 project-local skill：`.claude/skills/easyvm-cli/SKILL.md`，会教 Claude 如何正确调用每一个子命令。

## 许可证

MIT，详见 [LICENSE](LICENSE)。

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=everettjf/EasyVM&type=Date)](https://star-history.com/#everettjf/EasyVM&Date)
