#!/bin/bash
# Rebuild just the paste-on-cursor native helper into the installed bin dir,
# without a full ./install.sh.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HOME/.screenshot-ai/bin/cursorpaste"
mkdir -p "$(dirname "$OUT")"

xcrun --find clang >/dev/null 2>&1 || {
    echo "ERROR: clang not found. Install Xcode Command Line Tools: xcode-select --install"
    exit 1
}

echo "==> Building cursorpaste..."
xcrun clang -fobjc-arc -O2 -framework Cocoa -framework ApplicationServices \
    -o "$OUT" "$SCRIPT_DIR/cursorpaste.m"
echo "Built: $OUT"
echo "First run will prompt for Accessibility (System Settings → Privacy & Security → Accessibility)."
