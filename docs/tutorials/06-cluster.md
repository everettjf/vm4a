---
title: 6 · Cluster scheduling
layout: default
parent: Tutorials
nav_order: 6
description: "Treat several Macs as one pool and land VMs on the least-loaded node."
---

# Cluster scheduling
{: .no_toc }

**Goal:** schedule VMs across several Macs as if they were one machine.
{: .fs-5 .fw-300 }

- TOC
{:toc}

---

## The idea

A single Mac has finite cores. The cluster scheduler treats several Macs — each running `vm4a serve` — as one pool, and lands new VMs on the **least-loaded** node ("fewest running VMs wins"). Unreachable nodes are skipped.

```
  controller  ──cluster spawn──►  picks least-loaded reachable node
       │
       ├── mac-studio  (vm4a serve, 10.0.0.5:7777)   3 VMs
       └── mac-mini    (vm4a serve, 10.0.0.6:7777)   1 VM   ◄── lands here
```

## Step 1 — run a server on each worker Mac

```bash
# On every worker, behind a shared token, bound to the LAN:
export VM4A_AUTH_TOKEN=shared-secret
vm4a serve --bind 0.0.0.0 --port 7777
```

## Step 2 — register the nodes on the controller

```bash
vm4a cluster add mac-studio --url http://10.0.0.5:7777 --token shared-secret
vm4a cluster add mac-mini   --url http://10.0.0.6:7777 --token shared-secret
vm4a cluster list
# mac-studio   http://10.0.0.5:7777   auth
# mac-mini     http://10.0.0.6:7777   auth
```

The registry is plain JSON under `~/.vm4a/cluster/` — version it or template it for reproducible fleets.

## Step 3 — spawn on the least-loaded node

```bash
vm4a cluster spawn dev --from ghcr.io/yourorg/python-dev:latest --wait-ssh
# → {"node":"mac-mini","outcome":{ …SpawnOutcome… }}
```

## Step 4 — target a node for follow-up work

```bash
vm4a cluster exec --node mac-mini /tmp/vm4a/dev -- python3 /work/step.py
vm4a cluster status        # aggregate VM counts across all nodes
```

## Command reference

| Subcommand | What it does |
|---|---|
| `cluster add <name> --url <u> [--token <t>]` | Register a remote `vm4a serve` node |
| `cluster remove <name>` | Unregister a node |
| `cluster list [--output json]` | List nodes + reachability |
| `cluster spawn <name> [spawn flags]` | Spawn on the least-loaded reachable node |
| `cluster exec --node <name> <vm> -- <cmd>` | Exec on a specific node's VM |
| `cluster status [--output json]` | Aggregate VM counts across nodes |

{: .warning }
> Each node is a full `vm4a serve` over the network. Bind to `0.0.0.0` **only** with `VM4A_AUTH_TOKEN` set, and keep it on a trusted LAN.

## What you learned

- `vm4a serve` nodes + `cluster add` form a pool; `cluster spawn` schedules least-loaded.
- The node registry is just JSON under `~/.vm4a/cluster/`.

**Next:** [GitHub Action](07-github-action) — the same idea in CI.
