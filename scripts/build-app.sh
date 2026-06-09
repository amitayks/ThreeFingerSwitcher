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
# xcodebuild uses a capitalized configuration name ("Release"), unlike swift build's "release".
CONFIG="${CONFIG:-Release}"
APP="ThreeFingerSwitcher.app"
PRODUCT="ThreeFingerSwitcher"
DEV_CERT="ThreeFingerSwitcher Dev"
DERIVED="$PWD/.derivedData"

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

# The app transitively links MLX (Gemma 4 runtime), whose Metal shaders ONLY compile under
# xcodebuild — `swift build` cannot build the app target anymore. We still keep STABLE signing:
# xcodebuild builds WITHOUT signing (CODE_SIGNING_ALLOWED=NO), then the codesign block below applies
# the stable "ThreeFingerSwitcher Dev" identity, so TCC grants survive across rebuilds.
echo "▸ xcodebuild build -scheme $PRODUCT -configuration $CONFIG (no xcodebuild signing; stable codesign below)"
# `-onlyUsePackageVersionsFromResolvedFile`: build EXACTLY the versions in the committed
# Package.resolved and never re-resolve. Some dependencies (gemma-4-swift-mlx, and its transitive
# mlx-swift-lm) track `branch: main`, whose upstream HEAD drifts and has shipped commits that fail to
# compile — without this flag a clean CI checkout re-resolves those branches to a broken newer HEAD
# and fails the release build even though the lockfile pins known-good commits. The lockfile is the
# source of truth; bump deliberately via `swift package update` + a verified `xcodebuild`.
xcodebuild build \
    -scheme "$PRODUCT" \
    -destination 'platform=macOS' \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" \
    -skipMacroValidation \
    -skipPackagePluginValidation \
    -onlyUsePackageVersionsFromResolvedFile \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

BIN_PATH="$DERIVED/Build/Products/$CONFIG"
# xcodebuild copies the OpenMultitouchSupport XCFramework's macOS slice into the products dir.
XCF_FRAMEWORK="$BIN_PATH/OpenMultitouchSupportXCF.framework"

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN_PATH/$PRODUCT" "$APP/Contents/MacOS/$PRODUCT"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp -R "$XCF_FRAMEWORK" "$APP/Contents/Frameworks/"

# SwiftPM resource bundles (e.g. mlx-swift_Cmlx.bundle, which holds default.metallib — MLX's compiled
# Metal shaders). xcodebuild emits these into the products dir; they are NOT baked into the binary.
# Each package finds its bundle via `Bundle.module`, whose first candidate is `Bundle.main.resourceURL`
# = Contents/Resources. WITHOUT this copy the app is SIGKILLed with no crash report the instant MLX
# touches the GPU — i.e. "it disappears at 100%". Copy every produced *.bundle into Resources.
for bundle in "$BIN_PATH"/*.bundle; do
    [ -e "$bundle" ] || continue
    echo "▸ bundling resource: $(basename "$bundle")"
    cp -R "$bundle" "$APP/Contents/Resources/"
done

# App icon (shown in Finder / Spotlight / login-items / Accessibility list). Referenced by
# CFBundleIconFile = "AppIcon" in Info.plist.
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Menu-bar brand mark (template PNGs @1x/@2x/@3x). StatusItemController loads it via
# NSImage(named: "MenuBarIcon"), which gathers the @Nx reps from loose files in Resources.
for mark in Resources/Branding/MenuBarIcon.png Resources/Branding/MenuBarIcon@2x.png Resources/Branding/MenuBarIcon@3x.png; do
    [ -f "$mark" ] && cp "$mark" "$APP/Contents/Resources/$(basename "$mark")"
done

# Optional version stamping (used by CI to inject the release version from the git tag).
# Patches the COPIED bundle Info.plist only — the repo Info.plist keeps its dev value.
if [ -n "${MARKETING_VERSION:-}" ]; then
    plutil -replace CFBundleShortVersionString -string "$MARKETING_VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "${BUILD_VERSION:-}" ]; then
    plutil -replace CFBundleVersion -string "$BUILD_VERSION" "$APP/Contents/Info.plist"
fi

echo "▸ fixing rpath → @executable_path/../Frameworks"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$PRODUCT" 2>/dev/null || true

echo "▸ signing (id: $SIGN_ID)"
# Notarized Developer-ID distribution requires the hardened runtime AND a secure (Apple)
# timestamp on EVERY signature, including the nested framework. Local/dev builds skip both
# (faster, no network round-trip, and a self-signed cert can't get an Apple timestamp).
RUNTIME_FLAG=""
TS_FLAG="--timestamp=none"
if [ "${NOTARIZE:-}" = "1" ]; then
    RUNTIME_FLAG="--options runtime"
    TS_FLAG="--timestamp"
fi
# Sign nested framework first, then the binary, then the app — entitlements on the app code.
codesign --force --sign "$SIGN_ID" $TS_FLAG $RUNTIME_FLAG \
    "$APP/Contents/Frameworks/OpenMultitouchSupportXCF.framework"
codesign --force --sign "$SIGN_ID" $TS_FLAG $RUNTIME_FLAG \
    --entitlements "Resources/ThreeFingerSwitcher.entitlements" \
    "$APP/Contents/MacOS/$PRODUCT"
codesign --force --sign "$SIGN_ID" $TS_FLAG $RUNTIME_FLAG \
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
        # Remove the local working copy so it isn't indexed by Launch Services / Spotlight as a
        # second "ThreeFingerSwitcher" alongside the canonical install. (Skipped for non-INSTALL
        # builds below, where the local copy IS the deliverable.)
        rm -rf "$APP"
        echo "✓ built + installed: $DEST  (run: open \"$DEST\")"
    else
        echo "✗ could not write to $INSTALL_DIR (permissions?). Run once with elevation:"
        echo "    sudo rm -rf \"$DEST\" && sudo ditto \"$PWD/$APP\" \"$DEST\""
        exit 1
    fi
else
    echo "✓ built $APP  (run: open $APP)"
fi
