---
title: 7 · GitHub Action
layout: default
parent: 教程
grand_parent: 中文文档
nav_order: 7
description: "在自托管 Apple Silicon runner 上、在 VM4A VM 里跑代码。"
---

# GitHub Action
{: .no_toc }

**目标：** 把"在一台新 VM 里跑命令"作为一个 CI 步骤。
{: .fs-5 .fw-300 }

- TOC
{:toc}

---

## 为什么要自托管

GitHub 托管的 macOS runner 本身就是 VM，**无法嵌套** `Virtualization.framework`。所以这个 Action 面向**自托管 Apple Silicon runner**。它从 checkout 出来的仓库 build + codesign `vm4a`，再驱动它。

## 最小 workflow

```yaml
jobs:
  test-in-vm:
    runs-on: [self-hosted, macos, arm64]
    steps:
      - uses: actions/checkout@v4
      - uses: everettjf/vm4a@main
        id: vm
        with:
          from: ghcr.io/yourorg/python-dev:latest
          name: ci-${{ github.run_id }}
          command: "python3 -m pytest -q"      # 通过 `vm4a exec -- bash -lc` 运行
          allow-domains: pypi.org,github.com    # Linux 出站白名单
          cleanup: "true"                       # job 结束时停掉 + 删除 VM
      - run: echo "exit=${{ steps.vm.outputs.exit-code }} ip=${{ steps.vm.outputs.ip }}"
```

这个 Action 会 spawn 一台 VM（拉 `from`，或用 `image` 构建），通过 `bash -lc` 在里面跑 `command`，抓取结果 —— 除非 `cleanup: false`，否则 job 结束时停掉并删除 VM。guest 内命令**非零退出时 job 失败**。

## 输入

| 输入 | 默认 | 说明 |
|---|---|---|
| `command` *(必填)* | — | 在 guest 里通过 `bash -lc` 运行的 shell 命令 |
| `from` / `image` | `""` | 要拉的 OCI ref，或要构建的 catalog id / 路径 / URL（互斥） |
| `name` | `ci` | bundle 名（`<storage>/<name>`） |
| `os` | `linux` | `linux` 或 `macOS` |
| `storage` | `/tmp/vm4a` | bundle 父目录 |
| `wait-timeout` | `180` | 等 SSH 的秒数 |
| `exec-timeout` | `600` | 命令允许运行的秒数 |
| `allow-domains` | `""` | 逗号分隔的 Linux 出站白名单 |
| `cleanup` | `true` | 跑完后停掉 + 删除 VM |

## 输出

`exit-code`、`stdout`、`ip`。

## 配置 runner

runner Mac 需要 `vm4a` 的签名能正常工作。在 macOS 26 上，这意味着要用只含 NAT 的签名方案（见[快速上手](../getting-started)），除非你有能携带 bridged entitlement 的 Apple 开发者身份。NAT 足够这个 Action 用。

## 你学到了什么

- 这个 Action 在自托管 Apple Silicon runner 上、在一台 VM 里跑一次性的"spawn → exec → 清理"。
- `allow-domains` 按次运行应用出站白名单；`cleanup` 负责收尾。

**下一篇：** [网络与出站白名单](08-networking-egress) —— `allow-domains` 到底做了什么。
