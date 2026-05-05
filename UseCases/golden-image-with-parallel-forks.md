# Golden image with daily refresh + parallel ephemeral forks

> 中文：[golden-image-with-parallel-forks.zh-CN.md](golden-image-with-parallel-forks.zh-CN.md)

## The problem

You're building an agent system where each task needs:

- A specific Python (or Xcode, or other) toolchain pre-installed
- A working copy of one or more large repositories (~1 GB+ each)
- The repos kept reasonably current (yesterday's `git pull`, not last month's)
- Strict isolation between concurrent task runs — one task's `rm -rf /` must not touch another's files
- Fast hand-out — agents shouldn't sit through `apt-get install` or `git clone` on every task

The naive approaches all break:

- **Run everything on the host:** no isolation; one bad agent corrupts your machine
- **Spin up a fresh Linux VM per task:** isolation ✓, but install + clone takes 5–15 minutes; tasks become Slack-coffee-break length
- **Cache the install on shared disk:** isolation ✗, contention on shared `/repos`
- **One persistent VM with `git pull` between tasks:** isolation ✗, state leaks across tasks

What you want is **fast clones of a known-good image, with each clone being its own machine**. That's exactly what VM4A's golden-image + per-task fork pattern does.

## Goals

- One-time bootstrap, repeatable thereafter
- Daily refresh costs minutes, not hours
- Per-task spawn is **seconds** (warm path) or **<30 seconds** (cold path)
- Each task gets its own filesystem, its own kernel, its own network
- N parallel tasks share zero state at runtime
- Works for Linux guests (fully automated) and for macOS guests (one manual Setup Assistant step the very first time)

## Non-goals

- Sub-second hand-out without a daemon (the warm-pool runtime gets us there, but on-demand fork is ~1 s with `--from-snapshot` or ~30 s cold)
- Cross-host distribution at this layer (use `vm4a push` / `vm4a pull` to a registry — separate concern, fully supported)
- Containers; this is full VMs because agent isolation is a security boundary, not a packaging convenience

## Architecture

```
                          (cron, daily)
                                │
                                ▼
        ┌───────────────────────────────────────────┐
        │  Base bundle: /tmp/vm4a/base              │
        │   - Disk.img (Python + repos installed)   │
        │   - latest.vzstate → today.vzstate        │
        │   - history: v1.vzstate, 20260501.vzstate, …
        └───────────────────────────────────────────┘
                                │
                  vm4a fork --keep-identity --from-snapshot
                                │
       ┌────────────────────────┼────────────────────────┐
       ▼                        ▼                        ▼
  task-1234 (live)          task-1235 (live)        task-1236 (live)
   own Disk.img              own Disk.img            own Disk.img
   own MAC                   own MAC                 own MAC
   shared platform ID        shared platform ID      shared platform ID
   (so .vzstate              (so .vzstate            (so .vzstate
    restore works)           restore works)           restore works)
```

Three things make this work:

1. **APFS clonefile** — cloning the bundle is O(directory entries), not O(disk image size). A 100 GB bundle clones in milliseconds.
2. **VZ memory snapshots (`.vzstate`)** — the saved memory state lets a fork resume in <1 second instead of paying boot cost. The snapshot pairs with the cloned disk because the disk *was* the disk at save time.
3. **`--keep-identity`** — `MachineIdentifier` is part of VZ's platform identity check on snapshot restore. Forks must keep the source's identity verbatim; their isolation comes from the cloned disks and unique MAC addresses (which are independent of platform identity).

## Step-by-step

### 0. Pick an OS

| | Linux | macOS |
|---|---|---|
| First-time setup | Fully unattended (cloud-init or manual ssh) | One Setup Assistant click-through per fresh IPSW |
| Per-rebuild after that | Fully unattended | Fully unattended |
| Recommendation | Default. Use this unless you specifically need macOS-side toolchains (Xcode, signing, App Store builds) | When the agent needs to compile/test iOS/macOS apps |

The rest of this document uses Linux to keep examples short. The macOS variant is identical from step 4 onwards; differences are called out at the end.

### 1. Bootstrap the base VM (one time)

```bash
BASE=/tmp/vm4a/base

vm4a spawn base \
    --image ubuntu-24.04-arm64 \
    --storage /tmp/vm4a \
    --memory-gb 8 --disk-gb 100 \
    --wait-ssh
```

`--image ubuntu-24.04-arm64` is a catalog id; `vm4a` auto-downloads the ISO to `~/.cache/vm4a/images/` on first use. After SSH is up, install your toolchain and clone the repos:

```bash
vm4a exec $BASE -- bash -lc '
    set -euo pipefail
    apt-get update -qq
    apt-get install -y -qq curl git build-essential
    curl -fsSL https://pyenv.run | bash
    export PATH="$HOME/.pyenv/bin:$PATH"
    eval "$(pyenv init -)"
    pyenv install 3.12 && pyenv global 3.12
    mkdir -p /repos && cd /repos
    git clone --depth=1 https://github.com/yourorg/repo-a.git
    git clone --depth=1 https://github.com/yourorg/repo-b.git
'
```

### 2. Save the first snapshot

```bash
# Re-arm the running VM with --save-on-stop, then stop to trigger the save
vm4a stop $BASE
vm4a run $BASE --save-on-stop $BASE/v1.vzstate
sleep 30
vm4a stop $BASE

# Symlink "latest" so consumers don't need to know the date suffix
ln -sf v1.vzstate $BASE/latest.vzstate
```

The symlink is the trick that lets the daily-refresh job atomically swap which snapshot is "current" without consumers knowing.

### 3. Daily refresh (cron)

A small wrapper script, e.g. `~/bin/vm4a-refresh-base`:

```bash
#!/usr/bin/env bash
set -euo pipefail
BASE=/tmp/vm4a/base
TODAY=$BASE/$(date -u +%Y%m%d).vzstate

# Restore yesterday's snapshot, pull, save today's snapshot
vm4a run $BASE --restore $BASE/latest.vzstate --save-on-stop $TODAY
sleep 10
vm4a exec $BASE --timeout 1800 -- bash -lc '
    set -euo pipefail
    cd /repos
    for r in */; do
        echo "=== updating $r ==="
        (cd "$r" && git fetch --all --prune && git pull --rebase)
    done
'
vm4a stop $BASE

# Atomic switch
ln -sfn "$(basename "$TODAY")" $BASE/latest.vzstate

# Garbage-collect snapshots older than 30 days
find $BASE -name '20*.vzstate' -mtime +30 -delete
```

Cron entry:

```
30 3 * * *   /Users/me/bin/vm4a-refresh-base 2>&1 | logger -t vm4a-refresh
```

If the refresh fails (`git pull` conflict, network down, disk full), the cron exits non-zero and `latest.vzstate` keeps pointing at yesterday's snapshot — agents continue with slightly stale repos rather than no repos.

### 4. Per-task fork (the agent's hot path)

```bash
JOB=task-$(date +%s)-$RANDOM
DST=/tmp/vm4a/$JOB

vm4a fork $BASE $DST \
    --auto-start \
    --from-snapshot $BASE/latest.vzstate \
    --keep-identity \
    --wait-ssh

# Run the agent step
vm4a exec $DST --output json --timeout 600 \
    -- python3 /repos/repo-a/scripts/agent_step.py "$@"

# Done — clean up
vm4a stop $DST
rm -rf $DST
```

End-to-end on a 100 GB bundle:
- `vm4a fork` (APFS clonefile): ~100 ms
- VM boot from `.vzstate` restore: ~500 ms
- SSH ready: ~1–2 s additional
- Total: **2–3 seconds** from cold to "ready to run code"

> **Critical: `--keep-identity`.** Without it, `vm4a fork` re-randomises `MachineIdentifier` and the subsequent `--from-snapshot` restore is rejected by VZ (the saved state was bound to the original platform identity). Network MAC addresses are independent — they're auto-generated per-fork by VZ, so parallel forks still get distinct DHCP leases.

### 5. Parallel scaling — the warm pool

Step 4 is fast enough for most workloads, but if you spawn dozens of tasks per minute, even ~2 s adds up. The warm-pool daemon keeps N forks pre-spawned so acquire is a millisecond-fast filesystem rename:

```bash
# Define the pool once
vm4a pool create py \
    --base $BASE \
    --snapshot $BASE/latest.vzstate \
    --prefix task \
    --storage /tmp/vm4a-tasks \
    --size 4

# Run the daemon (foreground; restart-safe)
vm4a pool serve py &

# Per task: acquire (instant), exec, release
VM=$(vm4a pool acquire py --output json | jq -r .path)
vm4a exec "$VM" --output json -- python3 /repos/repo-a/scripts/agent_step.py
vm4a pool release "$VM"
# The daemon notices the deficit on its next tick (default 5 s) and refills.
```

`vm4a pool serve` automatically passes `--keep-identity` whenever the pool definition includes a `--snapshot`, so you don't need to thread the flag through.

## Operational concerns

### Disk usage

- `Disk.img` is allocated up to `--disk-gb` (default 64 GB). APFS clonefile makes the disk for each fork *initially* free (it shares blocks with the source), but each guest write to the cloned disk allocates new blocks. A 100 GB base + 10 forks each writing 5 GB = 100 + 50 = 150 GB on disk, not 1 TB.
- `.vzstate` snapshots are roughly the size of the VM's RAM (8 GB if `--memory-gb 8`). Keep maybe 7–30 days of dated snapshots for forensics, garbage-collect the rest in the cron.
- If you're tight on disk: shrink memory (smaller `.vzstate`), or only keep `latest.vzstate` (delete dated snapshots immediately after the symlink swap).

### Snapshot health

The daily refresh script is the riskiest piece. Recommended monitoring:

```bash
# In the cron wrapper:
START=$(date +%s)
... main work ...
END=$(date +%s)
DURATION=$((END - START))
echo "vm4a-refresh: ok, ${DURATION}s, snapshot=$(readlink $BASE/latest.vzstate)"
```

Pipe to your alerting system (Slack webhook, Datadog, whatever). Alert if duration > 30 minutes, or if the cron exits non-zero, or if `latest.vzstate` is older than 36 hours.

### Repo-level surprises

- **`git pull` merge conflicts**: rare on a fresh checkout, but possible if you pre-installed local commits. Make sure the base VM's working trees are pristine; use `git pull --rebase` (script does this) and consider `git pull --ff-only` to fail fast.
- **Repos with submodules**: add `git submodule update --init --recursive` to the loop.
- **LFS-backed repos**: install `git-lfs` in the base, run `git lfs pull` after the regular pull.

### Fork lifecycle

- **Stale forks accumulate** if your task wrapper doesn't run `vm4a stop` + `rm -rf` on errors. Use a `trap` in shell, a context manager in Python, or the warm-pool's `pool release` (which always cleans up).
- **Pool overflow**: if you `pool acquire` faster than `pool serve` can refill, acquires block until a warm VM is ready. The daemon's `--interval` controls how often it scans.

## Variations

### Linux + autoinstall (hands-off bootstrap)

For step 1, instead of interactive install, build a `user-data` cloud-init seed and pass it to the ISO. Out of scope for this doc; see [Ubuntu autoinstall](https://canonical-subiquity.readthedocs-hosted.com/en/latest/intro-to-autoinstall.html). The principle is "step 1 also runs from cron", so a brand-new dev machine can rebuild from zero in a single script.

### macOS guest (with one-time Setup Assistant)

```bash
# Step 1 changes:
vm4a create base --os macOS --memory-gb 8 --disk-gb 100
# ... auto-fetches latest IPSW + drives VZMacOSInstaller (10–20 min)

# Then OPEN VM4A.app, click through Setup Assistant ONCE:
#   region → skip Apple ID → create user `vm4a` → desktop
#   System Settings → General → Sharing → Remote Login: ON
# Stop the VM.

# Step 1 (continued) — same as Linux, just with --user vm4a:
vm4a run base
sleep 30
vm4a exec base --user vm4a -- bash -lc '
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
    brew install pyenv git
    pyenv install 3.12 && pyenv global 3.12
    mkdir -p /Users/vm4a/repos && cd /Users/vm4a/repos
    git clone https://github.com/yourorg/repo-a.git
'

# Steps 2–5: identical to Linux (just remember --user vm4a on every exec).
```

After the snapshot is saved post-Setup-Assistant, the daily refresh and per-task fork are completely automated — no human in the loop. Push the snapshot once to GHCR and any other developer can `vm4a spawn dev --from <ref> --os macOS` and skip Setup Assistant entirely.

### Pre-baked image distribution (team / CI)

Instead of every developer running step 1, push the post-bootstrap base to a registry:

```bash
# Once
vm4a push $BASE ghcr.io/yourorg/agent-base:py3.12-2026-05-04

# On every developer machine / CI runner
vm4a spawn base --from ghcr.io/yourorg/agent-base:py3.12-latest \
    --storage /tmp/vm4a --wait-ssh
# Steps 2–5 then proceed as above
```

The registry is the source of truth; cron rebuilds + re-pushes weekly or on demand.

### "I don't trust `--keep-identity` yet"

Skip `--keep-identity` (and `--from-snapshot` along with it) and let each fork cold-boot from the cloned disk:

```bash
vm4a fork $BASE $DST --auto-start --wait-ssh
```

Cold boot from a Linux disk that already has Python + repos: 10–30 seconds. Slower than snapshot restore, but works regardless of any VZ identity-matching subtlety. Useful as a fallback if you hit issues with snapshot-based forks on a particular host.

## Tradeoffs

| Decision | Pro | Con |
|---|---|---|
| Snapshot-based fork (`--from-snapshot --keep-identity`) | <2 s per task | Requires VZ snapshot restore to work with a duplicated platform ID; works in our testing but is a less-trodden path than cold boot |
| Cold-boot fork (no snapshot) | Most reliable | 10–30 s per task |
| Warm pool (`pool serve`) | Hand-out is ms-fast | Daemon has to run; spawns N idle VMs even when not needed; uses `--memory-gb × N` of RAM continuously |
| Daily snapshot vs hourly | Cheap, simple | Tasks may use 1-day-old commits |
| 30-day snapshot retention | Forensics-friendly | `8 GB × 30 = 240 GB` per pool |

## Why VM4A (vs alternatives)

- **vs Docker / containers**: containers share the host kernel — hostile-by-default agent code can escape. VMs are a hardware boundary.
- **vs UTM / VirtualBuddy**: those don't expose programmatic snapshot+fork primitives a CLI can drive.
- **vs Tart**: similar Apple-Silicon-native tool; vm4a's differentiators here are MCP/HTTP/SDK surfaces, the Python SDK, the warm-pool runtime, and (importantly) being open about the `--keep-identity` requirement.
- **vs cloud sandboxes (E2B, Modal)**: those are Linux-only and not local. If you need macOS guests, only local Apple-Silicon-host VMs work.

## See also

- [`Cookbook.md`](../Cookbook.md) — per-command reference and shorter recipes
- [`Usage.md`](../Usage.md) — full CLI flag reference
- `vm4a fork --help`, `vm4a pool --help`, `vm4a image --help`
