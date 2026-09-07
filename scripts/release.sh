#!/bin/bash
#
# Build, Developer ID sign, notarize, staple, and package a shippable DMG.
#
#   scripts/release.sh 1.0.0
#   scripts/release.sh 1.0.0 --publish     # also create the GitHub release
#
# WHAT YOU NEED FIRST (one-time, and this script cannot do it for you):
#
#   1. An Apple Developer Program membership ($99/yr). Notarization is not
#      available without one; there is no free path.
#
#   2. A "Developer ID Application" certificate in your login keychain.
#      Xcode → Settings → Accounts → Manage Certificates → + → Developer ID
#      Application. Check it landed:
#          security find-identity -v -p codesigning
#
#   3. A stored notarytool credential profile, so no secret is ever typed on
#      a command line or lands in this repo. Run this yourself, once:
#          xcrun notarytool store-credentials diskbuddy-notary \
#              --apple-id you@example.com \
#              --team-id ABCDE12345 \
#              --password <app-specific-password>
#      The app-specific password comes from appleid.apple.com → Sign-In and
#      Security → App-Specific Passwords. It is NOT your Apple ID password.
#
# Then point this script at them:
#
#   export SIGN_ID="Developer ID Application: Your Name (ABCDE12345)"
#   export NOTARY_PROFILE=diskbuddy-notary
#   ./scripts/release.sh 1.0.0
#
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: scripts/release.sh <version> [--publish]" >&2
    exit 2
fi
PUBLISH="${2:-}"

APP_NAME="Disk Buddy Checker.app"
APP="$DIR/$APP_NAME"
OUT="$DIR/build/release"
DMG="$OUT/DiskVisualizer-$VERSION.dmg"
ZIP="$OUT/DiskVisualizer-$VERSION.zip"

# --- Preflight ------------------------------------------------------------
# Fail here, loudly, rather than half way through a five-minute notarization.

: "${SIGN_ID:?SIGN_ID is not set. See the header of this script — it needs a Developer ID Application identity, and ad-hoc signatures can never be notarized.}"
: "${NOTARY_PROFILE:?NOTARY_PROFILE is not set. See the header — run 'xcrun notarytool store-credentials' first.}"

if ! security find-identity -v -p codesigning | grep -qF "$SIGN_ID"; then
    echo "error: no codesigning identity matching:" >&2
    echo "         $SIGN_ID" >&2
    echo "       available identities:" >&2
    security find-identity -v -p codesigning | sed 's/^/         /' >&2
    exit 1
fi

echo "==> Releasing $VERSION as $SIGN_ID"
mkdir -p "$OUT"

# --- Build + sign ---------------------------------------------------------

SIGN_ID="$SIGN_ID" "$DIR/scripts/bundle-app.sh"

# Stamp the version into the bundle so About and Finder agree with the tag.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
    "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" \
    "$APP/Contents/Info.plist"

# Editing Info.plist invalidates the signature, so re-sign after stamping.
codesign --force --sign "$SIGN_ID" \
    --identifier com.diskbuddy.checker \
    --options runtime --timestamp "$APP"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

# --- Notarize -------------------------------------------------------------
# Apple wants an archive, not a bundle. The zip is only a transport; the DMG
# built afterwards is what people actually download.

echo "==> Submitting to Apple (this usually takes 1-5 minutes)..."
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

xcrun notarytool submit "$ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

# Staple the ticket into the bundle so it validates offline, on a machine
# that has never talked to Apple about this build.
echo "==> Stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# The real test: what Gatekeeper says about a freshly downloaded copy.
echo "==> Gatekeeper assessment"
spctl --assess --type execute --verbose=4 "$APP"

# --- Package --------------------------------------------------------------

echo "==> Building DMG"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"     # the familiar drag-to-install
hdiutil create -volname "Disk Visualizer" \
    -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null
rm -rf "$STAGE"

# The DMG needs its own signature and ticket — the app's doesn't cover it.
codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

# Rebuild the zip from the now-stapled app.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "==> Done"
ls -lh "$DMG" "$ZIP" | sed 's/^/    /'
shasum -a 256 "$DMG" "$ZIP" | sed 's/^/    /'

# --- Ship -----------------------------------------------------------------

if [ "$PUBLISH" = "--publish" ]; then
    echo
    echo "==> Publishing GitHub release v$VERSION"
    gh release create "v$VERSION" "$DMG" "$ZIP" \
        --title "Disk Visualizer $VERSION" \
        --notes "Notarized by Apple and stapled — no Gatekeeper warning, no \`xattr\` dance.

**Install:** open the DMG and drag the app to Applications.

Then grant **Full Disk Access** (System Settings → Privacy & Security → Full Disk Access) so the scan can see your whole disk. Without it macOS hides parts of the filesystem and your totals come out too small — the app tells you when this is the case rather than under-reporting quietly.

Requires macOS 14 or later."
    echo "==> https://github.com/aryacooks/Disk-Visualizer/releases/tag/v$VERSION"
else
    echo
    echo "    Not published. Re-run with --publish to create the GitHub release,"
    echo "    or upload $DMG by hand."
fi
