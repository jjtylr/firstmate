#!/usr/bin/env bash
# Behavior tests for bin/fm-alert-wake.sh - the Bridge's wake for an alert its
# mate has not written under.
#
# The command runs from a copy of bin/ whose lifecycle and transport helpers
# (fm-control.sh, fm-remote-secondmate-relaunch.sh, fm-on.sh) are recording
# stubs, and the local endpoint state comes from a fake tmux. Local notes go
# through the real bin/fm-inbox.sh, so a replayed request id is proven against
# its owner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(fm_test_tmproot fm-alert-wake)
CODE=$T/code
HOME_DIR=$T/home
SM_HOME=$T/sm1-home
CALLS=$T/calls
FAKEBIN=$(fm_fakebin "$T/fake")
mkdir -p "$CODE" "$HOME_DIR/data" "$HOME_DIR/state"
cp -R "$ROOT/bin" "$CODE/bin"

cat > "$CODE/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf 'control %s\n' "$*" >> "$FM_FAKE_CALLS"
if [ -n "${FM_FAKE_HOLD:-}" ]; then
  for _ in $(seq 1 300); do [ -e "$FM_FAKE_HOLD" ] || break; sleep 0.1; done
  : > "$FM_FAKE_CALLS.finished"
fi
[ -z "${FM_FAKE_RELAUNCH_FAIL:-}" ] || { echo 'error: the replacement agent did not come up' >&2; exit 1; }
SH
cat > "$CODE/bin/fm-remote-secondmate-relaunch.sh" <<'SH'
#!/usr/bin/env bash
printf 'remote-relaunch %s\n' "$*" >> "$FM_FAKE_CALLS"
[ -z "${FM_FAKE_RELAUNCH_FAIL:-}" ] || { echo 'error: the host refused the relaunch' >&2; exit 1; }
SH
cat > "$CODE/bin/fm-on.sh" <<'SH'
#!/usr/bin/env bash
stdin=0
if [ "$1" = --stdin ]; then stdin=1; shift; fi
printf 'on stdin=%s %s\n' "$stdin" "$*" >> "$FM_FAKE_CALLS"
case "$2 ${3:-}" in
  'fm-inbox.sh note')
    cat > "$FM_FAKE_CALLS.remote-body"
    exit "${FM_FAKE_REMOTE_NOTE_RC:-0}"
    ;;
  'fm-remote-secondmate-control.sh state')
    [ "$FM_FAKE_REMOTE_STATE" != unreachable ] || exit 255
    printf '%s\n' "$FM_FAKE_REMOTE_STATE"
    ;;
  *) exit 90 ;;
esac
SH

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message)
    case "$FM_FAKE_PANE" in missing|unreadable) exit 1 ;; esac
    case "$*" in *pane_current_command*) printf '%s\n' "$FM_FAKE_PANE" ;; esac
    ;;
  list-windows)
    case "$FM_FAKE_PANE" in
      missing) printf 'main\n' ;;
      unreadable) echo 'permission denied' >&2; exit 1 ;;
      *) printf 'fm-sm1\n' ;;
    esac
    ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"

reset_world() {
  rm -rf "$HOME_DIR/state" "$SM_HOME" "$CALLS" "$CALLS.remote-body" "$CALLS.finished"
  mkdir -p "$HOME_DIR/state" "$SM_HOME"
  printf 'sm1\n' > "$SM_HOME/.fm-secondmate-home"
  : > "$CALLS"
  cat > "$HOME_DIR/data/secondmates.md" <<EOF
# Second mates

- sm1 - Own alpha. (home: $SM_HOME; scope: Alpha work; projects: alpha; added 2026-01-02)
- far - Own beta remotely. (host: box-2; root: /srv/fm; home: /srv/fm-home; scope: Beta work; projects: beta; added 2026-01-03)
EOF
  fm_write_meta "$HOME_DIR/state/sm1.meta" \
    "window=sess:fm-sm1" "worktree=$SM_HOME" "home=$SM_HOME" \
    "harness=claude" "kind=secondmate"
  fm_write_meta "$HOME_DIR/state/far.meta" \
    "window=remote:far" "worktree=/srv/fm-home" "home=/srv/fm-home" \
    "harness=claude" "model=" "effort=high" "kind=secondmate" \
    "remote_host=box-2" "remote_backend=herdr"
}

wake_env() {
  env PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_FAKE_CALLS="$CALLS" \
    FM_FAKE_PANE="${PANE:-claude}" FM_FAKE_REMOTE_STATE="${REMOTE_STATE:-alive}" \
    FM_FAKE_REMOTE_NOTE_RC="${REMOTE_NOTE_RC:-0}" \
    FM_FAKE_RELAUNCH_FAIL="${RELAUNCH_FAIL:-}" FM_FAKE_HOLD="${HOLD:-}" \
    "$CODE/bin/fm-alert-wake.sh" "$@"
}

# Background checks end with exactly one outcome line in the mate's log.
outcome_count() {  # <mate-id>
  grep -cE 'note only:|relaunched |relaunch of .* (failed|not attempted)' \
    "$HOME_DIR/state/.alert-wake-$1.log" 2>/dev/null || true
}

wait_until() {  # <label> <command...>
  local label=$1
  shift
  for _ in $(seq 1 200); do
    "$@" && return 0
    sleep 0.1
  done
  fail "timed out waiting for $label"
}

outcomes_reach() {  # <mate-id> <count>
  [ "$(outcome_count "$1")" -ge "$2" ] 2>/dev/null
}

# run_wake <args...>: sets OUT (stdout and stderr together), RC, and, once any
# background check it started has ended, LOGGED (that mate's log).
run_wake() {
  local before
  before=$(outcome_count "$1")
  RC=0
  OUT=$(wake_env "$@" 2>&1) || RC=$?
  LOGGED=
  case "$OUT" in
    *'in the background'*)
      wait_until "the background check of $1" outcomes_reach "$1" "$((${before:-0} + 1))"
      LOGGED=$(cat "$HOME_DIR/state/.alert-wake-$1.log")
      ;;
  esac
}

note_count() {  # <home>
  find "$1/state/inbox" -name '*.note' 2>/dev/null | wc -l | tr -d ' '
}

note_text() {  # <home>
  cat "$1/state/inbox"/*.note 2>/dev/null
}

assert_no_relaunch() {  # <label>
  assert_no_grep 'control ' "$CALLS" "$1: a local relaunch ran"
  assert_no_grep 'remote-relaunch ' "$CALLS" "$1: a remote relaunch ran"
}

# --- main: the note only, with its wake ---------------------------------------
reset_world
run_wake main alerts-darkpoolz 42 'Feed silent: da_hrl_lmps' 15
expect_code 0 "$RC" "main wake"$'\n'"$OUT"
assert_equals 1 "$(note_count "$HOME_DIR")" "main should get one note"
assert_contains "$(note_text "$HOME_DIR")" \
  'Alert 42 on board alerts-darkpoolz not written under for 15 minutes: Feed silent: da_hrl_lmps' \
  "the note should name the board, the alert, the wait, and the title"
assert_contains "$(note_text "$HOME_DIR")" 'request_id=alert-wake-42-1' "first wake's request id"
assert_grep 'captain inbox note' "$HOME_DIR/state/.wake-queue" "the note should bring a wake"
assert_contains "$OUT" 'nothing in firstmate restarts main' "main should be reported as note only"
assert_no_relaunch main
pass "main gets a note with its wake and nothing else"

# --- one note per wake count ---------------------------------------------------
run_wake main alerts-darkpoolz 42 'Feed silent: da_hrl_lmps' 29
expect_code 0 "$RC" "repeat inside one count"$'\n'"$OUT"
assert_equals 1 "$(note_count "$HOME_DIR")" "a repeat of the same wake count must not duplicate the note"
assert_equals 1 "$(grep -c 'captain inbox note' "$HOME_DIR/state/.wake-queue")" \
  "a repeat of the same wake count must not wake twice"
NOTE_FILE=$(find "$HOME_DIR/state/inbox" -name '*.note')
mkdir -p "$HOME_DIR/state/inbox/handled"
mv "$NOTE_FILE" "$HOME_DIR/state/inbox/handled/"
run_wake main alerts-darkpoolz 42 'Feed silent: da_hrl_lmps' 30
expect_code 0 "$RC" "second wake"$'\n'"$OUT"
assert_equals 2 "$(note_count "$HOME_DIR")" "the next wake should add exactly one note"
assert_contains "$(note_text "$HOME_DIR")" 'request_id=alert-wake-42-2' \
  "the next 15-minute wake should write a fresh note"
assert_equals 2 "$(grep -c 'captain inbox note' "$HOME_DIR/state/.wake-queue")" \
  "the next wake should wake the mate again after the first note was read"
reset_world
run_wake main alerts-darkpoolz 42 --json 0
expect_code 0 "$RC" "short wait"$'\n'"$OUT"
assert_contains "$(note_text "$HOME_DIR")" 'request_id=alert-wake-42-1' "the count is at least 1"
assert_contains "$(note_text "$HOME_DIR")" 'minutes: --json' "an option-like title is plain text"
pass "each wake count writes exactly one note"

# --- a down local mate is started ----------------------------------------------
for pane in zsh missing; do
  reset_world
  PANE=$pane
  FM_STATE_OVERRIDE="$HOME_DIR/state" run_wake sm1 alerts-alpha 7 'Job failed' 15
  unset PANE
  expect_code 0 "$RC" "down local mate ($pane)"$'\n'"$OUT"
  assert_equals 1 "$(note_count "$SM_HOME")" "the note belongs in the mate's own home ($pane)"
  assert_equals 0 "$(note_count "$HOME_DIR")" "the primary inbox must not get the mate's note ($pane)"
  assert_grep 'captain inbox note' "$SM_HOME/state/.wake-queue" "the mate's own queue gets the wake ($pane)"
  assert_equals 'control sm1 relaunch' "$(cat "$CALLS")" "a down local mate is relaunched once ($pane)"
  assert_contains "$LOGGED" 'relaunched sm1' "the relaunch should be logged ($pane)"
done
pass "a local mate proven not running is relaunched through fm-control"

# --- a live or unclear local mate gets the note only ----------------------------
for pane in claude node unreadable; do
  reset_world
  PANE=$pane
  run_wake sm1 alerts-alpha 7 'Job failed' 15
  unset PANE
  expect_code 0 "$RC" "local mate reading $pane"$'\n'"$OUT"
  assert_equals 1 "$(note_count "$SM_HOME")" "note expected ($pane)"
  assert_contains "$LOGGED" 'note only' "note-only outcome expected ($pane)"
  assert_no_relaunch "local $pane"
done
reset_world
rm "$HOME_DIR/state/sm1.meta"
PANE=zsh run_wake sm1 alerts-alpha 7 'Job failed' 15
expect_code 0 "$RC" "mate without a record"$'\n'"$OUT"
assert_contains "$LOGGED" 'no second mate record' "a missing record is unclear"
assert_no_relaunch "no record"
reset_world
printf 'remote_host=box-9\n' >> "$HOME_DIR/state/sm1.meta"
PANE=zsh run_wake sm1 alerts-alpha 7 'Job failed' 15
expect_code 0 "$RC" "mate whose records disagree"$'\n'"$OUT"
assert_contains "$LOGGED" 'disagree on where sm1 runs' "disagreeing records are unclear"
assert_no_relaunch "records disagree"
pass "a live or unclear local mate gets the note only"

# --- another supervisor mid-episode keeps the mate to itself ---------------------
reset_world
FM_HOME="$HOME_DIR" bash -c '
  STATE=$1/state
  . "$2/fm-secondmate-liveness-lib.sh"
  fm_secondmate_liveness_lock sm1 || exit 1
  : > "$3"
  while [ -e "$3" ]; do sleep 0.1; done
  fm_secondmate_liveness_unlock sm1
' _ "$HOME_DIR" "$CODE/bin" "$T/lock-held" &
HOLDER=$!
for _ in $(seq 1 100); do [ -e "$T/lock-held" ] && break; sleep 0.1; done
assert_present "$T/lock-held" "the fixture never took the liveness lock"
PANE=zsh run_wake sm1 alerts-alpha 7 'Job failed' 15
rm -f "$T/lock-held"
wait "$HOLDER"
expect_code 0 "$RC" "locked mate"$'\n'"$OUT"
assert_contains "$LOGGED" 'is in progress' "a held liveness lock should be reported"
assert_no_relaunch "locked"
PANE=zsh run_wake sm1 alerts-alpha 7 'Job failed' 30
assert_grep 'control sm1 relaunch' "$CALLS" "the lock should be free again afterwards"
pass "a mate another liveness episode holds is not relaunched"

# --- the command returns before the relaunch finishes ----------------------------
reset_world
: > "$T/hold"
RC=0
# The command substitution returns only once nothing holds its output open.
OUT=$(PANE=zsh HOLD="$T/hold" wake_env sm1 alerts-alpha 7 'Job failed' 15 2>&1) || RC=$?
expect_code 0 "$RC" "wake with a slow relaunch"$'\n'"$OUT"
assert_absent "$CALLS.finished" "the command must return before the relaunch finishes"
assert_contains "$OUT" 'checking sm1 in the background' "the handoff should be reported"
wait_until "the relaunch to start" grep -q '^control sm1 relaunch$' "$CALLS"
PANE=zsh run_wake sm1 alerts-alpha 7 'Job failed' 30
assert_contains "$LOGGED" 'is in progress' "the running relaunch should still hold the liveness lock"
assert_equals 1 "$(grep -c '^control ' "$CALLS")" "a mate mid-relaunch must not be relaunched again"
rm -f "$T/hold"
wait_until "the held relaunch to be logged" outcomes_reach sm1 2
assert_present "$CALLS.finished" "the background relaunch should run to completion"
assert_grep 'relaunched sm1' "$HOME_DIR/state/.alert-wake-sm1.log" "its success should be logged"
pass "the command returns while the relaunch still runs under the liveness lock"

# --- a caller that kills its process group does not stop the relaunch -------------
reset_world
: > "$T/hold"
set -m
( PANE=zsh HOLD="$T/hold" wake_env sm1 alerts-alpha 7 'Job failed' 15; sleep 30 ) > "$T/caller.out" 2>&1 &
CALLER=$!
set +m
wait_until "the relaunch to start" grep -q '^control sm1 relaunch$' "$CALLS"
kill -KILL -- "-$CALLER" || fail "could not kill the caller's process group"
wait "$CALLER" 2>/dev/null || true
rm -f "$T/hold"
wait_until "the relaunch to outlive its caller" outcomes_reach sm1 1
assert_present "$CALLS.finished" "the relaunch should survive the caller's process group"
pass "killing the caller's process group leaves the relaunch running"

# --- a down remote mate is started through the remote helper ---------------------
for state in dead missing; do
  reset_world
  REMOTE_STATE=$state run_wake far alerts-beta 9 'Feed silent' 45
  expect_code 0 "$RC" "down remote mate ($state)"$'\n'"$OUT"
  assert_grep 'on stdin=1 far fm-inbox.sh note --request-id alert-wake-9-3 -' "$CALLS" \
    "the note should be written in the remote mate's home ($state)"
  assert_equals 'Alert 9 on board alerts-beta not written under for 45 minutes: Feed silent' \
    "$(cat "$CALLS.remote-body")" "remote note body ($state)"
  assert_grep 'remote-relaunch far claude default high' "$CALLS" \
    "the remote relaunch takes the recorded profile ($state)"
  assert_no_grep 'control ' "$CALLS" "a remote mate is never relaunched locally ($state)"
done
pass "a remote mate proven not running is relaunched through the remote helper"

for state in alive ambiguous unreadable unverified unreachable; do
  reset_world
  REMOTE_STATE=$state run_wake far alerts-beta 9 'Feed silent' 15
  expect_code 0 "$RC" "remote mate reading $state"$'\n'"$OUT"
  assert_grep 'fm-inbox.sh note' "$CALLS" "note expected ($state)"
  assert_contains "$LOGGED" 'note only' "note-only outcome expected ($state)"
  assert_no_relaunch "remote $state"
done
pass "a live or unclear remote mate gets the note only"

# --- a failed relaunch still succeeds and says why --------------------------------
reset_world
PANE=zsh RELAUNCH_FAIL=1 run_wake sm1 alerts-alpha 7 'Job failed' 15
expect_code 0 "$RC" "failed local relaunch"$'\n'"$OUT"
assert_contains "$LOGGED" 'relaunch of sm1 failed (exit 1)' "local failure should be logged"
assert_contains "$LOGGED" 'the replacement agent did not come up' "local failure reason"
assert_equals 1 "$(note_count "$SM_HOME")" "the note survives a failed relaunch"
reset_world
REMOTE_STATE=dead RELAUNCH_FAIL=1 run_wake far alerts-beta 9 'Feed silent' 15
expect_code 0 "$RC" "failed remote relaunch"$'\n'"$OUT"
assert_contains "$LOGGED" 'the host refused the relaunch' "remote failure reason"
pass "a failed relaunch exits 0 after the note and reports why"

# --- the note decides the exit status ---------------------------------------------
reset_world
REMOTE_STATE=dead REMOTE_NOTE_RC=255 run_wake far alerts-beta 9 'Feed silent' 15
expect_code 1 "$RC" "unconfirmed remote note"$'\n'"$OUT"
assert_no_relaunch "unconfirmed note"
reset_world
REMOTE_STATE=dead REMOTE_NOTE_RC=3 run_wake far alerts-beta 9 'Feed silent' 15
expect_code 0 "$RC" "saved note with no wake"$'\n'"$OUT"
assert_contains "$OUT" 'wake was not queued' "a missing wake should be reported"
assert_grep 'remote-relaunch far' "$CALLS" "a saved note still lets the down mate start"
reset_world
mkdir "$HOME_DIR/state/.alert-wake-sm1.log"
PANE=zsh run_wake sm1 alerts-alpha 7 'Job failed' 15
expect_code 0 "$RC" "unwritable log"$'\n'"$OUT"
assert_contains "$OUT" 'sm1 was not checked' "an unstartable check should be reported"
assert_no_relaunch "unwritable log"
reset_world
printf 'other\n' > "$SM_HOME/.fm-secondmate-home"
PANE=zsh run_wake sm1 alerts-alpha 7 'Job failed' 15
expect_code 1 "$RC" "home seeded for another mate"$'\n'"$OUT"
assert_absent "$SM_HOME/state" "nothing may be written into another mate's home"
assert_no_relaunch "wrong home"
reset_world
run_wake nobody alerts-alpha 7 'Job failed' 15
expect_code 1 "$RC" "unknown mate"$'\n'"$OUT"
run_wake main alerts-alpha 7 'Job failed'
expect_code 2 "$RC" "missing argument"
run_wake main alerts-alpha 7 'Job failed' soon
expect_code 2 "$RC" "non-numeric minutes"
run_wake main alerts-alpha 'a/b' 'Job failed' 15
expect_code 2 "$RC" "unsafe alert id"
assert_equals 0 "$(note_count "$HOME_DIR")" "a refused call writes no note"
pass "an unwritten note or a bad call fails without relaunching"
