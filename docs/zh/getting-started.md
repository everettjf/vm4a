---
title: 快速上手
layout: default
parent: 中文文档
nav_order: 1
description: "安装 vm4a、确认能跑起来、启动第一台 VM。"
---

# 快速上手
{: .no_toc }

安装 `vm4a`、确认它真的能运行，并在开始教程前理解几个基本概念。
{: .fs-5 .fw-300 }

<details open markdown="block">
  <summary>本页内容</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## 环境要求

- **Apple Silicon Mac**（M1+）。不支持 Intel Mac —— VM4A 用的是 `Virtualization.framework`。
- **macOS 13+**。VZ 快照（`--save-on-stop` / `--restore`）需要 macOS 14+。
- 从源码构建：需要 **Swift 6 工具链**（Xcode 16+）。

## 安装

### Homebrew（推荐）

```bash
brew tap everettjf/tap
brew install vm4a              # CLI
brew install --cask vm4a       # 可选的 GUI app
```

### 从源码构建

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
> **CLI 必须签名**，用 `Sources/VM4ACLI/VM4ACLI.entitlements`。没有 `com.apple.security.virtualization` entitlement，VM 操作会失败。

{: .warning }
> **macOS 26（Tahoe）+ ad-hoc 签名。** `com.apple.vm.networking`（bridged 模式用的 entitlement）是**受限** entitlement。在 macOS 26 上，用 ad-hoc 方式（`--sign -`）给带它的二进制签名，会让 **AMFI 在启动时直接杀掉进程** —— 每条 `vm4a` 命令都退出码 `137`、无任何输出。遇到的话，改用**只含 NAT** 的 entitlements 重新签名（只删掉那一个 key）：
>
> ```bash
> cp Sources/VM4ACLI/VM4ACLI.entitlements /tmp/nat.entitlements
> /usr/libexec/PlistBuddy -c "Delete :com.apple.vm.networking" /tmp/nat.entitlements
> codesign --force --sign - --entitlements /tmp/nat.entitlements ./.build/release/vm4a
> ./.build/release/vm4a --version   # 必须能打印版本号，而不是被杀掉
> ```
>
> NAT 覆盖 `spawn`/`exec`/`run-code`/`expose-port`/快照/OCI。bridged 模式需要真实的 Apple 开发者签名身份来携带这个受管 entitlement。

## 确认能跑起来

```bash
vm4a --version          # → 2.5.0
vm4a --help             # 列出所有子命令
```

如果 `vm4a --version` 没输出且非零退出，回去看上面的签名警告。

## 心智模型：一台 VM 就是一个文件夹

`vm4a` 做的一切都围绕 **bundle** —— 一个装着 VM 配置、磁盘、身份文件的目录：

```
dev/
├── config.json      # CPU / 内存 / 设备（schemaVersion: 1）
├── state.json       # 运行时状态指针
├── Disk.img         # 磁盘
├── MachineIdentifier
├── NVRAM            # EFI 变量存储（Linux）
├── console.log      # 串口控制台（Linux）
└── .vm4a-run.log    # 后台 worker 日志
```

CLI 创建的 bundle 能在 GUI app 里打开，反之亦然。命令都指向 bundle 路径：`vm4a exec /tmp/vm4a/dev -- …`。

## 30 秒启动第一台 VM

最快的方式是从 OCI registry 拉一个预制镜像：

```bash
# 1. 拉取、启动、等 SSH。
vm4a spawn dev \
    --from ghcr.io/yourorg/python-dev:latest \
    --storage /tmp/vm4a --wait-ssh

# 2. 跑代码。JSON 可被机器解析。
vm4a exec /tmp/vm4a/dev --output json -- python3 -c 'print(1+1)'
# → {"exit_code":0,"stdout":"2\n","stderr":"","duration_ms":312,"timed_out":false}

# 3. 完事。
vm4a stop /tmp/vm4a/dev
```

{: .note }
> 手头没有 registry 镜像？也可以 `vm4a create demo --image ubuntu-24.04-arm64` 从 ISO 构建 —— 但 ISO 安装是交互式的。要自动化，能直接启动到 SSH 的预制 OCI bundle 才是正道。[第一台 VM 教程](tutorials/01-first-vm) 两种都讲。

## 处处是 JSON

每个 agent 原语都支持 `--output json`，每次调用返回一个对象。字段是 **snake_case**：

- `exec` / `run-code` → `{exit_code, stdout, stderr, duration_ms, timed_out}`
- `spawn` → `{id, name, path, os, pid, ip, ssh_ready}`

这正是 `vm4a` 能从 agent 循环里被脚本化驱动的原因。下一步：[教程](tutorials)。
