#!/bin/bash
set -e

PLIST="$HOME/Library/LaunchAgents/io.local.screenshot-ai.plist"

echo "==> Unloading LaunchAgent..."
launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"

echo "==> Restoring default screenshot location and thumbnail preview..."
defaults delete com.apple.screencapture location 2>/dev/null || true
defaults delete com.apple.screencapture show-thumbnail 2>/dev/null || true
killall SystemUIServer 2>/dev/null || true

echo ""
echo "Uninstalled. Screenshots will save to ~/Desktop again."
echo "Binary and logs remain at ~/.screenshot-ai/. Delete manually if desired:"
echo "  rm -rf ~/.screenshot-ai"
