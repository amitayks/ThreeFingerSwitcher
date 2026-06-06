#!/bin/bash
# Package a built ThreeFingerSwitcher.app into a compressed, drag-to-Applications DMG.
#
#   ./scripts/package-dmg.sh                          # uses ./ThreeFingerSwitcher.app
#   APP=/path/to/ThreeFingerSwitcher.app ./scripts/package-dmg.sh
#   VERSION=0.2.0 OUT=dist/ThreeFingerSwitcher-0.2.0.dmg ./scripts/package-dmg.sh
#
# Produces a UDZO (zlib-compressed, read-only) DMG containing the app plus a symlink to
# /Applications so the user can drag-install. Dependency-free (pure hdiutil). A custom
# background/layout can be added later; this ships a clean, functional disk image.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="${APP:-ThreeFingerSwitcher.app}"
APP_NAME="$(basename "$APP")"
PRODUCT="${PRODUCT:-ThreeFingerSwitcher}"

if [ ! -d "$APP" ]; then
    echo "✗ app bundle not found: $APP" >&2
    echo "  build it first:  ./scripts/build-app.sh" >&2
    exit 1
fi

# Derive the version from the bundle if not supplied.
if [ -z "${VERSION:-}" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.0.0)"
fi
VOL_NAME="${VOL_NAME:-$PRODUCT $VERSION}"
OUT="${OUT:-dist/$PRODUCT-$VERSION.dmg}"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

STAGE="$(mktemp -d -t tfsdmg)"
trap 'rm -rf "$STAGE"' EXIT

echo "▸ staging $APP_NAME + /Applications link"
ditto "$APP" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"

echo "▸ creating DMG → $OUT (volume: \"$VOL_NAME\")"
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov "$OUT" >/dev/null

echo "✓ built $OUT"
hdiutil imageinfo "$OUT" 2>/dev/null | awk -F': ' '/Format:|Compressed/ {print "  " $0}' || true
