#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

usage() {
  cat <<USAGE
Usage:
  scripts/release_homebrew_tap.sh --version <x.y.z> [options]

Options:
  --version <x.y.z>        Release version (required). Accepts x.y.z or vx.y.z.
  --tap-repo <owner/repo>  Homebrew tap repository. Default: everettjf/homebrew-tap
  --tap-dir <path>         Local temp dir for cloned tap repo. Default: /tmp/homebrew-vm4a-tap
  --repo <owner/name>      GitHub source repo. Auto-detected from gh if omitted.
  --app-dmg <path>         Path to VM4A.dmg for cask release (required when publishing app cask).
  --only-cli               Publish only CLI formula.
  --only-app               Publish only app cask.
  --skip-tag               Do not create/push git tag when missing.
  -h, --help               Show this help.

Environment variables:
  TAP_REPO                 Same as --tap-repo
  TAP_DIR                  Same as --tap-dir
  GH_REPO                  Same as --repo
  APP_DMG_PATH             Same as --app-dmg

Examples:
  # Publish both CLI + app cask
  scripts/release_homebrew_tap.sh \
    --version 0.2.0 \
    --tap-repo everettjf/homebrew-tap \
    --app-dmg /path/to/VM4A.dmg

  # Publish only CLI formula
  scripts/release_homebrew_tap.sh --version 0.2.0 --only-cli
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

VERSION=""
TAP_REPO="${TAP_REPO:-everettjf/homebrew-tap}"
TAP_DIR="${TAP_DIR:-/tmp/homebrew-vm4a-tap}"
GH_REPO="${GH_REPO:-}"
APP_DMG_PATH="${APP_DMG_PATH:-}"
PUBLISH_CLI=1
PUBLISH_APP=1
SKIP_TAG=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --tap-repo)
      TAP_REPO="${2:-}"
      shift 2
      ;;
    --tap-dir)
      TAP_DIR="${2:-}"
      shift 2
      ;;
    --repo)
      GH_REPO="${2:-}"
      shift 2
      ;;
    --app-dmg)
      APP_DMG_PATH="${2:-}"
      shift 2
      ;;
    --only-cli)
      PUBLISH_CLI=1
      PUBLISH_APP=0
      shift
      ;;
    --only-app)
      PUBLISH_CLI=0
      PUBLISH_APP=1
      shift
      ;;
    --skip-tag)
      SKIP_TAG=1
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

if [[ -z "$VERSION" ]]; then
  echo "--version is required" >&2
  usage
  exit 1
fi

VERSION="${VERSION#v}"
TAG="v$VERSION"

if [[ "$PUBLISH_CLI" -eq 0 && "$PUBLISH_APP" -eq 0 ]]; then
  echo "Nothing to publish. Use default, --only-cli, or --only-app." >&2
  exit 1
fi

if [[ "$PUBLISH_APP" -eq 1 ]]; then
  if [[ -z "$APP_DMG_PATH" ]]; then
    echo "--app-dmg is required when publishing app cask." >&2
    exit 1
  fi
  if [[ ! -f "$APP_DMG_PATH" ]]; then
    echo "App DMG not found: $APP_DMG_PATH" >&2
    exit 1
  fi
fi

require_cmd git
require_cmd gh
require_cmd shasum
require_cmd mktemp
require_cmd python3

if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI is not authenticated. Run: gh auth login" >&2
  exit 1
fi

if [[ -z "$GH_REPO" ]]; then
  GH_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
fi

if [[ -z "$GH_REPO" ]]; then
  echo "Unable to resolve GitHub repo. Set --repo or GH_REPO." >&2
  exit 1
fi

if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  if [[ "$SKIP_TAG" -eq 1 ]]; then
    echo "Tag does not exist locally and --skip-tag is set: $TAG" >&2
    exit 1
  fi

  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Worktree is dirty. Commit/stash before creating release tag." >&2
    exit 1
  fi

  echo "Creating and pushing tag $TAG ..."
  git tag "$TAG"
  git push origin "$TAG"
fi

TMP_DIR=$(mktemp -d)
cleanup() {
  remove_dir_if_exists "$TMP_DIR"
}
trap cleanup EXIT

RELEASE_ASSETS=()
CLI_ASSET_NAME="vm4a-cli-${TAG}.tar.gz"
CLI_SHA=""
APP_SHA=""

if [[ "$PUBLISH_CLI" -eq 1 ]]; then
  CLI_ARCHIVE_PATH="$TMP_DIR/$CLI_ASSET_NAME"
  git archive --format=tar.gz --output "$CLI_ARCHIVE_PATH" "$TAG"
  CLI_SHA=$(shasum -a 256 "$CLI_ARCHIVE_PATH" | awk '{print $1}')
  RELEASE_ASSETS+=("$CLI_ARCHIVE_PATH")
fi

if [[ "$PUBLISH_APP" -eq 1 ]]; then
  APP_RELEASE_PATH="$TMP_DIR/VM4A.dmg"
  cp -f "$APP_DMG_PATH" "$APP_RELEASE_PATH"
  APP_SHA=$(shasum -a 256 "$APP_RELEASE_PATH" | awk '{print $1}')
  RELEASE_ASSETS+=("$APP_RELEASE_PATH")
fi

if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
  echo "Uploading assets to existing release $TAG ..."
  gh release upload "$TAG" --repo "$GH_REPO" "${RELEASE_ASSETS[@]}" --clobber
else
  echo "Creating release $TAG ..."
  gh release create "$TAG" --repo "$GH_REPO" "${RELEASE_ASSETS[@]}" -t "$TAG" -n "VM4A $TAG"
fi

FORMULA_URL="https://github.com/$GH_REPO/releases/download/$TAG/$CLI_ASSET_NAME"
CASK_URL="https://github.com/$GH_REPO/releases/download/$TAG/VM4A.dmg"

remove_dir_if_exists "$TAP_DIR"
mkdir -p "$(dirname "$TAP_DIR")"
echo "Cloning tap repo $TAP_REPO ..."
git clone "https://github.com/$TAP_REPO.git" "$TAP_DIR"

FORMULA_PATH="$TAP_DIR/Formula/vm4a.rb"
CASK_PATH="$TAP_DIR/Casks/vm4a.rb"
mkdir -p "$TAP_DIR/Formula" "$TAP_DIR/Casks"

if [[ "$PUBLISH_CLI" -eq 1 ]]; then
  cat > "$FORMULA_PATH" <<FORMULA
class Easyvm < Formula
  desc "Lightweight VM CLI for Apple Virtualization framework"
  homepage "https://github.com/$GH_REPO"
  url "$FORMULA_URL"
  sha256 "$CLI_SHA"
  license "MIT"

  depends_on :macos

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/vm4a"
  end

  test do
    assert_match "VM4A standalone CLI", shell_output("#{bin}/vm4a --help")
  end

  def caveats
    <<~EOS
      vm4a uses Apple's Virtualization framework.
      Before running VMs, sign the binary with virtualization entitlement:

        codesign --force --sign - \\
          --entitlements VM4A.entitlements \\
          #{HOMEBREW_PREFIX}/bin/vm4a

      You can copy entitlement file from VM4A source repo:
        VM4A/VM4A/VM4A.entitlements
    EOS
  end
end
FORMULA
fi

if [[ "$PUBLISH_APP" -eq 1 ]]; then
  cat > "$CASK_PATH" <<CASK
cask "vm4a" do
  version "$VERSION"
  sha256 "$APP_SHA"

  url "$CASK_URL"
  name "VM4A"
  desc "Lightweight virtual machine app for macOS"
  homepage "https://github.com/$GH_REPO"

  depends_on macos: ">= :ventura"

  app "VM4A.app"
end
CASK
fi

cd "$TAP_DIR"
git add -A
if git diff --cached --quiet; then
  echo "No tap changes detected."
else
  COMMIT_MSG="release vm4a $TAG"
  if [[ "$PUBLISH_CLI" -eq 1 && "$PUBLISH_APP" -eq 0 ]]; then
    COMMIT_MSG="release vm4a CLI $TAG"
  elif [[ "$PUBLISH_CLI" -eq 0 && "$PUBLISH_APP" -eq 1 ]]; then
    COMMIT_MSG="release vm4a app $TAG"
  fi
  git commit -m "$COMMIT_MSG"
  git push
fi

cat <<SUMMARY
Done.
  Repo:        $GH_REPO
  Tag:         $TAG
  Tap repo:    $TAP_REPO
  CLI formula: $([ "$PUBLISH_CLI" -eq 1 ] && echo "updated" || echo "skipped")
  App cask:    $([ "$PUBLISH_APP" -eq 1 ] && echo "updated" || echo "skipped")
SUMMARY
