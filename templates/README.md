# vm4a templates

Pre-baked VM4A bundles published to `ghcr.io/everettjf/vm4a-templates/*`. Use them as base images for agent flows so individual runs don't pay the ISO install cost.

```bash
vm4a spawn dev \
    --from ghcr.io/everettjf/vm4a-templates/python-dev:latest \
    --storage /tmp/vm4a --wait-ssh
```

| Template | Tag | What's inside |
|---|---|---|
| `ubuntu-base` | `24.04`, `latest` | Ubuntu 24.04 server, ARM64, OpenSSH enabled, sudoer `vm4a` user, Python 3.12 |
| `python-dev` | `latest` | `ubuntu-base` + Python 3.12 + pipx + uv + ripgrep + git + build-essential |
| `xcode-dev` | `latest` | macOS Sequoia + Xcode CLI tools (built manually; see template README) |

Each template's directory contains:

- `provision.sh` — the script that runs inside the guest over SSH
- `build.sh` — host-side orchestration: spawn from ISO, provision, snapshot, push
- `README.md` — what's installed and how to rebuild

## Building locally

The templates need an Apple Silicon Mac with vm4a installed and a GHCR token with `write:packages`:

```bash
export VM4A_REGISTRY_USER=youruser
export VM4A_REGISTRY_PASSWORD=ghp_xxx
cd templates/ubuntu-base
./build.sh
```

The Linux templates download their ISO automatically (URL is hard-coded in each `build.sh`); macOS templates need a pre-existing bundle from the GUI install flow.

## CI

`.github/workflows/templates.yml` rebuilds the Linux templates on a self-hosted Apple Silicon runner each month. GitHub-hosted runners cannot run vm4a — Virtualization.framework requires Apple Silicon hardware that the hosted runners don't expose.
