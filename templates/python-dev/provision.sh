#!/usr/bin/env bash
# Adds Python tooling on top of ubuntu-base.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y --no-install-recommends \
    git ripgrep build-essential pkg-config libssl-dev libffi-dev \
    python3-pip pipx \
    jq

echo "==> install uv (Astral)"
curl -LsSf https://astral.sh/uv/install.sh | sh
ln -sf /root/.local/bin/uv /usr/local/bin/uv
ln -sf /root/.local/bin/uvx /usr/local/bin/uvx

echo "==> warm pipx + uv path for vm4a user"
sudo -u vm4a bash -lc 'pipx ensurepath || true'

apt-get clean
rm -rf /var/lib/apt/lists/*
