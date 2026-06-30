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

echo "==> Building cursor-paste helper (native, optional)..."
if xcrun --find clang >/dev/null 2>&1; then
    if xcrun clang -fobjc-arc -O2 -framework Cocoa -framework ApplicationServices \
        -o "$BIN_DIR/cursorpaste" "$SCRIPT_DIR/cursorpaste.m" 2>"$BASE_DIR/swiftc.log"; then
        echo "  built: $BIN_DIR/cursorpaste"
        echo "  NOTE: grant it Accessibility on first use (System Settings → Privacy & Security → Accessibility)."
    else
        rm -f "$BIN_DIR/cursorpaste"
        echo "  WARN: helper build failed (see $BASE_DIR/swiftc.log) — paste-on-cursor disabled, Keep/Auto-delete still work."
    fi
else
    echo "  clang not found — paste-on-cursor disabled (install Xcode Command Line Tools to enable)."
fi

echo "==> Redirecting macOS screenshot location to $PENDING_DIR..."
defaults write com.apple.screencapture location "$PENDING_DIR"
defaults write com.apple.screencapture type png
# Disable the floating thumbnail preview: with it on, screencapture holds the
# image in memory and only writes the file ~5s later, so the dialog can't fire
# until then. Off = file lands on disk immediately.
defaults write com.apple.screencapture show-thumbnail -bool false
killall SystemUIServer

# The watcher only calls stock tools (osascript, stat, mv, rm, sleep, date) — a
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
