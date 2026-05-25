---
title: 10 · Pools
layout: default
parent: 教程
grand_parent: 中文文档
nav_order: 10
description: "定义按任务的 VM 模板，并运行 warm pool 实现毫秒级发放。"
---

# Pools
{: .no_toc }

**目标：** 从模板批量生成按任务 VM，并维持一个 warm pool 实现即时发放。
{: .fs-5 .fw-300 }

- TOC
{:toc}

---

## 按需：一个 pool 定义

只定义一次"如何生成一台按任务的新 VM"，然后每个任务调 `pool spawn`：

```bash
# 一次性，在 golden VM 配好之后：
vm4a pool create py \
    --base /tmp/vm4a/python-dev \
    --snapshot /tmp/vm4a/python-dev/clean.vzstate \
    --prefix task --storage /tmp/vm4a-tasks

# 每个任务（等价于 fork --auto-start）：
vm4a pool spawn py --wait-ssh
# → 生成 /tmp/vm4a-tasks/task-<unix-时间戳>
```

定义是 `~/.vm4a/pools/<name>.json` 里的 JSON：

```bash
vm4a pool list
vm4a pool show py
vm4a pool destroy py
```

## Warm pool：毫秒级发放

对延迟敏感的负载，跑一个 daemon，保持 `--size N` 台 VM 空闲待命。这时 `pool acquire` 就是一次原子文件系统重命名 —— 毫秒级：

```bash
vm4a pool create py \
    --base /tmp/vm4a/python-dev \
    --snapshot /tmp/vm4a/python-dev/clean.vzstate \
    --prefix task --storage /tmp/vm4a-tasks \
    --size 4

vm4a pool serve py &        # daemon；重启安全（接管已有 warm VM）

# 每个任务：acquire（即时）→ exec → release
VM=$(vm4a pool acquire py --output json | jq -r .path)
vm4a exec "$VM" -- python3 /work/step.py
vm4a pool release "$VM"
```

磁盘上：

- `<storage>/<prefix>-warm-<n>` —— 空闲、daemon 拥有、待发放
- `<storage>/<prefix>-leased-<label>` —— 已认领；在 `release` 前归你

## 用哪个

- `pool spawn` —— 按需，无 daemon。简单。
- `pool acquire` / `release` —— 热路径，亚毫秒发放。需跑 `pool serve`。

按各自负载自由搭配。

## 你学到了什么

- **pool 定义**捕获按任务生成的配方（base + 快照 + 前缀）。
- **warm pool**（`pool serve` + `acquire`/`release`）近乎即时地发放就绪 VM。

**教程到此结束。** 回到[教程目录](./)，或看仓库的 [`Usage.zh-CN.md`](https://github.com/everettjf/vm4a/blob/main/Usage.zh-CN.md) 获取完整逐命令参考。
