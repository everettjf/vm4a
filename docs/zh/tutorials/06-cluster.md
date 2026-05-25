---
title: 6 · 集群调度
layout: default
parent: 教程
grand_parent: 中文文档
nav_order: 6
description: "把多台 Mac 当一个池子，把 VM 落到负载最低的节点上。"
---

# 集群调度
{: .no_toc }

**目标：** 把多台 Mac 当成一台机器来调度 VM。
{: .fs-5 .fw-300 }

- TOC
{:toc}

---

## 思路

单台 Mac 核数有限。集群调度把若干台各自跑着 `vm4a serve` 的 Mac 当成一个池子，把新 VM 落到**负载最低**的节点（"运行 VM 最少者胜"）。不可达节点会被跳过。

```
  控制端  ──cluster spawn──►  选负载最低的可达节点
       │
       ├── mac-studio  (vm4a serve, 10.0.0.5:7777)   3 台 VM
       └── mac-mini    (vm4a serve, 10.0.0.6:7777)   1 台 VM   ◄── 落在这
```

## 第 1 步 —— 每台 worker Mac 跑一个 server

```bash
# 每台 worker，用共享 token，绑到 LAN：
export VM4A_AUTH_TOKEN=shared-secret
vm4a serve --bind 0.0.0.0 --port 7777
```

## 第 2 步 —— 在控制端注册节点

```bash
vm4a cluster add mac-studio --url http://10.0.0.5:7777 --token shared-secret
vm4a cluster add mac-mini   --url http://10.0.0.6:7777 --token shared-secret
vm4a cluster list
# mac-studio   http://10.0.0.5:7777   auth
# mac-mini     http://10.0.0.6:7777   auth
```

注册表是 `~/.vm4a/cluster/` 下的纯 JSON —— 可纳入版本管理或做成模板，复现固定机群。

## 第 3 步 —— 落到负载最低的节点

```bash
vm4a cluster spawn dev --from ghcr.io/yourorg/python-dev:latest --wait-ssh
# → {"node":"mac-mini","outcome":{ …SpawnOutcome… }}
```

## 第 4 步 —— 指定节点做后续

```bash
vm4a cluster exec --node mac-mini /tmp/vm4a/dev -- python3 /work/step.py
vm4a cluster status        # 汇总所有节点的 VM 数量
```

## 命令参考

| 子命令 | 作用 |
|---|---|
| `cluster add <name> --url <u> [--token <t>]` | 注册一个远程 `vm4a serve` 节点 |
| `cluster remove <name>` | 注销节点 |
| `cluster list [--output json]` | 列出节点 + 可达性 |
| `cluster spawn <name> [spawn 参数]` | 落到负载最低的可达节点 |
| `cluster exec --node <name> <vm> -- <cmd>` | 在指定节点的 VM 上 exec |
| `cluster status [--output json]` | 汇总各节点 VM 数量 |

{: .warning }
> 每个节点都是一个对网络开放的完整 `vm4a serve`。**只在设了 `VM4A_AUTH_TOKEN` 时**才绑 `0.0.0.0`，并且只放在可信 LAN 上。

## 你学到了什么

- `vm4a serve` 节点 + `cluster add` 组成池子；`cluster spawn` 按最低负载调度。
- 节点注册表就是 `~/.vm4a/cluster/` 下的 JSON。

**下一篇：** [GitHub Action](07-github-action) —— 同样的思路用在 CI 里。
