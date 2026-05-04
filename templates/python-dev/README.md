# python-dev — Python 3 + uv + ripgrep on top of ubuntu-base

Common starter image for agents that write and run Python:

- Everything from `ubuntu-base`
- `uv` (the fast Python package installer)
- `pipx` (so each tool gets its own venv)
- `ripgrep`, `git`, `build-essential`, `pkg-config`, `libssl-dev` (for native wheels)

```bash
vm4a spawn dev --from ghcr.io/everettjf/vm4a-templates/python-dev:latest \
    --storage /tmp/vm4a --wait-ssh
vm4a exec /tmp/vm4a/dev -- uv --version
```

## Rebuild

```bash
export VM4A_REGISTRY_USER=youruser VM4A_REGISTRY_PASSWORD=ghp_xxx
./build.sh
```

`build.sh` pulls `ubuntu-base:24.04` from GHCR, runs `provision.sh` over SSH, then pushes the resulting bundle as `python-dev:latest`.
