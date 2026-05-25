<div align="center">

# VM4A — 给 AI Agent 用的虚拟机

**在 Apple Silicon 上为 AI Agent 跑代码提供一次性、可隔离的 macOS / Linux 虚拟机。**

基于 Apple [Virtualization framework](https://developer.apple.com/documentation/virtualization)，按 2026 年 AI Agent 的真实工作方式打包。

[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)](https://www.apple.com/macos)
[![Apple Silicon](https://img.shields.io/badge/arch-Apple%20Silicon-black?logo=apple)](https://www.apple.com/mac/)
[![Latest release](https://img.shields.io/github/v/release/everettjf/vm4a?label=release)](https://github.com/everettjf/vm4a/releases/latest)
[![Discord](https://img.shields.io/badge/Discord-Join%20Chat-7289DA?logo=discord&logoColor=white)](https://discord.gg/uxuy3vVtWs)

[**为什么**](#为什么要做-vm4a) · [**30 秒上手**](#30-秒看一遍) · [**安装**](#安装) · [**教程站**](https://everettjf.github.io/vm4a/zh/) · [**Cookbook**](Cookbook.zh-CN.md) · [**Usage**](Usage.zh-CN.md) · [**Developer**](Developer.zh-CN.md) · [English](README.md)

</div>

---

## 为什么要做 VM4A

写代码的 Agent —— Claude Code、Cursor、OpenAI Codex、自己写的循环 —— 反复需要一个东西：**一台干净、隔离、坏了能重置的机器**。VM4A 是本地的、跑在你 Mac 上的、并且是这条赛道里**唯一**同时满足下面这些条件的工具：

| | |
|---|---|
| 🖥 **同时支持 macOS 和 Linux guest** | 跑 iOS/macOS app 编译，不只是 `pip install` |
| 📸 **VZ 快照** *(macOS 14+)* | `--save-on-stop` / `--restore`，失败 → 重置 → 重试只要 1 秒级 |
| 📦 **OCI registry push/pull** | 像分发容器镜像那样分发 Agent 环境 |
| 🚀 **Apple Silicon 原生** | `Virtualization.framework`，接近裸机性能，不走 QEMU |
| 🪟 **GUI 是调试器，不是主界面** | Agent 跑挂的时候，打开 App 看那一刻的快照 |

> **macOS guest 安装流程。** `vm4a create --os macOS --image foo.ipsw` 直接用 Apple 的 `VZMacOSInstaller` 走完整安装流程（10–20 分钟）。装好的 VM 首次启动时会进 Setup Assistant，需要交互完成一次（建账号 + 打开 Remote Login），之后所有 vm4a 操作 —— `run`、`exec`、`cp`、`fork`、`reset`、`pool`、OCI push/pull、MCP 工具 —— 在 macOS bundle 上和 Linux 一样能用。从 registry 拉一个预制好的 macOS bundle 完全跳过 Setup Assistant。

VM4A 念作 **"VM for Agent"**，CLI 二进制叫 `vm4a`。

---

## 30 秒看一遍

```bash
# 1. 拉一个预制好的 Python 开发镜像，启动，等 SSH 就绪
vm4a spawn dev \
    --from ghcr.io/everettjf/vm4a-templates/python-dev:latest \
    --storage /tmp/vm4a --wait-ssh

# 2. 在 guest 里跑代码，JSON 输出方便程序消费
vm4a exec /tmp/vm4a/dev --output json -- python3 -c 'print(1+1)'
# → {"exit_code":0,"stdout":"2\n","stderr":"","duration_ms":312,"timed_out":false}

# 3. 每个任务一台 VM 的模式：APFS 克隆 1 秒一个，跑完丢
vm4a fork /tmp/vm4a/dev /tmp/vm4a/task-42 --auto-start --wait-ssh
vm4a exec /tmp/vm4a/task-42 -- bash /work/agent_step.sh
```

```
    golden bundle          per-task fork          per-task fork
   ┌───────────┐  fork →   ┌───────────┐          ┌───────────┐
   │   /dev    │  ──────►  │ /task-42  │          │ /task-43  │  ...
   └───────────┘           └───────────┘          └───────────┘
   只拉一次                 APFS clonefile，~1s     执行完即丢
```

---

## 多种调用方式

| 接入方式 | 适合场景 | 入口 |
|---|---|---|
| 🐚 **CLI** | shell 脚本、CI、手动调试 | `vm4a <command>` |
| 🤖 **MCP** | Claude Code / Cursor / Cline 等支持 MCP 的 AI | `vm4a mcp`（stdio JSON-RPC） |
| 🌐 **HTTP + SDK** | 自定义 harness、各种语言绑定 | `vm4a serve` + Python（`pip install vm4a`）或 JS/TS（`sdk/typescript`） |
| 🛰 **Cluster** | 多台 Mac 当一个池子 | `vm4a cluster add/spawn/exec` 调度远程 `vm4a serve` 节点 |

所有接入背后都是同一组 agent 原语：`spawn`、`run-code`、`expose-port`、`exec`、`cp`、`fork`、`reset`、`list`、`ip`、`stop`。哪种用着顺手就用哪种。逐命令参考见 [**Usage.zh-CN.md**](Usage.zh-CN.md)。

---

## 安装

```bash
brew tap everettjf/tap
brew install vm4a              # CLI
brew install --cask vm4a       # GUI（拖拽安装）
```

<details>
<summary>源码编译</summary>

```bash
git clone https://github.com/everettjf/vm4a.git
cd vm4a
swift build -c release
codesign --force --sign - \
    --entitlements Sources/VM4ACLI/VM4ACLI.entitlements \
    ./.build/release/vm4a
cp ./.build/release/vm4a /usr/local/bin/
```

> ⚠️ CLI **必须**用 `Sources/VM4ACLI/VM4ACLI.entitlements` 签名。bridged 网络和 Rosetta 路径在没签名时会静默失败。

> ⚠️ **macOS 26（Tahoe）+ ad-hoc 签名。** entitlements 文件里的 `com.apple.vm.networking`（bridged 模式用）是**受限** entitlement。在 macOS 26 上，用 ad-hoc 方式（`--sign -`）给带这个 entitlement 的二进制签名，会让 **AMFI 在启动时直接杀掉进程** —— 每次执行 `vm4a` 都没有任何输出就退出（退出码 `137`/SIGKILL）。两条出路：
>
> - **只用 NAT（不需要 Apple 开发者账号）：** 用一份去掉 `com.apple.vm.networking` 的 entitlements 签名，只保留 `com.apple.security.virtualization`（+ `network.client`/`network.server`）。NAT 虚拟机、`spawn`/`exec`/`run-code`/`expose-port`、快照、OCI 全都正常，只是用不了 `--network bridged`。
>   ```bash
>   # 只含 NAT 的 entitlements：复制原文件，删掉受限的 bridged key
>   cp Sources/VM4ACLI/VM4ACLI.entitlements /tmp/nat.entitlements
>   /usr/libexec/PlistBuddy -c "Delete :com.apple.vm.networking" /tmp/nat.entitlements
>   codesign --force --sign - --entitlements /tmp/nat.entitlements ./.build/release/vm4a
>   ```
> - **需要 bridged 网络：** 用真实的 Apple 开发者签名身份（`--sign "Developer ID Application: …"`）签名，且该身份已被授权携带受管的 `com.apple.vm.networking` entitlement；ad-hoc 授不了这个权限。
>
> 签完务必验证二进制能跑：`./.build/release/vm4a --version` 应打印版本号，而不是被杀掉。

</details>

**要求：** Apple Silicon Mac（M1+），macOS 13+（快照功能要 macOS 14+）。

---

## 当前进度

**最新 — v2.4** · warm-pool 运行时 + 网络沙盒

- `vm4a pool serve / acquire / release` —— 预热 N 台空闲 VM，毫秒级派发。
- `--network none | nat | bridged | host` —— 每台 VM 独立指定隔离级别。

<details>
<summary>完整发布历史</summary>

| 阶段 | 目标 | 状态 |
|---|---|---|
| v1.1 | VM 生命周期 + OCI 分发 + 快照 | ✅ 已发布 |
| v2.0 P0 | Agent CLI 原语（`spawn`/`exec`/`cp`/`fork`/`reset`） | ✅ 已发布 |
| v2.0 P1 | MCP server（`vm4a mcp`），Claude Code / Cursor / Cline 接入 | ✅ 已发布 |
| v2.1 | HTTP API（`vm4a serve`）+ Python SDK | ✅ 已发布 |
| v2.2 | 官方 OCI 模板（`ubuntu-base`/`python-dev`/`xcode-dev`） | ✅ 已发布 *(macOS 模板需要一次手动 Setup Assistant)* |
| v2.3 | Time Machine 视图（`vm4a-sessions` SwiftUI app + `vm4a session` CLI） | ✅ 已发布 *(独立 app；主 app 集成待做)* |
| v2.4 | 预热池运行时 + `--network` 沙盒 | ✅ 已发布 |

每个版本的具体变更见 [CHANGELOG.md](CHANGELOG.md)。

</details>

---

## 进一步阅读

| 你想做的事 | 看这里 |
|---|---|
| 逐步学习（从这开始） | [**教程站（中文）**](https://everettjf.github.io/vm4a/zh/) —— 从第一台 VM 到集群/CI 的渐进式教程，含 Cookbook（[源码](docs/zh/)） |
| 上手实战、端到端 recipe | [**Cookbook.zh-CN.md**](Cookbook.zh-CN.md) —— macOS / Linux guest、Agent loop、sessions、pools、MCP/HTTP 接入 |
| 完整场景方案（golden image + 并行 fork 等） | [**UseCases/**](UseCases/) |
| 查 flag 或 JSON 字段 | [**Usage.zh-CN.md**](Usage.zh-CN.md) —— 每个命令的完整参考 |
| 自己改 VM4A | [**Developer.zh-CN.md**](Developer.zh-CN.md) —— 仓库结构、架构、构建、测试、发布流程 |
| 看版本变更 | [**CHANGELOG.md**](CHANGELOG.md) |
| 用 Python SDK | [**sdk/python/README.md**](sdk/python/README.md) |
| 用 JS/TS SDK | [**sdk/typescript/README.md**](sdk/typescript/README.md) |
| 从 CI 跑 VM（GitHub Action） | [**action.yml**](action.yml) —— 自托管 Apple Silicon runner |
| 拉 / 重建模板镜像 | [**templates/README.md**](templates/README.md) |

> 在用 **Claude Code**？仓库里自带一个 skill：`.claude/skills/vm4a-cli/SKILL.md`，会教 Claude 怎么使用每个子命令。

---

## License

MIT。详见 [LICENSE](LICENSE)。

## Star 历史

[![Star History Chart](https://api.star-history.com/svg?repos=everettjf/vm4a&type=Date)](https://star-history.com/#everettjf/vm4a&Date)
