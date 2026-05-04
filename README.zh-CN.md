# VM4A — 给 AI Agent 用的虚拟机

**在 Apple Silicon 上为 AI Agent 跑代码提供一次性、可隔离的 macOS / Linux 虚拟机。** 基于 Apple [Virtualization framework](https://developer.apple.com/documentation/virtualization)，按 2026 年 AI Agent 的真实工作方式打包。

> English: [README.md](README.md)

[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)](https://www.apple.com/macos)
[![Latest release](https://img.shields.io/github/v/release/everettjf/VM4A?label=release)](https://github.com/everettjf/VM4A/releases/latest)
[![Discord](https://img.shields.io/badge/Discord-Join%20Chat-7289DA)](https://discord.gg/uxuy3vVtWs)

---

## 为什么要做 VM4A

写代码的 Agent —— Claude Code、Cursor、OpenAI Codex、自己写的循环 —— 反复需要一个东西：**一台干净、隔离、坏了能重置的机器**。VM4A 是本地的、跑在你 Mac 上的、并且是这条赛道里**唯一**同时满足下面这些条件的工具：

- 🖥 **同时支持 macOS 和 Linux guest** —— 跑 iOS/macOS app 编译，不只是 `pip install`
- 📸 **VZ 快照（macOS 14+）** —— `--save-on-stop` / `--restore`，失败 → 重置 → 重试只要 1 秒级
- 📦 **OCI registry push/pull** —— 像分发容器镜像那样分发 Agent 环境
- 🚀 **Apple Silicon 原生** —— `Virtualization.framework`，接近裸机性能，不走 QEMU
- 🪟 **GUI 是调试器，不是主界面** —— Agent 跑挂的时候，打开 App 看那一刻的快照

VM4A 念作 **"VM for Agent"**，CLI 二进制叫 `vm4a`。

---

## 30 秒看一遍

```bash
# 拉一个预制好的 Python 开发镜像，启动，等 SSH 就绪，跑代码
vm4a spawn dev \
    --from ghcr.io/everettjf/vm4a-templates/python-dev:latest \
    --storage /tmp/vm4a --wait-ssh

vm4a exec /tmp/vm4a/dev --output json -- python3 -c 'print(1+1)'
# → {"exit_code":0,"stdout":"2\n","stderr":"","duration_ms":312,"timed_out":false}

# 每个任务模式：APFS 克隆 1 秒一个，跑完丢
vm4a fork /tmp/vm4a/dev /tmp/vm4a/task-42 --auto-start --wait-ssh
vm4a exec /tmp/vm4a/task-42 -- bash /work/agent_step.sh
```

---

## 三种调用方式

| 接入方式 | 适合场景 | 入口 |
|---|---|---|
| **CLI** | shell 脚本、CI、手动调试 | `vm4a <command>` |
| **MCP** | Claude Code / Cursor / Cline 等支持 MCP 的 AI | `vm4a mcp`（stdio JSON-RPC） |
| **HTTP + Python SDK** | 自定义 Python harness、其他语言绑定 | `vm4a serve` + `pip install vm4a` |

三种接入背后都是同一组 agent 原语：`spawn`、`exec`、`cp`、`fork`、`reset`、`list`、`ip`、`stop`。哪种用着顺手就用哪种。

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

> ⚠️ CLI **必须**用 `Sources/VM4ACLI/VM4ACLI.entitlements` 签名。bridged 网络和 Rosetta 路径在没签名时会静默失败。

**要求：** Apple Silicon Mac（M1+），macOS 13+，快照功能要 macOS 14+。

---

## 当前状态 — v2.4（warm-pool 运行时 + 网络沙盒已发布）

| 阶段 | 目标 | 状态 |
|---|---|---|
| v1.1 | VM 生命周期 + OCI 分发 + 快照 | ✅ 已发布 |
| v2.0 P0 | Agent CLI 原语（`spawn`/`exec`/`cp`/`fork`/`reset`） | ✅ 已发布 |
| v2.0 P1 | MCP server（`vm4a mcp`），Claude Code / Cursor / Cline 接入 | ✅ 已发布 |
| v2.1 | HTTP API（`vm4a serve`）+ Python SDK | ✅ 已发布 |
| v2.2 | 官方 OCI 模板（`ubuntu-base`/`python-dev`/`xcode-dev`） | ✅ 已发布（构建脚本 + CI） |
| v2.3 | Time Machine 视图（`vm4a-sessions` SwiftUI app + `vm4a session` CLI） | ✅ 已发布（独立 app；主 app 集成待做） |
| v2.4 | 预热池运行时（`vm4a pool serve/acquire/release`）、`--network none\|nat\|bridged\|host` | ✅ 已发布（CPU/内存/磁盘大小之外的资源 cap + ISO 只读 是 VZ 限制下能做到的全部） |

---

## 进一步阅读

- **[Usage.zh-CN.md](Usage.zh-CN.md)** —— 每个命令、Agent 工作流、MCP/HTTP 接入、sessions、pools、模板、故障排查
- **[Developer.zh-CN.md](Developer.zh-CN.md)** —— 仓库结构、架构、构建、测试、新增工具的步骤、发布流程
- **[sdk/python/README.md](sdk/python/README.md)** —— Python SDK 快速上手
- **[templates/README.md](templates/README.md)** —— 预制 OCI 模板和重构方法

如果你在用 Claude Code，仓库里自带一个 skill：`.claude/skills/vm4a-cli/SKILL.md`，会教 Claude 怎么使用每个子命令。

---

## License

MIT。详见 [LICENSE](LICENSE)。

## Star 历史

[![Star History Chart](https://api.star-history.com/svg?repos=everettjf/VM4A&type=Date)](https://star-history.com/#everettjf/VM4A&Date)
