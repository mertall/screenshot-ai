# screenshot-ai

A macOS background plugin that intercepts every screenshot and asks one question: **"Using this for AI?"** If yes, the file gets a 5-minute self-destruct timer so it doesn't linger on disk after you've pasted it into your AI tool. If no, it's kept normally.

It does **not** call any AI CLI — you drag/paste the file into Claude / Codex / ChatGPT yourself during the TTL window. The plugin's only job is the prompt and the auto-delete timer.

## How it works

1. On install, `defaults write com.apple.screencapture location` redirects screenshots from `~/Desktop` to a hidden staging folder (`~/.screenshot-ai/pending`).
2. A `launchd` agent runs a small Rust binary (`src/main.rs`, built to `~/.screenshot-ai/bin/screenshot-ai`) that polls the staging folder ~10x/sec.
3. When a new `.png` / `.jpg` appears, it waits for the file to finish writing, then shows a native macOS dialog with two buttons: **Keep** and **Yes — auto-delete**.
4. Either way the file is moved to `~/Desktop` so it behaves like a normal screenshot. If you picked auto-delete, a detached `sleep $TTL && rm` is scheduled and a notification confirms the timer.

The watcher is pure-std Rust (no external crates) shelling out to `osascript`. `install.sh` builds it with `cargo`.

## Requirements

- macOS 12+ (uses `osascript`, `launchd`, `defaults` — all stock)
- Rust toolchain (`cargo`) to build — install from <https://rustup.rs>

## Install

```bash
cd ~/Documents/screenshot-ai
chmod +x install.sh uninstall.sh
./install.sh   # runs `cargo build --release` then installs the LaunchAgent
```

The first time the dialog or notification fires, macOS may ask to grant Automation / System Events permission. Approve it (System Settings → Privacy & Security → Automation).

## Use

Take a screenshot the usual way:

| Shortcut | Behaviour |
| --- | --- |
| `Cmd+Shift+3` | Full screen → staged → prompts you → moved to `~/Desktop` |
| `Cmd+Shift+4` | Region → staged → prompts you → moved to `~/Desktop` |
| `Cmd+Shift+5` | Capture UI → staged → prompts you → moved to `~/Desktop` |
| `Cmd+Ctrl+Shift+3 / 4` | Clipboard only — **not intercepted** (never hits disk) |

The dialog has two buttons:

- **Keep** — behaves like a normal screenshot. File stays on the Desktop until you delete it.
- **Yes — auto-delete** *(default)* — file stays on the Desktop long enough for you to drag/paste it into your AI tool, then is removed automatically after `SCREENSHOT_AI_TTL` seconds (default 300 = 5 min).

## Files

| Path | Purpose |
| --- | --- |
| `~/.screenshot-ai/bin/screenshot-ai` | Watcher binary (built from `src/main.rs`) |
| `~/.screenshot-ai/pending/` | Transient staging area (file lives here only between capture and dialog click) |
| `~/.screenshot-ai/stdout.log`, `stderr.log` | LaunchAgent logs |
| `~/Library/LaunchAgents/io.local.screenshot-ai.plist` | LaunchAgent definition |
| `~/Desktop/Screen Shot *.png` | Final landing spot for both Keep and auto-delete paths |

## Uninstall

```bash
./uninstall.sh
```

Restores the default screenshot location and removes the LaunchAgent. Leaves logs in `~/.screenshot-ai/`; `rm -rf ~/.screenshot-ai` for a clean wipe.

## Customisation

Edit `src/main.rs` and re-run `./install.sh` (it rebuilds and reloads). Run `cargo test` for the unit/integration tests. The `SCREENSHOT_AI_TTL` knob can also be set in the plist's `EnvironmentVariables` block — LaunchAgents ignore your shell env, so set it there:

| Variable | Default | Effect |
| --- | --- | --- |
| `SCREENSHOT_AI_TTL` | `300` | Seconds before an auto-delete screenshot is removed |
| `SCREENSHOT_AI_POLL_MS` | `100` | Watcher poll interval (ms) |
| `SCREENSHOT_AI_SETTLE_MS` | `80` | Per-sample wait while checking the file has stopped growing (ms) |

Other tweaks:

- **Change dialog wording** → edit `prompt_user`
- **Add a "delete now" button** → add a third button in `prompt_user`, then branch on it in `handle_screenshot`

## Troubleshooting

- **No dialog appears.** Check `~/.screenshot-ai/stderr.log` — first line should be `screenshot-ai watching ...`. If the agent isn't running, try `launchctl load ~/Library/LaunchAgents/io.local.screenshot-ai.plist`.
- **Screenshots still hit ~/Desktop.** `SystemUIServer` didn't pick up the new default. `killall SystemUIServer` and try again, or log out / back in.
- **Dialog shows on a half-written capture.** Bump `SCREENSHOT_AI_SETTLE_MS` in the plist environment block.
