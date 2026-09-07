#!/bin/bash
#
# Dev-mode launcher: debug build -> bundle -> ad-hoc sign -> launch, with the
# app's log output streamed to this terminal.
#
#   scripts/dev.sh          build and run
#   scripts/dev.sh --build  build only, don't launch
#
# Why a bundle and not just `.build/debug/DiskBuddyApp`?
# The bare binary works, but macOS keys Full Disk Access and the
# Documents / Downloads / Desktop grants to *code identity*. Running the raw
# binary means no stable identity, so every rebuild re-asks for permission —
# exactly the bug we fixed. The bundle carries a fixed identifier, so a grant
# given once survives every subsequent dev build.
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"

CONFIG=debug "$DIR/scripts/bundle-app.sh"

APP="$DIR/build/dev/Disk Buddy Checker.app"

if [ "$1" = "--build" ]; then
    echo "==> Built (not launched): $APP"
    exit 0
fi

# Kill a previous dev instance so you're never looking at a stale build.
pkill -f "build/dev/Disk Buddy Checker.app" 2>/dev/null || true

echo "==> Launching (Ctrl-C to quit)..."
exec "$APP/Contents/MacOS/DiskBuddyApp"
