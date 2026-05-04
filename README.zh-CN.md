# VM4A — 给 AI Agent 用的虚拟机

**在 Apple Silicon 上为 AI Agent 跑代码提供一次性、可隔离的 macOS / Linux 虚拟机。** 基于 Apple [Virtualization framework](https://developer.apple.com/documentation/virtualization)，按 2026 年 AI Agent 的真实工作方式打包。

> English: [README.md](README.md)

[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)](https://www.apple.com/macos)
[![Latest release](https://img.shields.io/github/v/release/everettjf/VM4A?label=release)](https://github.com/everettjf/VM4A/releases/latest)
[![Discord](https://img.shields.io/badge/Discord-Join%20Chat-7289DA)](https://discord.gg/uxuy3vVtWs)

---

## 为什么要做 VM4A

写代码的 Agent —— Claude Code、Cursor、OpenAI Codex、你自己的 Agent loop —— 反复需要一个东西：**一台干净、隔离、坏了能重置的机器**。现有方案要么是只支持 Linux 的云端沙盒（E2B、modal），要么是从来没考虑过 Agent 工效的通用 VM 工具。

VM4A 是本地的、跑在你 Mac 上的、并且是这条赛道里**唯一**同时满足下面这些条件的工具：

- 🖥 **同时支持 macOS 和 Linux guest** —— 跑 iOS/macOS app 编译，不只是 `pip install`
- 📸 **VZ 快照（macOS 14+）** —— `--save-on-stop` / `--restore`，一次失败 → 重置 → 再试的循环只要 1 秒级
- 📦 **OCI registry push/pull** —— 像分发容器镜像那样，通过 GHCR / Docker Hub / Harbor 分发预制好的 Agent 环境
- 🚀 **Apple Silicon 原生** —— `Virtualization.framework`，接近裸机性能，不走 QEMU 模拟
- 🪟 **GUI 是调试器，不是主界面** —— Agent 跑挂的时候，打开 App 直接看那一刻的快照状态

VM4A 念作 **"VM for Agent"**，CLI 二进制叫 `vm4a`。

---

## 当前状态 — v2.0 P0（Agent 原语已发布）

面向 Agent 的 CLI 原语已经**全部就绪**。一个二进制就能从"我要个干净机器"跑到"我拿到 guest 里命令的 JSON 输出"，不用写任何胶水。

| v2.0 P0 已发布 | 用途 |
|---|---|
| `vm4a spawn` | 一条命令从 OCI 镜像（`--from`）或本地 ISO（`--image`）创建+启动 VM，可选 `--wait-ip` / `--wait-ssh` |
| `vm4a exec` | SSH 进 guest 执行命令，返回 `{exit_code, stdout, stderr, duration_ms, timed_out}` |
| `vm4a cp` | SCP 双向文件传输 —— `:` 前缀标识 guest 路径 |
| `vm4a fork` | APFS clonefile 克隆 bundle，可选自动启动（带快照恢复） |
| `vm4a reset` | 停止 + 从 `.vzstate` 快照恢复 —— 给 try → fail → reset → retry 循环用 |

后续里程碑仍在设计中：`vm4a mcp`（给 Claude Code / Cursor 用的 MCP server）、`vm4a serve`（给 SDK 用的 HTTP API）、GUI Time Machine。详见[路线图](#路线图)。

---

## 安装

```bash
brew tap everettjf/tap
brew install vm4a              # CLI
brew install --cask vm4a       # GUI（拖拽安装）
```

或源码编译：

```bash
git clone https://github.com/everettjf/VM4A.git
cd VM4A
swift build -c release
codesign --force --sign - \
  --entitlements Sources/VM4ACLI/VM4ACLI.entitlements \
  ./.build/release/vm4a
cp ./.build/release/vm4a /usr/local/bin/
```

> ⚠️ CLI **必须**用 `Sources/VM4ACLI/VM4ACLI.entitlements` 签名。bridged 网络和部分 Rosetta 路径在没签名时会静默失败。

**要求：** Apple Silicon Mac（M1+），macOS 13+，快照功能要 macOS 14+。

---

## Agent 怎么用 VM4A

推荐流程基于 v2 原语 —— 一个并行 Agent harness 只需要 spawn / exec / fork 三个调用，加一个 reset 回滚路径。

```bash
# 1. 一条命令完成 pull + 启动（启用关机时存快照）+ 等 SSH 就绪。
vm4a spawn dev --from ghcr.io/yourorg/python-dev-arm64:latest \
  --storage /tmp/vm4a \
  --save-on-stop /tmp/vm4a/dev/clean.vzstate \
  --wait-ssh --output json
# → {"id":"vm-…","name":"dev","ip":"192.168.64.7","ssh_ready":true,…}

# 2. 装好 Agent 需要的东西后停掉 —— 关机时会自动存快照。
vm4a exec /tmp/vm4a/dev -- bash -lc "apt-get install -y ripgrep"
vm4a stop /tmp/vm4a/dev

# 3. 每个任务：从 golden bundle fork 一份，把代码丢进去跑。
vm4a fork /tmp/vm4a/dev /tmp/vm4a/task-$JOB_ID \
  --auto-start --from-snapshot /tmp/vm4a/dev/clean.vzstate --wait-ssh
vm4a cp   /tmp/vm4a/task-$JOB_ID ./agent_step.py :/work/step.py
vm4a exec /tmp/vm4a/task-$JOB_ID --output json --timeout 120 \
  -- python3 /work/step.py
# → {"exit_code":0,"stdout":"…","stderr":"","duration_ms":3142,"timed_out":false}

# 4. 任务把状态搞坏了？1 秒内回滚到 golden 快照。
vm4a reset /tmp/vm4a/task-$JOB_ID --from /tmp/vm4a/dev/clean.vzstate --wait-ip
```

所有命令都支持 `--output json`，Agent 不用做任何文本解析。

`fork` 用 APFS 的 `clonefile(2)`，所以新建一个 task VM 是 **O(目录条目数)，不是 O(磁盘镜像大小)**。配合 `--from-snapshot` 从状态文件恢复，Agent 从"我要个干净机器"到"VM 跑起来了"基本是 1 秒级。

---

## CLI 命令总览

```
Agent 原语（v2.0 P0）
vm4a spawn             一步创建+启动 VM，可等 IP / SSH 就绪
vm4a exec              SSH 进 VM 跑命令，返回 JSON
vm4a cp                SCP 主机 ↔ guest 拷文件（':' 前缀标 guest 路径）
vm4a fork              APFS clonefile 克隆 bundle，可选自动启动
vm4a reset             停 + 从 .vzstate 快照恢复 —— 给重试循环用

经典生命周期
vm4a create            创建 VM bundle
vm4a list              列出某个目录下的 VM bundle
vm4a run               启动 VM（默认后台；--foreground 前台）
vm4a stop              停止 VM（先 SIGTERM，超时再 SIGKILL）
vm4a clone             克隆 VM bundle（APFS clonefile 优先）
vm4a network list      列出 host 上可用的 bridged 网络接口
vm4a image list        列出官方维护的 Linux ARM64 ISO 链接
vm4a push              把 VM bundle 推到 OCI registry
vm4a pull              从 OCI registry 拉 VM bundle
vm4a ip                查 NAT VM 的 IP（解析 Apple 的 DHCP leases）
vm4a ssh               SSH 进 NAT VM
vm4a agent status      读 guest 内 agent 的最新心跳（脚手架）
vm4a agent ping        给 guest agent 发 ping（脚手架）
```

`vm4a <subcommand> --help` 看完整选项。

### Spawn

```bash
vm4a spawn <name> [--os linux|macOS] [--storage <dir>] \
  (--from <oci-ref> | --image <iso-or-ipsw>) \
  [--cpu <n>] [--memory-gb <n>] [--disk-gb <n>] \
  [--bridged-interface <bsdName>] [--rosetta] \
  [--restore <state.vzstate>] [--save-on-stop <state.vzstate>] \
  [--wait-ip] [--wait-ssh] [--ssh-user <name>] [--ssh-key <path>] \
  [--host <ip>] [--wait-timeout <seconds>] [--output text|json]
```

如果 `<storage>/<name>` 已存在，`spawn` 直接（重新）启动它；否则 `--from` 拉 OCI bundle，`--image` 从 ISO/IPSW 创建新的。`--output json` + `--wait-ssh` 一起用，Agent 一次调用就拿到 `{ip, ssh_ready: true}`，失败时也能快速失败。

### Exec

```bash
vm4a exec <vm-path> [--user <name>] [--key <path>] [--host <ip>] \
  [--timeout <seconds>] [--output text|json] -- <command...>
```

不加 `--output json` 时 stdout/stderr 流式输出，退出码作为本进程的退出码。加上 `--output json` 后返回 `{exit_code, stdout, stderr, duration_ms, timed_out}`，方便 Agent 决定重试、升级还是放过。Linux guest 默认 `root`，macOS guest 默认当前用户。

### Cp

```bash
vm4a cp <vm-path> [-r] [--user <name>] [--key <path>] [--host <ip>] \
  [--timeout <seconds>] [--output text|json] <source> <destination>
```

路径前缀 `:` 表示 guest 侧，否则是主机路径。两端必须**恰好一端**是 guest 路径。

```bash
vm4a cp /tmp/vm4a/dev ./local.py :/work/script.py        # 主机 → guest
vm4a cp /tmp/vm4a/dev :/var/log/syslog ./syslog.txt      # guest → 主机
vm4a cp /tmp/vm4a/dev -r ./project :/srv/code            # 递归
```

### Fork

```bash
vm4a fork <source-path> <destination-path> \
  [--auto-start] [--from-snapshot <state.vzstate>] \
  [--wait-ip] [--wait-ssh] [--ssh-user <name>] [--ssh-key <path>] \
  [--wait-timeout <seconds>] [--output text|json]
```

APFS `clonefile(2)` 复制源 bundle，再重新随机化 `MachineIdentifier` 让 fork 启动后是独立机器。`--auto-start --from-snapshot` 一起用，并行就绪的 VM 大约 1 秒内能拿到。

### Reset

```bash
vm4a reset <vm-path> --from <state.vzstate> \
  [--wait-ip] [--stop-timeout <seconds>] [--wait-timeout <seconds>] \
  [--output text|json]
```

给 `try → fail → reset → retry` Agent 循环用。停掉 VM（SIGTERM → SIGKILL）再从指定快照重启。需要 macOS 14+ 和提前存好的 `.vzstate`（看 `run --save-on-stop`）。

### Create

```bash
vm4a create <name> --os <macOS|linux> \
  [--storage <dir>] [--image <iso-or-ipsw>] \
  [--cpu <n>] [--memory-gb <n>] [--disk-gb <n>] \
  [--bridged-interface <bsdName>] [--rosetta] \
  [--output text|json]
```

- `--bridged-interface` 接 `vm4a network list` 列出的 `bsdName`（如 `en0`）
- `--rosetta` 启用 Linux x86_64 翻译（macOS 13+）
- `--output json` 给脚本用的机器可读输出
- 用 CLI 创建 macOS VM 是**骨架**，需要在 GUI 里完成安装

### Run

```bash
vm4a run <vm-path> [--foreground] [--recovery]
                   [--restore <state.vzstate>] [--save-on-stop <state.vzstate>]
```

- 默认 `run` 启动一个 `_run-worker` 子进程，shell 立即返回。日志在 `<vm-path>/.vm4a-run.log`
- `--foreground` 在前台显示 VZ 日志，阻塞到 VM 退出
- `--restore` / `--save-on-stop` 需要 macOS 14+

### List, IP, SSH

```bash
vm4a list --storage /tmp/vm4a --output json
vm4a ip   /tmp/vm4a/demo
vm4a ssh  /tmp/vm4a/demo --user ubuntu -- -L 8080:localhost:8080
```

`--` 后面的参数原样透传给 `/usr/bin/ssh`，可以做端口转发、指定 key 等。

### Clone

同 APFS volume 上用 `clonefile(2)`（瞬时、零额外占用），跨 volume fallback 字节复制。同时重新随机化 `MachineIdentifier`，让克隆体启动后是独立机器。

```bash
vm4a clone /tmp/vm4a/golden /tmp/vm4a/job-$CI_JOB_ID
```

---

## 通过 OCI registry 分发

bundle 打包成单个 `tar.gz` 层，media type 是 `application/vnd.vm4a.bundle.v1.tar+gzip`，配一个小的 JSON config blob。任何 Docker Registry v2 兼容的 registry 都能用（GHCR、Docker Hub、ECR、Harbor、私有部署）。

```bash
# 公开镜像匿名拉取
vm4a pull ghcr.io/someone/ubuntu-arm:24.04 --storage /tmp/vm4a

# 带认证推送（GHCR 示例）
export VM4A_REGISTRY_USER=yourname
export VM4A_REGISTRY_PASSWORD=ghp_xxx     # 带 write:packages 的 PAT
vm4a push /tmp/vm4a/my-vm ghcr.io/yourname/my-vm:v1
```

支持 Bearer token（GHCR 风格）和 HTTP Basic 两种认证。

---

## 网络

**NAT（默认）** —— 零配置，VM 在 `192.168.64.0/24` 网段，用 `vm4a ip` 查具体地址。

**Bridged** —— VM 从 LAN 的 DHCP 拿 IP：

```bash
vm4a network list                              # 查 bsdName
vm4a create web --os linux --bridged-interface en0 …
```

bridged 模式要求 CLI 带 `com.apple.vm.networking` entitlement，源码编译时按 [安装](#安装) 里的 codesign 命令重签即可。

---

## Rosetta（在 Linux guest 里跑 x86 二进制）

```bash
softwareupdate --install-rosetta --agree-to-license
vm4a create linux-dev --os linux --rosetta --image ubuntu-arm64.iso …
```

guest 里挂 `rosetta` 这个 virtiofs 共享，再用 `binfmt_misc` 注册。Apple 有[官方教程](https://developer.apple.com/documentation/virtualization/running_intel_binaries_in_linux_vms_with_rosetta)讲 guest 内步骤。

---

## 快照（macOS 14+）

保存/恢复 VM 完整执行状态（不是只磁盘）：

```bash
vm4a run  /tmp/vm4a/demo --save-on-stop /tmp/vm4a/demo/state.vzstate
vm4a stop /tmp/vm4a/demo                      # 退出前先暂停 + 保存

vm4a run  /tmp/vm4a/demo --restore /tmp/vm4a/demo/state.vzstate
```

Agent 工作流：第一次启动后存一份 snapshot，之后每次任务从 snapshot 起跑，省掉冷启动几十秒。

---

## GUI：VM4A.app

SwiftUI 桌面应用，目前主要做两件事做得好：

1. **macOS guest 的初始安装** —— 选版本、看进度、最后产出可快照的 bundle。macOS guest 安装需要交互式步骤，不适合放 CLI 里
2. **检视状态** —— 打开任意 bundle，看配置、交互运行、看 framebuffer 输出

> **路线图（v2）**：GUI 改造为类似 Time Machine 的调试器 —— Agent 运行 session 列表、快照时间线滚动、快照间文件系统 diff、"从这个快照 fork 一份给我手动调试"一键操作。当前版本仍是 v1 的管理 UI。

---

## Bundle 文件结构

```
demo/
├── config.json           # 设备/CPU/内存配置（schemaVersion: 1）
├── state.json            # 运行时状态指针
├── Disk.img              # raw 磁盘镜像
├── MachineIdentifier     # VZ 平台标识
├── NVRAM                 # （Linux）EFI 变量存储
├── HardwareModel         # （macOS）VZ 硬件标识
├── AuxiliaryStorage      # （macOS）操作系统启动数据
├── console.log           # （Linux）串口日志，每次 run 时滚动
└── guest-agent/          # 给可选 guest agent 用的 virtiofs 通信目录
```

CLI 创建的 bundle 能在 GUI 里用，反之亦然。

---

## 架构

```
┌───────────────────────┐     ┌───────────────────────┐
│   VM4A.app (GUI)      │     │     vm4a (CLI)        │
│   SwiftUI, Xcode      │     │     SwiftPM           │
└──────────┬────────────┘     └───────────┬───────────┘
           │                              │
           │     import VM4ACore          │
           ▼                              ▼
   ┌───────────────────────────────────────────────┐
   │              VM4ACore (共享库)                 │
   │  • VMConfigModel / VMStateModel (schema v1)   │
   │  • VZVirtualMachineConfiguration 构建         │
   │  • DispatchSource 驱动的 runner               │
   │  • macOS 14 快照 save/restore                 │
   │  • OCI Docker Registry v2 客户端              │
   │  • DHCP lease 解析                            │
   │  • Guest agent 协议类型                       │
   └───────────────────────────────────────────────┘
```

---

## 退出码（用于脚本判断）

| Code | 含义 |
| --- | --- |
| `0` | 成功 |
| `1` | 通用失败 |
| `2` | bundle / 文件 / 接口未找到 |
| `3` | 目标已存在 |
| `4` | VM 状态不符（在跑/没跑） |
| `5` | host 能力缺失 / Rosetta 未安装 |

可以直接 if-else 判断而不用解析 stderr。

---

## 故障排查

| 现象 | 可能原因 / 修复 |
| --- | --- |
| `run` 静默退出 | 看 `<bundle>/.vm4a-run.log` |
| `network list` 返回空 | CLI 没签 `com.apple.vm.networking` entitlement |
| `ssh` / `ip` 没结果 | VM 还在启动 / DHCP 中，等 10–30 秒 |
| `push` 返回 HTTP 401 | 设置 `VM4A_REGISTRY_USER` / `VM4A_REGISTRY_PASSWORD` |
| `--rosetta` 报"未安装" | `softwareupdate --install-rosetta --agree-to-license` |
| Linux guest 启动卡住 | 确认 ISO 是 ARM64；检查 `MachineIdentifier`、`NVRAM` 文件存在 |
| CLI 创建的 macOS VM 启不起来 | 正常 —— CLI 只创建骨架，要在 GUI 里完成安装 |
| 快照参数被拒 | 需要 macOS 14+ |

---

## 路线图

| 阶段 | 目标 | 状态 |
| --- | --- | --- |
| v1.1 | 完整 VM 生命周期 + OCI 分发 + 快照（即原 EasyVM 的能力） | ✅ 已发布 |
| v2.0 P0 | Agent CLI 原语（`spawn`/`exec`/`cp`/`fork`/`reset`） | ✅ 已发布 |
| v2.0 P1 | MCP server，Claude Code / Cursor / Cline 直接接入 | 🛠 设计中 |
| v2.1 | HTTP API + Python SDK | 计划中 |
| v2.2 | 官方维护的 OCI 模板（`vm4a/python-dev`、`vm4a/xcode-dev`、`vm4a/ubuntu-base`） | 计划中 |
| v2.3 | GUI Time Machine —— session/timeline/diff 调试器 | 计划中 |
| v2.4 | 预热 VM 池、网络沙盒策略、资源上限 | 计划中 |

有用例想推动优先级，开 issue 讨论。

---

## 发布流程

自托管 Homebrew tap（`everettjf/homebrew-tap`）：

```bash
./deploy.sh                 # patch 版本号 + 构建 + dmg + 推 formula/cask
./deploy.sh --only-cli      # 只发 CLI
./deploy.sh --only-app      # 只发 GUI
./deploy.sh --skip-tests    # 跳过 swift test
./deploy.sh --minor         # minor 版本号
./deploy.sh --major         # major 版本号
```

---

## 贡献

```bash
swift test
xcodebuild -project VM4A/VM4A.xcodeproj -scheme VM4A \
  -destination 'platform=macOS,arch=arm64' build
```

欢迎提 issue 和 PR。如果你在用 Claude Code，仓库里自带一个 skill：`.claude/skills/vm4a-cli/SKILL.md`，会教 Claude 怎么使用每个子命令。

---

## License

MIT。详见 [LICENSE](LICENSE)。

## Star 历史

[![Star History Chart](https://api.star-history.com/svg?repos=everettjf/VM4A&type=Date)](https://star-history.com/#everettjf/VM4A&Date)
