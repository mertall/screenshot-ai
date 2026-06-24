#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$HOME/.screenshot-ai"
BIN_DIR="$BASE_DIR/bin"
PENDING_DIR="$BASE_DIR/pending"
PLIST="$HOME/Library/LaunchAgents/io.local.screenshot-ai.plist"
WATCHER_SRC="$SCRIPT_DIR/screenshot-ai.sh"
WATCHER_DST="$BIN_DIR/screenshot-ai.sh"

mkdir -p "$BIN_DIR" "$PENDING_DIR"

echo "==> Installing watcher script..."
cp "$WATCHER_SRC" "$WATCHER_DST"
chmod +x "$WATCHER_DST"

echo "==> Redirecting macOS screenshot location to $PENDING_DIR..."
defaults write com.apple.screencapture location "$PENDING_DIR"
defaults write com.apple.screencapture type png
killall SystemUIServer

# The watcher only calls stock tools (osascript, stat, mv, rm, sleep) — a
# minimal system PATH is all the LaunchAgent needs.
RUNTIME_PATH="/usr/bin:/bin:/usr/sbin"

echo "==> Writing LaunchAgent at $PLIST..."
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.local.screenshot-ai</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$WATCHER_DST</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$RUNTIME_PATH</string>
        <key>HOME</key>
        <string>$HOME</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>StandardOutPath</key>
    <string>$BASE_DIR/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$BASE_DIR/stderr.log</string>
</dict>
</plist>
EOF

echo "==> (Re)loading LaunchAgent..."
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo ""
echo "Installed."
echo "  Watcher:     $WATCHER_DST"
echo "  Pending dir: $PENDING_DIR"
echo "  Logs:        $BASE_DIR/stdout.log, $BASE_DIR/stderr.log"
echo ""
echo "Take a screenshot (Cmd+Shift+3 or Cmd+Shift+4) — a dialog will ask whether to auto-delete it after use."
echo "To stop: ./uninstall.sh"
