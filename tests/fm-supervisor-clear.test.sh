#!/usr/bin/env bash
# bin/fm-supervisor-clear.sh: the supervisor clear policy.
#
# What these pin, through the real command against real conversation-size
# reads (bin/fm-context-size.sh over a fixture session log), the real semantic
# busy-state record, and a tmux stand-in that renders a Claude pane:
#
#   1. Second mates: over the soft size and idle they are restarted with their
#      recorded profile kept; busy under the hard size they are left alone; at
#      the hard size a busy mate is restarted anyway; one attempt per retry
#      window; a reading older than the last restart is ignored.
#   2. Main: told once at the soft size and once more at the hard size, never
#      repeatedly; nothing below the soft size; thresholds come from
#      config/supervisor-clear, and an invalid file is reported once.
#   3. The /clear guard: /clear is typed only into a recorded, idle, quiet pane
#      with an empty input box that did not change between two reads, and
#      never while text waits in the box, a turn is in progress, the pane is
#      changing, or a model call just ran. A typed clear is confirmed by main's
#      session start re-recording its endpoint, and logged with its size.
#   4. At the hard size, a save that could not be acted on safely, or a runtime
#      that cannot be cleared, becomes one line for the captain.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLEAR="$ROOT/bin/fm-supervisor-clear.sh"
TMP_ROOT=$(fm_test_tmproot fm-supervisor-clear)

IDLE_SCREEN=$'done.\n────────\n❯ \n────────\n  ? for shortcuts'
TYPED_SCREEN=$'done.\n────────\n❯ hel\n────────\n  ? for shortcuts'
BUSY_SCREEN=$'✻ Working… (12s · esc to interrupt)\n────────\n❯ \n────────\n  ? for shortcuts'

# A tmux stand-in for main's pane %7: it renders $D/screen with the cursor on
# the input row, records literal text and keys, and runs $D/on-enter when
# Enter arrives (a /clear that Claude acts on re-runs session start). With
# $D/animate present each read of the pane differs.
make_case() {  # <name> -> case dir
  local dir="$TMP_ROOT/$1-$RANDOM" fb
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/fake" "$dir/userhome"
  fb="$dir/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
D=$FM_FAKE_DIR
render() {
  cat "$D/screen"
  if [ -e "$D/animate" ]; then
    n=$(( $(cat "$D/reads" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$D/reads"
    printf '\ntick %s' "$n"
  fi
  printf '\n'
}
case "${1:-}" in
  list-panes) printf '%%7\n' ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '2\n'; exit 0 ;;
        *pane_current_command*) printf 'claude\n'; exit 0 ;;
        *pane_tty*) exit 0 ;;
      esac
    done
    printf '%%7\n' ;;
  capture-pane) render ;;
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$1" >> "$D/literal"
    else
      printf '%s\n' "$1" >> "$D/keys"
      if [ "$1" = Enter ] && [ -x "$D/on-enter" ]; then "$D/on-enter"; fi
    fi ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s' "$IDLE_SCREEN" > "$dir/fake/screen"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf '%s\n' "$dir"
}

# A Claude session log whose newest model call used <tokens>, <age> seconds ago.
write_log() {  # <case-dir> <cwd> <tokens> [age]
  local dir=$1 cwd=$2 tokens=$3 age=${4:-120} proj stamp
  proj="$dir/userhome/.claude/projects/$(printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$proj"
  stamp=$(python3 -I -c 'import datetime,sys,time; print(datetime.datetime.fromtimestamp(time.time()-int(sys.argv[1]),datetime.timezone.utc).isoformat())' "$age")
  printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","model":"claude-opus-5-5","usage":{"input_tokens":%s,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' \
    "$stamp" "$tokens" > "$proj/session.jsonl"
}

write_main_record() {  # <case-dir> [harness] [backend]
  local dir=$1
  mkdir -p "$dir/home/state/supervisor-clear"
  {
    echo "backend=${3:-tmux}"
    echo "target=%7"
    echo "harness=${2:-claude}"
    echo "worktree=$dir/home"
    echo "account=ordinary"
    echo "recorded_at=1"
  } > "$dir/home/state/supervisor-clear/main.endpoint"
}

add_mate() {  # <case-dir> <id> <busy|idle>
  local dir=$1 id=$2 smhome="$1/$2-home"
  mkdir -p "$smhome"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "model=claude-opus-5-5"
    echo "effort=high"
    echo "home=$smhome"
  } > "$dir/home/state/$id.meta"
  "$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" "$id" --state "$3" \
    --source claude-hook --event Stop >/dev/null
}

# A restart command that records how it was called.
arm_restart_recorder() {  # <case-dir>
  cat > "$1/restart" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$1/fake/restarts"
echo "restarted: \${@: -1} (claude)"
echo "summary: 1 of 1 restarted, 0 nudged, 0 unreached"
SH
  chmod +x "$1/restart"
}

run_clear() {  # <case-dir> <args...>
  local dir=$1; shift
  env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u CLAUDE_CONFIG_DIR \
    PATH="$dir/fakebin:$PATH" HOME="$dir/userhome" FM_HOME="$dir/home" \
    FM_FAKE_DIR="$dir/fake" FM_SUPERVISOR_CLEAR_RESTART="$dir/restart" \
    FM_SUPERVISOR_CLEAR_SETTLE="${SETTLE:-1}" FM_SUPERVISOR_CLEAR_QUIET=0 \
    FM_SUPERVISOR_CLEAR_CONFIRM=3 FM_SUPERVISOR_TARGET=%7 FM_SUPERVISOR_BACKEND=tmux \
    "$CLEAR" "$@" 2>&1
}

wait_for_file() {  # <path> [tries]
  local n=0
  while [ ! -s "$1" ] && [ "$n" -lt "${2:-100}" ]; do sleep 0.05; n=$((n + 1)); done
  [ -s "$1" ]
}

log_of() { cat "$1/home/state/supervisor-clear/clear.log" 2>/dev/null; }

# --- second mates ------------------------------------------------------------

test_idle_mate_over_soft_is_restarted_on_its_profile() {
  local dir out
  dir=$(make_case mate-idle)
  arm_restart_recorder "$dir"
  add_mate "$dir" sm1 idle
  write_log "$dir" "$dir/sm1-home" 160000
  out=$(run_clear "$dir" tick)
  assert_equals "" "$out" "a mate restart must not wake main"
  wait_for_file "$dir/fake/restarts" || fail "an idle mate over the soft size was not restarted"
  assert_equals "--keep-profile --reason context sm1" "$(cat "$dir/fake/restarts")" \
    "the restart must keep the mate's recorded profile and say why"
  wait_for_file "$dir/home/state/supervisor-clear/sm1.restarted" || fail "the restart was not recorded"
  assert_contains "$(log_of "$dir")" $'sm1\t160000\trestart-requested\tsoft' "the request must be logged with its size"
  assert_contains "$(log_of "$dir")" $'sm1\t160000\trestarted' "the restart must be logged"
  pass "an idle mate over the soft size is restarted on its recorded profile"
}

test_busy_mate_waits_until_hard() {
  local dir
  dir=$(make_case mate-busy)
  arm_restart_recorder "$dir"
  add_mate "$dir" sm1 busy
  write_log "$dir" "$dir/sm1-home" 170000
  run_clear "$dir" tick >/dev/null
  sleep 0.5
  assert_absent "$dir/fake/restarts" "a busy mate under the hard size must be left to finish"
  write_log "$dir" "$dir/sm1-home" 205000
  run_clear "$dir" tick >/dev/null
  wait_for_file "$dir/fake/restarts" || fail "a busy mate at the hard size was not restarted"
  assert_contains "$(log_of "$dir")" $'sm1\t205000\trestart-requested\thard' "the hard restart must be logged"
  pass "a busy mate waits for its idle moment until the hard size"
}

test_mate_attempts_are_spaced_and_old_readings_ignored() {
  local dir
  dir=$(make_case mate-retry)
  arm_restart_recorder "$dir"
  add_mate "$dir" sm1 idle
  write_log "$dir" "$dir/sm1-home" 120000
  run_clear "$dir" tick >/dev/null
  sleep 0.3
  assert_absent "$dir/fake/restarts" "a mate under the soft size must not be restarted"
  write_log "$dir" "$dir/sm1-home" 160000
  run_clear "$dir" tick >/dev/null
  wait_for_file "$dir/home/state/supervisor-clear/sm1.restarted" || fail "first restart missing"
  run_clear "$dir" tick >/dev/null
  sleep 0.3
  assert_equals 1 "$(wc -l < "$dir/fake/restarts" | tr -d ' ')" "a second pass inside the retry window must not restart again"
  # Past the retry window, the log still shows the call from before the restart.
  FM_SUPERVISOR_CLEAR_RETRY=0 run_clear "$dir" tick >/dev/null
  sleep 0.3
  assert_equals 1 "$(wc -l < "$dir/fake/restarts" | tr -d ' ')" "a reading older than the restart must be ignored"
  pass "mate restarts are spaced, and a reading from before a restart is ignored"
}

# A restart that did not complete but left the mate running is a failure: it is
# logged with its reason, and never recorded as a restart.
test_failed_restart_with_the_mate_running_is_logged_as_a_failure() {
  local dir line
  dir=$(make_case mate-failed)
  line='failed: sm1: the restart did not complete: the replacement agent for sm1 did not come up within 90s; a fresh agent was started in its place and is running'
  cat > "$dir/restart" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$dir/fake/restarts"
echo "$line"
echo "summary: 0 of 1 restarted, 0 nudged, 0 unreached, 1 failed"
exit 3
SH
  chmod +x "$dir/restart"
  add_mate "$dir" sm1 idle
  write_log "$dir" "$dir/sm1-home" 160000
  run_clear "$dir" tick >/dev/null
  wait_for_file "$dir/fake/restarts" || fail "the restart was not requested"
  local n=0
  while ! log_of "$dir" | grep -q restart-failed && [ "$n" -lt 100 ]; do sleep 0.05; n=$((n + 1)); done
  assert_contains "$(log_of "$dir")" "$(printf 'sm1\t160000\trestart-failed\t%s' "$line")" \
    "the failure must be logged with the mate's own outcome line"
  assert_not_contains "$(log_of "$dir")" $'\trestarted\t' "a failed restart must not be logged as a restart"
  assert_absent "$dir/home/state/supervisor-clear/sm1.restarted" "a failed restart must not be recorded as one"
  pass "a restart that failed with the mate still running is logged as a failure"
}

# --- main: asks and thresholds -------------------------------------------------

test_main_is_asked_once_per_level() {
  local dir out
  dir=$(make_case main-ask)
  write_main_record "$dir"
  write_log "$dir" "$dir/home" 100000
  out=$(run_clear "$dir" tick)
  assert_equals "" "$out" "main under the soft size must not be told anything"
  write_log "$dir" "$dir/home" 163000
  out=$(run_clear "$dir" tick)
  assert_contains "$out" "check: supervisor-clear: main's conversation is at 163,000 tokens" "main must be told its size"
  assert_contains "$out" "Open-record persistence section only" "main must be asked for the open records only"
  assert_contains "$out" "bin/fm-supervisor-clear.sh saved" "main must be told how to report the save"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c .)" "one pass prints at most one line"
  out=$(run_clear "$dir" tick)
  assert_equals "" "$out" "main must not be told twice at the soft size"
  write_log "$dir" "$dir/home" 201000
  out=$(run_clear "$dir" tick)
  assert_contains "$out" "past the 200,000 limit. Finish the step you are on" "main must be told once more at the hard size"
  out=$(run_clear "$dir" tick)
  assert_equals "" "$out" "the hard ask must not repeat"
  assert_contains "$(log_of "$dir")" $'main\t163000\tasked\tsoft' "the ask must be logged with its size"
  pass "main is told once at the soft size and once at the hard size"
}

test_thresholds_come_from_config() {
  local dir out
  dir=$(make_case config)
  write_main_record "$dir"
  write_log "$dir" "$dir/home" 55000
  printf 'soft 50000\nhard 60000   # tighter for this home\n' > "$dir/home/config/supervisor-clear"
  out=$(run_clear "$dir" tick)
  assert_contains "$out" "is at 55,000 tokens (cleared from 50,000, always before 60,000)" "the configured thresholds must apply"
  printf 'soft 70000\nhard 60000\n' > "$dir/home/config/supervisor-clear"
  out=$(run_clear "$dir" tick)
  assert_contains "$out" "config/supervisor-clear is invalid (soft must be below hard)" "an invalid file must be reported"
  out=$(run_clear "$dir" tick)
  assert_equals "" "$out" "an invalid file must be reported once"
  printf 'off\n' > "$dir/home/config/supervisor-clear"
  rm -f "$dir/home/state/supervisor-clear/main.asked"
  out=$(run_clear "$dir" tick)
  assert_equals "" "$out" "off must turn the policy off"
  pass "thresholds come from config/supervisor-clear, and an invalid file is reported once"
}

test_secondmate_home_never_clears_itself() {
  local dir out rc
  dir=$(make_case secondmate-home)
  printf 'sm1\n' > "$dir/home/.fm-secondmate-home"
  write_main_record "$dir"
  write_log "$dir" "$dir/home" 190000
  out=$(run_clear "$dir" tick)
  assert_equals "" "$out" "a secondmate home's own conversation belongs to its parent"
  out=$(run_clear "$dir" saved); rc=$?
  expect_code 1 "$rc" "saved must refuse in a secondmate home"
  pass "a secondmate home never schedules its own clear"
}

# --- main: the /clear guard ----------------------------------------------------

saved_case() {  # <name> [tokens] [age] -> case dir with main asked and saved
  local dir
  dir=$(make_case "$1")
  write_main_record "$dir"
  write_log "$dir" "$dir/home" "${2:-163000}" "${3:-120}"
  run_clear "$dir" tick >/dev/null
  run_clear "$dir" saved >/dev/null
  printf '%s\n' "$dir"
}

test_clear_typed_into_a_quiet_empty_pane_and_confirmed() {
  local dir
  dir=$(saved_case clean)
  cat > "$dir/fake/on-enter" <<SH
#!/usr/bin/env bash
grep -q '^/clear\$' "$dir/fake/literal" && env FM_HOME="$dir/home" FM_SUPERVISOR_TARGET=%7 \
  FM_SUPERVISOR_BACKEND=tmux "$CLEAR" record-main
SH
  chmod +x "$dir/fake/on-enter"
  run_clear "$dir" clear-main >/dev/null
  assert_equals "/clear" "$(cat "$dir/fake/literal")" "/clear must be typed exactly once"
  assert_equals "Enter" "$(cat "$dir/fake/keys")" "one Enter must submit it"
  assert_contains "$(log_of "$dir")" $'main\t163000\tcleared\tsession start re-ran after /clear' \
    "the clear must be confirmed and logged with the size before it"
  assert_absent "$dir/home/state/supervisor-clear/main.saved" "a done clear must close the save"
  assert_present "$dir/home/state/supervisor-clear/main.cleared" "the clear time must be kept"
  # The old conversation's reading no longer asks anything.
  assert_equals "" "$(run_clear "$dir" tick)" "the reading from before the clear must be ignored"
  pass "/clear is typed once into a quiet, empty pane and confirmed by session start"
}

assert_skipped_untouched() {  # <case-dir> <reason-fragment> <label>
  assert_equals "" "$(cat "$1/fake/literal")" "$3: nothing may be typed"
  assert_equals "" "$(cat "$1/fake/keys")" "$3: no key may be sent"
  assert_contains "$(log_of "$1")" "$2" "$3: the skip must say why"
  assert_present "$1/home/state/supervisor-clear/main.saved" "$3: the save must stay for the next try"
}

test_guard_refuses_text_in_the_input_box() {
  local dir
  dir=$(saved_case typed)
  printf '%s' "$TYPED_SCREEN" > "$dir/fake/screen"
  run_clear "$dir" clear-main >/dev/null
  assert_skipped_untouched "$dir" "text is waiting in main's input box" "captain typing"
  pass "the guard never types while text waits in main's input box"
}

test_guard_refuses_a_turn_in_progress() {
  local dir
  dir=$(saved_case busy)
  printf '%s' "$BUSY_SCREEN" > "$dir/fake/screen"
  run_clear "$dir" clear-main >/dev/null
  assert_skipped_untouched "$dir" "main's pane shows a turn in progress" "mid-turn"
  pass "the guard never types while main is mid-turn"
}

test_guard_refuses_a_changing_pane() {
  local dir
  dir=$(saved_case animate)
  : > "$dir/fake/animate"
  run_clear "$dir" clear-main >/dev/null
  assert_skipped_untouched "$dir" "main's pane changed while it was being watched" "changing pane"
  pass "the guard never types into a pane that changed between its two reads"
}

test_guard_refuses_a_recent_model_call() {
  local dir pid
  dir=$(saved_case recent)
  # Main makes a model call while the helper waits out its settle time.
  SETTLE=3 run_clear "$dir" clear-main >/dev/null &
  pid=$!
  sleep 1
  write_log "$dir" "$dir/home" 164000 0
  wait "$pid"
  assert_skipped_untouched "$dir" "main made a model call in the last" "recent call"
  pass "the guard never types right after a model call"
}

test_hard_size_skip_tells_the_captain_once() {
  local dir out
  dir=$(saved_case hard-skip 205000)
  printf '%s' "$TYPED_SCREEN" > "$dir/fake/screen"
  run_clear "$dir" clear-main >/dev/null
  out=$(run_clear "$dir" tick)
  assert_contains "$out" "past the 200,000 limit, and /clear could not be typed safely (text is waiting in main's input box). Tell the captain in one line that main needs a /clear." \
    "a hard-size skip must become one captain line"
  sleep 0.5
  out=$(run_clear "$dir" tick)
  assert_equals "" "$out" "the captain is told once"
  pass "at the hard size an unsafe moment becomes one line for the captain"
}

test_uncleared_runtime_tells_the_captain_at_hard() {
  local dir out
  dir=$(make_case orca)
  write_main_record "$dir" claude orca
  write_log "$dir" "$dir/home" 170000
  out=$(run_clear "$dir" tick)
  assert_equals "" "$out" "a runtime that cannot be cleared stays quiet under the hard size"
  write_log "$dir" "$dir/home" 210000
  out=$(run_clear "$dir" tick)
  assert_contains "$out" "this runtime (claude in orca) cannot be cleared automatically" "the captain line must name why"
  pass "a runtime that cannot be cleared here becomes one captain line at the hard size"
}

test_record_main_keeps_the_endpoint_it_was_given() {
  local dir rec
  dir=$(make_case record)
  run_clear "$dir" record-main >/dev/null
  rec="$dir/home/state/supervisor-clear/main.endpoint"
  assert_present "$rec" "session start must record main's endpoint"
  assert_grep 'target=%7' "$rec" "the recorded target must be the one main runs in"
  assert_grep 'backend=tmux' "$rec" "the recorded backend must be main's"
  pass "record-main records main's own endpoint"
}

fm_test_run \
  test_idle_mate_over_soft_is_restarted_on_its_profile \
  test_busy_mate_waits_until_hard \
  test_mate_attempts_are_spaced_and_old_readings_ignored \
  test_failed_restart_with_the_mate_running_is_logged_as_a_failure \
  test_main_is_asked_once_per_level \
  test_thresholds_come_from_config \
  test_secondmate_home_never_clears_itself \
  test_clear_typed_into_a_quiet_empty_pane_and_confirmed \
  test_guard_refuses_text_in_the_input_box \
  test_guard_refuses_a_turn_in_progress \
  test_guard_refuses_a_changing_pane \
  test_guard_refuses_a_recent_model_call \
  test_hard_size_skip_tells_the_captain_once \
  test_uncleared_runtime_tells_the_captain_at_hard \
  test_record_main_keeps_the_endpoint_it_was_given
