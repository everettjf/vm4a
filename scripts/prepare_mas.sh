#!/usr/bin/env bash
# prepare_mas.sh — Pre-flight checklist for submitting VM4A to the Mac App Store.
#
# Run from repo root:
#     ./scripts/prepare_mas.sh
#
# This script validates entitlements, Info.plist, and signing settings, and
# prints the remaining manual steps (App Store Connect record, screenshots,
# privacy disclosures). It does NOT upload or submit — that still happens in
# Xcode / Transporter because it needs your signing identity and 2FA session.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP_ENT="$ROOT/VM4A/VM4A/VM4A.entitlements"
CLI_ENT="$ROOT/Sources/VM4ACLI/VM4ACLI.entitlements"
INFO_PLIST="$ROOT/VM4A/VM4A/Info.plist"

status=0
warn() { printf "\033[33m! %s\033[0m\n" "$1"; status=1; }
ok()   { printf "\033[32m\xe2\x9c\x93 %s\033[0m\n" "$1"; }
section() { printf "\n\033[1m== %s ==\033[0m\n" "$1"; }

section "App entitlements"
if [[ -f "$APP_ENT" ]]; then
    if grep -q "com.apple.security.virtualization" "$APP_ENT"; then
        ok "virtualization entitlement present"
    else
        warn "missing com.apple.security.virtualization in $APP_ENT"
    fi
    if grep -q "com.apple.security.app-sandbox" "$APP_ENT"; then
        ok "app-sandbox entitlement present"
    else
        warn "app-sandbox entitlement missing — MAS requires sandboxing"
    fi
    if grep -q "com.apple.vm.networking" "$APP_ENT"; then
        warn "com.apple.vm.networking must NOT appear in App entitlements (App Store rejects). Move it to $CLI_ENT."
    else
        ok "vm.networking absent from App entitlements"
    fi
else
    warn "missing $APP_ENT"
fi

section "CLI entitlements"
if [[ -f "$CLI_ENT" ]]; then
    if grep -q "com.apple.vm.networking" "$CLI_ENT"; then
        ok "CLI has vm.networking entitlement (for bridged mode)"
    else
        warn "CLI missing vm.networking in $CLI_ENT (bridged mode will not work)"
    fi
else
    warn "missing $CLI_ENT"
fi

section "Info.plist"
if [[ -f "$INFO_PLIST" ]]; then
    if /usr/libexec/PlistBuddy -c "Print :LSApplicationCategoryType" "$INFO_PLIST" >/dev/null 2>&1; then
        cat_value=$(/usr/libexec/PlistBuddy -c "Print :LSApplicationCategoryType" "$INFO_PLIST")
        ok "LSApplicationCategoryType = $cat_value"
    else
        warn "Info.plist missing LSApplicationCategoryType (MAS requires a category)"
    fi
    if /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST" >/dev/null 2>&1; then
        ver=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
        ok "CFBundleShortVersionString = $ver"
    else
        warn "Info.plist missing CFBundleShortVersionString"
    fi
else
    warn "missing $INFO_PLIST"
fi

section "Manual steps still required"
cat <<'EOF'
  1. App Store Connect record:
       - Create app with bundle id matching Info.plist CFBundleIdentifier
       - Complete "App Privacy" disclosures (no tracking, no user data collected)
       - Fill in support URL and marketing URL
  2. Screenshots: 1280x800 or 2560x1600 (at least 1 for macOS)
  3. Provisioning profile: Mac App Distribution + Mac Installer Distribution
  4. Xcode: Product > Archive > Distribute App > App Store Connect
     OR: xcrun altool --upload-app -f VM4A.pkg -u <apple-id> ...
  5. Export compliance: declare HTTPS-only (no proprietary crypto)
  6. TestFlight for macOS (optional) before wider release.
EOF

if [[ $status -eq 0 ]]; then
    printf "\n\033[32mAll automated checks passed.\033[0m Ready for manual MAS steps above.\n"
else
    printf "\n\033[33mSome issues detected. Address warnings above before submitting.\033[0m\n"
    exit 1
fi
