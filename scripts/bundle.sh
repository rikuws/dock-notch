#!/usr/bin/env bash
# Builds DockNotch and wraps it in an app bundle with Sparkle embedded.
#
#   scripts/bundle.sh [release|debug]
#
# CHANNEL=source (the default) stamps the bundle with the checkout it came from, so the
# app can update itself by rebuilding from a newer release's source with your changes
# on top (see CUSTOMIZING.md). CHANNEL=release makes the universal build that's
# distributed, signed with Developer ID and the hardened runtime, which updates itself
# with Sparkle (see RELEASING.md).
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
CHANNEL="${CHANNEL:-source}"
APP="build/DockNotch.app"
PLIST="$APP/Contents/Info.plist"

# The release this checkout is built on, like v0.2.0, which is also the app's version.
BASE_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
VERSION="${VERSION:-${BASE_TAG#v}}"
VERSION="${VERSION:-$(plutil -extract CFBundleShortVersionString raw Support/Info.plist)}"

if [[ "$CHANNEL" == release ]]; then
    ARCHS=(--arch arm64 --arch x86_64)
else
    ARCHS=()
fi
swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"}
PRODUCTS="$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$PRODUCTS/DockNotch" "$APP/Contents/MacOS/DockNotch"
# ditto keeps the framework's symlinks, which its signature depends on.
ditto "$PRODUCTS/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# Sparkle only needs its XPC services in sandboxed apps.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
cp Support/Info.plist "$PLIST"

plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -replace CFBundleVersion -string "$VERSION" "$PLIST"
plutil -replace DNChannel -string "$CHANNEL" "$PLIST"

if [[ "$CHANNEL" == source ]]; then
    REVISION="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    [[ -z "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]] || REVISION+="-dirty"
    CHANGES=0
    [[ -z "$BASE_TAG" ]] || CHANGES="$(git rev-list --count "$BASE_TAG..HEAD")"

    # Follow the repository this checkout came from: the `upstream` remote when there is
    # one (a fork), otherwise `origin`.
    REMOTE_URL="$(git remote get-url upstream 2>/dev/null || git remote get-url origin 2>/dev/null || true)"
    UPSTREAM="$(sed -E 's#^(git@github\.com:|ssh://git@github\.com/|https://github\.com/)##; s#\.git$##' <<<"$REMOTE_URL")"
    [[ "$UPSTREAM" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || UPSTREAM="rikuws/dock-notch"

    plutil -replace DNSourceDirectory -string "$PWD" "$PLIST"
    plutil -replace DNSourceRevision -string "$REVISION" "$PLIST"
    plutil -replace DNSourceChanges -integer "$CHANGES" "$PLIST"
    plutil -replace DNUpstreamRepository -string "$UPSTREAM" "$PLIST"
fi

# The SHA-1 of the first signing identity whose name starts with $1. The hash keeps
# codesign from refusing when two certificates share a name.
find_identity() {
    security find-identity -v -p codesigning 2>/dev/null | awk -v kind="^$1" -F'"' '
        $2 ~ kind { split($1, f, " "); print f[2]; exit }'
}

if [[ "$CHANNEL" == release ]]; then
    IDENTITY="${SIGN_IDENTITY:-$(find_identity "Developer ID Application")}"
    FLAGS=(--options runtime --timestamp)
else
    # macOS ties the Accessibility grant to the code signature. An ad-hoc signature
    # changes on every build, so prefer a real identity when one is installed.
    IDENTITY="${SIGN_IDENTITY:-$(find_identity "Apple Development")}"
fi
NAME="$(security find-identity -v -p codesigning 2>/dev/null | awk -v id="$IDENTITY" -F'"' 'id != "" && index($1, id) { print $2; exit }')"
NAME="${NAME:-$IDENTITY}"

# Inside out, as Sparkle documents, and never --deep.
sign_all() {
    local identity="$1"
    shift
    local sparkle="$APP/Contents/Frameworks/Sparkle.framework"
    for code in "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle" "$APP"; do
        codesign --force --sign "$identity" "$@" "$code" || return 1
    done
}

if [[ "$CHANNEL" == release ]]; then
    if [[ -z "$IDENTITY" ]]; then
        echo "No Developer ID Application identity in the keychain. Set SIGN_IDENTITY." >&2
        exit 1
    fi
    sign_all "$IDENTITY" "${FLAGS[@]}"
    codesign --verify --strict "$APP"
elif [[ -z "$IDENTITY" ]] || ! sign_all "$IDENTITY" 2>/dev/null; then
    NAME="ad-hoc identity"
    sign_all - 2>/dev/null
fi

echo "Built $APP $VERSION ($CHANNEL, signed with $NAME)"
