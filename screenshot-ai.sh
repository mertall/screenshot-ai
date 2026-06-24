#!/bin/bash
# screenshot-ai watcher — when a new screenshot lands in the pending dir,
# ask the user whether it's for AI. If yes, drop it on the Desktop and
# schedule an auto-delete after SCREENSHOT_AI_TTL seconds. If no, leave it
# on the Desktop normally.
#
# Compatible with bash 3.2 (the only bash macOS ships at /bin/bash) — no
# associative arrays, no bash-4-only syntax.

set -u

BASE_DIR="$HOME/.screenshot-ai"
PENDING_DIR="$BASE_DIR/pending"
KEEP_DIR="${SCREENSHOT_AI_KEEP_DIR:-$HOME/Desktop}"
TTL_SECONDS="${SCREENSHOT_AI_TTL:-300}"        # 5 minutes
POLL_INTERVAL="${SCREENSHOT_AI_POLL:-0.5}"
SETTLE_WAIT="${SCREENSHOT_AI_SETTLE:-0.4}"

mkdir -p "$PENDING_DIR" "$KEEP_DIR"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

# Wait for the file to stop growing before we prompt or move it.
wait_for_settle() {
    local path="$1"
    local last_size=-1
    local deadline=$(( $(date +%s) + 4 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local size
        size=$(stat -f%z "$path" 2>/dev/null || echo 0)
        if [ "$size" -gt 0 ] && [ "$size" = "$last_size" ]; then
            return 0
        fi
        last_size="$size"
        sleep "$SETTLE_WAIT"
    done
}

prompt_user() {
    local path="$1"
    local display_name="$2"
    local esc_path="${path//\"/\\\"}"
    local esc_name="${display_name//\"/\\\"}"
    local minutes=$(( TTL_SECONDS / 60 ))
    # Route the dialog through System Events so it surfaces to the user
    # even when invoked from a non-foreground LaunchAgent context.
    osascript <<EOF 2>>"$BASE_DIR/stderr.log"
tell application "System Events"
    activate
    try
        set imgFile to POSIX file "$esc_path"
        set theDialog to (display dialog "Screenshot: $esc_name" & return & return & "Using this for AI?" & return & "(If yes, it will auto-delete in $minutes min.)" buttons {"Keep", "Yes — auto-delete"} default button "Yes — auto-delete" with title "Screenshot AI" with icon imgFile giving up after 600)
        return button returned of theDialog
    on error errMsg
        log "dialog error: " & errMsg
        return "Keep"
    end try
end tell
EOF
}

notify() {
    local title="$1"; local msg="$2"
    osascript -e "display notification \"${msg//\"/\\\"}\" with title \"${title//\"/\\\"}\"" 2>/dev/null || true
}

# Move a file into KEEP_DIR under the given final name, appending " (N)"
# if a file with that name already exists. Prints the final path on stdout.
relocate_unique() {
    local src="$1"
    local dst_dir="$2"
    local final_name="$3"
    local stem="${final_name%.*}"
    local ext="${final_name##*.}"
    local target="$dst_dir/$final_name"
    local i=1
    while [ -e "$target" ]; do
        target="$dst_dir/${stem} (${i}).${ext}"
        i=$((i + 1))
    done
    if mv "$src" "$target"; then
        printf '%s\n' "$target"
        return 0
    fi
    return 1
}

# Detach a sleep+rm into the background so it survives a watcher restart.
schedule_delete() {
    local path="$1"
    local ttl="$2"
    nohup /bin/bash -c 'sleep "$1" && rm -f "$2"' _ "$ttl" "$path" >/dev/null 2>&1 &
    disown 2>/dev/null || true
}

# $1 = path in pending dir, $2 = original filename
handle_screenshot() {
    local src="$1"
    local original_name="$2"

    wait_for_settle "$src"

    local choice
    choice=$(prompt_user "$src" "$original_name")

    local final
    if ! final=$(relocate_unique "$src" "$KEEP_DIR" "$original_name"); then
        log "Failed to move $src into $KEEP_DIR"
        return
    fi

    case "$choice" in
        "Yes — auto-delete")
            schedule_delete "$final" "$TTL_SECONDS"
            local minutes=$(( TTL_SECONDS / 60 ))
            notify "Screenshot AI" "Auto-delete in ${minutes} min: $(basename "$final")"
            log "AI mode: $final will be deleted in ${TTL_SECONDS}s"
            ;;
        *)
            log "Kept: $final"
            ;;
    esac
}

# Single sequential watcher: the dialog inside handle_screenshot blocks the
# loop, so a file is only ever processed once — no claim/lock needed.
watch_loop() {
    log "screenshot-ai watching $PENDING_DIR (keep dir: $KEEP_DIR, ttl: ${TTL_SECONDS}s)"
    while true; do
        shopt -s nullglob
        for f in "$PENDING_DIR"/*.png "$PENDING_DIR"/*.jpg; do
            handle_screenshot "$f" "$(basename "$f")"
        done
        shopt -u nullglob
        sleep "$POLL_INTERVAL"
    done
}

# Only start watching when executed directly. When sourced (e.g. by the e2e
# tests) the functions load but the loop doesn't run.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    watch_loop
fi
