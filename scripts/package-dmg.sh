#!/bin/bash
# Package a built ThreeFingerSwitcher.app into a drag-to-Applications DMG.
#
#   ./scripts/package-dmg.sh                          # uses ./ThreeFingerSwitcher.app
#   APP=/path/to/ThreeFingerSwitcher.app ./scripts/package-dmg.sh
#   VERSION=0.2.0 OUT=dist/ThreeFingerSwitcher-0.2.0.dmg ./scripts/package-dmg.sh
#
# Preferred: a STYLED image via `create-dmg` (brew) — branded background, fixed icon layout,
# and a "drag → Applications" arrow (background from scripts/make-dmg-background.sh). If
# `create-dmg` isn't installed (e.g. a quick local build), it falls back to a PLAIN but fully
# functional UDZO image (app + /Applications symlink) built with pure `hdiutil`.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="${APP:-ThreeFingerSwitcher.app}"
APP_NAME="$(basename "$APP")"
PRODUCT="${PRODUCT:-ThreeFingerSwitcher}"
BG="Resources/Branding/dmg-background.png"

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

# ── Styled image via create-dmg (icon coordinates must match the background art) ───────────
styled_dmg() {
    local stage; stage="$(mktemp -d -t tfsdmg)"
    ditto "$APP" "$stage/$APP_NAME"
    local rc=0
    create-dmg \
        --volname "$VOL_NAME" \
        --background "$BG" \
        --window-pos 200 120 \
        --window-size 660 400 \
        --icon-size 144 \
        --icon "$APP_NAME" 180 190 \
        --hide-extension "$APP_NAME" \
        --app-drop-link 480 190 \
        --no-internet-enable \
        "$OUT" "$stage" || rc=$?
    rm -rf "$stage"
    [ "$rc" -eq 0 ] && [ -f "$OUT" ]
}

# ── Plain fallback (pure hdiutil) ─────────────────────────────────────────────────────────
plain_dmg() {
    local stage; stage="$(mktemp -d -t tfsdmg)"
    ditto "$APP" "$stage/$APP_NAME"
    ln -s /Applications "$stage/Applications"
    hdiutil create -volname "$VOL_NAME" -srcfolder "$stage" \
        -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT" >/dev/null
    rm -rf "$stage"
    [ -f "$OUT" ]
}

if command -v create-dmg >/dev/null 2>&1 && [ -f "$BG" ]; then
    echo "▸ creating STYLED DMG → $OUT (volume: \"$VOL_NAME\")"
    if styled_dmg; then
        echo "✓ built styled $OUT"
    else
        echo "⚠ create-dmg failed — falling back to a plain DMG" >&2
        rm -f "$OUT"
        plain_dmg && echo "✓ built plain $OUT"
    fi
else
    [ -f "$BG" ] || echo "▸ (no background art at $BG)"
    command -v create-dmg >/dev/null 2>&1 || echo "▸ (create-dmg not installed — \`brew install create-dmg\` for the styled window)"
    echo "▸ creating plain DMG → $OUT (volume: \"$VOL_NAME\")"
    plain_dmg && echo "✓ built plain $OUT"
fi

hdiutil imageinfo "$OUT" 2>/dev/null | awk -F': ' '/Format:|Compressed/ {print "  " $0}' || true
