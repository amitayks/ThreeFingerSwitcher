#!/bin/bash
# Assemble ThreeFingerSwitcher.app from the SwiftPM build.
#
#   ./scripts/build-app.sh            # uses the stable "ThreeFingerSwitcher Dev" cert if present
#   INSTALL=1 ./scripts/build-app.sh  # also install (in place) to /Applications
#   INSTALL_DIR=/some/path ./scripts/build-app.sh
#   SIGN_ID="Developer ID Application: You (TEAMID)" NOTARIZE=1 ./scripts/build-app.sh
#
# INSTALL refreshes the app at a STABLE path with the SAME signature, so the "Open at Login"
# registration (and TCC grants) survive across rebuilds — a rebuild IS the update.
#
# Prefer a STABLE signing identity so macOS permission grants persist across rebuilds.
# Run ./scripts/make-dev-cert.sh once to create "ThreeFingerSwitcher Dev". Falls back to
# ad-hoc only if no stable identity is found (ad-hoc loses TCC grants every rebuild).
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
APP="ThreeFingerSwitcher.app"
PRODUCT="ThreeFingerSwitcher"
DEV_CERT="ThreeFingerSwitcher Dev"

# Pick a signing identity: explicit SIGN_ID > stable dev cert > ad-hoc.
if [ -n "${SIGN_ID:-}" ]; then
    :
elif security find-identity -p codesigning 2>/dev/null | grep -q "$DEV_CERT"; then
    SIGN_ID="$DEV_CERT"
    echo "▸ using stable dev signing identity (TCC grants will persist)"
else
    SIGN_ID="-"
    echo "▸ WARNING: no stable identity found — falling back to ad-hoc (grants reset each rebuild)."
    echo "  Run ./scripts/make-dev-cert.sh once to fix this."
fi

echo "▸ swift build -c $CONFIG"
swift build -c "$CONFIG" --product "$PRODUCT"

BIN_PATH="$(swift build -c "$CONFIG" --product "$PRODUCT" --show-bin-path)"
XCF_FRAMEWORK="$(find .build/artifacts -type d -name 'OpenMultitouchSupportXCF.framework' -path '*macos-arm64*' | head -1)"

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN_PATH/$PRODUCT" "$APP/Contents/MacOS/$PRODUCT"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp -R "$XCF_FRAMEWORK" "$APP/Contents/Frameworks/"

echo "▸ fixing rpath → @executable_path/../Frameworks"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$PRODUCT" 2>/dev/null || true

echo "▸ signing (id: $SIGN_ID)"
# Sign nested framework first, then the app with entitlements + hardened runtime.
codesign --force --sign "$SIGN_ID" --timestamp=none \
    "$APP/Contents/Frameworks/OpenMultitouchSupportXCF.framework"
RUNTIME_FLAG=""
# Hardened runtime is only needed for notarized Developer-ID distribution.
if [ "${NOTARIZE:-}" = "1" ]; then RUNTIME_FLAG="--options runtime"; fi
codesign --force --sign "$SIGN_ID" $RUNTIME_FLAG \
    --entitlements "Resources/ThreeFingerSwitcher.entitlements" \
    "$APP/Contents/MacOS/$PRODUCT"
codesign --force --sign "$SIGN_ID" $RUNTIME_FLAG \
    --entitlements "Resources/ThreeFingerSwitcher.entitlements" \
    "$APP"

echo "▸ verifying"
codesign --verify --deep --strict --verbose=2 "$APP" || true

# Terminate any running instance so a subsequent `open` launches THIS build.
# (macOS `open` only re-activates an already-running LSUIElement agent; it won't relaunch it.)
if pgrep -x "$PRODUCT" >/dev/null; then
    echo "▸ terminating running instance so the new build can launch"
    pkill -x "$PRODUCT" 2>/dev/null || true
    sleep 1
    pkill -9 -x "$PRODUCT" 2>/dev/null || true
fi

# Optional in-place install to a stable location so Open-at-Login + TCC grants persist across
# rebuilds. INSTALL=1 targets /Applications; or set INSTALL_DIR=/some/path explicitly.
if [ "${INSTALL:-}" = "1" ] && [ -z "${INSTALL_DIR:-}" ]; then INSTALL_DIR="/Applications"; fi
if [ -n "${INSTALL_DIR:-}" ]; then
    DEST="$INSTALL_DIR/$APP"
    echo "▸ installing in place → $DEST (same path + signature: Open-at-Login stays registered)"
    if rm -rf "$DEST" 2>/dev/null && ditto "$APP" "$DEST" 2>/dev/null; then
        echo "✓ built + installed: $DEST  (run: open \"$DEST\")"
    else
        echo "✗ could not write to $INSTALL_DIR (permissions?). Run once with elevation:"
        echo "    sudo rm -rf \"$DEST\" && sudo ditto \"$PWD/$APP\" \"$DEST\""
        exit 1
    fi
else
    echo "✓ built $APP  (run: open $APP)"
fi
