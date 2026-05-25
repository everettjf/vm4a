---
title: 中文文档
layout: default
nav_order: 90
has_children: true
permalink: /zh/
description: "VM4A 中文文档 —— 在 Apple Silicon 上为 AI agent 提供隔离的 macOS / Linux 虚拟机。"
---

# VM4A —— 给 Agent 用的虚拟机
{: .fs-8 }

在 Apple Silicon 上启动隔离的 **macOS 或 Linux** 虚拟机，给 AI agent 一个能安全跑代码的真实环境。基于 Apple 的 [Virtualization framework](https://developer.apple.com/documentation/virtualization)，由单个命令行工具 `vm4a` 驱动。
{: .fs-5 .fw-300 }

[快速上手](getting-started){: .btn .btn-primary .fs-5 .mb-4 .mb-md-0 .mr-2 }
[开始教程](tutorials){: .btn .fs-5 .mb-4 .mb-md-0 .mr-2 }
[English](../){: .btn .fs-5 .mb-4 .mb-md-0 }

---

## VM4A 是什么？

各种编码 agent —— Claude Code、Cursor、OpenAI Codex、或你自己写的 loop —— 反复需要同一样东西：**一台干净、隔离、可以随便折腾的机器**。VM4A 本地优先，跑在你自己的 Mac 上，给 agent 一台真实的 VM：可以创建、跑代码、打快照、fork、用完即弃 —— 每个任务大约一秒。

一个二进制 `vm4a` 管理整个生命周期：创建、运行、快照、fork、OCI 推送/拉取，以及面向 agent 的各种接入方式（CLI、MCP、HTTP API、SDK、集群调度）。

```bash
# 拉取预制镜像、启动、等 SSH、跑代码 —— 各一行。
vm4a spawn dev --from ghcr.io/yourorg/python-dev:latest --storage /tmp/vm4a --wait-ssh
vm4a run-code /tmp/vm4a/dev --lang python --code 'print(1 + 1)'
```

## 四种调用方式

| 接入方式 | 适合场景 | 入口 |
|---|---|---|
| 🐚 **CLI** | shell 脚本、CI、手动调试 | `vm4a <command>` |
| 🤖 **MCP** | Claude Code / Cursor / Cline 等支持 MCP 的 AI | `vm4a mcp` |
| 🌐 **HTTP + SDK** | 自定义 harness、各种语言绑定 | `vm4a serve` + Python / JS-TS |
| 🛰 **Cluster** | 多台 Mac 当一个池子 | `vm4a cluster …` |

## 该看哪里

- **第一次用？** → [快速上手](getting-started)：安装 `vm4a` 并启动你的第一台 VM。
- **想边做边学？** → [教程](tutorials)：每个功能从头到尾走一遍。
- **查 flag 或 JSON 字段？** → 仓库里的 [`Usage.zh-CN.md`](https://github.com/everettjf/vm4a/blob/main/Usage.zh-CN.md) 是逐命令参考。
- **卡住了？** → [故障排查](troubleshooting)。

---

## 环境要求

- Apple Silicon Mac（M1 及以上）
- macOS 13+（VZ 快照需要 macOS 14+）
- 从源码构建还需要 Swift 6 工具链（Xcode 16+）

{: .note }
> VM4A 念作 **"VM for Agent"**，CLI 二进制叫 `vm4a`。
