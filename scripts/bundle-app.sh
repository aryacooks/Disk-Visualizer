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

cat << 'EOF' > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>DiskBuddyApp</string>
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
echo "==> Signing (ad-hoc, stable identifier)..."
codesign --force --sign - \
    --identifier com.diskbuddy.checker \
    --options runtime \
    "$APP_DIR" 2>/dev/null \
  || codesign --force --sign - --identifier com.diskbuddy.checker "$APP_DIR"

codesign --verify --verbose=1 "$APP_DIR" 2>&1 | sed 's/^/    /'

echo "==> Done: $APP_DIR"
