#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$HOME/.screenshot-ai"
BIN_DIR="$BASE_DIR/bin"
PENDING_DIR="$BASE_DIR/pending"
PLIST="$HOME/Library/LaunchAgents/io.local.screenshot-ai.plist"
WATCHER_DST="$BIN_DIR/screenshot-ai"

mkdir -p "$BIN_DIR" "$PENDING_DIR"

command -v cargo >/dev/null || { echo "ERROR: cargo not found. Install Rust: https://rustup.rs"; exit 1; }

echo "==> Building release binary..."
cargo build --release --manifest-path "$SCRIPT_DIR/Cargo.toml"

echo "==> Installing watcher binary..."
cp "$SCRIPT_DIR/target/release/screenshot-ai" "$WATCHER_DST"
chmod +x "$WATCHER_DST"

echo "==> Redirecting macOS screenshot location to $PENDING_DIR..."
defaults write com.apple.screencapture location "$PENDING_DIR"
defaults write com.apple.screencapture type png
killall SystemUIServer

# The binary only shells out to osascript / sh / rm — a minimal PATH suffices.
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
