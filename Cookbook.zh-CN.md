# VM4A Cookbook

按使用场景组织的实战手册。`Usage.md` 是按命令组织的参考；这份文档是按"我想干什么"组织的。

> English: [Cookbook.md](Cookbook.md)

## 目录

- [安装](#安装)
- [命令总览](#命令总览)
- [macOS vs Linux —— 支持差异](#macos-vs-linux--支持差异)
- [macOS guest 工作流](#macos-guest-工作流)
- [Linux guest 工作流](#linux-guest-工作流)
- [通用功能（macOS / Linux 都适用）](#通用功能macos--linux-都适用)
- [退出码](#退出码)
- [故障排查](#故障排查)
- [一图总结](#一图总结)

---

## 安装

```bash
brew tap everettjf/tap && brew install vm4a
```

源码编译时**必须**用 entitlement 签名（否则 bridged 网络和 Rosetta 静默失败）：

```bash
git clone https://github.com/everettjf/VM4A.git
cd VM4A
swift build -c release
codesign --force --sign - \
    --entitlements Sources/VM4ACLI/VM4ACLI.entitlements \
    ./.build/release/vm4a
cp ./.build/release/vm4a /usr/local/bin/
```

**Host 要求：** Apple Silicon Mac，macOS 13+（快照需 macOS 14+）。

---

## 命令总览

```
Agent 原语（v2.0 P0）
  vm4a spawn     一步 create+start，可等 IP/SSH 就绪
  vm4a exec      SSH 进 VM 跑命令，返回 JSON
  vm4a cp        SCP 双向拷贝（: 前缀标 guest 路径）
  vm4a fork      APFS clonefile 克隆 bundle，可选自动启动
  vm4a reset     停 + 从 .vzstate 快照恢复

Agent 集成（v2.0 P1, v2.1）
  vm4a mcp       stdio JSON-RPC 2.0 MCP server
  vm4a serve     localhost HTTP REST API

Sessions + 池（v2.3, v2.4）
  vm4a session list/show         检视 agent 运行会话
  vm4a pool create/show/list     管理池定义
  vm4a pool spawn                按需 fork 一台
  vm4a pool serve                预热池 daemon（保持 N 台空闲）
  vm4a pool acquire/release      毫秒级取出/归还
  vm4a pool destroy              删除池定义

经典生命周期
  vm4a create    创建 VM bundle（Linux 从 ISO，macOS 从 IPSW）
  vm4a list      列出 bundle
  vm4a run       启动 VM（默认后台；--foreground 前台）
  vm4a stop      停止（SIGTERM → 超时 SIGKILL）
  vm4a clone     克隆 bundle

镜像 / 网络
  vm4a image list/pull/where     catalog 列表 / 预下载 / 缓存位置
  vm4a network list              host 上可用的 bridged 接口
  vm4a push                      推 bundle 到 OCI registry
  vm4a pull                      从 OCI registry 拉 bundle
  vm4a ip                        查 NAT VM 的 IP
  vm4a ssh                       SSH 进 NAT VM
  vm4a agent status/ping         guest agent 心跳（脚手架）
```

每个命令都支持 `--output text|json`。`vm4a <cmd> --help` 是权威参考。

---

## macOS vs Linux —— 支持差异

CLI 的命令名（`spawn` / `exec` / `cp` / `fork` / `reset` / `pool` / `session` / `push` / `pull` / `mcp` / `serve`）在两个 OS 上完全一致 —— 这是设计目标。但**底下的实现和首次成本有真实差异**。先看清楚再用。

### 首次创建 / 安装

| 维度 | Linux | macOS |
|---|---|---|
| 镜像类型 | ISO（约 1–3 GB） | IPSW（约 12–15 GB） |
| catalog 条目 | 4 个固定 distro（Ubuntu / Fedora / Debian / Alpine） | 1 个 `macos-latest`（运行时查 Apple） |
| `--image` 缺省 | **必填** | **可省** —— 自动用 `macos-latest` |
| 安装方式 | ISO 当 USB 挂上，guest 自己跑安装器 | `vm4a` 调 `VZMacOSInstaller` 完整安装 |
| 安装时长 | 几分钟（autoinstall）到 10+ 分钟 | 10–20 分钟 |
| **首次启动** | **全 headless**（cloud-init / autoinstall / preseed 跑完） | **必须手动**点一次 Setup Assistant |
| SSH 引导 | distro 镜像默认开，或 autoinstall 自动开 | **必须手动**开 Remote Login（系统设置 → 通用 → 共享） |
| 安装阶段总成本 | 几分钟，0 人工 | 20–30 分钟，需要 1 次人工点击 |

### 运行参数

| 维度 | Linux | macOS |
|---|---|---|
| `--rosetta` | ✅ 支持（virtiofs 共享 + binfmt_misc） | ❌ 不适用（macOS guest 已经是 ARM 原生） |
| `--recovery`（run/spawn） | ❌ 不适用（VZ EFI 没有 recovery 模式） | ✅ 支持（`VZMacOSBootLoader.startUpFromMacOSRecoveryMode`） |
| 内存最小值 | distro 决定，几百 MB 起步 | IPSW 决定，通常 ≥ 4 GB（Sequoia 起 ≥ 8 GB） |
| 磁盘最小值 | 5–10 GB 够大多数 distro | IPSW 决定，通常 ≥ 60 GB |
| 默认 SSH 用户 | `root` | 当前 host 用户名（NSUserName） |

### 平台文件

bundle 内文件结构因 OS 而异：

| 文件 | Linux | macOS |
|---|---|---|
| `config.json` / `state.json` / `Disk.img` | ✅ | ✅ |
| `MachineIdentifier`（VZ 平台标识） | ✅ Generic | ✅ Mac |
| `NVRAM`（EFI 变量） | ✅ | ❌ |
| `HardwareModel`（VZ 硬件标识） | ❌ | ✅ |
| `AuxiliaryStorage`（OS 启动数据） | ❌ | ✅ |

### 完全一致的功能（two OSes，零差异）

下面这些命令在 Linux 和 macOS 上**行为一模一样**，只要 base bundle 已经准备好（macOS 已过 Setup Assistant、已开 Remote Login）：

- `vm4a run` / `stop` / `list` / `clone`
- `vm4a fork` / `reset`（包括 `--auto-start`、`--from-snapshot`、`--wait-ssh`）
- `vm4a exec` / `cp` / `ssh` / `ip`
- `vm4a push` / `pull`（OCI bundle 格式两个 OS 共享）
- `vm4a session` 全套
- `vm4a pool create/show/list/serve/spawn/acquire/release/destroy`
- 网络模式 `--network none|nat|bridged|host`
- 快照 `--save-on-stop` / `--restore`（host macOS 14+ 都支持）
- MCP server（`vm4a mcp`）—— `os` 字段在 spawn tool 里可选
- HTTP REST API（`vm4a serve`）—— `os` 字段在 `/v1/spawn` body 里可选
- Python SDK —— `client.spawn(os_="macOS")` 或 `os_="linux"`
- Sessions JSONL 格式
- Image 缓存（`~/.cache/vm4a/images/`）

### 模板（官方）

| 模板 | OS | 重建方式 |
|---|---|---|
| `ubuntu-base` | Linux | CI 月度全自动 rebuild |
| `python-dev` | Linux | CI 月度全自动 rebuild |
| `xcode-dev` | macOS | 手动 Setup Assistant 一次后，`build.sh` 自动跑剩下的 |

下游用户**拉模板**完全一致：`vm4a spawn dev --from <ref> --wait-ssh` —— Setup Assistant 已经在制作模板时过了，pull 下来直接可用。

### 一句话总结

**Linux 全自动；macOS 在创建一台新 base 时需要 1 次人工点击 Setup Assistant；之后所有 agent 操作两个 OS 完全一致。** 把 Setup Assistant 看成 Docker 里 `docker pull` 之前要先有人构建一次镜像 —— 一次性成本，之后全自动。

---

## macOS guest 工作流

> **唯一的限制：** `vm4a create --os macOS --image foo.ipsw` 跑完后 VM 进 Setup Assistant，Apple 没暴露脚本化跳过的 API，必须**人工点一次**完成首次启动设置。之后所有 vm4a 命令都和 Linux 一样能用，并且推到 GHCR 之后下游 `vm4a pull` 完全跳过 Setup Assistant。

### 第一次：从 IPSW 装一台 base

```bash
# 不指定 --image，自动用 Apple 的"当前 host 支持的最新 IPSW"
vm4a create mac-base --os macOS \
    --storage /tmp/vm4a \
    --cpu 4 --memory-gb 8 --disk-gb 80

# 或者用本地已下载的 IPSW
vm4a create mac-base --os macOS --image ~/Downloads/macos-15.ipsw \
    --storage /tmp/vm4a --cpu 4 --memory-gb 8 --disk-gb 80
```

`vm4a` 自动通过 `VZMacOSRestoreImage.fetchLatestSupported` 拿最新 IPSW URL，下载到 `~/.cache/vm4a/images/`，然后调 `VZMacOSInstaller` 装。10–20 分钟。

### 一次性：Setup Assistant

打开 VM4A.app，从 sidebar 选 `mac-base`，点 Run。在 framebuffer 里：
1. 选区域和键盘
2. 跳过 Apple ID
3. **建一个用户账号** —— 记下用户名
4. 进入桌面后，**系统设置 → 通用 → 共享 → 远程登录：开**
5. 关掉 VM4A.app 的 VM 窗口

### 之后：和 Linux 一模一样

```bash
# 启动
vm4a run /tmp/vm4a/mac-base

# 等 IP / SSH（通常 30 秒内）
vm4a ip /tmp/vm4a/mac-base
vm4a ssh /tmp/vm4a/mac-base --user youruser

# 跑命令，拿 JSON 结果
vm4a exec /tmp/vm4a/mac-base --user youruser --output json -- xcodebuild -version
# → {"exit_code":0,"stdout":"Xcode …\n","stderr":"","duration_ms":234,"timed_out":false}

# 拷文件
vm4a cp /tmp/vm4a/mac-base --user youruser ./Project.xcodeproj :/Users/youruser/Project.xcodeproj -r

# 存一个干净状态的快照（macOS 14+ host 才支持）
vm4a stop /tmp/vm4a/mac-base
vm4a run /tmp/vm4a/mac-base --save-on-stop /tmp/vm4a/mac-base/clean.vzstate
sleep 60
vm4a stop /tmp/vm4a/mac-base   # 关机时把状态存到 clean.vzstate
```

### 每个任务一台 fork（推荐 agent 模式）

```bash
# 从 base fork 一份，自动启动 + 从快照恢复 + 等 SSH（毫秒级）
vm4a fork /tmp/vm4a/mac-base /tmp/vm4a/task-$JOB_ID \
    --auto-start \
    --from-snapshot /tmp/vm4a/mac-base/clean.vzstate \
    --wait-ssh \
    --ssh-user youruser

# 跑代码
vm4a exec /tmp/vm4a/task-$JOB_ID --user youruser --timeout 600 --output json \
    -- xcodebuild -scheme MyApp test

# 任务搞坏了？1 秒回到快照
vm4a reset /tmp/vm4a/task-$JOB_ID --from /tmp/vm4a/mac-base/clean.vzstate --wait-ip

# 任务完了清理
vm4a stop /tmp/vm4a/task-$JOB_ID
rm -rf /tmp/vm4a/task-$JOB_ID
```

### 推到 registry，团队共享

```bash
export VM4A_REGISTRY_USER=yourname
export VM4A_REGISTRY_PASSWORD=ghp_xxx          # write:packages PAT
vm4a push /tmp/vm4a/mac-base ghcr.io/yourorg/macos-xcode:15
```

### 别人 / CI 上拉下来用 —— **跳过 Setup Assistant**

```bash
# 一条命令：拉镜像、启动、等 SSH。Setup Assistant 已经过了
vm4a spawn dev --os macOS \
    --from ghcr.io/yourorg/macos-xcode:15 \
    --storage /tmp/vm4a --wait-ssh --ssh-user youruser

vm4a exec /tmp/vm4a/dev --user youruser -- xcodebuild -version
```

预制 `xcode-dev` 模板：

```bash
vm4a spawn dev --os macOS \
    --from ghcr.io/everettjf/vm4a-templates/xcode-dev:latest \
    --storage /tmp/vm4a --wait-ssh
```

---

## Linux guest 工作流

完全 headless，没有 Setup Assistant 这种东西。Agent 全自动跑得通。

### 三种最少打字方式

```bash
# 用 catalog id（自动下载到 ~/.cache/vm4a/images/）
vm4a image list                                    # 看可用 id
vm4a create demo --image ubuntu-24.04-arm64 \
    --storage /tmp/vm4a --memory-gb 4

# 本地 ISO
vm4a create demo --image ~/Downloads/ubuntu.iso

# 任意 https URL
vm4a create demo --image https://cdimage.ubuntu.com/.../ubuntu.iso
```

### 启动 + 安装

第一次启动会进 ISO 安装器（或 cloud-init / autoinstall 自动跑完）：

```bash
vm4a run /tmp/vm4a/demo            # 后台启动
vm4a run /tmp/vm4a/demo --foreground   # 前台看 VZ 日志
```

装完之后用 IP + SSH：

```bash
vm4a ip /tmp/vm4a/demo                       # 查 IP
vm4a ssh /tmp/vm4a/demo --user ubuntu       # SSH
vm4a exec /tmp/vm4a/demo --user ubuntu -- whoami
```

### 推荐：用预制模板 + 一条 spawn

```bash
vm4a spawn dev \
    --from ghcr.io/everettjf/vm4a-templates/python-dev:latest \
    --storage /tmp/vm4a --wait-ssh --output json
# → {"id":"vm-…","name":"dev","ip":"192.168.64.7","ssh_ready":true,…}

vm4a exec /tmp/vm4a/dev -- python3 -c 'print(1+1)'
```

### Agent loop（fork-per-task 模式）

```bash
# 1. 装一次 base
vm4a spawn dev --from ghcr.io/yourorg/python-dev:latest \
    --storage /tmp/vm4a \
    --save-on-stop /tmp/vm4a/dev/clean.vzstate \
    --wait-ssh

vm4a exec /tmp/vm4a/dev -- bash -lc 'apt-get install -y ripgrep'
vm4a stop /tmp/vm4a/dev          # 关机时存快照

# 2. 每个任务
JOB=task-$(date +%s)
vm4a fork /tmp/vm4a/dev "/tmp/vm4a/$JOB" \
    --auto-start --from-snapshot /tmp/vm4a/dev/clean.vzstate --wait-ssh

vm4a cp   "/tmp/vm4a/$JOB" ./step.py :/work/step.py
vm4a exec "/tmp/vm4a/$JOB" --output json --timeout 120 -- python3 /work/step.py

# 3. 失败时 1 秒回滚
vm4a reset "/tmp/vm4a/$JOB" --from /tmp/vm4a/dev/clean.vzstate --wait-ip

# 4. 清理
vm4a stop "/tmp/vm4a/$JOB" && rm -rf "/tmp/vm4a/$JOB"
```

### 网络模式

```bash
vm4a create demo --image ubuntu-24.04-arm64 --network nat        # 默认
vm4a create demo --image ubuntu-24.04-arm64 --network none       # 不挂网卡
vm4a create demo --image ubuntu-24.04-arm64 --network bridged \
    --bridged-interface en0                                       # 桥接

vm4a network list                       # 查 bsdName
```

bridged 模式下 `vm4a ip` 拿不到（不走 Apple DHCP），用 `vm4a ssh --host <ip>`。

### Rosetta（在 Linux guest 跑 x86）

```bash
softwareupdate --install-rosetta --agree-to-license
vm4a create dev --image ubuntu-24.04-arm64 --rosetta
```

guest 里挂 `rosetta` 这个 virtiofs 共享并用 binfmt_misc 注册（[Apple 文档](https://developer.apple.com/documentation/virtualization/running_intel_binaries_in_linux_vms_with_rosetta)）。

---

## 通用功能（macOS / Linux 都适用）

### 镜像与缓存

| 命令 | 用途 |
|---|---|
| `vm4a image list` | 列出 catalog（Linux ISO + macos-latest） |
| `vm4a image pull <id>` | 显式预下载到 `~/.cache/vm4a/images/`，stdout 输出本地路径 |
| `vm4a image where` | 打印缓存目录 + 已缓存文件 |

`--image` 接受四种形式：catalog id / 本地路径 / `https://` URL / `macos-latest`（仅 macOS）。

### OCI registry 分发

```bash
export VM4A_REGISTRY_USER=yourname
export VM4A_REGISTRY_PASSWORD=ghp_xxx     # write:packages PAT

vm4a push /tmp/vm4a/dev ghcr.io/you/python-dev:24.04
vm4a pull ghcr.io/you/python-dev:24.04 --storage /tmp/vm4a
```

支持 Bearer token（GHCR）和 HTTP Basic 认证。

### 快照（macOS 14+ host）

```bash
vm4a run /tmp/vm4a/demo --save-on-stop /tmp/vm4a/demo/state.vzstate
vm4a stop /tmp/vm4a/demo                  # 关机时存到 state.vzstate
vm4a run /tmp/vm4a/demo --restore /tmp/vm4a/demo/state.vzstate
```

`spawn` 也支持同样的 flag。

### Sessions（运行轨迹记录）

任何 agent 命令加 `--session <id>`，在 `<bundle>/.vm4a-sessions/<id>.jsonl` 追加事件：

```bash
SID=run-$(date +%s)
vm4a fork /tmp/vm4a/dev /tmp/vm4a/task-1 --auto-start --wait-ssh --session $SID
vm4a exec /tmp/vm4a/task-1 --session $SID -- python3 /work/step.py

vm4a session list --bundle /tmp/vm4a/task-1
vm4a session show $SID --bundle /tmp/vm4a/task-1
# ✓ #1  …  fork dev → task-1 (started)
# ✓ #2  …  exec python3 → exit 0
```

或者用 SwiftUI 时间线 viewer：

```bash
swift run vm4a-sessions
```

### Pool（按需 / 预热两种）

**按需** —— 每次取一台时才 fork：

```bash
vm4a pool create py --base /tmp/vm4a/dev \
    --snapshot /tmp/vm4a/dev/clean.vzstate \
    --prefix task --storage /tmp/vm4a-tasks --size 0

vm4a pool spawn py --wait-ssh --output json   # 等价于 fork
```

**预热**（毫秒级出库）—— 后台 daemon 保持 N 台空闲：

```bash
vm4a pool create py ... --size 4
vm4a pool serve py &                           # daemon

VM=$(vm4a pool acquire py --output json | jq -r .path)   # 原子 mv
vm4a exec "$VM" -- python3 /work/step.py
vm4a pool release "$VM"                                  # daemon 自动补
```

### Agent 集成

#### MCP（Claude Code / Cursor / Cline）

`.mcp.json`：

```json
{ "mcpServers": { "vm4a": { "command": "vm4a", "args": ["mcp"] } } }
```

暴露 8 个 tool（`spawn`/`exec`/`cp`/`fork`/`reset`/`list`/`ip`/`stop`）+ 资源 `vm4a://vms`、`vm4a://sessions`、`vm4a://session/<id>`、`vm4a://pools` + 三条 prompt（`agent-loop`、`debug-failed-task`、`triage-vm`）。

#### HTTP API + Python SDK

```bash
vm4a serve --port 7777          # 可选 export VM4A_AUTH_TOKEN=xxx
```

```python
from vm4a import Client
c = Client()
vm = c.spawn(name="dev", os_="macOS", wait_ssh=True)        # 或 os_="linux"
out = c.exec(vm.path, ["python3", "-c", "print(1+1)"])
```

端点：`/v1/{health,spawn,exec,cp,fork,reset,vms,vms/ip,vms/stop}`，所有 body shape 和 SpawnOptions / ExecOptions / … 对齐。

---

## 退出码

| Code | 含义 |
|---|---|
| `0` | 成功 |
| `1` | 通用失败 |
| `2` | bundle / 文件 / 接口未找到 |
| `3` | 目标已存在 |
| `4` | VM 状态不符（在跑/没跑） |
| `5` | host 能力缺失 / Rosetta 未装 |

非 0 时不用解析 stderr，直接 `if`/`case` 判断即可。

---

## 故障排查

| 现象 | 修复 |
|---|---|
| `run` 静默退出 | 看 `<bundle>/.vm4a-run.log` |
| `network list` 空 | CLI 没签 `com.apple.vm.networking` entitlement |
| `vm4a ip` 没结果 | VM 还在 boot/DHCP，等 10–30 秒 |
| `push` HTTP 401 | 设 `VM4A_REGISTRY_USER` / `VM4A_REGISTRY_PASSWORD` |
| `--rosetta` 报 not installed | `softwareupdate --install-rosetta --agree-to-license` |
| Linux guest 卡 boot | 确认 ISO 是 ARM64；检查 `MachineIdentifier`、`NVRAM` 存在 |
| macOS guest 装完一直黑屏 | 正常 —— 在 Setup Assistant，VM4A.app 里交互完成 |
| `vm4a exec /macos-vm` Connection refused | macOS guest 没开 Remote Login。VM4A.app 里：系统设置 → 通用 → 共享 → 远程登录 |
| 快照参数被拒 | host 需 macOS 14+ |
| Bridged VM `vm4a ip` 没结果 | bridged 不走 Apple DHCP，传 `--host <ip>` |
| `vm4a serve` 401 | 客户端要带同样的 `VM4A_AUTH_TOKEN` |

---

## 一图总结

```
                                                ┌──────────────────────┐
                                                │  ~/.cache/vm4a/      │
                                                │   images/<id>.iso    │
                                                │   images/<id>.ipsw   │
                                                └─────────▲────────────┘
                                                          │ 自动下载+缓存
                                                          │
  ┌────────────────────────────────────────────────────────────────────┐
  │                          vm4a CLI                                  │
  │                                                                    │
  │  Linux:  create/spawn --image ubuntu-24.04-arm64                   │
  │          → 下载 ISO → 装 → run/exec/cp/fork/reset                  │
  │                                                                    │
  │  macOS:  create/spawn --os macOS  (or --image foo.ipsw)            │
  │          → 下载 IPSW → VZMacOSInstaller → ⚠ Setup Assistant 一次   │
  │          → run/exec/cp/fork/reset (= Linux 同样的 API)             │
  │                                                                    │
  │  之后:    push 到 GHCR → 别人 spawn --from <ref> 完全跳过安装      │
  └────────────────────────────────────────────────────────────────────┘
                  │              │              │
              MCP server   HTTP REST API   Python SDK
              (Claude     (vm4a serve)    (pip install vm4a)
              Code etc.)
```

**核心信息：** Linux 全自动；macOS 第一次需要 1 次手动 Setup Assistant，之后 push 一份基础镜像，所有 agent 操作两个 OS 行为一致。
