---
title: Tutorials
layout: default
nav_order: 3
has_children: true
permalink: /tutorials/
description: "Hands-on, progressive tutorials covering every part of VM4A."
---

# Tutorials
{: .no_toc }

Hands-on, progressive walkthroughs. Each one is self-contained: a goal, the prerequisites, copy-pasteable steps, and what you learned. Work top to bottom, or jump to the feature you need.
{: .fs-5 .fw-300 }

## The path

| # | Tutorial | You'll learn |
|---|---|---|
| 1 | [Your first VM](01-first-vm) | Create/boot a Linux VM two ways (OCI pull vs. ISO), get its IP, SSH in |
| 2 | [The agent loop](02-agent-loop) | The golden-image + per-task-fork pattern; snapshots and reset |
| 3 | [run-code & expose-port](03-run-code-expose-port) | Run snippets in one call; reach a guest service from the host |
| 4 | [MCP integration](04-mcp) | Wire `vm4a` into Claude Code / Cursor / Cline as tools |
| 5 | [HTTP API & SDKs](05-http-and-sdks) | Drive VMs over HTTP from Python or JavaScript/TypeScript |
| 6 | [Cluster scheduling](06-cluster) | Treat several Macs as one pool; least-loaded scheduling |
| 7 | [GitHub Action](07-github-action) | Run code inside a VM on a self-hosted Apple Silicon runner |
| 8 | [Networking & egress](08-networking-egress) | NAT/bridged/none modes; lock a guest to an allow-list |
| 9 | [Snapshots](09-snapshots) | Save/restore full VM state for sub-second resets |
| 10 | [Pools](10-pools) | Warm pools for millisecond per-task VM hand-out |

## Conventions used throughout

- `/tmp/vm4a` is the storage directory and `dev` the bundle name — change freely.
- Commands assume `vm4a` is on your `PATH` and codesigned (see [Getting started](../getting-started)).
- `--output json` is shown where the machine-readable shape matters.

{: .tip }
> Short on a ready-to-boot image? Tutorial 1 shows both the OCI-pull path (fastest) and building from an ISO.
