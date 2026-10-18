#!/usr/bin/env bash
# Builds DockNotch and wraps the binary in a minimal .app bundle.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/DockNotch.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/DockNotch"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DockNotch"
cp Support/Info.plist "$APP/Contents/Info.plist"

# macOS ties the Accessibility grant to the code signature. An ad-hoc signature
# changes on every build, so prefer a real identity when one is installed.
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development/ { print $2; exit }')"
fi
codesign --force --sign "${IDENTITY:--}" "$APP" >/dev/null 2>&1 \
    || codesign --force --sign - "$APP"

echo "Built $APP (signed with ${IDENTITY:-ad-hoc identity})"
