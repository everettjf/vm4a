#!/usr/bin/env bash
# Provision an already-installed macOS bundle into the xcode-dev template
# and push it to GHCR. We can't fully automate the macOS guest install
# yet — Apple's VZMacOSInstaller handles the OS install but the resulting
# VM still boots into Setup Assistant, which can't be scripted from
# outside the VM. So this script *takes* the path to a base bundle
# you've already created via the GUI app's "New macOS VM" flow, then
# automates everything from there.
#
# Required environment:
#   VM4A_REGISTRY_USER     GHCR username
#   VM4A_REGISTRY_PASSWORD GHCR PAT with write:packages
#   XCODE_DEV_BASE_BUNDLE  Path to the already-installed macOS bundle
#   XCODE_DEV_SSH_USER     SSH username inside the guest (created during Setup Assistant)
#
# Optional:
#   XCODE_DEV_SSH_KEY      SSH private key for the guest user (if not using agent)
#   XCODE_DEV_TAG          Override the date-based tag
set -euo pipefail

: "${XCODE_DEV_BASE_BUNDLE:?Set to the path of a fully-installed macOS bundle (use the GUI app: File → New macOS VM).}"
: "${XCODE_DEV_SSH_USER:?Set to the SSH username you created during the macOS install.}"
: "${VM4A_REGISTRY_USER:?Required for push.}"
: "${VM4A_REGISTRY_PASSWORD:?Required for push.}"

NAME=xcode-dev
TAG_BASE="ghcr.io/everettjf/vm4a-templates/${NAME}"
DATE_TAG="${XCODE_DEV_TAG:-$(date -u +%Y%m%d)}"
SNAPSHOT="${XCODE_DEV_BASE_BUNDLE}/clean.vzstate"

if [[ ! -f "${XCODE_DEV_BASE_BUNDLE}/config.json" ]]; then
    echo "error: ${XCODE_DEV_BASE_BUNDLE} doesn't look like a vm4a bundle (no config.json)." >&2
    exit 2
fi

CP_FLAGS=(--user "${XCODE_DEV_SSH_USER}")
EXEC_FLAGS=(--user "${XCODE_DEV_SSH_USER}")
if [[ -n "${XCODE_DEV_SSH_KEY:-}" ]]; then
    CP_FLAGS+=(--key "${XCODE_DEV_SSH_KEY}")
    EXEC_FLAGS+=(--key "${XCODE_DEV_SSH_KEY}")
fi

echo "==> starting base bundle (with --save-on-stop armed)"
vm4a run "${XCODE_DEV_BASE_BUNDLE}" --save-on-stop "${SNAPSHOT}" >/dev/null

echo "==> waiting for SSH"
for _ in $(seq 1 60); do
    if vm4a exec "${XCODE_DEV_BASE_BUNDLE}" "${EXEC_FLAGS[@]}" --timeout 5 -- echo ready >/dev/null 2>&1; then
        break
    fi
    sleep 5
done

echo "==> uploading provision.sh"
vm4a cp "${XCODE_DEV_BASE_BUNDLE}" "${CP_FLAGS[@]}" ./provision.sh ":/tmp/provision.sh"

echo "==> running provision.sh (this can take 10-20 minutes for Xcode CLT + brew install)"
vm4a exec "${XCODE_DEV_BASE_BUNDLE}" "${EXEC_FLAGS[@]}" --timeout 1800 -- \
    bash -lc 'sudo bash /tmp/provision.sh'

echo "==> stopping (snapshot will be saved at ${SNAPSHOT})"
vm4a stop "${XCODE_DEV_BASE_BUNDLE}"

echo "==> pushing ${TAG_BASE}:${DATE_TAG}"
vm4a push "${XCODE_DEV_BASE_BUNDLE}" "${TAG_BASE}:${DATE_TAG}"
vm4a push "${XCODE_DEV_BASE_BUNDLE}" "${TAG_BASE}:latest"

echo "==> done"
