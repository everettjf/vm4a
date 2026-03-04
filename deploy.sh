#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT_DIR"

usage() {
  cat <<USAGE
Usage:
  ./deploy.sh [options]

Options:
  --tap-repo <owner/repo>  Homebrew tap repository. Default: everettjf/homebrew-tap
  --repo <owner/name>      GitHub source repo. Auto-detected if omitted.
  --only-cli               Publish only CLI formula (skip app/cask build).
  --only-app               Publish only app cask.
  --skip-tests             Skip pre-release tests.
  -h, --help               Show this help.

What this script does:
  1) Bump patch version in VERSION
  2) Build artifacts (CLI and/or App DMG)
  3) Commit & push version bump
  4) Call scripts/release_homebrew_tap.sh with the bumped version
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

remove_dir_if_exists() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    python3 - "$dir" <<'PY'
import shutil
import sys
shutil.rmtree(sys.argv[1], ignore_errors=False)
PY
  fi
}

TAP_REPO="everettjf/homebrew-tap"
GH_REPO=""
ONLY_CLI=0
ONLY_APP=0
SKIP_TESTS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tap-repo)
      TAP_REPO="${2:-}"
      shift 2
      ;;
    --repo)
      GH_REPO="${2:-}"
      shift 2
      ;;
    --only-cli)
      ONLY_CLI=1
      shift
      ;;
    --only-app)
      ONLY_APP=1
      shift
      ;;
    --skip-tests)
      SKIP_TESTS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$ONLY_CLI" -eq 1 && "$ONLY_APP" -eq 1 ]]; then
  echo "--only-cli and --only-app cannot be used together." >&2
  exit 1
fi

PUBLISH_CLI=1
PUBLISH_APP=1
if [[ "$ONLY_CLI" -eq 1 ]]; then
  PUBLISH_APP=0
elif [[ "$ONLY_APP" -eq 1 ]]; then
  PUBLISH_CLI=0
fi

require_cmd git
require_cmd swift
require_cmd xcodebuild
require_cmd hdiutil
require_cmd mktemp
require_cmd python3

if [[ ! -x "$ROOT_DIR/scripts/release_homebrew_tap.sh" ]]; then
  echo "Missing release script: scripts/release_homebrew_tap.sh" >&2
  exit 1
fi

if [[ ! -x "$ROOT_DIR/inc_patch_version.sh" ]]; then
  echo "Missing version script: inc_patch_version.sh" >&2
  exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Worktree is dirty. Commit/stash before deploy." >&2
  exit 1
fi

if [[ "$SKIP_TESTS" -ne 1 ]]; then
  echo "Running tests..."
  swift test
fi

RELEASE_DONE=0
TMP_BUILD_DIR=""
rollback() {
  if [[ "$RELEASE_DONE" -eq 0 ]]; then
    git checkout -- VERSION >/dev/null 2>&1 || true
  fi
  if [[ -n "$TMP_BUILD_DIR" ]]; then
    remove_dir_if_exists "$TMP_BUILD_DIR"
  fi
}
trap rollback EXIT

echo "Bumping patch version..."
NO_GIT=1 "$ROOT_DIR/inc_patch_version.sh"
VERSION=$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")
TAG="v$VERSION"
echo "Release version: $VERSION"

if [[ "$PUBLISH_CLI" -eq 1 ]]; then
  echo "Building CLI release binary..."
  swift build -c release
fi

APP_DMG_PATH=""
if [[ "$PUBLISH_APP" -eq 1 ]]; then
  echo "Building macOS app (Release)..."
  TMP_BUILD_DIR=$(mktemp -d)
  xcodebuild \
    -project EasyVM/EasyVM.xcodeproj \
    -scheme EasyVM \
    -configuration Release \
    -sdk macosx \
    -derivedDataPath "$TMP_BUILD_DIR/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

  APP_PATH="$TMP_BUILD_DIR/DerivedData/Build/Products/Release/EasyVM.app"
  if [[ ! -d "$APP_PATH" ]]; then
    echo "Build output not found: $APP_PATH" >&2
    exit 1
  fi

  APP_DMG_PATH="$TMP_BUILD_DIR/EasyVM.dmg"
  echo "Packaging DMG: $APP_DMG_PATH"
  hdiutil create -volname "EasyVM" -srcfolder "$APP_PATH" -ov -format UDZO "$APP_DMG_PATH" >/dev/null
fi

echo "Committing version bump..."
git add VERSION
git commit -m "new version: $VERSION"
git push

echo "Publishing to GitHub release + Homebrew tap..."
RELEASE_ARGS=(--version "$VERSION" --tap-repo "$TAP_REPO")
if [[ -n "$GH_REPO" ]]; then
  RELEASE_ARGS+=(--repo "$GH_REPO")
fi
if [[ "$PUBLISH_CLI" -eq 1 && "$PUBLISH_APP" -eq 0 ]]; then
  RELEASE_ARGS+=(--only-cli)
elif [[ "$PUBLISH_CLI" -eq 0 && "$PUBLISH_APP" -eq 1 ]]; then
  RELEASE_ARGS+=(--only-app --app-dmg "$APP_DMG_PATH")
else
  RELEASE_ARGS+=(--app-dmg "$APP_DMG_PATH")
fi

"$ROOT_DIR/scripts/release_homebrew_tap.sh" "${RELEASE_ARGS[@]}"

RELEASE_DONE=1
trap - EXIT
if [[ -n "$TMP_BUILD_DIR" ]]; then
  remove_dir_if_exists "$TMP_BUILD_DIR"
fi

cat <<SUMMARY
Deploy finished.
  Version: $VERSION
  Tag:     $TAG
  CLI:     $([ "$PUBLISH_CLI" -eq 1 ] && echo "published" || echo "skipped")
  App:     $([ "$PUBLISH_APP" -eq 1 ] && echo "published" || echo "skipped")
SUMMARY
