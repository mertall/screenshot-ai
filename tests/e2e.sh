#!/bin/bash
# End-to-end tests for the screenshot-ai watcher.
#
# Sources screenshot-ai.sh (the loop is guarded so it won't start), stubs the
# interactive bits (prompt_user / notify), and drives the REAL handle_screenshot
# pipeline against throwaway temp dirs — exercising relocate_unique,
# schedule_delete, and wait_for_settle as actually shipped.
set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
export SCREENSHOT_AI_KEEP_DIR="$WORK/keep"
export SCREENSHOT_AI_TTL=2          # short TTL so the auto-delete test is fast
STAGE="$WORK/stage"
mkdir -p "$STAGE" "$SCREENSHOT_AI_KEEP_DIR"

# shellcheck source=../screenshot-ai.sh
source "$REPO_DIR/screenshot-ai.sh"

# Replace the interactive pieces. CHOICE drives what the "dialog" returns.
CHOICE="Keep"
prompt_user() { printf '%s\n' "$CHOICE"; }
notify() { :; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

make_shot() { printf 'PNGDATA' > "$1"; }   # non-empty stand-in for a real capture

echo "== test 1: auto-delete path moves file to keep dir, then removes it =="
CHOICE="Yes — auto-delete"
make_shot "$STAGE/a.png"
handle_screenshot "$STAGE/a.png" "a.png"
[ -f "$SCREENSHOT_AI_KEEP_DIR/a.png" ] && ok "landed in keep dir" || bad "not in keep dir"
[ -e "$STAGE/a.png" ] && bad "still in staging" || ok "removed from staging"
sleep 3   # TTL(2) + buffer
[ -e "$SCREENSHOT_AI_KEEP_DIR/a.png" ] && bad "auto-delete did not fire" || ok "auto-deleted after TTL"

echo "== test 2: keep path moves file and leaves it in place =="
CHOICE="Keep"
make_shot "$STAGE/b.png"
handle_screenshot "$STAGE/b.png" "b.png"
[ -f "$SCREENSHOT_AI_KEEP_DIR/b.png" ] && ok "landed in keep dir" || bad "not in keep dir"
sleep 3
[ -f "$SCREENSHOT_AI_KEEP_DIR/b.png" ] && ok "still present after TTL (no delete)" || bad "wrongly deleted"

echo "== test 3: name collision gets a ' (1)' suffix, original untouched =="
CHOICE="Keep"
printf 'ORIGINAL' > "$SCREENSHOT_AI_KEEP_DIR/c.png"   # pre-existing file
make_shot "$STAGE/c.png"
handle_screenshot "$STAGE/c.png" "c.png"
[ "$(cat "$SCREENSHOT_AI_KEEP_DIR/c.png")" = "ORIGINAL" ] && ok "original not overwritten" || bad "original clobbered"
[ -f "$SCREENSHOT_AI_KEEP_DIR/c (1).png" ] && ok "new file got ' (1)' suffix" || bad "no suffixed copy"

echo "== test 4: wait_for_settle returns on a stable file =="
make_shot "$STAGE/d.png"
start=$(date +%s)
wait_for_settle "$STAGE/d.png"
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -le 3 ] && ok "settled in ${elapsed}s" || bad "took too long (${elapsed}s)"

rm -rf "$WORK"
echo ""
echo "RESULTS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
