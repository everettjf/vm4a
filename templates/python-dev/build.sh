#!/usr/bin/env bash
# Derive python-dev from ubuntu-base.
set -euo pipefail

NAME=python-dev
PARENT_REF="ghcr.io/everettjf/vm4a-templates/ubuntu-base:24.04"
TAG_BASE="ghcr.io/everettjf/vm4a-templates/${NAME}"
DATE_TAG="$(date -u +%Y%m%d)"

CACHE_DIR="${HOME}/.cache/vm4a-templates"
STORAGE="${VM4A_TEMPLATE_STORAGE:-${CACHE_DIR}/storage}"
SNAPSHOT="${STORAGE}/${NAME}/clean.vzstate"

mkdir -p "${STORAGE}"
rm -rf "${STORAGE:?}/${NAME}"

echo "==> spawning from ${PARENT_REF}"
vm4a spawn "${NAME}" \
    --from "${PARENT_REF}" \
    --storage "${STORAGE}" \
    --save-on-stop "${SNAPSHOT}" \
    --wait-ssh --wait-timeout 300 \
    --output json

echo "==> provisioning"
vm4a cp "${STORAGE}/${NAME}" ./provision.sh :/tmp/provision.sh
vm4a exec "${STORAGE}/${NAME}" --timeout 900 -- bash -lc 'sudo bash /tmp/provision.sh'

echo "==> stopping (snapshot: ${SNAPSHOT})"
vm4a stop "${STORAGE}/${NAME}"

echo "==> pushing"
vm4a push "${STORAGE}/${NAME}" "${TAG_BASE}:${DATE_TAG}"
vm4a push "${STORAGE}/${NAME}" "${TAG_BASE}:latest"
