#!/bin/bash
# Install "open360" for DaVinci Resolve (macOS, Apple Silicon / Intel).
#   ./install.sh          build + copy into the current user's Resolve folders
#   ./install.sh --link   symlink instead of copy (for development)
#   ./install.sh --uninstall
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
RESOLVE="$HOME/Library/Application Support/Blackmagic Design/DaVinci Resolve"
FUSES="$RESOLVE/Fusion/Fuses"
SCRIPTS="$RESOLVE/Fusion/Scripts/Utility"
MODE="copy"
[[ "${1:-}" == "--link" ]] && MODE="link"

if [[ "${1:-}" == "--uninstall" ]]; then
    rm -f "$FUSES/Open360Reframe.fuse" "$SCRIPTS/open360.py"
    rm -rf "$SCRIPTS/open360"
    echo "Removed. (Lens link folders named open360_links next to your footage can be deleted safely.)"
    exit 0
fi

echo "==> Building open360-stitch helper"
command -v swift >/dev/null || { echo "Swift toolchain missing: run 'xcode-select --install' first"; exit 1; }
(cd "$ROOT/stitcher" && swift build -c release 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" || true)
BIN="$ROOT/stitcher/.build/release/open360-stitch"
[[ -x "$BIN" ]] || { echo "build failed"; exit 1; }

mkdir -p "$FUSES" "$SCRIPTS/open360/bin"
put() { # src dst
    rm -rf "$2"
    if [[ $MODE == link ]]; then ln -s "$1" "$2"; else cp -R "$1" "$2"; fi
}
echo "==> Installing Fuse"
put "$ROOT/resolve/Fuses/Open360Reframe.fuse" "$FUSES/Open360Reframe.fuse"
echo "==> Installing Workspace script"
put "$ROOT/resolve/Scripts/Utility/open360.py" "$SCRIPTS/open360.py"
for f in open360_resolve.py insv_ref.py; do
    put "$ROOT/resolve/Scripts/Utility/open360/$f" "$SCRIPTS/open360/$f"
done
put "$BIN" "$SCRIPTS/open360/bin/open360-stitch"

echo
echo "Installed. Restart DaVinci Resolve, then use Workspace > Scripts > open360."
echo "The Fusion tool is under Add Tool > Fuses > open360 > Open360Reframe."
