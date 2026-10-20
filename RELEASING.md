# Releasing Dock Notch

Pushing a tag like `v0.2.0` runs [.github/workflows/release.yml](.github/workflows/release.yml).
It builds a universal app, signs it with Developer ID and the hardened runtime, notarizes
and staples it, and publishes a GitHub release with:

- `DockNotch.dmg`, for people downloading it. The README links to
  `releases/latest/download/DockNotch.dmg`, which is always the newest.
- `DockNotch-<version>.zip`, which Sparkle installs.
- `appcast.xml`, the feed every installed copy reads from
  `releases/latest/download/appcast.xml` (`SUFeedURL` in `Support/Info.plist`). It lists
  this release only, with its notes and the zip's EdDSA signature.

Builds from source follow the same releases through the GitHub API's latest release and
its tag (see [CUSTOMIZING.md](CUSTOMIZING.md)).

## Cutting a release

1. Add a `## <version>` section to [CHANGELOG.md](CHANGELOG.md). It becomes the notes in
   the update window and on GitHub, so describe changes the way someone using the app
   would see them.
2. Update [PROMPT.md](PROMPT.md) for anything that changed how the app behaves or looks,
   and the version it says it describes. Its difference between releases is how people who
   built their own from it catch up.
3. Commit, then tag and push:

   ```bash
   git tag v0.2.0
   git push origin main v0.2.0
   ```

Installed copies check once a day, and builds from source every six hours. Don't delete a
release's `appcast.xml`, and keep the newest release marked latest: that's what every copy
reads.

## One-time setup

The workflow needs six repository secrets. One script sets them all:

```bash
scripts/setup-release-secrets.sh
```

The only thing it can't do for you is make the notarization key. When there's no
`AuthKey_*.p8` in your Downloads folder, it opens App Store Connect's API keys page: under
Team Keys, add a key with Developer access and download it (Apple lets you download it only
once). Then the script needs only the Issuer ID shown above the list of keys. Everything
else comes from your keychain, and macOS asks for your login password to allow each export.

| Secret | Where the script gets it |
| --- | --- |
| `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD` | Your Developer ID Application certificate and its key, exported from your keychain as a .p12 with a random password. |
| `NOTARY_KEY`, `NOTARY_KEY_ID`, `NOTARY_ISSUER` | The newest `AuthKey_<Key ID>.p8` in Downloads, and the Issuer ID you paste. It checks them with Apple first, and also saves them as the `docknotch` notarytool profile for releasing from your Mac. |
| `SPARKLE_PRIVATE_KEY` | The key that signs updates, from your keychain, after checking it matches `SUPublicEDKey`. |

To redo one part, name it: `scripts/setup-release-secrets.sh developer-id`, `notary` or
`sparkle`.

### The Sparkle key

Every copy of Dock Notch checks updates against the public key in `SUPublicEDKey`. Its
private half is in your login keychain (account `ed25519`), made with
`.build/artifacts/sparkle/Sparkle/bin/generate_keys`. **Back it up**: GitHub never shows a
secret again, so without a copy, losing this Mac means you can't ship an update that
installed copies accept, and they'd have to download a new version by hand. The setup
script offers to put the key on your clipboard to paste into your password manager, then
clears it.

### Certificates expire

Developer ID certificates last a limited time; check yours in Keychain Access. Releases
already published keep working, because their signatures are timestamped. Before it
expires, make a new one at developer.apple.com and run
`scripts/setup-release-secrets.sh developer-id`. Updates keep installing as long as the new
certificate is from the same team.

## Releasing from your Mac

The same script the workflow uses runs locally, with the notarytool profile the setup
script saved. Build everything into `dist/` and publish it:

```bash
make release VERSION=0.2.0
gh release create v0.2.0 dist/DockNotch.dmg dist/DockNotch-0.2.0.zip dist/appcast.xml \
  --title "Dock Notch 0.2.0" --notes-file dist/release-notes.md --latest
```

`SKIP_NOTARIZE=1` makes a dry run without Apple. Signing the update reads the Sparkle key
from your keychain, and macOS may ask you to allow that.
