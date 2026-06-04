#!/bin/bash
# One-time: authorize /usr/bin/codesign to use the dev signing key without prompting on
# every build. Modern macOS gates private-key use with a "partition list"; this adds codesign
# to it so signing is silent. You will be asked for your macOS login password once.
set -euo pipefail

KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

printf "Enter your macOS login password (authorizes codesign to use the signing key): "
read -rs PW
echo

if security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "✓ codesign can now use the signing key without prompting."
else
    echo "✗ Could not set the partition list (wrong password?). You can instead click"
    echo "  'Always Allow' on the keychain prompts during a build to achieve the same thing."
    exit 1
fi
