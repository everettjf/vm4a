---
title: 5 · HTTP API 与 SDK
layout: default
parent: 教程
grand_parent: 中文文档
nav_order: 5
description: "用 Python 或 JS/TS 通过 localhost HTTP API 驱动 VM。"
---

# HTTP API 与 SDK
{: .no_toc }

**目标：** 用 Python 或 JS/TS 自定义 harness，通过 HTTP 驱动 VM。
{: .fs-5 .fw-300 }

- TOC
{:toc}

---

## 启动 server

```bash
vm4a serve --port 7777
# 可选 bearer 鉴权：启动前 export VM4A_AUTH_TOKEN=secret
# 远程/集群用：vm4a serve --bind 0.0.0.0 --port 7777（务必配 token）
```

默认绑 `127.0.0.1`。

## 端点

| 端点 | 请求体 | 返回 |
|---|---|---|
| `GET /v1/health` | — | `{status, version}` *(免鉴权)* |
| `POST /v1/spawn` | SpawnOptions | SpawnOutcome |
| `POST /v1/run_code` | `{vm_path, language, code, …}` | ExecResult |
| `POST /v1/expose_port` | `{vm_path, port, scheme?, host?}` | `{url, host, port, scheme}` |
| `POST /v1/exec` | `{vm_path, command, …}` | ExecResult |
| `POST /v1/cp` | `{vm_path, source, destination, …}` | ExecResult |
| `POST /v1/fork` | `{source_path, destination_path, …}` | ForkOutcome |
| `POST /v1/reset` | `{vm_path, from, …}` | ResetOutcome |
| `GET /v1/vms` | `?storage=/path` | `[VMSummary]` |
| `GET /v1/vms/ip` | `?path=/bundle` | `[Lease]` |
| `POST /v1/vms/stop` | `{vm_path, timeout?}` | StopOutcome |

设了 `VM4A_AUTH_TOKEN` 后，除 `GET /v1/health` 外每个端点都要 `Authorization: Bearer <token>`（否则 `401`）。

```bash
curl -s localhost:7777/v1/health
# → {"status":"ok","version":"2.5.0"}
```

{: .note }
> 响应 JSON 是 **snake_case**（`exit_code`、`duration_ms`、`timed_out`、`ssh_ready`）。下面的 SDK 与之一致。

## Python SDK

只用 stdlib（不依赖 `requests`/`httpx`）：

```python
from vm4a import Client

c = Client()                       # http://127.0.0.1:7777，或 Client(token="…")
vm = c.spawn(name="dev", from_="ghcr.io/yourorg/python-dev:latest", wait_ssh=True)

out = c.run_code(vm.path, "python", "print(1+1)")
print(out.exit_code, out.stdout)   # 0  "2\n"

url = c.expose_port(vm.path, 8000).url   # http://192.168.64.7:8000
```

发布后 `pip install vm4a`；之前用 `PYTHONPATH=sdk/python/src` 直接跑源码。

## JavaScript / TypeScript SDK

零依赖，用内置全局 `fetch`（Node 18+）：

```ts
import { Client } from "vm4a";

const c = new Client();             // 或 new Client({ token: "…" })
const vm = await c.spawn("dev", { from: "ghcr.io/yourorg/python-dev:latest", waitSsh: true });

const out = await c.runCode(vm.path, "python", "print(1+1)");
console.log(out.exit_code, out.stdout);   // 0  "2\n"

const { url } = await c.exposePort(vm.path, 8000);
```

发布后 `npm install vm4a`；之前先 `cd sdk/typescript && npm install && npm run build`。

{: .tip }
> 字段名跟随协议：`out.exit_code`（不是 `exitCode`）。完整 agent 循环示例在 `sdk/typescript/examples/agent_loop.ts`。

## 你学到了什么

- `vm4a serve` 把每个原语暴露成 localhost REST API，可选 bearer 鉴权。
- Python 与 JS/TS SDK 镜像同一组操作和 snake_case 协议结构。

**下一篇：** [集群调度](06-cluster) —— 把多台 Mac 放到一个调度器后面。
