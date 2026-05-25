---
title: 故障排查
layout: default
parent: 中文文档
nav_order: 4
description: "VM4A 常见现象与解决办法。"
---

# 故障排查
{: .no_toc }

- TOC
{:toc}

---

## 安装与签名

| 现象 | 可能原因 / 解决 |
|---|---|
| 每条 `vm4a` 命令都退出 `137` 且无输出（macOS 26） | AMFI 因受限的 `com.apple.vm.networking` entitlement 杀掉了 ad-hoc 签名的二进制。改用**只含 NAT** 重新签名 —— 见[快速上手 → 安装](getting-started#安装)。 |
| `network list` 返回空 | CLI 没签 `com.apple.vm.networking`（在 macOS 26 上这需要 Apple 开发者身份）。 |
| `--rosetta` 报 "not installed" | `softwareupdate --install-rosetta --agree-to-license`。 |

## 启动与网络

| 现象 | 可能原因 / 解决 |
|---|---|
| `run` 静默退出 | 看 `<bundle>/.vm4a-run.log`。 |
| `ssh` / `ip` 没结果 | VM 还在启动 / DHCP —— 等 10–30 秒。 |
| Linux guest 卡在启动 | 确认 ISO 是 ARM64；确认 `MachineIdentifier` 和 `NVRAM` 存在。 |
| bridged VM 用 `vm4a ip` 没 IP | bridged 模式不走 Apple DHCP；传 `--host <ip>`（`expose-port --host` 同理）。 |
| `--allow-domains` 不生效 | 出站 guard 只支持 Linux 且需 SSH 已就绪；macOS guest 不受影响。 |

## API、SDK 与集群

| 现象 | 可能原因 / 解决 |
|---|---|
| `vm4a serve` 返回 `401` | 客户端要带同样的 `VM4A_AUTH_TOKEN`（`GET /v1/health` 始终开放）。 |
| SDK 字段是 `undefined` / `nil` | 协议是 **snake_case**（`exit_code`、`duration_ms`、`ssh_ready`）。Python 暴露 snake_case；JS/TS SDK 的接口也是 snake_case。 |
| `cluster spawn` 跳过某节点 | 节点不可达或 token 不匹配 —— 查 `vm4a cluster list` 和该节点的 `VM4A_AUTH_TOKEN`。 |
| `push` 返回 HTTP 401 | 设置 `VM4A_REGISTRY_USER` / `VM4A_REGISTRY_PASSWORD`。 |

## macOS guest

| 现象 | 可能原因 / 解决 |
|---|---|
| macOS guest 装完后黑屏 | 正常 —— 它在 Setup Assistant。在 GUI app 里手动过一次。 |
| `vm4a exec /macos-vm` → "Connection refused" | 在 guest 里开 Remote Login：系统设置 → 通用 → 共享 → 远程登录。 |
| 快照 flag 被拒 | 需要 macOS 14+ 主机。 |

---

还是卡住？到 [github.com/everettjf/vm4a/issues](https://github.com/everettjf/vm4a/issues) 提 issue。
