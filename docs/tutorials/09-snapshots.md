---
title: 9 · Snapshots
layout: default
parent: Tutorials
nav_order: 9
description: "Save and restore full VM execution state for sub-second resets."
---

# Snapshots
{: .no_toc }

**Goal:** freeze a VM's full execution state and restore it in under a second.
{: .fs-5 .fw-300 }

- TOC
{:toc}

---

## Requirements

VZ snapshots need **macOS 14+**. The state is stored in a `.vzstate` file — the whole machine state (memory + devices), not just the disk.

## Save and restore

```bash
# Save the running state when the VM stops:
vm4a run  /tmp/vm4a/demo --save-on-stop /tmp/vm4a/demo/state.vzstate
vm4a stop /tmp/vm4a/demo                    # pauses + saves on the way down

# Bring it back exactly where it left off:
vm4a run  /tmp/vm4a/demo --restore /tmp/vm4a/demo/state.vzstate
```

`spawn` accepts the same flags, so one command both starts the VM and arms snapshot saving:

```bash
vm4a spawn dev --from ghcr.io/yourorg/python-dev:latest \
    --save-on-stop /tmp/vm4a/dev/clean.vzstate --wait-ssh
```

## Why it matters for agents

Boot cost is paid once. After the first boot you save a clean snapshot, then **every task starts from restore in ~1 s** instead of cold-booting. This is the engine behind the [agent loop](02-agent-loop):

```bash
# per task — restore into a fork, run, and on failure reset back to the snapshot
vm4a fork  /tmp/vm4a/dev /tmp/vm4a/task-7 --auto-start \
     --from-snapshot /tmp/vm4a/dev/clean.vzstate --wait-ssh
vm4a reset /tmp/vm4a/task-7 --from /tmp/vm4a/dev/clean.vzstate --wait-ip
```

## What you learned

- `--save-on-stop` / `--restore` capture and replay full VM state (macOS 14+).
- Snapshots turn per-task boot cost into a sub-second restore.

**Next:** [Pools](10-pools) — hand out warm VMs in milliseconds.
