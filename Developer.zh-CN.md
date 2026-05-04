# 开发者指南

仓库结构、架构、构建、测试，以及如何扩展 `vm4a`。

> English: [Developer.md](Developer.md)

## 目录

- [仓库结构](#仓库结构)
- [从源码构建](#从源码构建)
- [架构总览](#架构总览)
- [每个模块在哪](#每个模块在哪)
- [新增一个 Agent 工具](#新增一个-agent-工具)
- [测试](#测试)
- [代码风格](#代码风格)
- [发布流程](#发布流程)
- [还没做的事](#还没做的事)

---

## 仓库结构

```
vm4a/
├── Package.swift                  ← SwiftPM 清单（CLI + 库 + guest）
├── README.md / Usage.md / Developer.md   （+ zh-CN 镜像）
├── AGENT.md                       ← 重定向到本文
├── Sources/
│   ├── VM4ACore/                  ← 共享 Swift 库
│   │   ├── Core.swift             ← VZ 配置、磁盘、runner、错误类型
│   │   ├── Networking.swift       ← DHCP lease 解析、bridged 接口枚举
│   │   ├── OCI.swift              ← Docker Registry v2 客户端（push/pull）
│   │   ├── GuestAgent.swift       ← virtiofs guest agent 协议类型
│   │   ├── Agent.swift            ← 低阶辅助：runProcess、sshExec、
│   │   │                            scpCopy、waitForVMIP、vmShortID 等
│   │   ├── AgentCore.swift        ← runSpawn / runExec / runCp / runFork /
│   │   │                            runReset + Options/Outcome 类型
│   │   ├── MCPServer.swift        ← JSON-RPC 2.0 + 工具注册表 + StdioMCPTransport
│   │   ├── HTTPServer.swift       ← HTTP/1.1 解析 + NWListener + vm4a 路由
│   │   └── Sessions.swift         ← SessionEvent + SessionStore + PoolDefinition
│   ├── VM4ACLI/                   ← `vm4a` 二进制（ArgumentParser 命令）
│   │   ├── VM4ACLI.swift          ← 根命令 + 经典生命周期命令
│   │   ├── AgentCommands.swift    ← 套在 runSpawn/runExec/… 外面的薄壳
│   │   ├── MCPCommand.swift       ← `vm4a mcp`
│   │   ├── ServeCommand.swift     ← `vm4a serve`
│   │   ├── SessionCommand.swift   ← `vm4a session list/show`
│   │   ├── PoolCommand.swift      ← `vm4a pool create/show/list/spawn/destroy`
│   │   └── VM4ACLI.entitlements   ← com.apple.vm.networking 等
│   └── VM4AGuest/                 ← `vm4a-guest` 客内 agent（脚手架）
├── Tests/VM4ACoreTests/           ← swift-testing 单元测试
├── VM4A/VM4A.xcodeproj            ← SwiftUI app（独立 xcodebuild 构建）
├── sdk/python/                    ← Python SDK 包（仅 stdlib）
├── templates/                     ← OCI 模板构建脚本（ubuntu-base、python-dev、xcode-dev）
├── .github/workflows/             ← CI（目前只有月度模板 rebuild）
├── deploy.sh                      ← 发布：bump 版本、签名、推 brew tap
└── scripts/                       ← 发布辅助（homebrew tap、MAS 准备）
```

CLI 和 SwiftUI app **共享 `VM4ACore`**。CLI 创建的 bundle 在 GUI 能用，反之亦然，配置 schema 完全一致。

---

## 从源码构建

```bash
git clone https://github.com/everettjf/VM4A.git
cd VM4A
swift build                                # debug
swift build -c release                     # 优化构建
swift test                                 # 跑全部单元测试
```

CLI **必须**签名才能用 bridged 网络和 Rosetta：

```bash
codesign --force --sign - \
    --entitlements Sources/VM4ACLI/VM4ACLI.entitlements \
    ./.build/debug/vm4a
```

SwiftUI app 单独构建：

```bash
xcodebuild -project VM4A/VM4A.xcodeproj -scheme VM4A \
    -destination 'platform=macOS,arch=arm64' build
```

> **重命名 / 仓库迁移后模块缓存失效：** 如果 `swift build` 报 *"PCH was compiled with module cache path …"* 或 *"missing required module 'SwiftShims'"*，删掉 `.build/` 重新构建。Swift 编译器按绝对路径缓存 PCH，工作树重命名会让缓存失效。

---

## 架构总览

```
┌──────────────────────────────────────────────────────────────────────────┐
│                            用户接入面                                      │
│                                                                          │
│   vm4a CLI            vm4a mcp           vm4a serve         VM4A.app     │
│   (ArgumentParser)    (stdio JSON-RPC)   (HTTP/1.1)         (SwiftUI)    │
└──────────┬──────────────────┬──────────────────┬───────────────┬─────────┘
           │                  │                  │               │
           │           ┌──────┴──────┐    ┌──────┴──────┐        │
           │           │ MCPServer   │    │ HTTPServer  │        │
           │           └──────┬──────┘    └──────┬──────┘        │
           │                  │                  │               │
           ▼                  ▼                  ▼               ▼
        ┌────────────────────────────────────────────────────────────┐
        │              VM4ACore —— 共享 Agent 运行时                  │
        │                                                            │
        │  AgentCore: runSpawn / runExec / runCp / runFork /         │
        │             runReset (+ Options / Outcome 类型)             │
        │                                                            │
        │  Agent: runProcess、sshExec、scpCopy、waitForVMIP、         │
        │         waitForSSHReady、vmShortID、listVMSummaries、      │
        │         startVMWorker                                      │
        │                                                            │
        │  Sessions: SessionEvent JSONL 日志 + PoolDefinition         │
        │                                                            │
        │  Core: VZ 配置 / 磁盘 / DispatchSource runner /            │
        │        VZ 快照 save+restore                                │
        │                                                            │
        │  OCI: Docker Registry v2 push/pull                         │
        │  Networking: Apple DHCP lease 解析                         │
        │  GuestAgent: virtiofs 通信协议                             │
        └────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
                         Apple Virtualization.framework
```

架构上有三条强约束：

1. **每个命令在 VM4ACore 里有且只有一个 core 函数。** CLI 命令是薄壳：解析 → 调 core → 输出格式化。MCP 和 HTTP server 复用同一个 core 函数。如果你发现自己在新接入面里重新实现了逻辑，正确做法是先把它抽到 VM4ACore。

2. **Outcome 类型是 `Codable & Sendable`。** CLI JSON 输出、MCP `tools/call` 的 text content、HTTP 响应、Python SDK 的 dataclass 用同一份字段。加一个字段四个地方一起出现。

3. **VZ runner 是单进程的。** 每个跑着的 VM 是一个 `_run-worker` 子进程；主 `vm4a` 进程只管 PID 文件和 detached children。这意味着 `vm4a serve` 和 `vm4a mcp` 可以放心 spawn/run，而不会把自己进程的生命周期绑死在 VM 上。

---

## 每个模块在哪

| 模块 | 职责 |
|---|---|
| **`VM4ACore/Core.swift`** | `VMConfigModel`、`VMStateModel`、`VMModel`、schema-versioned JSON；`runVM(model:options:)`；VZ 配置构建器；macOS 14 `--save-on-stop` / `--restore`；clone helpers；image catalog；`VM4AError`（带类型化退出码） |
| **`VM4ACore/Networking.swift`** | `parseDHCPLeases`、`findLeasesForBundle`、`availableBridgedInterfaces` |
| **`VM4ACore/OCI.swift`** | `OCIReference.parse`、`ociPush`、`ociPull`。Docker Registry v2，bearer + basic 认证。Bundle media type `application/vnd.vm4a.bundle.v1.tar+gzip` |
| **`VM4ACore/GuestAgent.swift`** | `GuestAgentCommand`、`GuestAgentHeartbeat`、virtiofs 读写。脚手架 —— 当前只实现了 `ping` 和 `status` |
| **`VM4ACore/Agent.swift`** | runner 和接入层用到的低阶 helper：`runProcess`（带 timeout + SIGTERM/SIGKILL）、`SSHOptions` + `sshExec` + `scpCopy`、`waitForVMIP`、`waitForSSHReady`、`parseCopyEndpoint`、`vmShortID`（FNV-1a，去尾斜杠归一化）、`listVMSummaries`、`startVMWorker`、`reidentifyVM` |
| **`VM4ACore/AgentCore.swift`** | 5 个 agent runner：`runSpawn`（async，可拉 OCI）、`runExec`、`runCp`、`runFork`、`runReset`。还有 `createBundle`（被 `CreateCommand` 和 `SpawnCommand` 的从零创建路径共用）、`normalizePath`、`bytesFromGB`。每个 runner 收一个 `Sendable` Options struct，返回一个 `Codable` Outcome |
| **`VM4ACore/MCPServer.swift`** | `MCPServer` actor、`MCPTransport` 协议、`StdioMCPTransport`、JSON-RPC 2.0 类型（`JSONValue`、`JSONRPCRequest/Response/Error`）、`MCPTool` schemas、8 个工具的 dispatcher |
| **`VM4ACore/HTTPServer.swift`** | 极简 HTTP/1.1（`HTTPWire.parse`/`encode`，不支持 chunked/keep-alive）、`HTTPRouter` actor、`makeVM4ARouter(config:)` 注册 9 个 `/v1/*` 路由、基于 Network framework 的 `HTTPServer` 配合 `HTTPSession` 强引用 |
| **`VM4ACore/Sessions.swift`** | `SessionEvent` + `SessionStore`（JSONL append/read/discover）、`PoolDefinition` + `PoolStore`（`~/.vm4a/pools/*.json`）、`recordSessionEvent`、`nextSessionSeq` |

CLI 命令一对一映射到 runner。grep `runSpawn`，每个接入面（CLI / MCP / HTTP）刚好一个调用点。

---

## 新增一个 Agent 工具

走一遍：假设你想加 `vm4a snap` 给运行中的 VZ snapshot 起名并存盘。步骤：

**1. `VM4ACore/AgentCore.swift` 里定义 Options + Outcome：**
```swift
public struct SnapOptions: Sendable {
    public var vmPath: String
    public var label: String
    public var savePath: String
    public init(vmPath: String, label: String, savePath: String) { … }
}

public struct SnapOutcome: Codable, Sendable {
    public let path: String
    public let label: String
    public let savedAt: String
}
```

**2. 实现 runner。** 复用 `loadModel`、`Core.swift` 里的 VZ 快照 API、其他已有 helper。
```swift
public func runSnap(options: SnapOptions) throws -> SnapOutcome { … }
```

**3. CLI 套壳放 `Sources/VM4ACLI/AgentCommands.swift`** —— 一个 `ParsableCommand`，构造 `SnapOptions`、调 `runSnap`、格式化输出。别忘了 `--output text|json` 和 `--session <id>`。在 `VM4ACLI.swift` 的 `subcommands:` 列表里注册。

**4. MCP 工具放 `Sources/VM4ACore/MCPServer.swift`** —— 在 `vm4aTools()` 里加一项带 JSON Schema 的工具，再在 `runTool(name:arguments:)` 里加一个 `callSnap(...)` 分支。

**5. HTTP 路由放 `Sources/VM4ACore/HTTPServer.swift`** —— 在 `makeVM4ARouter(config:)` 里追加。

**6. Python SDK 放 `sdk/python/src/vm4a/client.py`** —— 加 `snap(...)` 方法和 `SnapOutcome` dataclass。

**7. 测试放 `Tests/VM4ACoreTests/`** —— 至少把 Outcome 用 `JSONEncoder`/`JSONDecoder` 来回过一遍；如果 runner 是 pure 的，加一个行为测试。

**8. 文档。** `Usage.md` 的 CLI 参考表加一行、MCP 工具表加一行、HTTP 路由表加一行。镜像到 `Usage.zh-CN.md`。

如果只在 MCP/HTTP 暴露不进 CLI，跳第 3 步。如果只进 CLI 不暴露，4–6 可以先不做，但 MCP/HTTP 暴露每边只要 5 行，一起做比回头补便宜。

---

## 测试

```bash
swift test                          # 全部 42 个测试，4 个 suite
swift test --filter MCPServerTests
```

当前覆盖：

| Suite | 覆盖了什么 |
|---|---|
| `CoreTests`（19） | `VMConfigModel.defaults` / round-trip、schema-version 容错解码、PID helpers、clone、OCI reference 解析、DHCP leases 解析、guest agent heartbeat round-trip、`parseCopyEndpoint`、`vmShortID` 稳定性、`runProcess` timeout |
| `MCPServerTests`（8） | `initialize` / `tools/list` / `tools/call list` / 未知工具 / 未知方法 / notifications no-op / parse error / `JSONValue` round-trip |
| `HTTPServerTests`（9） | HTTP wire parse 对 GET/POST/query/incomplete-headers、response 编码；router 404 vs 405；bearer 鉴权开关 |
| `SessionsTests`（6） | JSONL append/read round-trip、bundle + home 双源 discover、nil-id no-op、单调递增 seq、坏行跳过、pool save/load/list/remove |

**没**自动覆盖的：

- 端到端 VM 生命周期（boot → ssh → exec → snapshot → restore）。需要真的 Linux ISO 和 ~1 GB 内存，今天靠手动
- OCI push/pull 对真实 registry。OCI 解析器有单元测试，wire 路径没有
- HTTP server 的 `NWListener`/`NWConnection` 套接字层。Wire 格式和 router 有测试，绑端口的部分只有手动 smoke test

加测试：选最近的 suite、抓一个相似的 `@Test func` 当模板、用 `NSTemporaryDirectory()` 做文件 fixture（用 `defer { try? FileManager.default.removeItem(at:) }` 清理）。

---

## 代码风格

- **语言：** Swift 6 工具链，`swift-tools-version: 6.0`
- **缩进：** 4 空格。CamelCase 类型、camelCase 函数/属性
- **Codable 字段：** JSON 里用 snake_case（`exit_code`、`ssh_ready`、`vm_path`、`wait_ssh`），wire 格式是 SDK 和 MCP/HTTP 的契约。Swift 属性名是 camelCase；只在必要时定制 JSON encoder
- **错误：** 抛 `VM4AError` 带正确的 case，类型化退出码会自动传出去。CLI 的 `ParsableCommand.run()` throw 出来的 `VM4AError` 通过 `VM4AError.exitCode` 变成进程退出码
- **并发：** runner 真的需要时才 `async`（比如 `runSpawn` 要 await `ociPull`）。`runExec`、`runCp`、`runFork`、`runReset` 是同步的 —— 没必要别改
- **Sendable：** 所有 Options + Outcome 类型都是 `Sendable`。避免在 `Task` 边界捕获非 Sendable 的闭包；free function 上需要时用 `@Sendable`（参考 `HTTPServer.swift` 里的 `vm4aAuthorized`）
- **注释：** 注释解释*为什么*，不解释*做什么*。public API 一行短 doc 注释，internal helper 通常不需要。不要写多段大注释块
- **不要写"为以后兼容"的死代码。** 这个项目还年轻，删除是廉价操作

---

## 发布流程

自托管 Homebrew tap（`everettjf/homebrew-tap`）：

```bash
./deploy.sh                 # patch + build + dmg + 推 formula/cask
./deploy.sh --only-cli      # 只发 CLI
./deploy.sh --only-app      # 只发 GUI
./deploy.sh --skip-tests    # 跳过 swift test
./deploy.sh --minor         # minor bump
./deploy.sh --major         # major bump
```

Bump `VERSION`、构建 release 产物、签名、打包、更新 tap 仓库的 brew formula/cask。脚本即是事实 —— 第一次在新机器上运行前先读一遍。

OCI 模板按月通过 `.github/workflows/templates.yml` 在自托管 Apple Silicon runner 上 rebuild，runner 标签必须有 `[self-hosted, macOS, ARM64, vm4a]`。GitHub-hosted runner 跑不了 `vm4a`（那边没有 Virtualization.framework）。

---

## 还没做的事

到 v2.3+v2.4 基础设施为止，这些是粗糙的边缘。欢迎 PR：

- **`--session` 只记录成功路径。** throw 的调用不会留下日志。把每个 runner 在 CLI 里的调用包到 `do/catch`（或 `defer`）里、记一条 error 事件 —— 改动小、可控
- **池的 warm runtime。** `vm4a pool spawn` 现在只是 `fork` 的薄壳。真正的"提前预热 N 台、取一台、后台补"daemon（大概是 `vm4a pool serve` 后台进程）是 v2.4 剩下的部分
- **GUI Time Machine 视图。** CLI 写 JSONL 事件了，SwiftUI 那边还没写时间线和快照 diff 视图。数据形状见 `Sources/VM4ACore/Sessions.swift`
- **网络沙盒。** `--network none|host|egress-only` flag 还没有。当前只有 NAT 和 bridged；要"完全无网"或"只能出站"得在 runner 里加 packet filter 规则
- **超出 CPU/内存/磁盘大小的资源 cap。** VZ 在创建时支持 `cpuCount`、`memorySize`、磁盘镜像大小（已经通过 `--cpu`、`--memory-gb`、`--disk-gb` 暴露），以及每个 attachment 的 read-only（已通过 `VMModelFieldStorageDevice.readOnly` 暴露，ISO/USB 默认 `true`）。VZ **不**支持、因此 macOS 在用户态无法实现的：每 VM 的 CPU share/配额、内存软限制、磁盘 IO 带宽、网络带宽、每 VM 文件系统配额。这些不应该加 CLI flag，因为加了也是骗用户。
- **`xcode-dev` 模板的 `build.sh`。** 缺失，因为 macOS guest 现在没法 headless 安装；得先 GUI 安装 base，再用 `provision.sh` 走 SSH
- **MCP `resources` 和 `prompts`。** 只实现了 `tools`。给 VM 状态做一个 `vm4a://vms` 只读 resource 是自然的下一步
- **Python 之外的 SDK。** Go 和 Node 是自然的下一个 —— 都是同一套 HTTP API 之上的 urllib 等价物
- **PR 上的 `swift test` CI。** 有 deploy 流水线，没有 PR 验证流水线。加起来不难，但需要自托管 runner（又是 Virtualization.framework）
- **端到端 VM 测试。** 没有自动化的 boot → SSH → exec 测试。有自托管 runner 的话，用一个小的 Alpine ARM64 ISO 是可行的

如果你打算开始做这些里的任何一项，先开 issue —— 设计讨论应该公开进行。
