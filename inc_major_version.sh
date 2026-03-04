#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")" && pwd)
VERSION_FILE="$ROOT_DIR/VERSION"

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "Missing VERSION file at $VERSION_FILE" >&2
  exit 1
fi

CURRENT_VERSION=$(tr -d '[:space:]' < "$VERSION_FILE")
if [[ ! "$CURRENT_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "Invalid VERSION format: $CURRENT_VERSION (expected x.y.z)" >&2
  exit 1
fi

MAJOR="${BASH_REMATCH[1]}"
NEW_VERSION="$((MAJOR + 1)).0.0"

echo "$NEW_VERSION" > "$VERSION_FILE"
echo "Bumping version: $CURRENT_VERSION -> $NEW_VERSION"

if [[ "${NO_GIT:-0}" == "1" ]]; then
  exit 0
fi

cd "$ROOT_DIR"
git add VERSION
git commit -m "new version: $NEW_VERSION"
git push
git tag "v$NEW_VERSION"
git push origin "v$NEW_VERSION"

echo "Done!"
