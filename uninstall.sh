#!/bin/bash
# Removes an installed Git Agent. Your repositories are never touched.
set -euo pipefail

for TARGET in "/Applications/Git Agent.app" "$HOME/Applications/Git Agent.app"; do
    if [ -d "$TARGET" ]; then
        pgrep -x GitAgent >/dev/null 2>&1 && osascript -e 'quit app "Git Agent"' >/dev/null 2>&1 || true
        rm -rf "$TARGET"
        echo "removed: $TARGET"
    fi
done

echo
echo "Settings and the list of open projects live in:"
echo "  ~/Library/Preferences/com.burh.gitagent.plist"
echo "Remove them too with:  defaults delete com.burh.gitagent"
