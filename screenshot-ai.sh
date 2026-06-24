#!/bin/bash
# screenshot-ai watcher — when a new screenshot lands in the pending dir, ask
# the user whether it's for AI. If yes, drop it on the Desktop and record a
# delete time; if no, leave it. A poll-tick sweep deletes due files.
#
# Compatible with bash 3.2 (the only bash macOS ships at /bin/bash).

set -u

BASE_DIR="$HOME/.screenshot-ai"
PENDING_DIR="$BASE_DIR/pending"
KEEP_DIR="${SCREENSHOT_AI_KEEP_DIR:-$HOME/Desktop}"
DELETES_FILE="$BASE_DIR/deletes.tsv"
HELPER_BIN="$BASE_DIR/bin/cursorpaste"
TTL_SECONDS="${SCREENSHOT_AI_TTL:-300}"        # 5 minutes
POLL_INTERVAL="${SCREENSHOT_AI_POLL:-0.1}"
SETTLE_WAIT="${SCREENSHOT_AI_SETTLE:-0.08}"

mkdir -p "$PENDING_DIR" "$KEEP_DIR"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

# Wait for the file to stop growing before we prompt or move it, so we never
# act on a half-written capture. Two equal non-zero size samples, or a 4s cap.
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
    # Test seam: bypass the real dialog so the pipeline is testable.
    if [ -n "${SCREENSHOT_AI_TEST_CHOICE:-}" ]; then
        printf '%s\n' "$SCREENSHOT_AI_TEST_CHOICE"
        return
    fi
    # No "with icon <image>": using the raw screenshot decodes a multi-MB Retina
    # PNG and adds ~2.5s of lag. A stock "note" icon is instant.
    osascript <<EOF 2>>"$BASE_DIR/stderr.log"
tell application "System Events"
    activate
    try
        set theDialog to (display dialog "Using this for AI?" buttons {"Keep", "Auto-delete"} default button "Auto-delete" with title "Screenshot AI" with icon note giving up after 600)
        return button returned of theDialog
    on error
        return "Keep"
    end try
end tell
EOF
}

notify() {
    local msg="$1"
    osascript -e "display notification \"${msg//\"/\\\"}\" with title \"Screenshot AI\"" 2>/dev/null || true
}

# Move a file into KEEP_DIR under the given name, appending " (N)" if a file
# with that name already exists so we never clobber an existing capture.
# Prints the final path on stdout.
move_to_keep() {
    local src="$1"
    local final_name="$2"
    local stem="${final_name%.*}"
    local ext="${final_name##*.}"
    local target="$KEEP_DIR/$final_name"
    local i=1
    while [ -e "$target" ]; do
        target="$KEEP_DIR/${stem} (${i}).${ext}"
        i=$((i + 1))
    done
    if mv "$src" "$target"; then
        printf '%s\n' "$target"
        return 0
    fi
    return 1
}

# Record a file to delete at now+TTL. Persisted to disk so the schedule
# survives watcher reloads, logout, and reboots — a spawned "sleep && rm" would
# be a child of the launchd job and get killed on every reload.
mark_for_delete() {
    local path="$1"
    printf '%s\t%s\n' "$(( $(date +%s) + TTL_SECONDS ))" "$path" >> "$DELETES_FILE"
}

# Delete any recorded file whose time has come (or that's already gone) and
# rewrite the schedule with what's left. Called every poll tick.
sweep_deletes() {
    [ -f "$DELETES_FILE" ] || return
    local now tmp when path
    now=$(date +%s)
    tmp="$(mktemp "${TMPDIR:-/tmp}/ssai-del.XXXXXX")"
    while IFS=$'\t' read -r when path; do
        # drop malformed lines or already-gone files
        case "$when" in ''|*[!0-9]*) continue;; esac
        [ -n "$path" ] && [ -e "$path" ] || continue
        if [ "$now" -ge "$when" ]; then
            rm -f "$path" && log "auto-deleted: $path"
        else
            printf '%s\t%s\n' "$when" "$path" >> "$tmp"
        fi
    done < "$DELETES_FILE"
    mv "$tmp" "$DELETES_FILE"
}

handle_screenshot() {
    local src="$1"
    local original_name
    original_name="$(basename "$src")"

    wait_for_settle "$src"

    local choice
    choice=$(prompt_user)

    local final
    if ! final=$(move_to_keep "$src" "$original_name"); then
        log "Failed to move $src into $KEEP_DIR"
        return
    fi

    if [ "$choice" = "Auto-delete" ]; then
        # Float the screenshot on the cursor — click to paste it into your AI
        # tool, Esc to skip. Only if the Swift helper is built; harmless without.
        if [ -x "$HELPER_BIN" ]; then
            "$HELPER_BIN" "$final" >/dev/null 2>>"$BASE_DIR/stderr.log" || true
        fi
        mark_for_delete "$final"
        notify "Auto-delete in $(( TTL_SECONDS / 60 )) min: $(basename "$final")"
        log "AI mode: $final will be deleted in ${TTL_SECONDS}s"
    else
        log "Kept: $final"
    fi
}

# Single sequential watcher: the blocking dialog inside handle_screenshot means
# a file is only ever processed once — no claim/lock needed. Globs skip the
# hidden ".Screenshot ….png" macOS writes mid-capture (dotfiles don't match *).
watch_loop() {
    log "screenshot-ai watching $PENDING_DIR (keep dir: $KEEP_DIR, ttl: ${TTL_SECONDS}s)"
    while true; do
        sweep_deletes
        shopt -s nullglob
        for f in "$PENDING_DIR"/*.png "$PENDING_DIR"/*.jpg; do
            handle_screenshot "$f"
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
