# Changelog

All notable changes to this project. Versions follow [Semantic Versioning](https://semver.org/).

> Versions v2.1–v2.4 were developed on the v2.0 line and were originally
> described together under the v2.0.0 entry below. They are broken out into
> their own sections here so the `VERSION` file, the README status table, and
> this changelog tell the same story.

## v2.5.0 — unreleased

The "higher-level surface" release: a code-runner and port-exposer on top of
the SSH primitives, an egress allow-list for network-restricted runs, a JS/TS
SDK, a reusable GitHub Action, and a thin multi-host scheduler.

### Added — High-level sandbox API

- `vm4a run-code <vm> --lang python --code '…'` (or `--file step.py`) — write a
  snippet into the guest and run it with the matching interpreter in one call.
  Returns the same `{exit_code, stdout, stderr, duration_ms, timed_out}` shape
  as `exec`. Languages: `python`/`python3`, `node`/`javascript`, `bash`/`sh`,
  `ruby`. Also exposed over MCP (`run_code`) and HTTP (`POST /v1/run_code`).
- `vm4a expose-port <vm> --port 8000` — resolve the guest's reachable address
  and print a `{url, host, port, scheme}` the host can hit directly (NAT guests
  are routable from the host). MCP tool `expose_port`, HTTP `POST /v1/expose_port`.

### Added — Network egress allow-list

- `--allow-domains a.com,b.com` on `spawn` (and `vm4a network guard <vm>`) — for
  Linux guests, installs an nftables `inet vm4a_egress` table that permits
  loopback, established/related, DNS, and the resolved addresses of the listed
  domains, then drops the rest of egress. Best-effort, Linux + `nft` only;
  persisted to `<bundle>/egress.json` and re-applied via `network guard`.

### Added — JavaScript / TypeScript SDK

- `sdk/typescript` — a dependency-free client mirroring the Python SDK against
  the same `vm4a serve` HTTP surface (Node 18+ global `fetch`). Publishable as
  the `vm4a` npm package.

### Added — GitHub Action

- `action.yml` — composite action for self-hosted Apple Silicon runners: builds
  + codesigns the CLI, spawns a VM from an OCI ref or image, runs a command, and
  exposes `exit-code` / `stdout` / `ip` outputs.

### Added — Multi-host scheduler

- `vm4a cluster add/remove/list` — register remote `vm4a serve` nodes
  (`~/.vm4a/cluster/<name>.json`).
- `vm4a cluster spawn` — pick the least-loaded node (by live VM count) and spawn
  there. `vm4a cluster exec --node <name>` proxies an exec; `vm4a cluster status`
  aggregates `/v1/vms` across every node.

### Added — Benchmarks

- `scripts/bench.sh` — reproducible timing harness for fork / boot-to-SSH /
  `pool acquire`, emitting a Markdown table to fill into the README on real
  Apple Silicon hardware.

### Changed

- Version string is now a single `vm4aVersion` constant in `VM4ACore`, surfaced
  by `/v1/health` and MCP `serverInfo` (previously hard-coded `2.0.0`).

## v2.4.0 — 2026-05-04

### Added — Pools and network sandbox

- `vm4a pool create/show/list/destroy` — pool definitions (JSON at `~/.vm4a/pools/<name>.json`) describing how to mint per-task VMs from a base.
- `vm4a pool spawn` — on-demand fork, equivalent to `fork --auto-start --from-snapshot` from the saved definition.
- `vm4a pool serve` — warm-pool daemon that keeps `--size N` VMs idle and ready, refilling on consumption.
- `vm4a pool acquire <name>` — atomic filesystem rename hand-out (millisecond-fast).
- `vm4a pool release <vm-path>` — stop + delete; daemon refills on next tick.
- `--network none|nat|bridged|host` mode flag on `create` and `spawn`.
- `VMModelFieldStorageDevice.readOnly` — per-attachment read-only flag, defaults to `true` for ISOs/USB attachments.

### Added — Image catalog with auto-download

- `vm4a image list` — Linux ISOs (Ubuntu / Fedora / Debian / Alpine) plus the dynamic `macos-latest` sentinel that resolves via `VZMacOSRestoreImage.fetchLatestSupported`.
- `vm4a image pull <spec>` — explicit prefetch.
- `vm4a image where` — print cache directory + cached files.
- `--image` accepts: catalog id / local path / `https://` URL / nothing-with-`--os macOS` (auto-fetches latest IPSW). Cache lives at `~/.cache/vm4a/images/`. SHA256 verified when the catalog provides it.

## v2.3.0 — 2026-05-04

### Added — Sessions and Time Machine

- `--session <id>` flag on every agent primitive; appends a JSONL event to `<bundle>/.vm4a-sessions/<id>.jsonl` with `{seq, timestamp, kind, vmPath, success, durationMs, summary, args, outcome}`. Both success and error paths are recorded via `SessionRecorder` + `defer`.
- `vm4a session list/show` — CLI inspection.
- `vm4a-sessions` — standalone SwiftUI Time Machine viewer (built via SwiftPM), reads the same JSONL files and renders a timeline with expandable args/outcome panels.

## v2.2.0 — 2026-05-04

### Added — Templates

- Curated OCI templates published to `ghcr.io/everettjf/vm4a-templates/*`:
  - `ubuntu-base:24.04` (Ubuntu 24.04 server, ARM64, OpenSSH, Python 3.12)
  - `python-dev:latest` (ubuntu-base + uv + pipx + ripgrep + git + build-essential)
  - `xcode-dev:latest` (macOS 15 + Xcode CLT + Homebrew, post-Setup-Assistant)
- Linux templates rebuild monthly via `.github/workflows/templates.yml` on a self-hosted Apple Silicon runner. macOS template requires one-time Setup Assistant click-through per IPSW; rebuild from there is automated.

## v2.1.0 — 2026-05-04

### Added — Programmatic surfaces

- `vm4a serve` — localhost HTTP REST API. Same operations as MCP under `/v1/*`. Optional bearer-token auth via `VM4A_AUTH_TOKEN`.
- Python SDK (`pip install vm4a`) — stdlib-only, no third-party deps.

## v2.0.0 — 2026-05-04

The "agent-first" major release. v1.x was a solid VM lifecycle tool; v2 is a programmable surface for AI agents that need disposable VMs.

### Added — Agent primitives (v2.0 P0)

- `vm4a spawn <name>` — one-shot create+start with `--from <oci-ref>` / `--image <iso-or-ipsw>`, optional `--wait-ip` / `--wait-ssh`. Returns `{id, name, path, os, pid, ip, ssh_ready}`.
- `vm4a exec <vm> -- <cmd>` — SSH-driven command runner. Returns `{exit_code, stdout, stderr, duration_ms, timed_out}`.
- `vm4a cp` — bidirectional SCP using `:` prefix to mark guest paths.
- `vm4a fork <src> <dst>` — APFS clonefile + auto re-randomised `MachineIdentifier`, with `--auto-start` and `--from-snapshot`.
- `vm4a fork --keep-identity` — for parallel snapshot-restore use cases (see [`UseCases/golden-image-with-parallel-forks.md`](UseCases/golden-image-with-parallel-forks.md)). Required when `--from-snapshot` was saved on the source bundle, since VZ matches platform identity.
- `vm4a reset <vm> --from <state.vzstate>` — stop + restart from snapshot for try → fail → reset → retry agent loops.

### Added — Programmatic surfaces (v2.0 P1)

- `vm4a mcp` — Model Context Protocol stdio JSON-RPC 2.0 server. Eight tools (`spawn`/`exec`/`cp`/`fork`/`reset`/`list`/`ip`/`stop`) plus four resources (`vm4a://vms`/`sessions`/`session/<id>`/`pools`) plus three prompts (`agent-loop`/`debug-failed-task`/`triage-vm`). Drop-in for Claude Code, Cursor, Cline.

> `vm4a serve` + the Python SDK (v2.1), templates (v2.2), sessions (v2.3), and
> pools + network sandbox + image catalog (v2.4) now have their own sections
> above.

### Added — macOS install via CLI (`VZMacOSInstaller`)

- `vm4a create --os macOS --image foo.ipsw` drives `VZMacOSInstaller` end-to-end (10–20 minutes). Setup Assistant on first boot still requires manual click-through (Apple does not expose a scriptable skip path); after that one-time step every subsequent operation is automated.
- The CLI is co-equal across Linux and macOS guests; differences are documented explicitly in [`Cookbook.md`](Cookbook.md).

### Added — Ergonomic touches

- `--pretty` flag on every JSON-emitting command (`vm4a list --output json --pretty`, etc.). Compact stays default; the `--output` enum stays `text|json` and `--pretty` is a modifier rather than a third format.
- `vm4a-sessions` standalone SwiftUI app for browsing session histories.

### Changed

- `ListCommand` now uses the shared `listVMSummaries` helper from VM4ACore. Output gains an IP column and an id column (FNV-1a hash of the bundle path).
- `OCI bundle layout`: media type unchanged; bundle layout unchanged. v1 bundles still load.

### Documentation

- `README.md` slimmed to a 115-line entry point: pitch, status table, links to detailed docs.
- New `Cookbook.md` (recipe-driven; macOS workflow / Linux workflow / cross-cutting features) and matching `Cookbook.zh-CN.md`.
- New `UseCases/` directory with the first scenario walkthrough: golden image + daily refresh + parallel ephemeral forks.
- `Usage.md` (per-command reference), `Developer.md` (architecture + contributor guide), `AGENT.md` (now a redirect stub) — all in en + zh-CN.

### CI

- `.github/workflows/test.yml` — `swift build` + `swift test` on push and pull request, on macos-14 hosted runners.
- `.github/workflows/templates.yml` — monthly Linux template rebuild on self-hosted Apple Silicon runner.

### Tests

- 63 unit tests across 5 suites (`CoreTests`, `MCPServerTests`, `HTTPServerTests`, `SessionsTests`, `IntegrationTests`).
- `IntegrationTests` is opt-in via `VM4A_RUN_INTEGRATION=1` + `VM4A_INTEGRATION_ISO`; default `swift test` skips it.

### Migration from v1.1

- All v1.1 commands behave identically. Bundles created in v1 load and run in v2 without changes.
- The `vm4a` brand is unchanged; the GitHub URL is `github.com/everettjf/vm4a` (lowercase) — older docs that referenced `everettjf/VM4A` were corrected.

## v1.1.0 and earlier

Pre-2.0 lineage; see git history. v1.1 was the rebrand from EasyVM with the same VM lifecycle + OCI distribution + snapshot feature set.
