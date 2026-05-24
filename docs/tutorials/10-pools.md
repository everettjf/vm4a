---
title: 10 · Pools
layout: default
parent: Tutorials
nav_order: 10
description: "Define per-task VM templates and run a warm pool for millisecond hand-out."
---

# Pools
{: .no_toc }

**Goal:** mint per-task VMs from a template, and keep a warm pool for instant hand-out.
{: .fs-5 .fw-300 }

- TOC
{:toc}

---

## On-demand: a pool definition

Define how to mint a fresh per-task VM once, then call `pool spawn` per task:

```bash
# Once, after your golden VM is set up:
vm4a pool create py \
    --base /tmp/vm4a/python-dev \
    --snapshot /tmp/vm4a/python-dev/clean.vzstate \
    --prefix task --storage /tmp/vm4a-tasks

# Per task (equivalent to fork --auto-start):
vm4a pool spawn py --wait-ssh
# → mints /tmp/vm4a-tasks/task-<unix-timestamp>
```

Definitions are JSON at `~/.vm4a/pools/<name>.json`:

```bash
vm4a pool list
vm4a pool show py
vm4a pool destroy py
```

## Warm pool: millisecond hand-out

For latency-sensitive workloads, run a daemon that keeps `--size N` VMs idle and ready. `pool acquire` is then an atomic filesystem rename — millisecond-fast:

```bash
vm4a pool create py \
    --base /tmp/vm4a/python-dev \
    --snapshot /tmp/vm4a/python-dev/clean.vzstate \
    --prefix task --storage /tmp/vm4a-tasks \
    --size 4

vm4a pool serve py &        # daemon; restart-safe (adopts existing warm VMs)

# Per task: acquire (instant) → exec → release
VM=$(vm4a pool acquire py --output json | jq -r .path)
vm4a exec "$VM" -- python3 /work/step.py
vm4a pool release "$VM"
```

On disk:

- `<storage>/<prefix>-warm-<n>` — idle, owned by the daemon, ready to hand out
- `<storage>/<prefix>-leased-<label>` — claimed; yours until `release`

## Which to use

- `pool spawn` — on-demand, no daemon. Simple.
- `pool acquire` / `release` — warm path, sub-millisecond hand-out. Run `pool serve`.

Mix freely per workload.

## What you learned

- A **pool definition** captures the per-task minting recipe (base + snapshot + prefix).
- A **warm pool** (`pool serve` + `acquire`/`release`) hands out ready VMs near-instantly.

**That's the tour.** Back to the [tutorials index](./) or the repo's [`Usage.md`](https://github.com/everettjf/vm4a/blob/main/Usage.md) for the full per-command reference.
