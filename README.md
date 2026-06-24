# screenshot-ai

A macOS background plugin that intercepts every screenshot and asks one question: **"Using this for AI?"** If yes, the file gets a 5-minute self-destruct timer so it doesn't linger on disk after you've pasted it into your AI tool. If no, it's kept normally.

It does **not** call any AI CLI — you drag/paste the file into Claude / Codex / ChatGPT yourself during the TTL window. The plugin's only job is the prompt and the auto-delete timer.

## Why this exists

If you regularly screenshot things to paste into an AI chat, those PNGs pile up on your Desktop and in `~/Downloads` forever — and screenshots often contain things you don't want lingering on disk: account pages, dashboards, private messages, internal tooling. This adds a one-tap decision at capture time: *"is this a throwaway I'm pasting into an AI tool?"* If yes, it cleans itself up; if no, nothing changes. No background uploads, no AI calls, no telemetry — just a prompt and a timer.

## How it works

1. On install, `defaults write com.apple.screencapture location` redirects screenshots from `~/Desktop` to a hidden staging folder (`~/.screenshot-ai/pending`).
2. A `launchd` agent runs a small bash watcher (`screenshot-ai.sh`) that polls the staging folder ~10x/sec.
3. When a new `.png` / `.jpg` appears, it waits for the file to finish writing, then shows a native macOS dialog with two buttons: **Keep** and **Auto-delete**.
4. Either way the file is moved to `~/Desktop` so it behaves like a normal screenshot. If you picked auto-delete, the deletion time is appended to a small state file (`~/.screenshot-ai/deletes.tsv`) and a notification confirms the timer.
5. On every poll tick the watcher also sweeps `deletes.tsv` and removes any file whose time has come. Because the schedule lives on disk (not in a spawned timer process), pending deletes survive watcher reloads, logout, and reboots.

The watcher is plain bash shelling out to `osascript` — nothing to compile, no toolchain dependency.

## Requirements

- macOS 12+ (uses `osascript`, `launchd`, `defaults`, `stat -f%z` — all stock)
- No external CLIs needed.

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
- **Auto-delete** *(default)* — file stays on the Desktop long enough for you to drag/paste it into your AI tool, then is removed automatically after `SCREENSHOT_AI_TTL` seconds (default 300 = 5 min).

## Files

| Path | Purpose |
| --- | --- |
| `~/.screenshot-ai/bin/screenshot-ai.sh` | Watcher script (installed copy) |
| `~/.screenshot-ai/pending/` | Transient staging area (file lives here only between capture and dialog click) |
| `~/.screenshot-ai/deletes.tsv` | Persisted auto-delete schedule (`<unix-time>\t<path>` per line) |
| `~/.screenshot-ai/stdout.log`, `stderr.log` | LaunchAgent logs |
| `~/Library/LaunchAgents/io.local.screenshot-ai.plist` | LaunchAgent definition |
| `~/Desktop/Screen Shot *.png` | Final landing spot for both Keep and auto-delete paths |

## Uninstall

```bash
./uninstall.sh
```

Restores the default screenshot location and removes the LaunchAgent. Leaves logs in `~/.screenshot-ai/`; `rm -rf ~/.screenshot-ai` for a clean wipe.

## Customisation

Edit `screenshot-ai.sh` and re-run `./install.sh` (it copies the script into place and reloads). Run `bash tests/e2e.sh` for the end-to-end tests. The `SCREENSHOT_AI_TTL` knob can also be set in the plist's `EnvironmentVariables` block — LaunchAgents ignore your shell env, so set it there:

| Variable | Default | Effect |
| --- | --- | --- |
| `SCREENSHOT_AI_TTL` | `300` | Seconds before an auto-delete screenshot is removed |
| `SCREENSHOT_AI_POLL` | `0.1` | Watcher poll interval (seconds) |
| `SCREENSHOT_AI_SETTLE` | `0.08` | Per-sample wait while checking the file has stopped growing (seconds) |

Other tweaks:

- **Change dialog wording** → edit `prompt_user`
- **Add a "delete now" button** → add a third button in `prompt_user`, then branch on it in `handle_screenshot`

## Troubleshooting

- **No dialog appears.** Check `~/.screenshot-ai/stderr.log` — first line should be `screenshot-ai watching ...`. If the agent isn't running, try `launchctl load ~/Library/LaunchAgents/io.local.screenshot-ai.plist`.
- **Screenshots still hit ~/Desktop.** `SystemUIServer` didn't pick up the new default. `killall SystemUIServer` and try again, or log out / back in.
- **Dialog shows on a half-written capture.** Bump `SCREENSHOT_AI_SETTLE` in the plist environment block.

## License

MIT — see [LICENSE](LICENSE).
