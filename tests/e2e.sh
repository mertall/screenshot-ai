#!/bin/bash
# End-to-end tests for the screenshot-ai watcher.
#
# Sources screenshot-ai.sh (the loop is guarded so it won't start), stubs the
# dialog via the SCREENSHOT_AI_TEST_CHOICE seam, and drives the REAL
# handle_screenshot / sweep_deletes pipeline against throwaway temp dirs.
set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
export SCREENSHOT_AI_KEEP_DIR="$WORK/keep"
export SCREENSHOT_AI_TTL=2          # short TTL so the auto-delete test is fast
STAGE="$WORK/stage"
mkdir -p "$STAGE" "$SCREENSHOT_AI_KEEP_DIR"

# Point the watcher's state at the temp work dir, then load its functions.
HOME="$WORK"
# shellcheck source=../screenshot-ai.sh
source "$REPO_DIR/screenshot-ai.sh"
DELETES_FILE="$WORK/deletes.tsv"   # re-pin after sourcing (HOME was set above)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

make_shot() { printf 'PNGDATA' > "$1"; }

echo "== test 1: auto-delete records, sweep removes after TTL =="
export SCREENSHOT_AI_TEST_CHOICE="Auto-delete"
make_shot "$STAGE/a.png"
handle_screenshot "$STAGE/a.png"
[ -f "$KEEP_DIR/a.png" ] && ok "landed in keep dir" || bad "not in keep dir"
[ -e "$STAGE/a.png" ] && bad "still in staging" || ok "removed from staging"
sweep_deletes
[ -f "$KEEP_DIR/a.png" ] && ok "survives before TTL" || bad "deleted too early"
sleep 3
sweep_deletes
[ -e "$KEEP_DIR/a.png" ] && bad "auto-delete did not fire" || ok "auto-deleted after TTL"

echo "== test 2: keep path moves file and leaves it =="
export SCREENSHOT_AI_TEST_CHOICE="Keep"
make_shot "$STAGE/b.png"
handle_screenshot "$STAGE/b.png"
[ -f "$KEEP_DIR/b.png" ] && ok "landed in keep dir" || bad "not in keep dir"
sleep 3; sweep_deletes
[ -f "$KEEP_DIR/b.png" ] && ok "still present (no delete scheduled)" || bad "wrongly deleted"

echo "== test 3: name collision gets a ' (1)' suffix, original untouched =="
export SCREENSHOT_AI_TEST_CHOICE="Keep"
printf 'ORIGINAL' > "$KEEP_DIR/c.png"
make_shot "$STAGE/c.png"
handle_screenshot "$STAGE/c.png"
[ "$(cat "$KEEP_DIR/c.png")" = "ORIGINAL" ] && ok "original not overwritten" || bad "original clobbered"
[ -f "$KEEP_DIR/c (1).png" ] && ok "new file got ' (1)' suffix" || bad "no suffixed copy"

echo "== test 4: wait_for_settle returns on a stable file =="
make_shot "$STAGE/d.png"
start=$(date +%s)
wait_for_settle "$STAGE/d.png"
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -le 3 ] && ok "settled in ${elapsed}s" || bad "took too long (${elapsed}s)"

unset SCREENSHOT_AI_TEST_CHOICE
rm -rf "$WORK"
echo ""
echo "RESULTS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
