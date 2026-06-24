# screenshot-ai

A macOS background plugin that intercepts every screenshot and asks one question: **"Using this for AI?"** If yes, the file gets a 5-minute self-destruct timer so it doesn't linger on disk after you've pasted it into Claude / Codex / ChatGPT. If no, it's kept normally.

## How it works

1. On install, `defaults write com.apple.screencapture location` redirects screenshots from `~/Desktop` to a hidden staging folder (`~/.screenshot-ai/pending`).
2. A `launchd` agent runs a small bash watcher (`screenshot-ai.sh`) that polls the staging folder ~2x/sec.
3. When a new `.png` / `.jpg` / `.heic` appears, it waits for the file to finish writing, then shows a native macOS dialog (using the image itself as the icon) with two buttons: **Keep** and **Yes — auto-delete**.
4. Either way the file is moved to `~/Desktop` so it behaves like a normal screenshot. If you picked auto-delete, a detached `sleep $TTL && rm` is scheduled and a notification confirms the timer.

The watcher is plain bash + `osascript` — nothing to compile, no toolchain dependency.

## Requirements

- macOS 12+ (uses `osascript`, `launchd`, `defaults`, `stat -f%z` — all stock)
- No external CLIs needed — you handle the AI tool yourself (drag the file, paste from Finder, etc.) during the TTL window.

## Install

```bash
cd ~/Documents/screenshot-ai
chmod +x install.sh uninstall.sh screenshot-ai.sh
./install.sh
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
| `~/.screenshot-ai/bin/screenshot-ai.sh` | Watcher (installed copy) |
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

Edit `screenshot-ai.sh` and re-run `./install.sh` (the installer just copies it into place). Or tune via env vars in the plist's `EnvironmentVariables` block — LaunchAgents ignore your shell env, so set them there:

| Variable | Default | Effect |
| --- | --- | --- |
| `SCREENSHOT_AI_TTL` | `300` | Seconds before an auto-delete screenshot is removed |
| `SCREENSHOT_AI_KEEP_DIR` | `$HOME/Desktop` | Where screenshots land after the prompt |
| `SCREENSHOT_AI_POLL` | `0.5` | Watcher poll interval (seconds) |
| `SCREENSHOT_AI_SETTLE` | `0.4` | How long to wait for the file to stop growing before prompting |

Other tweaks:

- **Change dialog wording** → edit `prompt_user`
- **Add a "delete now" button** → add a third button in `prompt_user`, then in `handle_screenshot`'s `case`, branch on it before/instead of `relocate_unique`
- **Skip the prompt and always auto-delete** → replace `handle_screenshot` body with `relocate_unique` + `schedule_delete`

## Troubleshooting

- **No dialog appears.** Check `~/.screenshot-ai/stderr.log` — first line should be `screenshot-ai watching ...`. If the agent isn't running, try `launchctl load ~/Library/LaunchAgents/io.local.screenshot-ai.plist`.
- **AI command fails ("command not found").** The `PATH` baked into the plist is wrong for your shell. Re-run `install.sh` from a terminal where `which claude` and `which codex` both succeed.
- **Screenshots still hit ~/Desktop.** `SystemUIServer` didn't pick up the new default. `killall SystemUIServer` and try again, or log out / back in.
- **Dialog shows but image is wrong / empty.** Sometimes macOS writes screenshots in two phases; bump `SCREENSHOT_AI_SETTLE=0.8` in the plist environment block.
