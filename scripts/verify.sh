#!/bin/bash
# Verification for the scanner and the layout algorithms.
# These two files never compiled as part of any target, so they could not rot
# quietly: run this and it either agrees with `du` or it doesn't.
set -e
DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"
TARGET="${1:-$HOME/Documents}"

echo "==> Building"
swift build -c release --product dbscan >/dev/null

echo "==> 1. Correctness on a fixture with a hardlink"
T="$(mktemp -d)"
mkdir -p "$T/a/b" "$T/c"
head -c 3000000 /dev/urandom > "$T/a/big.bin"
head -c 500000  /dev/urandom > "$T/a/b/mid.bin"
head -c 1000    /dev/urandom > "$T/c/small.bin"
ln "$T/a/big.bin" "$T/c/hardlink.bin"
DU_KB=$(du -sk "$T" | awk '{print $1}')
DU_BYTES=$((DU_KB * 1024))
SCAN=$(./.build/release/dbscan "$T" -n 0 | awk '/size on disk/ {print $4, $5}')
echo "    du:     $(echo "$DU_BYTES" | awk '{printf "%.2f MB", $1/1e6}')"
echo "    dbscan: $SCAN   (hardlink must be charged once)"
rm -rf "$T"

echo "==> 2. Totals vs du on $TARGET"
./.build/release/dbscan "$TARGET" -n 0 | sed -n '2,10p'
echo "    du -sk:"
du -sk "$TARGET" | awk '{printf "    %.2f GB\n", $1*1024/1e9}'

echo "==> 3. Layout algorithms"
./.build/release/dbscan "$TARGET" -n 0 --layouts | tail -8

echo "==> 4. Duplicate funnel: clone vs hardlink vs true copy"
D="$(mktemp -d)"
mkdir -p "$D/a" "$D/b"
head -c 8000000 /dev/urandom > "$D/a/original.bin"
cp "$D/a/original.bin" "$D/b/real-copy.bin"     # a genuine second copy
cp -c "$D/a/original.bin" "$D/a/clone.bin"      # APFS clone: shares blocks
head -c 8000000 /dev/urandom > "$D/b/different.bin"  # same size, other bytes
ln "$D/a/original.bin" "$D/b/hardlink.bin"      # same inode, not a copy
./.build/release/dbscan "$D" -n 0 --dupes | tail -12
echo "    EXPECTED: 1 group of 3, reclaimable 8.00 MB (NOT 16 MB), 1 clone excluded."
echo "    The hardlink must never appear, and different.bin must die at stage 2."
rm -rf "$D"

echo "==> 5. Snapshot round-trip + diff (Snapshots tab)"
./.build/release/dbscan "$TARGET" -n 0 --snapshot | tail -6
echo "    EXPECTED: round-trip identical YES, self-diff 0 changes."

echo "==> 6. Temperature sensors (Monitor tab)"
./.build/release/dbscan --temp | head -5

echo "==> 7. System sampler (Monitor tab)"
./.build/release/dbscan --monitor | sed -n '1,4p'

echo "==> 8. App inventory (Applications tab)"
./.build/release/dbscan --apps | sed -n '1,4p'
echo "    cross-check the top app against du:"
TOP_APP=$(./.build/release/dbscan --apps | sed -n '3p' | sed 's/  v.*//')
if [ -d "/Applications/$TOP_APP.app" ]; then
  du -sk "/Applications/$TOP_APP.app" | awk '{printf "    du %s.app: %.2f GB\n", "'"$TOP_APP"'", $1*1024/1e9}'
fi

echo
echo "PASS criteria: 'size on disk' matches du, treemap coverage is ~100%,"
echo "the sunburst depth-0 sweep is ~6.283 rad (a full circle), bubbles report zero
sibling overlap, the duplicate fixture reclaims 8 MB rather than 16, CPU/memory
are non-zero on the second sample, the snapshot round-trip is identical with a
zero self-diff, and the top app's bundle size matches du."
