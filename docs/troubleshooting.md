---
title: Troubleshooting
layout: default
nav_order: 4
description: "Common VM4A symptoms and their fixes."
---

# Troubleshooting
{: .no_toc }

- TOC
{:toc}

---

## Install & signing

| Symptom | Likely cause / fix |
|---|---|
| Every `vm4a` command exits `137` with no output (macOS 26) | AMFI killed the ad-hoc-signed binary over the restricted `com.apple.vm.networking` entitlement. Re-sign **NAT-only** — see [Getting started → Install](getting-started#install). |
| `network list` is empty | CLI not signed with `com.apple.vm.networking` (and that needs an Apple Developer identity on macOS 26). |
| `--rosetta` fails with "not installed" | `softwareupdate --install-rosetta --agree-to-license`. |

## Boot & networking

| Symptom | Likely cause / fix |
|---|---|
| `run` exits silently | Check `<bundle>/.vm4a-run.log`. |
| `ssh` / `ip` returns nothing | VM still booting / DHCP-ing — wait 10–30 s. |
| Linux guest hangs at boot | Confirm the ISO is ARM64; verify `MachineIdentifier` and `NVRAM` exist. |
| Bridged VM has no IP via `vm4a ip` | Bridged mode doesn't use Apple's DHCP; pass `--host <ip>` (also works with `expose-port --host`). |
| `--allow-domains` has no effect | Egress guard is Linux-only and needs SSH up; macOS guests are unaffected. |

## API, SDKs & cluster

| Symptom | Likely cause / fix |
|---|---|
| `vm4a serve` returns `401` | Set the same `VM4A_AUTH_TOKEN` on the client (`GET /v1/health` stays open). |
| SDK field is `undefined` / `nil` | The wire is **snake_case** (`exit_code`, `duration_ms`, `ssh_ready`). Python exposes snake_case; the JS/TS SDK interfaces are snake_case too. |
| `cluster spawn` skips a node | Node unreachable or token mismatch — check `vm4a cluster list` and the node's `VM4A_AUTH_TOKEN`. |
| `push` returns HTTP 401 | Set `VM4A_REGISTRY_USER` / `VM4A_REGISTRY_PASSWORD`. |

## macOS guests

| Symptom | Likely cause / fix |
|---|---|
| macOS guest stays black after install | Expected — it's at Setup Assistant. Open in the GUI app to interact once. |
| `vm4a exec /macos-vm` → "Connection refused" | Enable Remote Login in the guest: System Settings → General → Sharing → Remote Login. |
| Snapshot flags refused | Requires a macOS 14+ host. |

---

Still stuck? Open an issue at [github.com/everettjf/vm4a/issues](https://github.com/everettjf/vm4a/issues).
