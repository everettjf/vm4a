# 使用指南

如何实际使用 `vm4a` —— 每个命令、每种接入方式，配实例。

> English: [Usage.md](Usage.md)

## 目录

- [快速上手](#快速上手)
- [Agent 工作流](#agent-工作流)
- [Agent 原语](#agent-原语) — `spawn`、`exec`、`cp`、`fork`、`reset`、`run-code`、`expose-port`
- [经典生命周期命令](#经典生命周期命令) — `create`、`list`、`run`、`stop`、`clone`、`ip`、`ssh`
- [MCP —— Claude Code、Cursor、Cline](#mcp--claude-codecursorcline)
- [HTTP API 与 SDK](#http-api-与-sdk) — Python + JavaScript/TypeScript
- [Cluster —— 跨主机调度](#cluster--跨主机调度)
- [GitHub Action](#github-action)
- [Sessions —— 记录 Agent 运行](#sessions--记录-agent-运行)
- [Pools —— 批量生成任务 VM](#pools--批量生成任务-vm)
- [OCI 模板与镜像分发](#oci-模板与镜像分发)
- [网络](#网络) — 模式 + 出站白名单
- [Rosetta（在 Linux guest 跑 x86）](#rosetta在-linux-guest-跑-x86)
- [快照（macOS 14+）](#快照macos-14)
- [Bundle 文件结构](#bundle-文件结构)
- [退出码](#退出码)
- [故障排查](#故障排查)

---

## 快速上手

```bash
brew tap everettjf/tap && brew install vm4a
```

启动一个 VM 的三种方式，按"打字最少"排序：

```bash
# 1. 拉预制好的镜像（最快 —— 不用花时间装系统）
vm4a spawn dev \
    --from ghcr.io/everettjf/vm4a-templates/python-dev:latest \
    --storage /tmp/vm4a --wait-ssh

# 2. 用 catalog id —— vm4a 自动下载 + 缓存 ISO/IPSW
vm4a create demo --image ubuntu-24.04-arm64 --storage /tmp/vm4a --memory-gb 4
vm4a create mac  --os macOS                  # 自动拉最新 macOS IPSW

# 3. 本地路径或任意 https URL —— 也会自动缓存
vm4a create demo --image ~/Downloads/ubuntu-24.04-arm64.iso
vm4a create demo --image https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04.1-live-server-arm64.iso

vm4a exec /tmp/vm4a/dev -- python3 -c 'print(1+1)'
vm4a stop /tmp/vm4a/dev
```

`vm4a image list` 看现有 catalog id；`vm4a image pull <id>` 只下载不建 VM；`vm4a image where` 打印缓存目录（`~/.cache/vm4a/images/`）。

每个命令都支持 `--output json`，便于脚本解析。任何子命令的 `--help` 都是它自己选项的权威说明。

---

## Agent 工作流

大多数 Agent 流程符合下面两种形态之一。**一次性任务 VM** 是推荐模式 —— 一个 golden bundle，每个任务用 APFS 克隆一份：

```bash
# 1. 第一次：拉 base 镜像、装好工具、存一份干净快照
vm4a spawn dev \
    --from ghcr.io/yourorg/python-dev-arm64:latest \
    --storage /tmp/vm4a \
    --save-on-stop /tmp/vm4a/dev/clean.vzstate \
    --wait-ssh --output json

vm4a exec /tmp/vm4a/dev -- bash -lc "apt-get install -y ripgrep"
vm4a stop /tmp/vm4a/dev          # save_on_stop 在关机时自动存快照

# 2. 每个任务：APFS 克隆 bundle，从快照重启，跑代码，丢掉
JOB_ID="task-$(date +%s)"
vm4a fork /tmp/vm4a/dev "/tmp/vm4a/$JOB_ID" \
    --auto-start --from-snapshot /tmp/vm4a/dev/clean.vzstate --wait-ssh

vm4a cp   "/tmp/vm4a/$JOB_ID" ./step.py :/work/step.py
vm4a exec "/tmp/vm4a/$JOB_ID" --output json --timeout 120 -- python3 /work/step.py
# → {"exit_code":0,"stdout":"…","stderr":"","duration_ms":3142,"timed_out":false}

# 3. 任务把状态搞坏了？1 秒内回滚到快照
vm4a reset "/tmp/vm4a/$JOB_ID" --from /tmp/vm4a/dev/clean.vzstate --wait-ip

# 4. 完事了，停掉删掉
vm4a stop "/tmp/vm4a/$JOB_ID"
rm -rf "/tmp/vm4a/$JOB_ID"
```

`fork` 用 APFS `clonefile(2)` —— 新建一个任务 VM 是 **O(目录条目数)，不是 O(磁盘镜像大小)**。配合 `--from-snapshot`，从"我要个干净机器"到"VM 跑起来 SSH 就绪"基本就 1 秒。

另一种形态 —— **长期持久化 VM** —— 直接 `vm4a spawn` 一次，然后反复 `vm4a exec`。适合状态需要跨任务累积的场景（比如交互式 Jupyter 会话）。

---

## Agent 原语

### spawn —— 一条命令完成创建+启动

```
vm4a spawn <name> [--os linux|macOS] [--storage <dir>]
                  (--from <oci-ref> | --image <iso-or-ipsw>)
                  [--cpu <n>] [--memory-gb <n>] [--disk-gb <n>]
                  [--bridged-interface <bsdName>] [--rosetta]
                  [--restore <state.vzstate>] [--save-on-stop <state.vzstate>]
                  [--wait-ip] [--wait-ssh]
                  [--ssh-user <name>] [--ssh-key <path>]
                  [--host <ip>] [--wait-timeout <seconds>]
                  [--output text|json] [--session <id>]
```

行为：
- 如果 `<storage>/<name>` 已存在，直接（重新）启动它
- 否则 `--from <oci-ref>` 拉一个 bundle，或者 `--image <iso/ipsw>` 从零创建
- `--wait-ssh`（隐含 `--wait-ip`）阻塞到 SSH 响应或超时
- `--output json` 返回 `{id, name, path, os, pid, ip, ssh_ready}` —— Agent 一次调用就够了

### exec —— SSH 跑命令

```
vm4a exec <vm-path> [--user <name>] [--key <path>] [--host <ip>]
                    [--timeout <seconds>] [--output text|json]
                    [--session <id>] -- <command...>
```

默认用户：Linux 是 `root`，macOS 是当前用户。不加 `--output json` 时 stdout/stderr 流式输出，退出码作为本进程的退出码。加上 `--output json` 后返回 `{exit_code, stdout, stderr, duration_ms, timed_out}`。

```bash
vm4a exec /tmp/vm4a/dev -- python3 -c 'print(1+1)'
vm4a exec /tmp/vm4a/dev --output json --timeout 30 -- bash -lc 'pip install numpy'
```

### cp —— SCP 双向拷贝

```
vm4a cp <vm-path> [-r] [--user <name>] [--key <path>] [--host <ip>]
                  [--timeout <seconds>] [--output text|json]
                  [--session <id>] <source> <destination>
```

路径前缀 `:` 表示 guest 侧，否则是主机路径。两端必须**恰好一端**是 guest 路径。

```bash
vm4a cp /tmp/vm4a/dev ./local.py :/work/script.py        # 主机 → guest
vm4a cp /tmp/vm4a/dev :/var/log/syslog ./syslog.txt      # guest → 主机
vm4a cp /tmp/vm4a/dev -r ./project :/srv/code            # 递归
```

### fork —— APFS 克隆，可选自动启动

```
vm4a fork <source-path> <destination-path>
          [--auto-start] [--from-snapshot <state.vzstate>]
          [--wait-ip] [--wait-ssh]
          [--ssh-user <name>] [--ssh-key <path>]
          [--wait-timeout <seconds>]
          [--output text|json] [--session <id>]
```

`fork` 是面向 Agent 循环的 `clone` —— APFS clonefile 复制 bundle，重新随机化 `MachineIdentifier` 让 fork 启动后是独立机器，加上 `--auto-start` 立刻启动 worker。

### reset —— 停止然后从快照重启

```
vm4a reset <vm-path> --from <state.vzstate>
           [--wait-ip] [--stop-timeout <seconds>] [--wait-timeout <seconds>]
           [--output text|json] [--session <id>]
```

给 try → fail → reset → retry Agent 循环用。停掉 VM（SIGTERM → SIGKILL）然后从指定 `.vzstate` 重启。需要 macOS 14+ 和提前存好的快照（看 `run` 和 `spawn` 的 `--save-on-stop`）。

### run-code —— 写一段代码片段并一次跑完

```
vm4a run-code <vm-path> --lang python|node|bash|sh|ruby
                        (--code '<源码>' | --file <主机路径>)
                        [--user <name>] [--key <path>] [--host <ip>]
                        [--timeout <秒>] [--output text|json]
                        [--pretty] [--session <id>]
```

一次调用顶 `cp` + `exec`。代码片段会写到 guest 里一个私有临时文件，用对应解释器运行，跑完即删。返回和 `exec` 一样的 JSON：`{exit_code, stdout, stderr, duration_ms, timed_out}`。

```bash
vm4a run-code /tmp/vm4a/dev --lang python --code 'print(1+1)'
vm4a run-code /tmp/vm4a/dev --lang node --file ./script.js --output json
```

支持的语言分别映射到 `python3`、`node`、`bash`、`sh`、`ruby`。`--code` / `--file` 只能传其中一个；未知语言、或两个都传/都不传，会在任何 SSH 之前就被拒绝。

### expose-port —— 拿到主机可访问的 guest 端口 URL

```
vm4a expose-port <vm-path> --port <n> [--scheme http|https]
                           [--host <ip>] [--output text|json] [--pretty]
```

NAT guest 在主机侧本来就能用其 DHCP 租约 IP 直连，所以"暴露"端口只是解析出那个 IP 再拼成 URL —— 不开隧道、不起端口转发 daemon。返回 `{url, host, port, scheme}`；text 形式只打印 URL。

```bash
vm4a run-code /tmp/vm4a/dev --lang bash --code 'python3 -m http.server 8000 &'
vm4a expose-port /tmp/vm4a/dev --port 8000
# → http://192.168.64.7:8000
```

`--host <ip>` 会完全跳过 DHCP 查询（bridged VM 用这个，因为 Apple DHCP server 没有它的租约）—— 此时连 bundle 都不需要，直接拼出 URL。

---

## 经典生命周期命令

| 命令 | 用途 |
|---|---|
| `vm4a create [<name>] [--os linux\|macOS] [--image <path>] [...]` | 创建 VM bundle。名字和镜像均可省（默认：自动命名 + Linux 用 `ubuntu-24.04-arm64`，macOS 用最新 IPSW）。Linux 用 ISO，macOS 用 IPSW（直接走完整安装） |
| `vm4a list [--storage <dir>]` | 列出某目录下的 bundle，附带状态、pid、IP |
| `vm4a run <vm-path> [--foreground]` | 后台（默认）或前台启动 VM |
| `vm4a stop <vm-path> [--timeout <s>]` | 先 SIGTERM，超时则 SIGKILL |
| `vm4a clone <src> <dst>` | APFS clonefile 复制 bundle（`fork` 是 Agent 友好的等价命令） |
| `vm4a network list` | 列出 host 上可用的 bridged 接口 |
| `vm4a image list` | 官方维护的 Linux ARM64 ISO 链接 |
| `vm4a push <vm> <ref>` | 推 bundle 到 OCI registry |
| `vm4a pull <ref> [--storage <dir>]` | 从 OCI registry 拉 bundle |
| `vm4a ip <vm>` | 解析 NAT VM 的 IP（读 Apple DHCP leases） |
| `vm4a ssh <vm> [--user <name>] -- <ssh args>` | SSH 进 VM，`--` 后的参数透传给 ssh |

`run` 默认起一个 detached worker —— shell 立即返回，日志写到 `<vm>/.vm4a-run.log`。`--foreground` 直接流式输出 VZ 日志。macOS guest 在 `vm4a create --os macOS --image foo.ipsw` 之后第一次启动会进 Setup Assistant，需要在 VM4A.app 里交互完成一次（建账号 + 打开 Remote Login → 系统设置 → 通用 → 共享），之后所有 vm4a 命令就能 SSH 进去了。

---

## MCP —— Claude Code、Cursor、Cline

把 `vm4a` 注册为 MCP server，AI 助手就能把每个 agent 原语当作可调用工具用 —— 不用写胶水代码、不用 spawn shell 命令。

**Claude Code** —— 在项目级或用户级 `.mcp.json` 里加：

```json
{
  "mcpServers": {
    "vm4a": { "command": "vm4a", "args": ["mcp"] }
  }
}
```

**Cursor** —— 同样的配置写到 `~/.cursor/mcp.json`。**Cline** —— 在 Cline 设置面板的 "MCP Servers" 里添加。

server 走按行分隔的 JSON-RPC 2.0（标准 MCP stdio transport，protocol version `2024-11-05`），暴露 10 个工具：

| 工具 | 返回 |
|---|---|
| `spawn` | `{id, name, path, os, pid, ip, ssh_ready}` |
| `run_code` | `{exit_code, stdout, stderr, duration_ms, timed_out}` —— 写片段并运行 |
| `expose_port` | `{url, host, port, scheme}` |
| `exec` | `{exit_code, stdout, stderr, duration_ms, timed_out}` |
| `cp` | 同 `exec` |
| `fork` | `{path, name, started, pid, ip}` |
| `reset` | `{path, restored, pid, ip}` |
| `list` | `{id, name, path, os, status, pid, ip}` 数组 |
| `ip` | `{ip, mac, name?}` 数组 |
| `stop` | `{stopped, pid, forced, reason?}` |

手动看一下工具目录：

```bash
printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n' | vm4a mcp
```

除了 tools，还暴露：

**Resources** —— vm4a 状态的只读视图：

| URI | 返回 |
|---|---|
| `vm4a://vms?storage=/path` | 某目录下的 VM bundle 列表（默认 cwd） |
| `vm4a://sessions?bundle=/path` | bundle + `~/.vm4a/sessions` 下能发现的 session 列表 |
| `vm4a://session/<id>?bundle=/path` | 某个 session 的所有 JSONL 事件 |
| `vm4a://pools` | 所有保存的池定义 |

**Prompts** —— AI 客户端可以调用的模板：

| Prompt | 参数 | 用途 |
|---|---|---|
| `agent-loop` | `image`、`task_command` | 标准 spawn → fork → exec → reset 模式 |
| `debug-failed-task` | `session_id`、`bundle_path?` | 排查一个已记录的 session，定位首个失败、给出修复建议 |
| `triage-vm` | `vm_path` | VM 快速健康检查（uptime、磁盘、内存、dmesg） |

---

## HTTP API 与 SDK

不走 MCP 的客户端（CI 跑批、自定义脚本、各种语言绑定）可以走 localhost 上的 HTTP server。

```bash
# 启动 server
vm4a serve --port 7777
# 可选 bearer 鉴权: 启动前 export VM4A_AUTH_TOKEN=...
# 绑到所有网卡（给远程/集群用）: vm4a serve --bind 0.0.0.0
```

| 端点 | 请求体 | 返回 |
|---|---|---|
| `GET /v1/health` | — | `{status, version}` *(免鉴权，给健康检查用)* |
| `POST /v1/spawn` | SpawnOptions JSON | SpawnOutcome |
| `POST /v1/run_code` | `{vm_path, language, code, ...}` | ExecResult |
| `POST /v1/expose_port` | `{vm_path, port, scheme?, host?}` | `{url, host, port, scheme}` |
| `POST /v1/exec` | `{vm_path, command, ...}` | ExecResult |
| `POST /v1/cp` | `{vm_path, source, destination, ...}` | ExecResult |
| `POST /v1/fork` | `{source_path, destination_path, ...}` | ForkOutcome |
| `POST /v1/reset` | `{vm_path, from, ...}` | ResetOutcome |
| `GET /v1/vms` | `?storage=/path` | `[VMSummary]` |
| `GET /v1/vms/ip` | `?path=/bundle` | `[Lease]` |
| `POST /v1/vms/stop` | `{vm_path, timeout?}` | StopOutcome |

设了 `VM4A_AUTH_TOKEN` 后，除 `GET /v1/health` 外每个端点都要带 `Authorization: Bearer <token>`，否则返回 `401`。server 默认绑 `127.0.0.1`；只有在设了 token 时才建议 `--bind 0.0.0.0`。

### Python SDK

Python SDK（[`sdk/python/`](sdk/python/)）只用 stdlib 实现（不依赖 `requests`/`httpx`）：

```python
from vm4a import Client

c = Client()  # http://127.0.0.1:7777，或 Client(token="...") 走 bearer 鉴权
vm = c.spawn(name="dev", from_="ghcr.io/yourorg/python-dev:latest", wait_ssh=True)
out = c.run_code(vm.path, "python", "print(1+1)")
print(out.exit_code, out.stdout)              # 0  "2\n"

url = c.expose_port(vm.path, 8000).url        # http://192.168.64.7:8000
```

`pip install vm4a` 等 release 后可用；之前可以用 `PYTHONPATH=sdk/python/src` 直接跑源码。

### JavaScript / TypeScript SDK

零依赖的客户端（[`sdk/typescript/`](sdk/typescript/)）镜像了 Python 的 API，面向 Node 18+（用内置全局 `fetch`）：

```ts
import { Client } from "vm4a";

const c = new Client();                       // 或 new Client({ token: "..." })
const vm = await c.spawn("dev", { from: "ghcr.io/yourorg/python-dev:latest", waitSsh: true });
const out = await c.runCode(vm.path, "python", "print(1+1)");
console.log(out.exit_code, out.stdout);       // 0  "2\n"

const { url } = await c.exposePort(vm.path, 8000);
```

`npm install vm4a` 发布后可用；之前先 `cd sdk/typescript && npm install && npm run build`。完整 Agent 循环示例见 [`sdk/typescript/examples/agent_loop.ts`](sdk/typescript/examples/agent_loop.ts)。

---

## Cluster —— 跨主机调度

单台 Mac 的核数有限。集群调度把若干台各自跑着 `vm4a serve` 的 Mac 当成一个池子，把新 VM 落到负载最低的节点上。

```bash
# 每台 worker Mac：用共享 token 在 LAN 上 serve。
export VM4A_AUTH_TOKEN=shared-secret
vm4a serve --bind 0.0.0.0 --port 7777

# 控制端：注册一次节点（存到 ~/.vm4a/cluster/<name>.json）。
vm4a cluster add mac-studio --url http://10.0.0.5:7777 --token shared-secret
vm4a cluster add mac-mini   --url http://10.0.0.6:7777 --token shared-secret
vm4a cluster list

# 落到运行 VM 最少的节点上。
vm4a cluster spawn dev --from ghcr.io/yourorg/python-dev:latest --wait-ssh
# → 选一个节点，返回 {node, outcome: SpawnOutcome}

# 指定节点做后续操作。
vm4a cluster exec --node mac-studio /tmp/vm4a/dev -- python3 /work/step.py

# 汇总所有节点的 VM 数量。
vm4a cluster status
```

| 子命令 | 作用 |
|---|---|
| `cluster add <name> --url <u> [--token <t>]` | 注册一个远程 `vm4a serve` 节点 |
| `cluster remove <name>` | 注销节点 |
| `cluster list [--output json]` | 列出已注册节点 + 可达性 |
| `cluster spawn <name> [spawn 参数]` | 落到负载最低的可达节点 |
| `cluster exec --node <name> <vm> -- <cmd>` | 在指定节点的 VM 上 exec |
| `cluster status [--output json]` | 汇总各节点 VM 数量 |

调度规则是"运行 VM 最少者胜"；不可达节点会被跳过。注册表就是 `~/.vm4a/cluster/` 下的 JSON —— 可以纳入版本管理或做成模板，复现固定的机群。

---

## GitHub Action

`action.yml` 是给**自托管 Apple Silicon runner** 用的 composite Action（Action 会从 checkout 出来的仓库 build + codesign `vm4a`，再驱动它）。GitHub 托管的 macOS runner 本身是 VM，无法嵌套 Virtualization.framework，所以必须用自托管的 M 系列 runner。

这个 Action 会 spawn 一个 VM（拉 `from` 或用 `image` 构建），通过 `bash -lc` 在里面跑 `command`，抓取结果 —— 除非 `cleanup: false`，否则 job 结束时停掉并删除 VM。

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

| 输入 | 默认 | 说明 |
|---|---|---|
| `command` *(必填)* | — | 在 guest 里通过 `bash -lc` 运行的 shell 命令 |
| `from` / `image` | `""` | 要拉的 OCI ref，或要构建的 catalog id / 路径 / URL（互斥） |
| `name` | `ci` | bundle 名（`<storage>/<name>`） |
| `os` | `linux` | `linux` 或 `macOS` |
| `storage` | `/tmp/vm4a` | bundle 的父目录 |
| `wait-timeout` | `180` | 等 SSH 的秒数 |
| `exec-timeout` | `600` | 命令允许运行的秒数 |
| `allow-domains` | `""` | 逗号分隔的 Linux 出站白名单 |
| `cleanup` | `true` | 跑完后停掉 + 删除 VM |

输出：`exit-code`、`stdout`、`ip`。guest 内命令非零退出时 job 失败。

---

## Sessions —— 记录 Agent 运行

给 `spawn`/`exec`/`cp`/`fork`/`reset` 加 `--session <id>`，`vm4a` 就会往 `<bundle>/.vm4a-sessions/<id>.jsonl` 追加一条 JSONL 事件。每条事件包含 `{seq, timestamp, kind, vmPath, success, durationMs, summary, args, outcome}`。

```bash
SID="run-$(date +%s)"
vm4a fork /tmp/vm4a/dev /tmp/vm4a/task-1 \
    --auto-start --from-snapshot /tmp/vm4a/dev/clean.vzstate \
    --wait-ssh --session $SID
vm4a exec /tmp/vm4a/task-1 --session $SID -- python3 /work/step.py

vm4a session show $SID --bundle /tmp/vm4a/task-1
# ✓ #1  2026-05-03T19:45:00Z  3142ms  fork /tmp/vm4a/dev → /tmp/vm4a/task-1 (started)
# ✓ #2  2026-05-03T19:45:08Z   712ms  exec python3 → exit 0

vm4a session list --bundle /tmp/vm4a/task-1
```

事件追加写入 JSONL，长跑时可以 `tail -f`。

可视化时间线视图：运行 `vm4a-sessions`（和 `vm4a` 一起构建）：

```bash
swift run vm4a-sessions       # 或: ./.build/release/vm4a-sessions
```

会打开一个 SwiftUI 窗口，左侧列表展示发现的所有 session，点击之后右侧时间线展示事件，支持展开 args / outcome 面板。Cmd-R 刷新（跑完新 agent 任务后用）。

> 当前版本 CLI 只在成功路径写事件，throw 的调用不会留下日志条目。把"缺失的 session 文件"理解为"Agent 没跑到记录器那一步"，而不是"全成功了"。

---

## Pools —— 批量生成任务 VM

定义"怎么生成一台任务 VM"一次，之后每个任务调一次 `pool spawn`：

```bash
# golden VM 准备好之后做一次：
vm4a pool create py \
    --base /tmp/vm4a/python-dev \
    --snapshot /tmp/vm4a/python-dev/clean.vzstate \
    --prefix task --storage /tmp/vm4a-tasks

# 每个任务：
vm4a pool spawn py --wait-ssh
# → 生成 /tmp/vm4a-tasks/task-<unix-timestamp>
```

定义存在 `~/.vm4a/pools/<name>.json`。查看或删除：

```bash
vm4a pool list
vm4a pool show py
vm4a pool destroy py
```

对延迟敏感的 workload 可以跑一个预热池 daemon。它保持 `--size N` 台空闲 VM 待命、被取走后自动补，`pool acquire` 是原子 `mv` 操作 —— 毫秒级取出：

```bash
# 创建带 size 的池定义
vm4a pool create py \
    --base /tmp/vm4a/python-dev \
    --snapshot /tmp/vm4a/python-dev/clean.vzstate \
    --prefix task --storage /tmp/vm4a-tasks \
    --size 4

# 启动 daemon（前台运行；重启安全 —— 会接管已有的 warm VM）
vm4a pool serve py &

# 每个任务：acquire（即时）、exec、release
VM=$(vm4a pool acquire py --output json | jq -r .path)
vm4a exec "$VM" -- python3 /work/step.py
vm4a pool release "$VM"
```

磁盘上布局：
- `<storage>/<prefix>-warm-<n>` —— 空闲，daemon 持有，待命
- `<storage>/<prefix>-leased-<label>` —— 已被取走，归 agent 所有直到 `release`

`pool spawn <name>` 是按需路径（不需要 daemon，等价于 `fork --auto-start`）；`pool acquire/release` 是预热路径。两种可以混用，看每个 workload 需要什么。

---

## OCI 模板与镜像分发

预制 bundle 在 `ghcr.io/everettjf/vm4a-templates/*`：

| 模板 | 拉取地址 |
|---|---|
| `ubuntu-base` | `ghcr.io/everettjf/vm4a-templates/ubuntu-base:24.04` |
| `python-dev` | `ghcr.io/everettjf/vm4a-templates/python-dev:latest` |
| `xcode-dev`（macOS，已过 Setup Assistant） | `ghcr.io/everettjf/vm4a-templates/xcode-dev:latest` |

构建脚本和每月自动 rebuild 的 CI 流水线在 [`templates/`](templates/)。

bundle 打包成单个 `tar.gz` 层（media type `application/vnd.vm4a.bundle.v1.tar+gzip`）配一个 JSON config blob。任何 Docker Registry v2 兼容的 registry 都能用（GHCR、Docker Hub、ECR、Harbor、私有部署）。

```bash
# 带认证推送（GHCR 示例）
export VM4A_REGISTRY_USER=yourname
export VM4A_REGISTRY_PASSWORD=ghp_xxx     # 带 write:packages 的 PAT
vm4a push /tmp/vm4a/my-vm ghcr.io/yourname/my-vm:v1

# 公开镜像匿名拉取
vm4a pull ghcr.io/someone/ubuntu-arm:24.04 --storage /tmp/vm4a
```

支持 Bearer token（GHCR 风格）和 HTTP Basic 两种认证。

---

## 网络

`--network <mode>` 控制 VM 怎么联网。可选值：

| 模式 | 含义 |
|---|---|
| `nat`（默认） | NAT 网段 `192.168.64.0/24`，用 `vm4a ip` 查 IP |
| `bridged` | VM 从 LAN DHCP 拿 IP。配合 `--bridged-interface <bsdName>` 指定接口；不指定则用第一个可用的 |
| `host` | `bridged` 的别名（VZ 没有真正独立的 host networking 模式） |
| `none` | 不挂网卡。给离线 workload 或只需要文件 I/O 的 Agent 用 |

```bash
vm4a network list                              # 查 bsdName
vm4a spawn web --image ubuntu-arm64.iso --network bridged --bridged-interface en0
vm4a spawn airgap --image ubuntu-arm64.iso --network none
```

bridged 模式要求 CLI 带 `com.apple.vm.networking` entitlement。源码编译时按 [安装](README.md#安装) 里的 codesign 命令重签即可。bridged VM 的 `vm4a ip` 拿不到结果（不走 Apple 的 DHCP），手动给 `ssh`/`exec`/`cp` 传 `--host <ip>`。`none` 模式没有 SSH，只能通过 virtiofs 或其他非网络方式通信，主要用于启动校验或纯文件类 workload。

> 向后兼容：单独传 `--bridged-interface en0` 不传 `--network` 仍隐含 bridged 模式，和旧 CLI 行为一致。

### 出站白名单（Linux guest）

如果某次运行只应访问一组已知主机（比如让 agent 能连 `pypi.org` 和 `github.com`、其余全禁），可以在 guest 里套一层 `nftables` 白名单。两种入口：

```bash
# spawn 时指定 —— SSH 起来后自动应用。
vm4a spawn dev --from ghcr.io/yourorg/python-dev:latest --wait-ssh \
    --allow-domains pypi.org,github.com

# 或事后 / 在运行中的 guest 上重新应用。
vm4a network guard /tmp/vm4a/dev --allow-domains pypi.org,github.com

# 重新应用之前存好的策略（不用再传 --allow-domains）。
vm4a network guard /tmp/vm4a/dev
```

策略会持久化到 `<bundle>/egress.json`，所以重启后仍在 —— 不带参数重跑 `network guard` 即可重新应用。guard 会把每个域名解析成 IP，写出一套 `nftables` 规则，丢弃发往其他地方的出站流量（DNS 和 loopback 保持开放）。这是 Linux guest 特性；macOS guest 不受影响。

> 出站过滤加固的是 **guest**，不是主机。完全离线就配 `--network none`；只需访问少量固定端点时，用 `nat`/`bridged` + 白名单。

---

## Rosetta（在 Linux guest 跑 x86）

```bash
softwareupdate --install-rosetta --agree-to-license
vm4a create linux-dev --rosetta --image ubuntu-arm64.iso …
```

guest 里挂名为 `rosetta` 的 virtiofs 共享，用 `binfmt_misc` 注册。Apple 有[官方教程](https://developer.apple.com/documentation/virtualization/running_intel_binaries_in_linux_vms_with_rosetta)讲 guest 内步骤。

---

## 快照（macOS 14+）

保存/恢复 VM 完整执行状态（不只是磁盘）：

```bash
vm4a run  /tmp/vm4a/demo --save-on-stop /tmp/vm4a/demo/state.vzstate
vm4a stop /tmp/vm4a/demo                       # 退出前先暂停 + 保存

vm4a run  /tmp/vm4a/demo --restore /tmp/vm4a/demo/state.vzstate
```

`spawn` 也支持同样的 `--save-on-stop` 和 `--restore`，一条命令既启动又武装好快照保存。

Agent 工作流：第一次启动后存一份 snapshot，之后每次任务从 snapshot 起跑，省掉冷启动几十秒。

---

## Bundle 文件结构

```
demo/
├── config.json           # 设备/CPU/内存配置（schemaVersion: 1）
├── state.json            # 运行时状态指针
├── Disk.img              # raw 磁盘镜像
├── MachineIdentifier     # VZ 平台标识
├── NVRAM                 # （Linux）EFI 变量存储
├── HardwareModel         # （macOS）VZ 硬件标识
├── AuxiliaryStorage      # （macOS）操作系统启动数据
├── console.log           # （Linux）串口日志，每次 run 时滚动
├── .vm4a-run.pid         # 运行中的 worker pid
├── .vm4a-run.log         # detached worker 的 stdout+stderr
├── .vm4a-sessions/       # 每个 <session-id>.jsonl 一条会话日志
└── guest-agent/          # 给可选 guest agent 用的 virtiofs 通信目录
```

CLI 创建的 bundle 能在 GUI 里用，反之亦然。

---

## 退出码

| Code | 含义 |
|---|---|
| `0` | 成功 |
| `1` | 通用失败 |
| `2` | bundle / 文件 / 接口未找到 |
| `3` | 目标已存在 |
| `4` | VM 状态不符（在跑/没跑） |
| `5` | host 能力缺失 / Rosetta 未安装 |

可以直接 if-else 判断而不用解析 stderr。

---

## 故障排查

| 现象 | 可能原因 / 修复 |
|---|---|
| 每个 `vm4a` 命令都退出码 `137` 且无输出（macOS 26） | AMFI 因受限的 `com.apple.vm.networking` entitlement 杀掉了 ad-hoc 签名的二进制 —— 改用只含 NAT 的 entitlements 重新签名（见 [安装 → 源码编译](README.zh-CN.md#安装)） |
| `run` 静默退出 | 看 `<bundle>/.vm4a-run.log` |
| `network list` 返回空 | CLI 没签 `com.apple.vm.networking` entitlement |
| `ssh` / `ip` 没结果 | VM 还在启动 / DHCP 中，等 10–30 秒 |
| `push` 返回 HTTP 401 | 设置 `VM4A_REGISTRY_USER` / `VM4A_REGISTRY_PASSWORD` |
| `--rosetta` 报"未安装" | `softwareupdate --install-rosetta --agree-to-license` |
| Linux guest 启动卡住 | 确认 ISO 是 ARM64；检查 `MachineIdentifier`、`NVRAM` 文件存在 |
| 快照参数被拒 | 需要 macOS 14+ host |
| macOS guest 安装完一直黑屏 | 正常 —— 它在 Setup Assistant，打开 VM4A.app 交互完成一次 |
| `vm4a exec /macos-vm` 报 "Connection refused" | macOS guest 还没开 Remote Login。VM4A.app 里：系统设置 → 通用 → 共享 → 远程登录打开 |
| `vm4a serve` 返回 401 | 客户端要带同样的 `VM4A_AUTH_TOKEN`（`GET /v1/health` 始终免鉴权） |
| Bridged VM `vm4a ip` 没结果 | bridged 模式不走 Apple DHCP，传 `--host <ip>`（`expose-port --host` 同理） |
| `cluster spawn` 跳过某节点 | 节点不可达或 token 不匹配 —— 查 `vm4a cluster list` 和该节点的 `VM4A_AUTH_TOKEN` |
| `--allow-domains` 不生效 | 出站 guard 只支持 Linux 且需 SSH 已就绪；macOS guest 不受影响 |
