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

# Reads an answer from the keyboard even when the script arrives through a pipe
# (curl ... | bash). With no terminal at all it takes the default.
ask() {
    local answer=""
    if [ -r /dev/tty ]; then
        read -r -p "$1" answer </dev/tty || true
    fi
    printf '%s' "$answer"
}

# Xcode command line tools: swift to build, git to run.
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
    echo "Xcode command line tools are missing. Opening the installer..."
    xcode-select --install >/dev/null 2>&1 || true
    echo "Finish the installer window; this script continues on its own."
    until xcode-select -p >/dev/null 2>&1 && command -v swift >/dev/null 2>&1; do
        sleep 5
    done
fi

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

if [ -z "${1:-}" ] && [ ! -w "$DEST_DIR" ]; then
    echo "$DEST_DIR is not writable by $(whoami), installing to ~/Applications"
    DEST_DIR="$HOME/Applications"
    TARGET="$DEST_DIR/$APP_NAME"
    mkdir -p "$DEST_DIR"
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
# Cursor CLI powers the AI features. Same search paths as the app.
has_cursor() {
    command -v cursor-agent >/dev/null 2>&1 && return 0
    local d
    for d in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin; do
        [ -x "$d/cursor-agent" ] && return 0
    done
    return 1
}
if ! has_cursor; then
    answer="$(ask "Cursor CLI (needed for AI review/commit) is not installed. Install it now? [Y/n] ")"
    case "${answer:-Y}" in
        [nN]*) echo "skipped. later:  curl https://cursor.com/install -fsS | bash && cursor-agent login" ;;
        *)
            if curl https://cursor.com/install -fsS | bash; then
                "$HOME/.local/bin/cursor-agent" login </dev/tty || \
                    echo "log in later with:  cursor-agent login"
            else
                echo "Cursor CLI install failed; the app still works without AI."
            fi
            ;;
    esac
fi

answer="$(ask "Open it now? [Y/n] ")"
case "${answer:-Y}" in
    [nN]*) ;;
    *) open -a "$TARGET" ;;
esac
