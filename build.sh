#!/bin/bash
# Builds Git Agent.app into ./build
#
# Signing identity: ad-hoc by default. Set CODESIGN_IDENTITY to a certificate in
# your keychain (see "A stable signature" in the README) so macOS keeps treating
# every build as the same app.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="build/Git Agent.app"
IDENTITY="${CODESIGN_IDENTITY:--}"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/GitAgent"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GitAgent"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null; then
    [ "$IDENTITY" = "-" ] && echo "signed: ad-hoc" || echo "signed: $IDENTITY"
else
    echo "warning: could not sign with '$IDENTITY', the app will still run" >&2
fi

touch "$APP"
echo "built: $APP"
echo "run:   open \"$APP\""
