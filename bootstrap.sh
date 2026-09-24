#!/bin/bash
# One-line install of Git Agent:
#
#   curl -fsSL https://raw.githubusercontent.com/gabrielrcosta1/zeru-git/main/bootstrap.sh | bash
#
# Clones (or updates) the repo in ~/.git-agent and runs install.sh.
# Run it again to update. GIT_AGENT_DIR changes where the source lives.
set -euo pipefail

REPO="https://github.com/gabrielrcosta1/zeru-git.git"
DIR="${GIT_AGENT_DIR:-$HOME/.git-agent}"

# git itself comes with the Xcode command line tools.
if ! xcode-select -p >/dev/null 2>&1; then
    echo "Xcode command line tools are missing. Opening the installer..."
    xcode-select --install >/dev/null 2>&1 || true
    echo "Finish the installer window; this script continues on its own."
    until xcode-select -p >/dev/null 2>&1; do sleep 5; done
fi

if [ -d "$DIR/.git" ]; then
    echo "updating $DIR"
    git -C "$DIR" pull --ff-only
else
    echo "cloning into $DIR"
    git clone --depth 1 "$REPO" "$DIR"
fi

exec "$DIR/install.sh"
