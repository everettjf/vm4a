# ubuntu-base — minimal Ubuntu 24.04 ARM64 for agents

Foundation template the other Linux images inherit from. Contains:

- Ubuntu 24.04 server, ARM64, kernel + base utilities
- OpenSSH server enabled, accepts password + key auth
- Sudoer user `vm4a` (password `vm4a`, no key required)
- Python 3.12 (system package), curl, ca-certificates
- A clean `.vzstate` snapshot saved at `clean.vzstate` so consumers get a sub-second boot

Pull and run:

```bash
vm4a spawn dev --from ghcr.io/everettjf/vm4a-templates/ubuntu-base:24.04 \
    --storage /tmp/vm4a --wait-ssh
vm4a exec /tmp/vm4a/dev -- whoami
```

## Rebuild

```bash
export VM4A_REGISTRY_USER=youruser VM4A_REGISTRY_PASSWORD=ghp_xxx
./build.sh        # spawn → provision → snapshot → push
```

The build downloads the Ubuntu ARM64 server ISO if not already cached at `~/.cache/vm4a-templates/`.
