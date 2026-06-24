#!/bin/bash
# Rebuild just the paste-on-cursor Swift helper into the installed bin dir,
# without a full ./install.sh. Useful after editing cursorpaste.swift or
# repairing the Swift toolchain.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HOME/.screenshot-ai/bin/cursorpaste"
mkdir -p "$(dirname "$OUT")"

xcrun --find swiftc >/dev/null 2>&1 || {
    echo "ERROR: swiftc not found. Install Xcode Command Line Tools: xcode-select --install"
    exit 1
}

echo "==> Building cursorpaste..."
xcrun swiftc -O -o "$OUT" "$SCRIPT_DIR/cursorpaste.swift"
echo "Built: $OUT"
echo "First run will prompt for Accessibility (System Settings → Privacy & Security → Accessibility)."
