---
title: 4 · MCP 接入
layout: default
parent: 教程
grand_parent: 中文文档
nav_order: 4
description: "把 VM4A 的每个原语作为 MCP 工具暴露给 Claude Code / Cursor / Cline。"
---

# MCP 接入
{: .no_toc }

**目标：** 让 AI 助手直接 spawn VM 并在里面跑代码 —— 不写胶水代码。
{: .fs-5 .fw-300 }

- TOC
{:toc}

---

## 这给你什么

`vm4a mcp` 在 stdio 上跑一个 [Model Context Protocol](https://modelcontextprotocol.io) server。注册之后，助手就把 VM4A 的每个原语当成可调用工具，返回和 CLI 一样的 JSON 结构。

## 注册 server

**Claude Code** —— 加到项目级或用户级的 `.mcp.json`：

```json
{
  "mcpServers": {
    "vm4a": { "command": "vm4a", "args": ["mcp"] }
  }
}
```

**Cursor** —— 同样的 JSON 放到 `~/.cursor/mcp.json`。
**Cline** —— 粘到 Cline 设置面板的 "MCP Servers" 下。

server 走按行分隔的 JSON-RPC 2.0 over stdio（protocol version `2024-11-05`）。

## 十个工具

| 工具 | 返回 |
|---|---|
| `spawn` | `{id, name, path, os, pid, ip, ssh_ready}` |
| `run_code` | `{exit_code, stdout, stderr, duration_ms, timed_out}` |
| `expose_port` | `{url, host, port, scheme}` |
| `exec` | `{exit_code, stdout, stderr, duration_ms, timed_out}` |
| `cp` | 同 `exec` |
| `fork` | `{path, name, started, pid, ip}` |
| `reset` | `{path, restored, pid, ip}` |
| `list` | `{id, name, path, os, status, pid, ip}` 数组 |
| `ip` | `{ip, mac, name?}` 数组 |
| `stop` | `{stopped, pid, forced, reason?}` |

## 不用 AI 客户端也能试

server 就是 stdio JSON-RPC，可以直接从 shell 驱动：

```bash
printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n' | vm4a mcp
```

```bash
# initialize，再调一个工具
printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"demo","version":"1"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list","arguments":{"storage":"/tmp/vm4a"}}}' \
  | vm4a mcp
```

## 不止工具：resources 与 prompts

server 还暴露只读 **resources**：

| URI | 返回 |
|---|---|
| `vm4a://vms?storage=/path` | 某目录下的 VM bundle |
| `vm4a://sessions?bundle=/path` | 某 bundle 的已记录 session |
| `vm4a://session/<id>?bundle=/path` | 某 session 的所有事件 |
| `vm4a://pools` | 已保存的 pool 定义 |

……以及预置 **prompts**：`agent-loop`、`debug-failed-task`、`triage-vm`。

## 你学到了什么

- `vm4a mcp` 用一行配置把全部十个原语暴露给任何支持 MCP 的助手。
- 协议就是纯 stdio JSON-RPC —— 容易从 shell 测试和调试。

**下一篇：** [HTTP API 与 SDK](05-http-and-sdks) —— 给非 MCP 客户端的同一组操作。
