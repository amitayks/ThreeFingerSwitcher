#!/bin/bash
# Install a LaunchAgent that relaunches ThreeFingerSwitcher.app at login and keeps it alive.
#
# This is an ALTERNATIVE to the in-app "Open at Login" toggle (SMAppService), intended for
# users who specifically want relaunch-on-exit (KeepAlive). SMAppService is the primary path.
#
#   ./scripts/install-launch-agent.sh                 # uses ./ThreeFingerSwitcher.app
#   APP_PATH=/Applications/ThreeFingerSwitcher.app ./scripts/install-launch-agent.sh
#
# Uninstall:
#   launchctl bootout gui/$(id -u)/com.threefingerswitcher.app.agent
#   rm ~/Library/LaunchAgents/com.threefingerswitcher.app.agent.plist
set -euo pipefail

cd "$(dirname "$0")/.."

LABEL="com.threefingerswitcher.app.agent"
APP_PATH="${APP_PATH:-$PWD/ThreeFingerSwitcher.app}"
BIN="$APP_PATH/Contents/MacOS/ThreeFingerSwitcher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ ! -x "$BIN" ]; then
    echo "✗ executable not found at: $BIN" >&2
    echo "  Build the app first (./scripts/build-app.sh) or set APP_PATH=/Applications/ThreeFingerSwitcher.app" >&2
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF

echo "▸ wrote $PLIST"

# Reload: bootout (ignore failure if not loaded) then bootstrap into the user GUI domain.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "✓ installed LaunchAgent ($LABEL) → $BIN"
echo "  It will run at login and relaunch on exit. To remove:"
echo "    launchctl bootout gui/\$(id -u)/$LABEL && rm \"$PLIST\""
