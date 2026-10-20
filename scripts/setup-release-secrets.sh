#!/usr/bin/env bash
# Sets up everything the release workflow needs as GitHub Actions secrets, with as little
# typing as it can:
#
#   developer-id  Exports your Developer ID certificate and key from your keychain.
#   notary        Finds the App Store Connect API key you downloaded, checks it with
#                 Apple, and also saves it for releasing from this Mac.
#   sparkle       Copies the key that signs updates from your keychain, and helps you
#                 back it up.
#
#   scripts/setup-release-secrets.sh             # all three
#   scripts/setup-release-secrets.sh notary      # or just the ones named
#
# macOS asks you to allow each keychain export. Run it again when a certificate or key
# changes. See RELEASING.md.
set -euo pipefail

cd "$(dirname "$0")/.."

die() {
    echo "$*" >&2
    exit 1
}

[[ $# -gt 0 ]] || set -- developer-id notary sparkle
for part; do
    [[ "$part" == developer-id || "$part" == notary || "$part" == sparkle ]] ||
        die "usage: scripts/setup-release-secrets.sh [developer-id] [notary] [sparkle]"
done

REPO="${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

developer_id() {
    local hash name password
    read -r hash name < <(security find-identity -v -p codesigning | awk -F'"' '
        $2 ~ /^Developer ID Application/ { split($1, f, " "); print f[2], $2; exit }') || true
    [[ -n "${hash:-}" ]] || die "There's no Developer ID Application certificate in your keychain." \
        "Make one at https://developer.apple.com/account/resources/certificates/add"

    echo "Exporting $name. macOS asks for your login password to allow it."
    swiftc -O -suppress-warnings scripts/lib/export-identity.swift -o "$WORK/export-identity"
    password="$(openssl rand -base64 24)"
    P12_PASSWORD="$password" "$WORK/export-identity" "$hash" "$WORK/developer-id.p12"
    base64 -i "$WORK/developer-id.p12" | gh secret set DEVELOPER_ID_P12 --repo "$REPO"
    printf '%s' "$password" | gh secret set DEVELOPER_ID_P12_PASSWORD --repo "$REPO"
}

newest_api_key() {
    ls -t "$HOME"/Downloads/AuthKey_*.p8 2>/dev/null | head -n 1 || true
}

notary() {
    local key key_id issuer
    key="$(newest_api_key)"
    if [[ -z "$key" ]]; then
        echo "Notarizing needs an App Store Connect API key. Opening App Store Connect: under"
        echo "Team Keys, add a key with Developer access, then download it."
        open "https://appstoreconnect.apple.com/access/integrations/api"
        read -rp "Press Return once it's in your Downloads folder… "
        key="$(newest_api_key)"
    fi
    if [[ -z "$key" ]]; then
        read -rp "It isn't in Downloads. Where is the .p8 file? " key
        key="${key/#\~/$HOME}"
    fi
    [[ -f "$key" ]] || die "No file at $key"

    # Apple names the file after the key's ID.
    key_id="$(basename "$key" .p8)"
    key_id="${key_id#AuthKey_}"
    [[ "$key_id" =~ ^[A-Z0-9]{10}$ ]] || read -rp "Its Key ID: " key_id
    echo "Using $key, Key ID $key_id."

    # Storing a notarytool profile asks Apple whether the key works first, so a mistyped
    # Issuer ID shows up here rather than in the first release.
    while true; do
        read -rp "Issuer ID, shown above the list of keys: " issuer
        issuer="${issuer//[[:space:]]/}"
        xcrun notarytool store-credentials docknotch \
            --key "$key" --key-id "$key_id" --issuer "$issuer" && break
        echo "Apple didn't accept that. Check the Issuer ID and try again, or press Control-C."
    done
    gh secret set NOTARY_KEY --repo "$REPO" <"$key"
    gh secret set NOTARY_KEY_ID --repo "$REPO" --body "$key_id"
    gh secret set NOTARY_ISSUER --repo "$REPO" --body "$issuer"
    echo "GitHub and your keychain have the key now, so you can delete $key."
}

# Puts a file's text on the clipboard, marked so clipboard managers that follow
# nspasteboard.org keep it out of their history.
conceal_copy() {
    osascript -l JavaScript - "$1" >/dev/null <<'JS'
ObjC.import("AppKit")
function run(argv) {
    const text = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null)
    const pasteboard = $.NSPasteboard.generalPasteboard
    pasteboard.clearContents
    pasteboard.setStringForType(text, $.NSPasteboardTypeString)
    pasteboard.setStringForType("", "org.nspasteboard.ConcealedType")
}
JS
}

sparkle() {
    local bin=.build/artifacts/sparkle/Sparkle/bin answer
    [[ -x "$bin/generate_keys" ]] || swift package resolve
    [[ "$("$bin/generate_keys" -p)" == "$(plutil -extract SUPublicEDKey raw Support/Info.plist)" ]] ||
        die "The Sparkle key in your keychain doesn't match SUPublicEDKey in Support/Info.plist," \
            "so installed copies would reject updates signed with it."
    "$bin/generate_keys" -x "$WORK/sparkle.key"
    gh secret set SPARKLE_PRIVATE_KEY --repo "$REPO" <"$WORK/sparkle.key"

    # GitHub never shows a secret again, so this Mac's keychain has the only copy you can read.
    echo "Without this key, installed copies can't accept another update. Keep a copy somewhere"
    echo "safe, like your password manager."
    read -rp "Copy it to your clipboard to save there? [Y/n] " answer
    if [[ "$answer" != [nN]* ]]; then
        conceal_copy "$WORK/sparkle.key"
        read -rp "Save it as \"Dock Notch Sparkle key\", then press Return to clear the clipboard… "
        [[ "$(pbpaste)" != "$(<"$WORK/sparkle.key")" ]] || pbcopy </dev/null
    fi
}

echo "Setting release secrets on $REPO."
for part; do
    echo
    case "$part" in
        developer-id) echo "== Developer ID certificate"; developer_id ;;
        notary) echo "== Notarization"; notary ;;
        sparkle) echo "== Sparkle update key"; sparkle ;;
    esac
done

echo
gh secret list --repo "$REPO"
echo
echo "Done. Once the workflow is on GitHub, pushing a tag like v0.1.0 releases that version."
