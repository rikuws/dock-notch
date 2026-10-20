#!/usr/bin/env bash
# Builds a signed, notarized release of Dock Notch and everything its GitHub release needs:
#
#   dist/DockNotch.dmg              for people downloading it
#   dist/DockNotch-<version>.zip    for Sparkle to update existing copies
#   dist/appcast.xml                the feed every copy checks, pointing at that zip
#   dist/notes.md                   this version's section of CHANGELOG.md
#   dist/release-notes.md           the same, plus how each kind of build gets it
#
#   scripts/release.sh 0.2.0
#
# Notarization uses an App Store Connect API key (NOTARY_KEY_PATH, NOTARY_KEY_ID and
# NOTARY_ISSUER) or a notarytool keychain profile (NOTARY_PROFILE, by default the docknotch
# one scripts/setup-release-secrets.sh saves). SKIP_NOTARIZE=1 skips it for a dry run. The update is signed with the Sparkle key in SPARKLE_KEY_FILE, or the
# one in your keychain. See RELEASING.md.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
VERSION="${VERSION#v}"
REPO="${GITHUB_REPOSITORY:-rikuws/dock-notch}"
APP="build/DockNotch.app"
DIST="dist"
ZIP="$DIST/DockNotch-$VERSION.zip"
DMG="$DIST/DockNotch.dmg"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"

NOTES="$(awk -v version="$VERSION" '
    /^## / { if (found) exit; found = ($2 == version); next }
    found && (started || NF) { started = 1; print }' CHANGELOG.md)"
if [[ -z "${NOTES//[[:space:]]/}" ]]; then
    echo "CHANGELOG.md has no notes under \"## $VERSION\"." >&2
    exit 1
fi

notarize() {
    if [[ -n "${SKIP_NOTARIZE:-}" ]]; then
        echo "Skipping notarization of $1"
        return
    fi
    local auth
    if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
        auth=(--key "$NOTARY_KEY_PATH" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER:?}")
    else
        # scripts/setup-release-secrets.sh saves this one.
        auth=(--keychain-profile "${NOTARY_PROFILE:-docknotch}")
    fi

    echo "Notarizing $1…"
    local result="$DIST/notary.json"
    xcrun notarytool submit "$1" "${auth[@]}" --wait --output-format json >"$result"
    local status id
    status="$(plutil -extract status raw "$result")"
    id="$(plutil -extract id raw "$result")"
    rm "$result"
    if [[ "$status" != Accepted ]]; then
        echo "Notarization of $1 ended $status. Apple's log:" >&2
        xcrun notarytool log "$id" "${auth[@]}" >&2 || true
        exit 1
    fi
}

staple() {
    [[ -n "${SKIP_NOTARIZE:-}" ]] || xcrun stapler staple "$1"
}

# By hash, so two certificates with the same name don't make codesign refuse.
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '
    $2 ~ /^Developer ID Application/ { split($1, f, " "); print f[2]; exit }')}"
export SIGN_IDENTITY
CHANNEL=release VERSION="$VERSION" scripts/bundle.sh release

rm -rf "$DIST"
mkdir -p "$DIST"

# The app first, stapled so it opens without a trip to Apple's servers.
ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
notarize "$DIST/notarize.zip"
rm "$DIST/notarize.zip"
staple "$APP"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# Then the disk image: the app beside a link to Applications.
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/DockNotch.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Dock Notch" -srcfolder "$STAGE" -format ULFO -ov "$DMG"
rm -rf "$STAGE"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
notarize "$DMG"
staple "$DMG"

# Sparkle checks this signature against SUPublicEDKey before installing anything.
if [[ -n "${SPARKLE_KEY_FILE:-}" ]]; then
    SIGNATURE="$("$SPARKLE_BIN/sign_update" --ed-key-file "$SPARKLE_KEY_FILE" "$ZIP")"
else
    SIGNATURE="$("$SPARKLE_BIN/sign_update" "$ZIP")"
fi

printf '%s\n' "$NOTES" >"$DIST/notes.md"

# The GitHub release also says how each kind of build gets this version.
PREVIOUS="$(git describe --tags --abbrev=0 --match 'v[0-9]*' "v$VERSION^" 2>/dev/null || true)"
{
    printf '%s\n\n---\n\n' "$NOTES"
    echo "**Download** DockNotch.dmg below. Installed copies update themselves."
    echo
    echo "**Built from source, with or without your own changes?** Right-click the strip and"
    echo "choose Check for Updates, or run \`make update\` in your checkout. See [CUSTOMIZING.md](https://github.com/$REPO/blob/v$VERSION/CUSTOMIZING.md)."
    if [[ -n "$PREVIOUS" ]]; then
        echo
        echo "**Built your own from PROMPT.md?** Give your agent [what changed in the spec](https://github.com/$REPO/compare/$PREVIOUS...v$VERSION) with [prompts/port-a-release.md](https://github.com/$REPO/blob/v$VERSION/prompts/port-a-release.md)."
    fi
} >"$DIST/release-notes.md"

cat >"$DIST/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Dock Notch</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Dock Notch $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$(plutil -extract LSMinimumSystemVersion raw Support/Info.plist).0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases</sparkle:fullReleaseNotesLink>
      <description sparkle:format="markdown"><![CDATA[${NOTES//]]>/]]]]><![CDATA[>}]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/$(basename "$ZIP")" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML

echo "Release $VERSION is ready in $DIST/:"
ls -l "$DIST"
