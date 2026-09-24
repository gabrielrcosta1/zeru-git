#!/bin/bash
# Builds Git Agent and installs it as a normal Mac app.
#
#   ./install.sh              -> /Applications/Git Agent.app
#   ./install.sh ~/Applications
#
# Set CODESIGN_IDENTITY to sign with your own certificate instead of ad-hoc.
set -euo pipefail
cd "$(dirname "$0")"

DEST_DIR="${1:-/Applications}"
APP_NAME="Git Agent.app"
BUILT="build/$APP_NAME"
TARGET="$DEST_DIR/$APP_NAME"

./build.sh release

# The app cannot be replaced while it is running.
if pgrep -x GitAgent >/dev/null 2>&1; then
    echo "quitting the running Git Agent..."
    osascript -e 'quit app "Git Agent"' >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        pgrep -x GitAgent >/dev/null 2>&1 || break
        sleep 0.25
    done
    pgrep -x GitAgent >/dev/null 2>&1 && pkill -x GitAgent || true
    sleep 0.5
fi

if [ ! -w "$DEST_DIR" ]; then
    echo "error: $DEST_DIR is not writable by $(whoami)." >&2
    echo "       try:  ./install.sh ~/Applications" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || echo '?')"

rm -rf "$TARGET"
mkdir -p "$DEST_DIR"
# ditto keeps the bundle's metadata and the code signature intact.
ditto "$BUILT" "$TARGET"

# Nothing here came from the internet, but a stray quarantine flag would make
# Gatekeeper complain for no reason.
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

# Tell Launch Services about it, so Spotlight and the Dock pick it up now.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$TARGET" >/dev/null 2>&1 || true

echo
echo "installed: $TARGET  (version $VERSION)"
echo "open it from Spotlight, or:  open -a \"$TARGET\""
echo
read -r -p "Open it now? [Y/n] " answer
case "${answer:-Y}" in
    [nN]*) ;;
    *) open -a "$TARGET" ;;
esac
