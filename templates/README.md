# vm4a templates

Pre-baked VM4A bundles published to `ghcr.io/everettjf/vm4a-templates/*`. Use them as base images for agent flows so individual runs don't pay the OS install cost. Both Linux and macOS guests are supported.

```bash
# Linux
vm4a spawn dev \
    --from ghcr.io/everettjf/vm4a-templates/python-dev:latest \
    --storage /tmp/vm4a --wait-ssh

# macOS (post-setup-assistant; the bundle has a user account + Remote Login on)
vm4a spawn xcode --os macOS \
    --from ghcr.io/everettjf/vm4a-templates/xcode-dev:latest \
    --storage /tmp/vm4a --wait-ssh
```

| Template | Tag | What's inside |
|---|---|---|
| `ubuntu-base` | `24.04`, `latest` | Ubuntu 24.04 server, ARM64, OpenSSH enabled, sudoer `vm4a` user, Python 3.12 |
| `python-dev` | `latest` | `ubuntu-base` + Python 3.12 + pipx + uv + ripgrep + git + build-essential |
| `xcode-dev` | `latest` | macOS 15 + Xcode Command Line Tools + Homebrew + git/ripgrep/jq |

Each template's directory contains:

- `provision.sh` — the script that runs inside the guest over SSH
- `build.sh` — host-side orchestration: install OS, provision, snapshot, push
- `README.md` — what's installed and how to rebuild

> The Linux templates rebuild fully unattended. The `xcode-dev` template needs **one** manual step per IPSW version — Apple's Setup Assistant on first boot can't be driven headlessly. After that, every rebuild is automated; consumers pulling the pushed image skip Setup Assistant entirely (the user account is baked in, Remote Login is on, the snapshot was saved post-setup).

## Building locally

Apple Silicon Mac with vm4a installed and a GHCR token with `write:packages`:

```bash
export VM4A_REGISTRY_USER=youruser
export VM4A_REGISTRY_PASSWORD=ghp_xxx
cd templates/ubuntu-base
./build.sh
```

Linux templates download their ISO automatically. The `xcode-dev` template needs a macOS IPSW you provide (and the one-time Setup Assistant click-through documented in its README).

## CI

`.github/workflows/templates.yml` rebuilds the Linux templates on a self-hosted Apple Silicon runner each month. The macOS template is built manually because its IPSW source and Setup Assistant step aren't safely automatable. GitHub-hosted runners cannot run vm4a — Virtualization.framework requires Apple Silicon hardware that the hosted runners don't expose.
