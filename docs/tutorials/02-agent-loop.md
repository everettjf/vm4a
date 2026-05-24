---
title: 2 · The agent loop
layout: default
parent: Tutorials
nav_order: 2
description: "The golden-image + per-task-fork pattern with snapshots and reset."
---

# The agent loop
{: .no_toc }

**Goal:** run many tasks fast and safely — each in a fresh machine that you throw away.
{: .fs-5 .fw-300 }

- TOC
{:toc}

---

## The idea

Booting a VM per task is slow. The VM4A pattern is a **golden bundle** plus an **APFS-cloned fork per task**:

```
   golden bundle           per-task fork           per-task fork
   ┌───────────┐  fork →   ┌───────────┐           ┌───────────┐
   │   /dev    │  ──────►  │ /task-42  │           │ /task-43  │  ...
   └───────────┘           └───────────┘           └───────────┘
   set up once             APFS clonefile, ~1s      throwaway after exec
```

`fork` uses APFS `clonefile(2)`, so creating a per-task VM is **O(directory entries), not O(disk size)**. Combined with a snapshot, an agent goes from "I want a clean machine" to "SSH-ready VM" in about a second.

## Step 1 — build the golden image once

```bash
vm4a spawn dev \
    --from ghcr.io/yourorg/python-dev:latest \
    --storage /tmp/vm4a \
    --save-on-stop /tmp/vm4a/dev/clean.vzstate \
    --wait-ssh --output json

# Install whatever your tasks need:
vm4a exec /tmp/vm4a/dev -- bash -lc "apt-get update && apt-get install -y ripgrep"

# Stop — the VM saves its full state to clean.vzstate on shutdown (macOS 14+).
vm4a stop /tmp/vm4a/dev
```

## Step 2 — per task: fork, push code, run

```bash
JOB_ID="task-$(date +%s)"

vm4a fork /tmp/vm4a/dev "/tmp/vm4a/$JOB_ID" \
    --auto-start --from-snapshot /tmp/vm4a/dev/clean.vzstate --wait-ssh

vm4a cp   "/tmp/vm4a/$JOB_ID" ./step.py :/work/step.py
vm4a exec "/tmp/vm4a/$JOB_ID" --output json --timeout 120 -- python3 /work/step.py
# → {"exit_code":0,"stdout":"…","stderr":"","duration_ms":3142,"timed_out":false}
```

`fork` also re-randomises the VM's `MachineIdentifier`, so the clone boots as a distinct host. It's what `clone` should have been for agent loops.

## Step 3 — bad state? reset in under a second

```bash
vm4a reset "/tmp/vm4a/$JOB_ID" --from /tmp/vm4a/dev/clean.vzstate --wait-ip
```

`reset` stops the VM and restarts it from the snapshot — the try → fail → reset → retry loop.

## Step 4 — done, throw it away

```bash
vm4a stop "/tmp/vm4a/$JOB_ID"
rm -rf "/tmp/vm4a/$JOB_ID"
```

## The other shape: a long-lived VM

When state must accumulate across tasks (an interactive Jupyter session, say), skip the fork: `spawn` once, then `exec` repeatedly against the same bundle.

## Record what happened

Tag any primitive with `--session <id>` and `vm4a` appends a JSONL event to `<bundle>/.vm4a-sessions/<id>.jsonl`:

```bash
SID="run-$(date +%s)"
vm4a fork /tmp/vm4a/dev /tmp/vm4a/task-1 --auto-start \
    --from-snapshot /tmp/vm4a/dev/clean.vzstate --wait-ssh --session $SID
vm4a exec /tmp/vm4a/task-1 --session $SID -- python3 /work/step.py
vm4a session show $SID --bundle /tmp/vm4a/task-1
```

## What you learned

- Set up a **golden bundle** once; **fork** a throwaway per task in ~1 s.
- `--save-on-stop` / `--from-snapshot` / `reset` give sub-second clean slates.
- `--session` records a replayable timeline of a run.

**Next:** [run-code & expose-port](03-run-code-expose-port) — fewer round-trips per task.
