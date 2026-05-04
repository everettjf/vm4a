#!/usr/bin/env bash
# Build and push ghcr.io/everettjf/vm4a-templates/ubuntu-base:24.04
#
# Requires:
#   - Apple Silicon Mac with vm4a installed
#   - GHCR token in VM4A_REGISTRY_USER / VM4A_REGISTRY_PASSWORD
set -euo pipefail

NAME=ubuntu-base
TAG_BASE="ghcr.io/everettjf/vm4a-templates/${NAME}"
DATE_TAG="24.04-$(date -u +%Y%m%d)"

CACHE_DIR="${HOME}/.cache/vm4a-templates"
STORAGE="${VM4A_TEMPLATE_STORAGE:-${CACHE_DIR}/storage}"
ISO_URL="https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04.2-live-server-arm64.iso"
ISO_PATH="${CACHE_DIR}/ubuntu-24.04-arm64.iso"
SNAPSHOT="${STORAGE}/${NAME}/clean.vzstate"

mkdir -p "${CACHE_DIR}" "${STORAGE}"

if [[ ! -f "${ISO_PATH}" ]]; then
    echo "==> downloading ISO"
    curl -L --progress-bar -o "${ISO_PATH}" "${ISO_URL}"
fi

# Wipe any previous attempt
rm -rf "${STORAGE:?}/${NAME}"

echo "==> spawning fresh VM (this triggers an interactive subiquity install)"
echo "    NOTE: subiquity expects user input. For a hands-off build you must"
echo "    pre-bake an autoinstall.yaml ISO. See templates/ubuntu-base/autoinstall/"
echo "    for the cloud-init seed used by CI."

vm4a spawn "${NAME}" \
    --image "${ISO_PATH}" \
    --storage "${STORAGE}" \
    --cpu 4 --memory-gb 4 --disk-gb 20 \
    --save-on-stop "${SNAPSHOT}" \
    --wait-ssh \
    --wait-timeout 1800 \
    --output json

echo "==> provisioning"
vm4a cp "${STORAGE}/${NAME}" ./provision.sh :/tmp/provision.sh
vm4a exec "${STORAGE}/${NAME}" --timeout 600 -- bash -lc 'sudo bash /tmp/provision.sh'

echo "==> stopping (will save snapshot to ${SNAPSHOT})"
vm4a stop "${STORAGE}/${NAME}"

echo "==> pushing ${TAG_BASE}:${DATE_TAG}"
vm4a push "${STORAGE}/${NAME}" "${TAG_BASE}:${DATE_TAG}"

echo "==> tagging :24.04 and :latest"
vm4a push "${STORAGE}/${NAME}" "${TAG_BASE}:24.04"
vm4a push "${STORAGE}/${NAME}" "${TAG_BASE}:latest"

echo "==> done"
