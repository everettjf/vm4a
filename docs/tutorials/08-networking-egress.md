---
title: 8 · Networking & egress
layout: default
parent: Tutorials
nav_order: 8
description: "NAT / bridged / none modes, and locking a Linux guest to an egress allow-list."
---

# Networking & egress
{: .no_toc }

**Goal:** choose how a VM reaches the network, and restrict what it can talk to.
{: .fs-5 .fw-300 }

- TOC
{:toc}

---

## Network modes

`--network <mode>` picks the NIC:

| Mode | What it does |
|---|---|
| `nat` (default) | NAT on `192.168.64.0/24`; find the IP with `vm4a ip` |
| `bridged` | Gets an IP from your LAN's DHCP. Pair with `--bridged-interface <bsdName>`; first available if omitted |
| `host` | Alias for `bridged` |
| `none` | No NIC. For offline workloads or filesystem-only access |

```bash
vm4a network list                              # list bridged interfaces (bsdNames)
vm4a spawn web   --image ubuntu-arm64.iso --network bridged --bridged-interface en0
vm4a spawn airgap --image ubuntu-arm64.iso --network none
```

{: .warning }
> **Bridged mode requires the `com.apple.vm.networking` entitlement.** On macOS 26 that entitlement can't be ad-hoc signed (the binary gets killed at launch). Use NAT, or sign with a real Apple Developer identity — see [Getting started](../getting-started#install). Bridged VMs also have no Apple DHCP lease, so pass `--host <ip>` to `ssh`/`exec`/`cp`/`expose-port`.

## Egress allow-list (Linux guests)

For runs that should reach only a known set of hosts — let an agent hit `pypi.org` and `github.com` but nothing else — apply an `nftables` allow-list **inside** the guest.

**At spawn time** (applied automatically once SSH is up):

```bash
vm4a spawn dev --from ghcr.io/yourorg/python-dev:latest --wait-ssh \
    --allow-domains pypi.org,github.com
```

**After the fact, or to re-apply on a running guest:**

```bash
vm4a network guard /tmp/vm4a/dev --allow-domains pypi.org,github.com

# Re-apply the previously saved policy (no --allow-domains needed):
vm4a network guard /tmp/vm4a/dev
```

The policy is persisted to `<bundle>/egress.json`, so it survives reboots. The guard resolves each domain to its IPs and writes an `nftables` ruleset that drops outbound traffic to anything else (DNS and loopback stay open).

{: .note }
> Egress filtering hardens the **guest**, not the host, and is Linux-only (macOS guests are unaffected). Combine `--network none` for fully offline runs, or `nat` + an allow-list when a task needs a few specific endpoints.

## What you learned

- Four network modes: `nat` (default), `bridged`/`host`, `none`.
- `--allow-domains` / `vm4a network guard` lock a Linux guest to an nftables allow-list, persisted in `egress.json`.

**Next:** [Snapshots](09-snapshots) — freeze and restore full VM state.
