# screenshot-ai

A macOS background plugin that intercepts every screenshot and asks one question: **"Using this for AI?"** If yes, the file gets a 5-minute self-destruct timer so it doesn't linger on disk after you've pasted it into your AI tool. If no, it's kept normally.

It does **not** call any AI CLI — you drag/paste the file into Claude / Codex / ChatGPT yourself during the TTL window. The plugin's only job is the prompt and the auto-delete timer.

Ships with two ways to use it:

- **Background watcher** (`screenshot-ai.sh` + `install.sh`) — intercepts *every* OS screenshot system-wide.
- **Claude Code slash command** (`commands/screenshot.md`) — type `/screenshot` in any Claude Code session to capture a region, load it straight into the conversation, and auto-delete it 5 min later. See [Claude Code slash command](#claude-code-slash-command) below.

## How it works

1. On install, `defaults write com.apple.screencapture location` redirects screenshots from `~/Desktop` to a hidden staging folder (`~/.screenshot-ai/pending`).
2. A `launchd` agent runs a small bash watcher (`screenshot-ai.sh`) that polls the staging folder ~2x/sec.
3. When a new `.png` / `.jpg` appears, it waits for the file to finish writing, then shows a native macOS dialog (using the image itself as the icon) with two buttons: **Keep** and **Yes — auto-delete**.
4. Either way the file is moved to `~/Desktop` so it behaves like a normal screenshot. If you picked auto-delete, a detached `sleep $TTL && rm` is scheduled and a notification confirms the timer.

The watcher is plain bash + `osascript` — nothing to compile, no toolchain dependency.

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
- **Yes — auto-delete** *(default)* — file stays on the Desktop long enough for you to drag/paste it into your AI tool, then is removed automatically after `SCREENSHOT_AI_TTL` seconds (default 300 = 5 min).

## Claude Code slash command

`commands/screenshot.md` is a [Claude Code](https://claude.com/claude-code) slash command — same idea as the watcher, but invoked on demand from inside a chat instead of intercepting every OS screenshot. Type `/screenshot` (optionally with a question, e.g. `/screenshot what's wrong with this error?`) and it captures a region (same UI as ⌘⇧4), loads the PNG into the conversation so Claude can see it, and schedules a 5-minute auto-delete.

Install it for all your Claude Code sessions:

```bash
cp commands/screenshot.md ~/.claude/commands/screenshot.md
```

Captures land in `~/.claude/screenshots/` and self-delete after 5 minutes. macOS only; needs Screen Recording permission on first run.

## Files

| Path | Purpose |
| --- | --- |
| `~/.screenshot-ai/bin/screenshot-ai.sh` | Watcher (installed copy) |
| `~/.screenshot-ai/pending/` | Transient staging area (file lives here only between capture and dialog click) |
| `~/.screenshot-ai/stdout.log`, `stderr.log` | LaunchAgent logs |
| `~/Library/LaunchAgents/io.local.screenshot-ai.plist` | LaunchAgent definition |
| `~/Desktop/Screen Shot *.png` | Final landing spot for both Keep and auto-delete paths |
| `commands/screenshot.md` | Claude Code `/screenshot` slash command (copy to `~/.claude/commands/`) |

## Uninstall

```bash
./uninstall.sh
```

Restores the default screenshot location and removes the LaunchAgent. Leaves logs in `~/.screenshot-ai/`; `rm -rf ~/.screenshot-ai` for a clean wipe. The slash command is removed with `rm ~/.claude/commands/screenshot.md`.

## Customisation

Edit `screenshot-ai.sh` and re-run `./install.sh` (the installer just copies it into place). The `SCREENSHOT_AI_TTL` knob can also be set in the plist's `EnvironmentVariables` block — LaunchAgents ignore your shell env, so set it there:

| Variable | Default | Effect |
| --- | --- | --- |
| `SCREENSHOT_AI_TTL` | `300` | Seconds before an auto-delete screenshot is removed |

Other tweaks:

- **Change dialog wording** → edit `prompt_user`
- **Add a "delete now" button** → add a third button in `prompt_user`, then branch on it in `handle_screenshot`'s `case`

## Troubleshooting

- **No dialog appears.** Check `~/.screenshot-ai/stderr.log` — first line should be `screenshot-ai watching ...`. If the agent isn't running, try `launchctl load ~/Library/LaunchAgents/io.local.screenshot-ai.plist`.
- **Screenshots still hit ~/Desktop.** `SystemUIServer` didn't pick up the new default. `killall SystemUIServer` and try again, or log out / back in.
- **Dialog shows but image is wrong / empty.** Sometimes macOS writes screenshots in two phases; the watcher waits for the file to settle, but on a slow disk you may need to bump the `sleep` in `wait_for_settle`.
