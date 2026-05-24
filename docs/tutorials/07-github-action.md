---
title: 7 · GitHub Action
layout: default
parent: Tutorials
nav_order: 7
description: "Run code inside a VM4A VM on a self-hosted Apple Silicon runner."
---

# GitHub Action
{: .no_toc }

**Goal:** run a command inside a fresh VM as a CI step.
{: .fs-5 .fw-300 }

- TOC
{:toc}

---

## Why self-hosted

GitHub's hosted macOS runners are themselves VMs and **cannot nest** `Virtualization.framework`. So the Action targets a **self-hosted Apple Silicon runner**. It builds + codesigns `vm4a` from the checked-out repo, then drives it.

## Minimal workflow

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
          command: "python3 -m pytest -q"      # run via `vm4a exec -- bash -lc`
          allow-domains: pypi.org,github.com    # Linux egress allow-list
          cleanup: "true"                       # stop + remove the VM at job end
      - run: echo "exit=${{ steps.vm.outputs.exit-code }} ip=${{ steps.vm.outputs.ip }}"
```

The Action spawns a VM (pulling `from`, or building from `image`), runs `command` inside it via `bash -lc`, captures the result, and — unless `cleanup: false` — stops and removes the VM when the job ends. The job **fails if the in-guest command exits non-zero**.

## Inputs

| Input | Default | Notes |
|---|---|---|
| `command` *(required)* | — | Shell command run in the guest via `bash -lc` |
| `from` / `image` | `""` | OCI ref to pull, or catalog id / path / URL to build (mutually exclusive) |
| `name` | `ci` | Bundle name (`<storage>/<name>`) |
| `os` | `linux` | `linux` or `macOS` |
| `storage` | `/tmp/vm4a` | Parent directory for the bundle |
| `wait-timeout` | `180` | Seconds to wait for SSH |
| `exec-timeout` | `600` | Seconds the command may run |
| `allow-domains` | `""` | Comma-separated Linux egress allow-list |
| `cleanup` | `true` | Stop + delete the VM after the run |

## Outputs

`exit-code`, `stdout`, `ip`.

## Setting up the runner

The runner Mac needs `vm4a`'s codesigning to work. On macOS 26, that means the NAT-only signing workaround (see [Getting started](../getting-started#install)) unless you have an Apple Developer identity for bridged mode. NAT is sufficient for the Action.

## What you learned

- The Action runs a one-shot "spawn → exec → cleanup" inside a VM on a self-hosted Apple Silicon runner.
- `allow-domains` applies the egress allow-list per run; `cleanup` handles teardown.

**Next:** [Networking & egress](08-networking-egress) — what `allow-domains` actually does.
