---
title: 1 · Your first VM
layout: default
parent: Tutorials
nav_order: 1
description: "Create and boot a Linux VM two ways, resolve its IP, and SSH in."
---

# Your first VM
{: .no_toc }

**Goal:** boot a Linux guest, find its IP, and run a command inside it.
{: .fs-5 .fw-300 }

- TOC
{:toc}

---

## Prerequisites

- `vm4a` installed and codesigned ([Getting started](../getting-started)).
- ~5 GB free disk.

## Path A — pull a pre-baked image (fastest)

Pre-baked OCI bundles boot straight to SSH, so there's no install step. This is the recommended path for any automation.

```bash
vm4a spawn dev \
    --from ghcr.io/yourorg/python-dev:latest \
    --storage /tmp/vm4a \
    --wait-ssh --output json
```

`spawn` creates the bundle, starts the VM, and (with `--wait-ssh`) blocks until SSH answers. The JSON it returns is your handle:

```json
{"id":"…","name":"dev","path":"/tmp/vm4a/dev","os":"linux","pid":4242,"ip":"192.168.64.7","ssh_ready":true}
```

Jump to [Run something in it](#run-something-in-it).

## Path B — create from an ISO

When you don't have a registry image, build from a catalog id, a local ISO, or any URL. `vm4a` downloads and caches the media for you.

```bash
# Catalog id (vm4a fetches + caches the ISO)
vm4a create demo --image ubuntu-24.04-arm64 --storage /tmp/vm4a \
    --cpu 4 --memory-gb 4 --disk-gb 32

vm4a run /tmp/vm4a/demo            # start it (detached worker)
```

{: .warning }
> A stock Ubuntu **Server ISO installer is interactive** — it won't reach SSH on its own. Either complete the install in the GUI app once, or use a cloud image with a cloud-init seed. For unattended automation, prefer Path A (a pre-baked OCI bundle).

`vm4a image list` shows catalog ids; `vm4a image where` prints the cache directory (`~/.cache/vm4a/images/`).

## Find the IP

NAT VMs get an address from Apple's DHCP server:

```bash
vm4a ip /tmp/vm4a/dev               # → 192.168.64.7
vm4a ip /tmp/vm4a/dev --output json # → [{"ip":"…","mac":"…","name":"dev"}]
```

If it returns nothing, the VM is still booting / DHCP-ing — wait 10–30 s.

## Run something in it

```bash
# Streamed output, exit code becomes the process exit code:
vm4a exec /tmp/vm4a/dev -- python3 -c 'print(1+1)'

# Machine-readable:
vm4a exec /tmp/vm4a/dev --output json -- bash -lc 'uname -a'
# → {"exit_code":0,"stdout":"Linux …\n","stderr":"","duration_ms":280,"timed_out":false}
```

Open an interactive shell with `vm4a ssh /tmp/vm4a/dev`. Default SSH user is `root` on Linux; override with `--user`.

## Copy files

The `:` prefix marks the guest side (the opposite of `docker cp`):

```bash
vm4a cp /tmp/vm4a/dev ./local.py :/work/script.py    # host → guest
vm4a cp /tmp/vm4a/dev :/var/log/syslog ./syslog.txt  # guest → host
vm4a cp /tmp/vm4a/dev -r ./project :/srv/code         # recursive
```

## Stop and clean up

```bash
vm4a stop /tmp/vm4a/dev
rm -rf /tmp/vm4a/dev        # the bundle is just a folder
```

## What you learned

- A VM is a **bundle** (a folder); you point commands at its path.
- `spawn --from` is the one-shot pull-and-boot path; `create --image` builds from media.
- `ip`, `exec`, `cp`, `ssh` are the basic guest interactions, all with optional `--output json`.

**Next:** [The agent loop](02-agent-loop) — the pattern you'll actually use for per-task work.
