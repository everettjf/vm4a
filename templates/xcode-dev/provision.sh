#!/usr/bin/env bash
# macOS guest provisioning. Idempotent.
set -euo pipefail

# Xcode CLT
if ! xcode-select -p >/dev/null 2>&1; then
    echo "==> install Xcode Command Line Tools"
    # Headless trick: place a sentinel so softwareupdate offers the CLT package.
    touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
    PROD=$(softwareupdate -l 2>/dev/null | awk '/Command Line Tools/ {print $NF; exit}' || true)
    if [[ -n "${PROD:-}" ]]; then
        softwareupdate -i "${PROD}" --verbose
    fi
    rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
fi

# Homebrew
if ! command -v brew >/dev/null 2>&1; then
    echo "==> install Homebrew (non-interactive)"
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
export PATH="/opt/homebrew/bin:${PATH}"
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile

echo "==> brew install dev tools"
brew install git ripgrep jq

echo "==> done"
