---
title: 教程
layout: default
parent: 中文文档
nav_order: 2
has_children: true
permalink: /zh/tutorials/
description: "覆盖 VM4A 各个部分的渐进式实操教程。"
---

# 教程
{: .no_toc }

一组循序渐进的实操教程。每篇都自洽：一个目标、前置条件、可直接复制的步骤、以及"你学到了什么"。从头往下走，或直接跳到你需要的功能。
{: .fs-5 .fw-300 }

## 学习路线

| # | 教程 | 你会学到 |
|---|---|---|
| 1 | [第一台 VM](01-first-vm) | 用两种方式创建/启动 Linux VM（OCI 拉取 vs ISO）、拿到 IP、SSH 进去 |
| 2 | [Agent 循环](02-agent-loop) | golden image + 按任务 fork 的模式；快照与 reset |
| 3 | [run-code 与 expose-port](03-run-code-expose-port) | 一次调用跑代码片段；从主机访问 guest 服务 |
| 4 | [MCP 接入](04-mcp) | 把 `vm4a` 接进 Claude Code / Cursor / Cline 当工具 |
| 5 | [HTTP API 与 SDK](05-http-and-sdks) | 用 Python 或 JS/TS 通过 HTTP 驱动 VM |
| 6 | [集群调度](06-cluster) | 把多台 Mac 当一个池子；最低负载调度 |
| 7 | [GitHub Action](07-github-action) | 在自托管 Apple Silicon runner 上、在 VM 里跑代码 |
| 8 | [网络与出站白名单](08-networking-egress) | NAT/bridged/none 模式；把 guest 锁到白名单 |
| 9 | [快照](09-snapshots) | 保存/恢复完整 VM 状态，实现亚秒级重置 |
| 10 | [Pools](10-pools) | 用 warm pool 实现毫秒级按任务发放 VM |

## 全篇约定

- `/tmp/vm4a` 是存储目录，`dev` 是 bundle 名 —— 随意改。
- 命令假设 `vm4a` 已在 `PATH` 上且已签名（见[快速上手](../getting-started)）。
- 在 JSON 结构重要的地方会显示 `--output json`。

{: .tip }
> 没有可直接启动的镜像？教程 1 同时讲了 OCI 拉取（最快）和从 ISO 构建两条路。
