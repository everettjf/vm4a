#!/usr/bin/env bash
#
# bench.sh — reproducible latency harness for VM4A's hot paths.
#
# Measures, on the machine it runs on (must be an Apple Silicon Mac with a
# signed `vm4a` on PATH):
#
#   1. fork           — APFS clonefile of a stopped golden bundle
#   2. boot-to-SSH    — fork --auto-start --wait-ssh (cold boot to usable shell)
#   3. pool acquire   — hand-out latency from a warm pool (if --pool given)
#
# It does NOT ship any numbers in the repo. Run it locally and paste the
# Markdown table it prints into README.md under "Benchmarks".
#
# Usage:
#   scripts/bench.sh --base /tmp/vm4a/golden [--iters 5] [--storage /tmp/vm4a]
#                    [--snapshot /tmp/vm4a/golden/clean.vzstate] [--pool mypool]
#
#   --base       Path to an existing, provisioned, *stopped* golden bundle.
#   --iters      Repeat count per measurement (default 5).
#   --storage    Where to place throwaway forks (default: dirname of --base).
#   --snapshot   .vzstate to restore on boot-to-SSH (optional; faster boots).
#   --pool       Name of a pool already being served (`vm4a pool serve`), to
#                measure `vm4a pool acquire` latency. Optional.
#
set -euo pipefail

BASE=""
ITERS=5
STORAGE=""
SNAPSHOT=""
POOL=""

die() { echo "bench: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)     BASE="${2:-}"; shift 2 ;;
    --iters)    ITERS="${2:-}"; shift 2 ;;
    --storage)  STORAGE="${2:-}"; shift 2 ;;
    --snapshot) SNAPSHOT="${2:-}"; shift 2 ;;
    --pool)     POOL="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v vm4a >/dev/null 2>&1 || die "vm4a not found on PATH"
[[ -n "$BASE" ]] || die "--base <golden-bundle> is required"
[[ -d "$BASE" ]] || die "--base path does not exist: $BASE"
[[ "$ITERS" =~ ^[0-9]+$ && "$ITERS" -ge 1 ]] || die "--iters must be a positive integer"
[[ -n "$STORAGE" ]] || STORAGE="$(dirname "$BASE")"

# Portable millisecond clock. macOS `date` has no %N, so use python3 (always
# present on macOS) for a monotonic-ish wall clock in milliseconds.
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

# Print: min / median / max over a whitespace-separated list of integers.
stats() {
  python3 - "$@" <<'PY'
import sys
xs = sorted(int(x) for x in sys.argv[1:])
if not xs:
    print("- | - | -"); raise SystemExit
n = len(xs)
mid = xs[n//2] if n % 2 else (xs[n//2 - 1] + xs[n//2]) / 2
print(f"{xs[0]} | {mid:g} | {xs[-1]}")
PY
}

cleanup_paths=()
cleanup() {
  for p in "${cleanup_paths[@]:-}"; do
    [[ -n "$p" && -d "$p" ]] || continue
    vm4a stop "$p" >/dev/null 2>&1 || true
    rm -rf "$p"
  done
}
trap cleanup EXIT

echo "bench: vm4a $(vm4a --version 2>/dev/null || echo '?')" >&2
echo "bench: base=$BASE iters=$ITERS storage=$STORAGE" >&2

fork_samples=()
boot_samples=()
acquire_samples=()

for i in $(seq 1 "$ITERS"); do
  echo "bench: iter $i/$ITERS" >&2

  # 1. fork (clone only, no start)
  dst="$STORAGE/bench-fork-$$-$i"
  cleanup_paths+=("$dst")
  t0=$(now_ms)
  vm4a fork "$BASE" "$dst" >/dev/null 2>&1
  t1=$(now_ms)
  fork_samples+=($((t1 - t0)))
  rm -rf "$dst"

  # 2. boot-to-SSH (fork + start + wait for ssh)
  bdst="$STORAGE/bench-boot-$$-$i"
  cleanup_paths+=("$bdst")
  snap_args=()
  [[ -n "$SNAPSHOT" ]] && snap_args=(--from-snapshot "$SNAPSHOT" --keep-identity)
  t0=$(now_ms)
  vm4a fork "$BASE" "$bdst" --auto-start --wait-ssh --wait-timeout 180 \
       "${snap_args[@]}" >/dev/null 2>&1
  t1=$(now_ms)
  boot_samples+=($((t1 - t0)))
  vm4a stop "$bdst" >/dev/null 2>&1 || true
  rm -rf "$bdst"

  # 3. pool acquire (optional)
  if [[ -n "$POOL" ]]; then
    t0=$(now_ms)
    leased=$(vm4a pool acquire "$POOL" --output json 2>/dev/null | python3 -c \
             'import sys,json; print(json.load(sys.stdin).get("path",""))' || true)
    t1=$(now_ms)
    acquire_samples+=($((t1 - t0)))
    [[ -n "$leased" ]] && { vm4a pool release "$leased" >/dev/null 2>&1 || true; }
  fi
done

echo ""
echo "## Benchmarks (this machine)"
echo ""
echo "| Operation | min (ms) | median (ms) | max (ms) |"
echo "|---|---|---|---|"
echo "| fork (APFS clone) | $(stats "${fork_samples[@]}") |"
echo "| boot-to-SSH | $(stats "${boot_samples[@]}") |"
if [[ -n "$POOL" ]]; then
  echo "| pool acquire | $(stats "${acquire_samples[@]}") |"
fi
echo ""
echo "_n=$ITERS, vm4a $(vm4a --version 2>/dev/null || echo '?'), $(uname -m), macOS $(sw_vers -productVersion 2>/dev/null || echo '?')_"
