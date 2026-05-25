---
title: 9 · 快照
layout: default
parent: 教程
grand_parent: 中文文档
nav_order: 9
description: "保存并恢复完整 VM 执行状态，实现亚秒级重置。"
---

# 快照
{: .no_toc }

**目标：** 冻结一台 VM 的完整执行状态，并在一秒内恢复。
{: .fs-5 .fw-300 }

- TOC
{:toc}

---

## 环境要求

VZ 快照需要 **macOS 14+**。状态存在一个 `.vzstate` 文件里 —— 是整台机器的状态（内存 + 设备），不只是磁盘。

## 保存与恢复

```bash
# VM 停止时保存运行状态：
vm4a run  /tmp/vm4a/demo --save-on-stop /tmp/vm4a/demo/state.vzstate
vm4a stop /tmp/vm4a/demo                    # 关机途中暂停 + 保存

# 原样恢复到离开时的位置：
vm4a run  /tmp/vm4a/demo --restore /tmp/vm4a/demo/state.vzstate
```

`spawn` 接受同样的 flag，所以一条命令既启动 VM 又装好保存快照：

```bash
vm4a spawn dev --from ghcr.io/yourorg/python-dev:latest \
    --save-on-stop /tmp/vm4a/dev/clean.vzstate --wait-ssh
```

## 为什么对 agent 重要

开机成本只付一次。首次启动后存一个干净快照，之后**每个任务都从恢复开始，约 1 秒**，而不是冷启动。这就是 [Agent 循环](02-agent-loop)背后的引擎：

```bash
# 每个任务 —— 恢复进一个 fork，跑，失败就 reset 回快照
vm4a fork  /tmp/vm4a/dev /tmp/vm4a/task-7 --auto-start \
     --from-snapshot /tmp/vm4a/dev/clean.vzstate --wait-ssh
vm4a reset /tmp/vm4a/task-7 --from /tmp/vm4a/dev/clean.vzstate --wait-ip
```

## 你学到了什么

- `--save-on-stop` / `--restore` 捕获并回放完整 VM 状态（macOS 14+）。
- 快照把每个任务的开机成本变成亚秒级恢复。

**下一篇：** [Pools](10-pools) —— 毫秒级发放热 VM。
