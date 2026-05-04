# Developer guide

Repo layout, architecture, build, tests, and how to extend `vm4a`.

> 中文：[Developer.zh-CN.md](Developer.zh-CN.md)

## Contents

- [Repo layout](#repo-layout)
- [Build from source](#build-from-source)
- [Architecture at a glance](#architecture-at-a-glance)
- [Where each module lives](#where-each-module-lives)
- [Adding a new agent tool](#adding-a-new-agent-tool)
- [Tests](#tests)
- [Coding conventions](#coding-conventions)
- [Release workflow](#release-workflow)
- [What's not done yet](#whats-not-done-yet)

---

## Repo layout

```
vm4a/
├── Package.swift                  ← SwiftPM manifest (CLI + library + guest)
├── README.md / Usage.md / Developer.md   (+ zh-CN mirrors)
├── AGENT.md                       ← redirect to this file
├── Sources/
│   ├── VM4ACore/                  ← shared Swift library
│   │   ├── Core.swift             ← VZ config, disk image, runner, errors
│   │   ├── Networking.swift       ← DHCP lease parser, bridged interfaces
│   │   ├── OCI.swift              ← Docker Registry v2 client (push/pull)
│   │   ├── GuestAgent.swift       ← virtiofs guest-agent protocol types
│   │   ├── Agent.swift            ← low-level helpers: runProcess, sshExec,
│   │   │                            scpCopy, waitForVMIP, vmShortID, …
│   │   ├── AgentCore.swift        ← runSpawn / runExec / runCp / runFork /
│   │   │                            runReset + Options/Outcome types
│   │   ├── MCPServer.swift        ← JSON-RPC 2.0 + tool registry + StdioMCPTransport
│   │   ├── HTTPServer.swift       ← HTTP/1.1 parser + NWListener + vm4a routes
│   │   └── Sessions.swift         ← SessionEvent + SessionStore + PoolDefinition
│   ├── VM4ACLI/                   ← `vm4a` binary (ArgumentParser commands)
│   │   ├── VM4ACLI.swift          ← root command + classic lifecycle commands
│   │   ├── AgentCommands.swift    ← thin wrappers over runSpawn/runExec/…
│   │   ├── MCPCommand.swift       ← `vm4a mcp`
│   │   ├── ServeCommand.swift     ← `vm4a serve`
│   │   ├── SessionCommand.swift   ← `vm4a session list/show`
│   │   ├── PoolCommand.swift      ← `vm4a pool create/show/list/spawn/destroy`
│   │   └── VM4ACLI.entitlements   ← com.apple.vm.networking, etc.
│   └── VM4AGuest/                 ← `vm4a-guest` in-guest agent (scaffold)
├── Tests/VM4ACoreTests/           ← swift-testing unit tests
├── VM4A/VM4A.xcodeproj            ← SwiftUI app (separate build via xcodebuild)
├── sdk/python/                    ← Python SDK package (stdlib-only)
├── templates/                     ← OCI template recipes (ubuntu-base, python-dev, xcode-dev)
├── .github/workflows/             ← CI (currently: monthly template rebuild)
├── deploy.sh                      ← release: bump version, codesign, push to brew tap
└── scripts/                       ← release helpers (homebrew tap, MAS prep)
```

The CLI and the SwiftUI app **share `VM4ACore`**. A bundle created by the CLI runs in the GUI and vice versa, with no schema differences.

---

## Build from source

```bash
git clone https://github.com/everettjf/VM4A.git
cd VM4A
swift build                                # debug
swift build -c release                     # optimised
swift test                                 # full unit suite
```

The CLI **must** be codesigned to access bridged networking and Rosetta:

```bash
codesign --force --sign - \
    --entitlements Sources/VM4ACLI/VM4ACLI.entitlements \
    ./.build/debug/vm4a
```

The SwiftUI app builds separately:

```bash
xcodebuild -project VM4A/VM4A.xcodeproj -scheme VM4A \
    -destination 'platform=macOS,arch=arm64' build
```

> **Stale module cache after rename / repo move:** if `swift build` fails with *"PCH was compiled with module cache path …"* or *"missing required module 'SwiftShims'"*, delete `.build/` and rebuild. The Swift compiler caches PCHs by absolute path and a renamed working tree breaks them.

---

## Architecture at a glance

```
┌────────────────────────────────────────────────────────────────────────┐
│                         User-facing surfaces                           │
│                                                                        │
│   vm4a CLI            vm4a mcp           vm4a serve         VM4A.app   │
│   (ArgumentParser)    (stdio JSON-RPC)   (HTTP/1.1)         (SwiftUI)  │
└──────────┬──────────────────┬──────────────────┬──────────────┬────────┘
           │                  │                  │              │
           │           ┌──────┴──────┐    ┌──────┴──────┐       │
           │           │ MCPServer   │    │ HTTPServer  │       │
           │           └──────┬──────┘    └──────┬──────┘       │
           │                  │                  │              │
           ▼                  ▼                  ▼              ▼
        ┌──────────────────────────────────────────────────────────┐
        │            VM4ACore — shared agent runtime                │
        │                                                           │
        │  AgentCore: runSpawn / runExec / runCp / runFork /        │
        │             runReset (+ Options / Outcome types)          │
        │                                                           │
        │  Agent: runProcess, sshExec, scpCopy, waitForVMIP,        │
        │         waitForSSHReady, vmShortID, listVMSummaries,      │
        │         startVMWorker                                     │
        │                                                           │
        │  Sessions: SessionEvent JSONL log + PoolDefinition        │
        │                                                           │
        │  Core: VZ config / disk / DispatchSource runner /         │
        │        VZ snapshot save+restore                           │
        │                                                           │
        │  OCI: Docker Registry v2 push/pull                        │
        │  Networking: Apple DHCP lease parser                      │
        │  GuestAgent: virtiofs rendezvous protocol                 │
        └──────────────────────────────────────────────────────────┘
                                    │
                                    ▼
                         Apple Virtualization.framework
```

Three rules the architecture enforces:

1. **Every command has one core function in VM4ACore.** The CLI command is a thin parser → call → output formatter. The MCP and HTTP servers reuse the same core. If you find yourself reimplementing logic in a new surface, the right move is to extract it into VM4ACore first.

2. **Outcome types are `Codable & Sendable`.** Same shape across CLI JSON output, MCP `tools/call` text content, HTTP responses, Python SDK dataclasses. Adding a new field shows up in all four places at once.

3. **The VZ runner is per-process.** Each running VM is a `_run-worker` child process; the main `vm4a` process only manages PID files and detached children. This means `vm4a serve` and `vm4a mcp` can safely fire `spawn`/`run` without pinning their own lifetime to the VM's.

---

## Where each module lives

| Module | Responsibility |
|---|---|
| **`VM4ACore/Core.swift`** | `VMConfigModel`, `VMStateModel`, `VMModel`, schema-versioned JSON; `runVM(model:options:)`; VZ config builder; macOS 14 `--save-on-stop` / `--restore`; clone helpers; image catalog; `VM4AError` (typed exit codes). |
| **`VM4ACore/Networking.swift`** | `parseDHCPLeases`, `findLeasesForBundle`, `availableBridgedInterfaces`. |
| **`VM4ACore/OCI.swift`** | `OCIReference.parse`, `ociPush`, `ociPull`. Docker Registry v2 with bearer + basic auth. Bundle media type `application/vnd.vm4a.bundle.v1.tar+gzip`. |
| **`VM4ACore/GuestAgent.swift`** | `GuestAgentCommand`, `GuestAgentHeartbeat`, virtiofs read/write helpers. (Scaffold — only `ping` and `status` implemented today.) |
| **`VM4ACore/Agent.swift`** | Low-level helpers used by the runners and surfaces: `runProcess` (with timeout + SIGTERM/SIGKILL), `SSHOptions` + `sshExec` + `scpCopy`, `waitForVMIP`, `waitForSSHReady`, `parseCopyEndpoint`, `vmShortID` (FNV-1a, trailing-slash-normalised), `listVMSummaries`, `startVMWorker`, `reidentifyVM`. |
| **`VM4ACore/AgentCore.swift`** | The five agent runners: `runSpawn` (async, can pull OCI), `runExec`, `runCp`, `runFork`, `runReset`. Plus `createBundle` (shared between `CreateCommand` and `SpawnCommand`'s fresh-create path), `normalizePath`, `bytesFromGB`. Each runner takes a `Sendable` Options struct and returns a `Codable` Outcome. |
| **`VM4ACore/MCPServer.swift`** | `MCPServer` actor, `MCPTransport` protocol, `StdioMCPTransport`, JSON-RPC 2.0 types (`JSONValue`, `JSONRPCRequest/Response/Error`), `MCPTool` schemas, dispatchers for the eight tools. |
| **`VM4ACore/HTTPServer.swift`** | Minimal HTTP/1.1 (`HTTPWire.parse`/`encode`, no chunked / no keep-alive), `HTTPRouter` actor, `makeVM4ARouter(config:)` with the nine `/v1/*` routes, `HTTPServer` over Network framework with strong-ref `HTTPSession` tracking. |
| **`VM4ACore/Sessions.swift`** | `SessionEvent` + `SessionStore` (JSONL append/read/discover), `PoolDefinition` + `PoolStore` (`~/.vm4a/pools/*.json`), `recordSessionEvent`, `nextSessionSeq`. |

CLI commands map 1-to-1 onto runners and read/format around them. If you grep for `runSpawn` you'll see exactly one call site per surface (CLI / MCP / HTTP).

---

## Adding a new agent tool

Walkthrough: suppose you want to add `vm4a snap` that names a VZ snapshot and saves it without stopping. Steps:

**1. Define options + outcome in `VM4ACore/AgentCore.swift`:**
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

**2. Implement the runner.** Reuse `loadModel`, the VZ snapshot APIs in `Core.swift`, and existing helpers.
```swift
public func runSnap(options: SnapOptions) throws -> SnapOutcome { … }
```

**3. CLI wrapper in `Sources/VM4ACLI/AgentCommands.swift`** — a `ParsableCommand` that builds `SnapOptions`, calls `runSnap`, and formats output. Don't forget `--output text|json` and `--session <id>`. Register it in `VM4ACLI.swift`'s `subcommands:` list.

**4. MCP tool in `Sources/VM4ACore/MCPServer.swift`** — add to `vm4aTools()` with a JSON Schema, and add a `callSnap(...)` dispatcher case in `runTool(name:arguments:)`.

**5. HTTP route in `Sources/VM4ACore/HTTPServer.swift`** — append to `makeVM4ARouter(config:)`.

**6. Python SDK in `sdk/python/src/vm4a/client.py`** — add a `snap(...)` method and a `SnapOutcome` dataclass.

**7. Tests in `Tests/VM4ACoreTests/`** — at minimum a roundtrip of the Outcome through `JSONEncoder`/`JSONDecoder`, and (if pure) a behavior test of the runner.

**8. Docs.** Add a row to the CLI reference in `Usage.md`, an entry to the MCP tool table, and an HTTP route entry. Mirror to `Usage.zh-CN.md`.

If you only need it in MCP/HTTP and not the CLI, skip step 3. If you only need it in the CLI, you can defer 4–6, but MCP/HTTP exposure is usually 5 lines each so adding them at the same time is cheaper than coming back.

---

## Tests

```bash
swift test                          # all 42 tests, all four suites
swift test --filter MCPServerTests
```

Coverage today:

| Suite | What it covers |
|---|---|
| `CoreTests` (19) | `VMConfigModel.defaults` / round-trip, schema-version tolerant decoding, PID helpers, clone, OCI reference parsing, DHCP leases parsing, guest agent heartbeat round-trip, `parseCopyEndpoint`, `vmShortID` stability, `runProcess` timeout. |
| `MCPServerTests` (8) | `initialize` / `tools/list` / `tools/call list` / unknown tool / unknown method / notifications no-op / parse error / `JSONValue` round-trip. |
| `HTTPServerTests` (9) | HTTP wire parse for GET/POST/query, incomplete-headers, response encoding; router 404 vs 405; bearer auth required vs not. |
| `SessionsTests` (6) | JSONL append/read round-trip, discover sessions across bundle + home, nil-id no-op, monotonic per-id sequence, malformed-line skip, pool save/load/list/remove. |

What's **not** covered automatically:

- End-to-end VM lifecycle (boot → ssh → exec → snapshot → restore). Requires a real Linux ISO and ~1 GB of RAM; today this is manual.
- OCI push/pull against a real registry. The OCI parser is unit-tested but the wire path is not.
- The HTTP server's `NWListener`/`NWConnection` plumbing. The wire format and router are tested; the socket binding is exercised only via manual smoke tests.

Adding a test: pick the closest existing suite, grab a similar `@Test func` as a template, and use `NSTemporaryDirectory()` for any filesystem fixture (cleaned up via `defer { try? FileManager.default.removeItem(at:) }`).

---

## Coding conventions

- **Language:** Swift 6 toolchain, `swift-tools-version: 6.0`.
- **Indent:** 4 spaces. CamelCase types, camelCase functions/properties.
- **Codable shapes:** snake_case in JSON (e.g. `exit_code`, `ssh_ready`, `vm_path`, `wait_ssh`); the wire format is the contract for SDKs and MCP/HTTP. Swift property names are camelCase; rely on JSON encoder customisation only when needed.
- **Errors:** throw `VM4AError` with the right case so the typed exit code propagates. The CLI's `ParsableCommand.run()` errors become process exit codes via `VM4AError.exitCode`.
- **Concurrency:** runners are `async` only when they actually need it (e.g. `runSpawn` awaits `ociPull`). `runExec`, `runCp`, `runFork`, `runReset` are synchronous — keep them so unless you have a reason to change.
- **Sendable:** all Options + Outcome types are `Sendable`. Avoid capturing non-Sendable closures across `Task` boundaries; use `@Sendable` on free functions where needed (see `vm4aAuthorized` in `HTTPServer.swift`).
- **Comments:** comment *why*, not *what*. Public APIs get one short doc comment; internal helpers usually need none. Don't write multi-paragraph block comments.
- **No background-compat shims unless they're earning their keep.** This is a young project; deletions are cheap.

---

## Release workflow

Self-hosted Homebrew tap (`everettjf/homebrew-tap`):

```bash
./deploy.sh                 # patch + build + dmg + push formula/cask
./deploy.sh --only-cli      # CLI only
./deploy.sh --only-app      # App only
./deploy.sh --skip-tests    # skip swift test
./deploy.sh --minor         # minor bump
./deploy.sh --major         # major bump
```

Bumps `VERSION`, builds release artefacts, codesigns, packages, and updates the brew formula/cask in the tap repo. The script is the source of truth — read it before running it the first time on a new machine.

The OCI templates rebuild monthly via `.github/workflows/templates.yml` on a self-hosted Apple Silicon runner with the labels `[self-hosted, macOS, ARM64, vm4a]`. GitHub-hosted runners can't run `vm4a` (Virtualization.framework is unavailable there).

---

## What's not done yet

These are the rough edges as of v2.3+v2.4 foundations. Pull requests welcome:

- **`--session` only logs success paths.** A throwing call leaves no session entry. Wrapping each runner's CLI call in `do/catch` (or `defer`) and recording an error event is a small, contained change.
- **Pool warm runtime.** `vm4a pool spawn` is a thin wrapper over `fork`. The actual "keep N idle VMs warm, hand one out, refill" daemon (probably a `vm4a pool serve` background process) is the rest of v2.4.
- **Time Machine viewer in the main GUI app.** A standalone `vm4a-sessions` SwiftUI app is shipped (built via SwiftPM, in `Sources/VM4ASessions/`); it lists sessions and shows events with expandable args/outcome panels. Integrating these views into `VM4A.app` proper is a one-Xcode-add step (drag both `.swift` files into the Detail group, register a sidebar entry); deferred because the Xcode project has two targets and pbxproj edits are best done in the IDE.
- **Network sandboxing.** `--network none|host|egress-only` flags don't exist yet. NAT and bridged are the only modes today; for "no network at all" or "outbound only" you'd need to wire packet filter rules in the runner.
- **Resource caps beyond CPU/memory/disk-size.** VZ exposes `cpuCount`, `memorySize`, and disk-image size at create time (already wired through `--cpu`, `--memory-gb`, `--disk-gb`), and per-attachment read-only (now wired through `VMModelFieldStorageDevice.readOnly`, defaulting to `true` for ISOs/USB). What VZ does **not** expose, and therefore can't be capped without OS-level mechanisms macOS doesn't grant to userland: per-VM CPU shares/quotas, memory soft limits, disk IO bandwidth, network bandwidth, or per-VM filesystem quotas. Don't add knobs for these — they would lie to users.
- **macOS guest first-boot Setup Assistant.** `vm4a create --os macOS --image foo.ipsw` drives Apple's `VZMacOSInstaller` end-to-end via `Sources/VM4ACore/MacOSInstall.swift` — bundle becomes bootable in 10–20 minutes. But the resulting VM lands at Setup Assistant on first boot and there's no public API to skip it; user must complete that interactively in VM4A.app once per fresh IPSW, then enable Remote Login so subsequent vm4a commands can SSH in. After that one click-through, every CLI / MCP / HTTP / SDK operation works on the macOS bundle exactly like a Linux one. Pulling a pre-installed macOS bundle from GHCR skips Setup Assistant entirely. If anyone has a working autounattend recipe (tart-style auxiliary-plist injection, or VNC scripting like packer's macOS builder), open an issue — we'd ship a fully automated `vm4a create --os macOS --auto`.
- **MCP `resources` and `prompts`.** Only `tools` is implemented. A `vm4a://vms` resource that streams VM state would be a natural add.
- **SDKs beyond Python.** Go and Node would be the obvious next ones — they're a thin urllib equivalent over the same HTTP API.
- **CI for `swift test` on PRs.** The deploy workflow exists but there's no PR validation workflow. Adding one is straightforward but requires a self-hosted runner (Virtualization.framework again).
- **End-to-end VM tests.** No automated boot → SSH → exec test. Doable with a small Alpine ARM64 ISO and a self-hosted runner.

If you start work on any of these, open an issue first so the design conversation happens in public.
