#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"

# CONFIG is "release" (default, ships the app at the repo root) or "debug"
# (dev builds, staged under build/dev so they never overwrite the real bundle).
CONFIG="${CONFIG:-release}"

echo "==> Building DiskBuddyApp ($CONFIG)..."
swift build -c "$CONFIG" --product DiskBuddyApp

APP_NAME="Disk Buddy Checker.app"
if [ "$CONFIG" = "debug" ]; then
    APP_DIR="$DIR/build/dev/$APP_NAME"
else
    APP_DIR="$DIR/$APP_NAME"
fi
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> Packaging $APP_NAME..."
mkdir -p "$(dirname "$APP_DIR")"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

cp "$DIR/.build/$CONFIG/DiskBuddyApp" "$MACOS_DIR/DiskBuddyApp"
chmod +x "$MACOS_DIR/DiskBuddyApp"

# The icon is generated from code (scripts/make-icon.swift) rather than checked
# in as a binary, so it stays reviewable in diffs. Regenerated only when
# missing — rendering ten sizes costs a couple of seconds.
if [ ! -f "$DIR/build/AppIcon.icns" ]; then
    echo "==> Generating app icon..."
    swift "$DIR/scripts/make-icon.swift" > /dev/null
    iconutil -c icns "$DIR/build/AppIcon.iconset" -o "$DIR/build/AppIcon.icns"
fi
cp "$DIR/build/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

cat << 'EOF' > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>DiskBuddyApp</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.diskbuddy.checker</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Disk Buddy Checker</string>
    <key>CFBundleDisplayName</key>
    <string>Disk Buddy Checker</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSRequiresAquaSystemAppearance</key>
    <false/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
EOF

# Ad-hoc sign with a STABLE bundle identifier.
#
# macOS TCC remembers permission grants per code identity. An unsigned bundle
# has no stable identity, so every rebuild looked like a brand-new app and the
# system re-asked for Documents / Downloads / Desktop access every single time.
# Signing (even ad-hoc) with a fixed identifier keeps the grant attached.
# SIGN_ID selects the identity. Unset (the default) means ad-hoc: fine for
# local use, but Gatekeeper will warn and it can never be notarized. Set it to
# a Developer ID to produce a distributable build — scripts/release.sh does.
SIGN_ID="${SIGN_ID:--}"

if [ "$SIGN_ID" = "-" ]; then
    echo "==> Signing (ad-hoc, stable identifier)..."
else
    echo "==> Signing (${SIGN_ID})..."
fi

# A secure timestamp is required for notarization, but an ad-hoc signature
# can't carry one — so only ask for it with a real identity.
EXTRA=()
[ "$SIGN_ID" != "-" ] && EXTRA+=(--timestamp)

codesign --force --sign "$SIGN_ID" \
    --identifier com.diskbuddy.checker \
    --options runtime \
    "${EXTRA[@]}" \
    "$APP_DIR"

codesign --verify --verbose=1 "$APP_DIR" 2>&1 | sed 's/^/    /'

echo "==> Done: $APP_DIR"
