---
title: 8 · 网络与出站白名单
layout: default
parent: 教程
grand_parent: 中文文档
nav_order: 8
description: "NAT / bridged / none 模式，以及把 Linux guest 锁到出站白名单。"
---

# 网络与出站白名单
{: .no_toc }

**目标：** 选择 VM 如何连网，并限制它能访问什么。
{: .fs-5 .fw-300 }

- TOC
{:toc}

---

## 网络模式

`--network <mode>` 选 NIC：

| 模式 | 作用 |
|---|---|
| `nat`（默认） | 在 `192.168.64.0/24` 上做 NAT；用 `vm4a ip` 找 IP |
| `bridged` | 从你 LAN 的 DHCP 拿 IP。配合 `--bridged-interface <bsdName>`；不指定则用第一个可用的 |
| `host` | `bridged` 的别名 |
| `none` | 没有 NIC。用于离线任务或只走文件系统 |

```bash
vm4a network list                              # 列出 bridged 接口（bsdName）
vm4a spawn web   --image ubuntu-arm64.iso --network bridged --bridged-interface en0
vm4a spawn airgap --image ubuntu-arm64.iso --network none
```

{: .warning }
> **bridged 模式需要 `com.apple.vm.networking` entitlement。** 在 macOS 26 上这个 entitlement 无法 ad-hoc 签名（二进制会一启动就被杀）。用 NAT，或用真实的 Apple 开发者身份签名 —— 见[快速上手](../getting-started)。bridged VM 也没有 Apple DHCP 租约，所以给 `ssh`/`exec`/`cp`/`expose-port` 传 `--host <ip>`。

## 出站白名单（Linux guest）

如果某次运行只应访问一组已知主机 —— 让 agent 能连 `pypi.org` 和 `github.com`、其余全禁 —— 就在 guest **内部**套一层 `nftables` 白名单。

**spawn 时指定**（SSH 起来后自动应用）：

```bash
vm4a spawn dev --from ghcr.io/yourorg/python-dev:latest --wait-ssh \
    --allow-domains pypi.org,github.com
```

**事后，或在运行中的 guest 上重新应用：**

```bash
vm4a network guard /tmp/vm4a/dev --allow-domains pypi.org,github.com

# 重新应用之前存好的策略（不用再传 --allow-domains）：
vm4a network guard /tmp/vm4a/dev
```

策略持久化到 `<bundle>/egress.json`，所以重启后仍在。guard 把每个域名解析成 IP，写出一套 `nftables` 规则，丢弃发往其他地方的出站流量（DNS 和 loopback 保持开放）。

{: .note }
> 出站过滤加固的是 **guest**，不是主机，且只支持 Linux（macOS guest 不受影响）。完全离线就配 `--network none`；只需访问少量固定端点时，用 `nat` + 白名单。

## 你学到了什么

- 四种网络模式：`nat`（默认）、`bridged`/`host`、`none`。
- `--allow-domains` / `vm4a network guard` 把 Linux guest 锁到 nftables 白名单，持久化在 `egress.json`。

**下一篇：** [快照](09-snapshots) —— 冻结并恢复完整 VM 状态。
