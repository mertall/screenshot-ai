---
description: Capture a screen region (macOS, same UI as Cmd+Shift+4), load the image into the conversation, and auto-delete the file after 5 minutes.
category: utility
---

Run this bash block via the Bash tool exactly as written. It triggers macOS's interactive region selector (same UI as ⌘⇧4), saves a PNG, schedules an auto-delete in 300 seconds via a detached background process, and prints the absolute path on stdout.

```bash
DIR="$HOME/.claude/screenshots"
mkdir -p "$DIR"
path="$DIR/capture-$(date +%Y%m%d-%H%M%S)-$$.png"
/usr/sbin/screencapture -i -x -t png "$path"
if [ ! -f "$path" ]; then
    echo "CANCELLED: no screenshot was saved (Esc pressed?)" >&2
    exit 1
fi
nohup /bin/bash -c 'sleep "$1" && rm -f "$2"' _ 300 "$path" >/dev/null 2>&1 &
disown 2>/dev/null || true
echo "$path"
```

Then:

1. If Bash exited non-zero, the user cancelled the region selector — tell them and stop. Do not invoke Read.
2. If Bash succeeded, the **last line of stdout is the absolute path** to the PNG. Immediately use the **Read** tool on that path so the image is loaded into the conversation context (the Read tool renders images visually).
3. The file is already scheduled to be deleted in 5 minutes by a detached `nohup bash -c 'sleep 300 && rm -f …'` — do not write any additional cleanup logic.
4. If the user supplied a question along with `/screenshot` (e.g. `/screenshot what's wrong with this error?`), answer that question about the captured image. If they invoked it with no further text, briefly describe what's in the image and ask what they'd like to do with it.

Notes:
- macOS only. The captured terminal/host app needs **Screen Recording** permission (System Settings → Privacy & Security → Screen Recording) — the first run will prompt.
- The captured file lives in `~/.claude/screenshots/` until the auto-delete fires. To recover one before deletion: `ps -ef | grep 'sleep 300' | grep -v grep` to find the timer PID, then `kill <pid>` to abort.
- Do not ask the user to confirm before running the bash block — just run it. The region selector is the confirmation.
