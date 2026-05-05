# Changelog

All notable changes to this project. Versions follow [Semantic Versioning](https://semver.org/).

## v2.0.0 — 2026-05-04

The "agent-first" major release. v1.x was a solid VM lifecycle tool; v2 is a programmable surface for AI agents that need disposable VMs.

### Added — Agent primitives (v2.0 P0)

- `vm4a spawn <name>` — one-shot create+start with `--from <oci-ref>` / `--image <iso-or-ipsw>`, optional `--wait-ip` / `--wait-ssh`. Returns `{id, name, path, os, pid, ip, ssh_ready}`.
- `vm4a exec <vm> -- <cmd>` — SSH-driven command runner. Returns `{exit_code, stdout, stderr, duration_ms, timed_out}`.
- `vm4a cp` — bidirectional SCP using `:` prefix to mark guest paths.
- `vm4a fork <src> <dst>` — APFS clonefile + auto re-randomised `MachineIdentifier`, with `--auto-start` and `--from-snapshot`.
- `vm4a fork --keep-identity` — for parallel snapshot-restore use cases (see [`UseCases/golden-image-with-parallel-forks.md`](UseCases/golden-image-with-parallel-forks.md)). Required when `--from-snapshot` was saved on the source bundle, since VZ matches platform identity.
- `vm4a reset <vm> --from <state.vzstate>` — stop + restart from snapshot for try → fail → reset → retry agent loops.

### Added — Programmatic surfaces (v2.0 P1, v2.1)

- `vm4a mcp` — Model Context Protocol stdio JSON-RPC 2.0 server. Eight tools (`spawn`/`exec`/`cp`/`fork`/`reset`/`list`/`ip`/`stop`) plus four resources (`vm4a://vms`/`sessions`/`session/<id>`/`pools`) plus three prompts (`agent-loop`/`debug-failed-task`/`triage-vm`). Drop-in for Claude Code, Cursor, Cline.
- `vm4a serve` — localhost HTTP REST API. Same operations as MCP under `/v1/*`. Optional bearer-token auth via `VM4A_AUTH_TOKEN`.
- Python SDK (`pip install vm4a`) — stdlib-only, no third-party deps.

### Added — Templates (v2.2)

- Curated OCI templates published to `ghcr.io/everettjf/vm4a-templates/*`:
  - `ubuntu-base:24.04` (Ubuntu 24.04 server, ARM64, OpenSSH, Python 3.12)
  - `python-dev:latest` (ubuntu-base + uv + pipx + ripgrep + git + build-essential)
  - `xcode-dev:latest` (macOS 15 + Xcode CLT + Homebrew, post-Setup-Assistant)
- Linux templates rebuild monthly via `.github/workflows/templates.yml` on a self-hosted Apple Silicon runner. macOS template requires one-time Setup Assistant click-through per IPSW; rebuild from there is automated.

### Added — Sessions and Time Machine (v2.3)

- `--session <id>` flag on every agent primitive; appends a JSONL event to `<bundle>/.vm4a-sessions/<id>.jsonl` with `{seq, timestamp, kind, vmPath, success, durationMs, summary, args, outcome}`. Both success and error paths are recorded via `SessionRecorder` + `defer`.
- `vm4a session list/show` — CLI inspection.
- `vm4a-sessions` — standalone SwiftUI Time Machine viewer (built via SwiftPM), reads the same JSONL files and renders a timeline with expandable args/outcome panels.

### Added — Pools and network sandbox (v2.4)

- `vm4a pool create/show/list/destroy` — pool definitions (JSON at `~/.vm4a/pools/<name>.json`) describing how to mint per-task VMs from a base.
- `vm4a pool spawn` — on-demand fork, equivalent to `fork --auto-start --from-snapshot` from the saved definition.
- `vm4a pool serve` — warm-pool daemon that keeps `--size N` VMs idle and ready, refilling on consumption.
- `vm4a pool acquire <name>` — atomic filesystem rename hand-out (millisecond-fast).
- `vm4a pool release <vm-path>` — stop + delete; daemon refills on next tick.
- `--network none|nat|bridged|host` mode flag on `create` and `spawn`.
- `VMModelFieldStorageDevice.readOnly` — per-attachment read-only flag, defaults to `true` for ISOs/USB attachments.

### Added — Image catalog with auto-download (v2.4)

- `vm4a image list` — Linux ISOs (Ubuntu / Fedora / Debian / Alpine) plus the dynamic `macos-latest` sentinel that resolves via `VZMacOSRestoreImage.fetchLatestSupported`.
- `vm4a image pull <spec>` — explicit prefetch.
- `vm4a image where` — print cache directory + cached files.
- `--image` accepts: catalog id / local path / `https://` URL / nothing-with-`--os macOS` (auto-fetches latest IPSW). Cache lives at `~/.cache/vm4a/images/`. SHA256 verified when the catalog provides it.

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
