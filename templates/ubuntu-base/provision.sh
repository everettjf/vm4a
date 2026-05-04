#!/usr/bin/env bash
# Run inside the guest. Idempotent.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "==> apt update + base tooling"
apt-get update -y
apt-get install -y --no-install-recommends \
    openssh-server \
    sudo ca-certificates curl wget \
    python3 python3-venv python3-pip \
    tzdata locales

echo "==> ensure 'vm4a' user exists"
if ! id vm4a &>/dev/null; then
    useradd -m -s /bin/bash vm4a
    echo 'vm4a:vm4a' | chpasswd
fi
usermod -aG sudo vm4a
echo 'vm4a ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/vm4a-nopasswd

echo "==> enable + start ssh"
systemctl enable --now ssh

echo "==> minimise disk image"
apt-get clean
rm -rf /var/lib/apt/lists/*
journalctl --vacuum-time=1s || true

echo "==> done"
