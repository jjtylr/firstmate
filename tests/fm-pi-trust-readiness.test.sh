#!/usr/bin/env bash
# Behavioral coverage for Pi-family project trust and launch readiness.
# The public fm-spawn.sh interface drives separate fake backend/harness
# processes; no implementation function is sourced or asserted by source text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-pi-trust-readiness)
JQ_BIN=$(command -v jq) || fail "test needs jq"
BASE_PATH=${FM_TEST_BASE_PATH:-$(dirname "$JQ_BIN"):/usr/bin:/bin:/usr/sbin:/sbin}
RUNTIME_TASK_TMPS=()

cleanup() {
  local path
  for path in "${RUNTIME_TASK_TMPS[@]:-}"; do
    [ -n "$path" ] && rm -rf "$path"
  done
  fm_test_cleanup
}
trap cleanup EXIT

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat >"$fakebin/pi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' "${FM_FAKE_PI_VERSION:-0.85.1}" ;;
  --help) printf '%s\n' '  --tui-mode <mode>' ;;
esac
exit 0
SH
  chmod +x "$fakebin/pi"
  ln -s pi "$fakebin/pi-signed"
  cat >"$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$FM_FAKE_TMUX_CALL_LOG"
state=$(cat "$FM_FAKE_PI_STATE" 2>/dev/null || true)
write_receipt() {
  [ "${FM_FAKE_PI_NEVER_BEGINS:-no}" != yes ] || return 0
  "$FM_FAKE_BUSY_EVENT" apply "$FM_FAKE_STATE_DIR" "$FM_FAKE_ID" busy \
    --current-gen --source pi-ext --event agent-start >/dev/null
}
show_complete_dialog() {
  local selected='→ Trust' path=$FM_FAKE_PANE_PATH
  [ "$state" != wrong-path ] || path='/tmp/not-the-task-copy'
  [ "$state" != changed-selection ] || selected='→ Trust parent folder'
  printf '%s\n' \
    'Trust project folder?' \
    "$path" \
    'This allows pi to load .pi settings and resources, install missing project' \
    'packages, and execute project extensions.' \
    "$selected" \
    '  Trust parent folder' \
    '  Trust (this session only)' \
    '  Do not trust' \
    '  Do not trust (this session only)'
  if [ "$state" = wrapped ]; then
    printf '%s\n' '↑↓ navigate' 'enter select' 'escape/ctrl+c cancel'
  else
    printf '%s\n' '↑↓ navigate  enter select  escape/ctrl+c cancel'
  fi
}
show_screen() {
  case "$state" in
    trust|persist|wrong-path|changed-selection|unverified|wrapped) show_complete_dialog ;;
    partial)
      printf '%s\n' 'Trust project folder?' "$FM_FAKE_PANE_PATH" \
        'This allows pi to load .pi settings' 'Do not trust'
      ;;
    changed)
      printf '%s\n' 'Trust this project directory?' "$FM_FAKE_PANE_PATH" \
        'Trust parent folder' 'Do not trust'
      ;;
    working)
      printf '%s\n' 'Reply from the launch brief' '── ⠋ Working ──' "$FM_FAKE_PANE_PATH"
      ;;
    ready)
      printf '%s\n' 'pi v0.85.1' 'Press ctrl+o to show full startup help.' "$FM_FAKE_PANE_PATH"
      ;;
    *) printf '%s\n' 'shell starting' '$ ' ;;
  esac
}
case "$*" in
  *'#{pane_current_path}'*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf '%s\n' '%99'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window) exit 0 ;;
  capture-pane)
    if [ "${FM_FAKE_VIEWPORT_FAILS:-no}" = yes ] && case " $* " in *' -S -0 '*) true;; *) false;; esac; then
      printf '%s\n' 'viewport unavailable' >&2
      exit 7
    fi
    show_screen
    exit 0
    ;;
  send-keys)
    prev= literal=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        *FM_PI_HARNESS=pi*|*FM_PI_HARNESS=pi-signed*)
          printf '%s\n' "$literal" >>"$FM_FAKE_LAUNCH_LOG"
          printf '%s\n' launched >"$FM_FAKE_PI_STATE"
          ;;
      esac
      exit 0
    fi
    case " $* " in
      *' Enter '*)
        case "$state" in
          launched)
            case "$FM_FAKE_PI_MODE" in
              trusted)
                printf '%s\n' working >"$FM_FAKE_PI_STATE"
                write_receipt
                ;;
              never-begins)
                printf '%s\n' ready >"$FM_FAKE_PI_STATE"
                ;;
              fresh|submission-fails|persists) printf '%s\n' trust >"$FM_FAKE_PI_STATE" ;;
              wrapped) printf '%s\n' wrapped >"$FM_FAKE_PI_STATE" ;;
              partial) printf '%s\n' partial >"$FM_FAKE_PI_STATE" ;;
              changed) printf '%s\n' changed >"$FM_FAKE_PI_STATE" ;;
              wrong-path) printf '%s\n' wrong-path >"$FM_FAKE_PI_STATE" ;;
              changed-selection) printf '%s\n' changed-selection >"$FM_FAKE_PI_STATE" ;;
              unverified) printf '%s\n' unverified >"$FM_FAKE_PI_STATE" ;;
            esac
            ;;
          trust|wrapped)
            printf '%s\n' enter >>"$FM_FAKE_TRUST_ENTER_LOG"
            if [ "$FM_FAKE_PI_MODE" = submission-fails ]; then
              exit 9
            elif [ "$FM_FAKE_PI_MODE" = persists ]; then
              printf '%s\n' persist >"$FM_FAKE_PI_STATE"
            else
              printf '%s\n' working >"$FM_FAKE_PI_STATE"
              write_receipt
            fi
            ;;
        esac
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh cmux
  ln -s "$JQ_BIN" "$fakebin/jq"
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 id=$2 case_dir home project worktree fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  cat >"$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Pi launch readiness.

## Firstmate spec
Verify trust and processing evidence.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
  printf '%s\n' manual >"$home/config/backlog-backend"
  fm_git_worktree "$project" "$worktree" "wt-$name"
  mkdir -p "$worktree/.pi"
  printf '{}\n' >"$worktree/.pi/settings.json"
  git -C "$worktree" add .pi/settings.json
  git -C "$worktree" commit -qm fixture
  : >"$case_dir/pi.state"
  : >"$case_dir/launch.log"
  : >"$case_dir/trust-enter.log"
  : >"$case_dir/tmux-calls.log"
  printf '%s\n' "$case_dir|$home|$project|$worktree|$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WORKTREE_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local case_dir=$1 home=$2 project=$3 worktree=$4 fakebin=$5 id=$6 mode=$7 harness=${8:-pi}
  shift 8 || true
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' FM_FAKE_PANE_PATH="$worktree" \
    FM_FAKE_PI_STATE="$case_dir/pi.state" FM_FAKE_PI_MODE="$mode" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_TRUST_ENTER_LOG="$case_dir/trust-enter.log" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_BUSY_EVENT="$ROOT/bin/fm-busy-event.sh" \
    FM_FAKE_STATE_DIR="$home/state" FM_FAKE_ID="$id" \
    FM_FAKE_VIEWPORT_FAILS="${FM_FAKE_VIEWPORT_FAILS:-no}" \
    FM_FAKE_PI_VERSION="${FM_FAKE_PI_VERSION:-0.85.1}" \
    FM_PI_READY_POLLS="${FM_PI_READY_POLLS:-3}" FM_PI_POLL_INTERVAL=0 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$project" --harness "$harness" \
      --mode no-mistakes --yolo off "$@" 2>&1
}

assert_failed_cleanup() {
  local out=$1 id=$2
  assert_not_contains "$out" "spawned $id" "failed Pi readiness reported a successful spawn"
  assert_absent "$HOME_DIR/state/$id.meta" "failed Pi readiness kept provisional endpoint metadata"
  assert_grep 'kill-window' "$CASE_DIR/tmux-calls.log" \
    "failed Pi readiness did not close the launched endpoint"
}

run_success_case() {
  local name=$1 mode=$2 harness=${3:-pi} id rec out rc=0
  id="$name-$$"
  RUNTIME_TASK_TMPS+=("/tmp/fm-$id")
  rec=$(make_case "$name" "$id")
  read_case "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJECT_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$mode" "$harness") || rc=$?
  expect_code 0 "$rc" "$name should launch"
  assert_contains "$out" "spawned $id harness=$harness" "$name did not report success"
  assert_grep 'source=pi-ext event=agent-start' "$HOME_DIR/state/$id.busy-state" \
    "$name reported success without the Pi lifecycle receipt"
  printf '%s\n' "$out"
}

test_fresh_dialog_is_answered_then_processing_is_proven() {
  run_success_case fresh-trust fresh pi >/dev/null
  [ "$(wc -l <"$CASE_DIR/trust-enter.log" | tr -d ' ')" = 1 ] \
    || fail "fresh trust was not accepted exactly once"
  pass "fm-spawn: a complete Pi trust selector for the exact isolated copy is accepted once before success"
}

test_reused_trusted_path_is_fast_and_needs_no_trust_key() {
  run_success_case trusted-reuse trusted pi-signed >/dev/null
  [ ! -s "$CASE_DIR/trust-enter.log" ] || fail "remembered trust received a stray Enter"
  pass "fm-spawn: Pi-signed reused trust skips the selector and succeeds on durable processing evidence"
}

test_wrapped_complete_dialog_is_accepted() {
  run_success_case wrapped-dialog wrapped pi >/dev/null
  [ "$(wc -l <"$CASE_DIR/trust-enter.log" | tr -d ' ')" = 1 ] \
    || fail "wrapped complete trust selector was not accepted once"
  pass "fm-spawn: wrapped Pi trust navigation markers retain the complete safe classifier"
}

test_partial_and_changed_dialogs_are_never_answered() {
  local mode id rec out rc
  for mode in partial changed changed-selection; do
    id="pi-$mode-$$"
    RUNTIME_TASK_TMPS+=("/tmp/fm-$id")
    rec=$(make_case "$mode" "$id")
    read_case "$rec"
    rc=0
    out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJECT_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$mode" pi) || rc=$?
    [ "$rc" -ne 0 ] || fail "$mode trust lookalike should fail"
    assert_contains "$out" "without the complete verified selector" \
      "$mode trust lookalike lacked the ambiguity diagnostic"
    [ ! -s "$CASE_DIR/trust-enter.log" ] || fail "$mode trust lookalike was answered"
    assert_failed_cleanup "$out" "$id"
  done
  pass "fm-spawn: partial, changed, and differently selected Pi trust lookalikes are never answered"
}

test_wrong_path_and_unverified_version_are_never_answered() {
  local mode id rec out rc
  for mode in wrong-path unverified; do
    id="pi-$mode-$$"
    RUNTIME_TASK_TMPS+=("/tmp/fm-$id")
    rec=$(make_case "$mode" "$id")
    read_case "$rec"
    rc=0
    if [ "$mode" = unverified ]; then
      out=$(FM_FAKE_PI_VERSION=0.85.2 run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJECT_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$mode" pi) || rc=$?
      assert_contains "$out" "rendered contract is not verified" "unverified Pi version lacked its refusal"
    else
      out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJECT_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$mode" pi) || rc=$?
      assert_contains "$out" "did not name the exact validated isolated copy" "wrong-path selector lacked its refusal"
    fi
    [ "$rc" -ne 0 ] || fail "$mode selector should fail"
    [ ! -s "$CASE_DIR/trust-enter.log" ] || fail "$mode selector was answered"
    assert_failed_cleanup "$out" "$id"
  done
  pass "fm-spawn: a complete selector for another path or an unverified Pi version is a disconfirming refusal"
}

test_submission_failure_and_persistent_dialog_fail() {
  local mode id rec out rc
  for mode in submission-fails persists; do
    id="pi-$mode-$$"
    RUNTIME_TASK_TMPS+=("/tmp/fm-$id")
    rec=$(make_case "$mode" "$id")
    read_case "$rec"
    rc=0
    out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJECT_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$mode" pi) || rc=$?
    [ "$rc" -ne 0 ] || fail "$mode should fail"
    if [ "$mode" = submission-fails ]; then
      assert_contains "$out" "could not be submitted" "trust submission failure lacked its diagnostic"
    else
      assert_contains "$out" "did not clear after its preselected Trust choice" "persistent trust selector lacked its diagnostic"
      [ "$(wc -l <"$CASE_DIR/trust-enter.log" | tr -d ' ')" = 1 ] \
        || fail "persistent selector received blind repeated Enter keys"
    fi
    assert_failed_cleanup "$out" "$id"
  done
  pass "fm-spawn: failed trust submission and a selector that persists after submission refuse the launch"
}

test_backend_without_viewport_capture_refuses_before_launch() {
  local id rec out rc=0
  id="pi-no-viewport-$$"
  rec=$(make_case no-viewport "$id")
  read_case "$rec"
  out=$(FM_BACKEND=cmux run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJECT_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" fresh pi) || rc=$?
  [ "$rc" -ne 0 ] || fail "backend without viewport capture should refuse"
  assert_contains "$out" "backend 'cmux' has no verified viewport-bounded capture" \
    "unsupported viewport backend lacked its preflight refusal"
  [ ! -s "$CASE_DIR/launch.log" ] || fail "Pi launched before the viewport capability refusal"
  assert_absent "$HOME_DIR/state/$id.meta" "viewport capability refusal published task metadata"
  pass "fm-spawn: Pi refuses a backend without verified viewport capture before launch"
}

test_missing_viewport_capture_fails() {
  local id rec out rc=0
  id="pi-capture-fail-$$"
  RUNTIME_TASK_TMPS+=("/tmp/fm-$id")
  rec=$(make_case capture-fail "$id")
  read_case "$rec"
  out=$(FM_FAKE_VIEWPORT_FAILS=yes run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJECT_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" fresh pi) || rc=$?
  [ "$rc" -ne 0 ] || fail "missing viewport capture should fail"
  assert_contains "$out" "could not read the visible viewport of backend 'tmux'" \
    "capture failure lacked the backend-specific diagnostic"
  [ ! -s "$CASE_DIR/trust-enter.log" ] || fail "capture failure sent a blind Enter"
  assert_failed_cleanup "$out" "$id"
  pass "fm-spawn: a missing Pi viewport capture fails rather than guessing at trust"
}

test_brief_never_begins_fails() {
  local id rec out rc=0
  id="pi-never-begins-$$"
  RUNTIME_TASK_TMPS+=("/tmp/fm-$id")
  rec=$(make_case never-begins "$id")
  read_case "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJECT_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" never-begins pi) || rc=$?
  [ "$rc" -ne 0 ] || fail "idle Pi without an agent_start receipt should fail"
  assert_contains "$out" "never proved that the launch brief began processing" \
    "missing Pi lifecycle receipt lacked its diagnostic"
  assert_failed_cleanup "$out" "$id"
  pass "fm-spawn: an idle Pi pane cannot report success before the brief begins processing"
}

# The failed launch's busy record is retired during rollback, so the final case
# checks the supervisor-visible failure rather than the removed seed record.
test_brief_never_begins_failure_record() {
  assert_grep 'failed: pi showed no project-trust selector' "$HOME_DIR/state/pi-never-begins-$$.status" \
    "missing processing evidence did not leave a concrete failure record"
}

test_fresh_dialog_is_answered_then_processing_is_proven
test_reused_trusted_path_is_fast_and_needs_no_trust_key
test_wrapped_complete_dialog_is_accepted
test_partial_and_changed_dialogs_are_never_answered
test_wrong_path_and_unverified_version_are_never_answered
test_submission_failure_and_persistent_dialog_fail
test_backend_without_viewport_capture_refuses_before_launch
test_missing_viewport_capture_fails
test_brief_never_begins_fails
test_brief_never_begins_failure_record
