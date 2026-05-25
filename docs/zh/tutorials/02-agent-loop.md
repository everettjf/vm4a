---
title: 2 · Agent 循环
layout: default
parent: 教程
grand_parent: 中文文档
nav_order: 2
description: "golden image + 按任务 fork 的模式，配合快照与 reset。"
---

# Agent 循环
{: .no_toc }

**目标：** 又快又安全地跑大量任务 —— 每个任务一台用完即弃的新机器。
{: .fs-5 .fw-300 }

- TOC
{:toc}

---

## 思路

每个任务都开机太慢。VM4A 的模式是一个 **golden bundle** 加上**按任务 APFS 克隆的 fork**：

```
   golden bundle           按任务 fork             按任务 fork
   ┌───────────┐  fork →   ┌───────────┐           ┌───────────┐
   │   /dev    │  ──────►  │ /task-42  │           │ /task-43  │  ...
   └───────────┘           └───────────┘           └───────────┘
   只配置一次               APFS clonefile，~1s      exec 完即弃
```

`fork` 用 APFS `clonefile(2)`，所以创建一台按任务 VM 是 **O(目录条目数)，不是 O(磁盘大小)**。配合快照，agent 从"我要一台干净机器"到"SSH 就绪的 VM"大约一秒。

## 第 1 步 —— 只构建一次 golden image

```bash
vm4a spawn dev \
    --from ghcr.io/yourorg/python-dev:latest \
    --storage /tmp/vm4a \
    --save-on-stop /tmp/vm4a/dev/clean.vzstate \
    --wait-ssh --output json

# 安装任务需要的东西：
vm4a exec /tmp/vm4a/dev -- bash -lc "apt-get update && apt-get install -y ripgrep"

# 停止 —— VM 关机时把完整状态存进 clean.vzstate（macOS 14+）。
vm4a stop /tmp/vm4a/dev
```

## 第 2 步 —— 每个任务：fork、推代码、跑

```bash
JOB_ID="task-$(date +%s)"

vm4a fork /tmp/vm4a/dev "/tmp/vm4a/$JOB_ID" \
    --auto-start --from-snapshot /tmp/vm4a/dev/clean.vzstate --wait-ssh

vm4a cp   "/tmp/vm4a/$JOB_ID" ./step.py :/work/step.py
vm4a exec "/tmp/vm4a/$JOB_ID" --output json --timeout 120 -- python3 /work/step.py
# → {"exit_code":0,"stdout":"…","stderr":"","duration_ms":3142,"timed_out":false}
```

`fork` 还会重新随机化 VM 的 `MachineIdentifier`，所以克隆体作为一台独立主机启动。它就是 agent 循环里 `clone` 本该有的样子。

## 第 3 步 —— 状态坏了？一秒内 reset

```bash
vm4a reset "/tmp/vm4a/$JOB_ID" --from /tmp/vm4a/dev/clean.vzstate --wait-ip
```

`reset` 停掉 VM 再从快照重启 —— try → fail → reset → retry 的循环。

## 第 4 步 —— 完事，扔掉

```bash
vm4a stop "/tmp/vm4a/$JOB_ID"
rm -rf "/tmp/vm4a/$JOB_ID"
```

## 另一种形态：长期存活的 VM

当状态必须跨任务累积时（比如交互式 Jupyter 会话），跳过 fork：`spawn` 一次，然后对同一个 bundle 反复 `exec`。

## 记录发生了什么

给任意原语加 `--session <id>`，`vm4a` 就会往 `<bundle>/.vm4a-sessions/<id>.jsonl` 追加 JSONL 事件：

```bash
SID="run-$(date +%s)"
vm4a fork /tmp/vm4a/dev /tmp/vm4a/task-1 --auto-start \
    --from-snapshot /tmp/vm4a/dev/clean.vzstate --wait-ssh --session $SID
vm4a exec /tmp/vm4a/task-1 --session $SID -- python3 /work/step.py
vm4a session show $SID --bundle /tmp/vm4a/task-1
```

## 你学到了什么

- 只配置一次 **golden bundle**；每个任务 **fork** 一个用完即弃的副本，约 1 秒。
- `--save-on-stop` / `--from-snapshot` / `reset` 提供亚秒级的干净起点。
- `--session` 记录一次运行的可回放时间线。

**下一篇：** [run-code 与 expose-port](03-run-code-expose-port) —— 每个任务更少的往返。
