---
title: 1 · 第一台 VM
layout: default
parent: 教程
grand_parent: 中文文档
nav_order: 1
description: "用两种方式创建并启动 Linux VM，拿到 IP，SSH 进去。"
---

# 第一台 VM
{: .no_toc }

**目标：** 启动一个 Linux guest，找到它的 IP，在里面跑个命令。
{: .fs-5 .fw-300 }

- TOC
{:toc}

---

## 前置条件

- 已安装并签名 `vm4a`（见[快速上手](../getting-started)）。
- 约 5 GB 空闲磁盘。

## 路线 A —— 拉预制镜像（最快）

预制的 OCI bundle 直接启动到 SSH，没有安装步骤。任何自动化都推荐这条路。

```bash
vm4a spawn dev \
    --from ghcr.io/yourorg/python-dev:latest \
    --storage /tmp/vm4a \
    --wait-ssh --output json
```

`spawn` 创建 bundle、启动 VM，并（带 `--wait-ssh`）阻塞到 SSH 响应。它返回的 JSON 就是你的句柄：

```json
{"id":"…","name":"dev","path":"/tmp/vm4a/dev","os":"linux","pid":4242,"ip":"192.168.64.7","ssh_ready":true}
```

直接跳到 [在里面跑点东西](#在里面跑点东西)。

## 路线 B —— 从 ISO 创建

没有 registry 镜像时，从 catalog id、本地 ISO 或任意 URL 构建。`vm4a` 会帮你下载并缓存。

```bash
# Catalog id（vm4a 下载 + 缓存 ISO）
vm4a create demo --image ubuntu-24.04-arm64 --storage /tmp/vm4a \
    --cpu 4 --memory-gb 4 --disk-gb 32

vm4a run /tmp/vm4a/demo            # 启动（后台 worker）
```

{: .warning }
> 标准 Ubuntu **Server ISO 的安装程序是交互式的** —— 它不会自己走到 SSH。要么在 GUI app 里手动装一次，要么用带 cloud-init 种子的 cloud image。要无人值守自动化，优先路线 A（预制 OCI bundle）。

`vm4a image list` 列出 catalog id；`vm4a image where` 打印缓存目录（`~/.cache/vm4a/images/`）。

## 找到 IP

NAT VM 从 Apple 的 DHCP server 拿地址：

```bash
vm4a ip /tmp/vm4a/dev               # → 192.168.64.7
vm4a ip /tmp/vm4a/dev --output json # → [{"ip":"…","mac":"…","name":"dev"}]
```

如果没返回，说明 VM 还在启动 / DHCP 中 —— 等 10–30 秒。

## 在里面跑点东西

```bash
# 流式输出，退出码即进程退出码：
vm4a exec /tmp/vm4a/dev -- python3 -c 'print(1+1)'

# 机器可读：
vm4a exec /tmp/vm4a/dev --output json -- bash -lc 'uname -a'
# → {"exit_code":0,"stdout":"Linux …\n","stderr":"","duration_ms":280,"timed_out":false}
```

用 `vm4a ssh /tmp/vm4a/dev` 开交互 shell。Linux 默认 SSH 用户是 `root`，用 `--user` 覆盖。

## 拷贝文件

`:` 前缀标记 guest 侧（和 `docker cp` 相反）：

```bash
vm4a cp /tmp/vm4a/dev ./local.py :/work/script.py    # 主机 → guest
vm4a cp /tmp/vm4a/dev :/var/log/syslog ./syslog.txt  # guest → 主机
vm4a cp /tmp/vm4a/dev -r ./project :/srv/code         # 递归
```

## 停止与清理

```bash
vm4a stop /tmp/vm4a/dev
rm -rf /tmp/vm4a/dev        # bundle 就是个文件夹
```

## 你学到了什么

- 一台 VM 就是一个 **bundle**（文件夹）；命令都指向它的路径。
- `spawn --from` 是一步拉取并启动；`create --image` 从介质构建。
- `ip`、`exec`、`cp`、`ssh` 是基本的 guest 交互，都可选 `--output json`。

**下一篇：** [Agent 循环](02-agent-loop) —— 你实际做按任务工作时会用的模式。
