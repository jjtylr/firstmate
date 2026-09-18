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
set -eu
case "${1:-}" in
  --version) printf '%s\n' '0.99.0'; exit 0 ;;
  --help) printf '%s\n' '  --tui-mode <mode>'; exit 0 ;;
esac
printf '%s\n' "$@" >"$FM_FAKE_ARGS_LOG"
approved=0
extension=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --approve) approved=1 ;;
    -e) shift; extension=$1 ;;
  esac
  shift
done
[ "$approved" -eq 1 ] || exit 0
[ "$FM_FAKE_PI_MODE" != never-begins ] || exit 0
EXT_PATH="$extension" node --input-type=module <<'JS'
import { pathToFileURL } from "node:url";
import { readFileSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
const handlers = {};
const extension = await import(pathToFileURL(process.env.EXT_PATH).href);
extension.default({ on: (name, fn) => { handlers[name] = fn; } });
const state = process.env.FM_FAKE_STATE_DIR;
const id = process.env.FM_FAKE_ID;
const mode = process.env.FM_FAKE_PI_MODE;
const record = `${state}/${id}.busy-state`;
const arm = () => execFileSync(process.env.FM_FAKE_BUSY_EVENT, ["arm", state, id]);
if (mode === "stale-callback") arm();
await handlers.agent_start({}, {});
if (mode === "settled") await handlers.agent_settled({}, { isIdle: () => true });
if (mode === "stale-record") {
  const prior = readFileSync(record);
  arm();
  writeFileSync(record, prior);
}
if (mode === "wrong-source") {
  execFileSync(process.env.FM_FAKE_BUSY_EVENT, ["apply", state, id, "busy",
    "--current-gen", "--source", "fm-spawn", "--event", "agent-start"]);
}
JS
SH
  chmod +x "$fakebin/pi"
  ln -s pi "$fakebin/pi-signed"
  ln -s "$(command -v node)" "$fakebin/node"
  cat >"$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$FM_FAKE_TMUX_CALL_LOG"
case "$*" in
  *'#{pane_current_path}'*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf '%s\n' '%99'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window) exit 0 ;;
  capture-pane)
    [ "${FM_FAKE_VIEWPORT_FAILS:-no}" != yes ] || exit 7
    printf '%s\n' 'The brief quotes "Do not trust" and "Trust parent folder".'
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
        *FM_PI_HARNESS=pi*) printf '%s\n' "$literal" >"$FM_FAKE_LAUNCH_LOG" ;;
      esac
    elif [ -s "$FM_FAKE_LAUNCH_LOG" ]; then
      case " $* " in
        *' Enter '*)
          printf '%s\n' enter >>"$FM_FAKE_ENTER_LOG"
          cd "$FM_FAKE_PANE_PATH" || exit 1
          bash -c "$(cat "$FM_FAKE_LAUNCH_LOG")"
          ;;
      esac
    fi
    ;;
esac
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh sleep
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
  : >"$case_dir/launch.log"
  : >"$case_dir/enter.log"
  : >"$case_dir/tmux-calls.log"
  printf '%s\n' "$case_dir|$home|$project|$worktree|$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WORKTREE_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local case_dir=$1 home=$2 project=$3 worktree=$4 fakebin=$5 id=$6 mode=$7 harness=$8 kind=${9:-ship}
  local -a delivery=(--mode no-mistakes --yolo off)
  [ "$kind" != scout ] || delivery=(--scout)
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux TMUX='fake,1,0' FM_FAKE_PANE_PATH="$worktree" \
    FM_FAKE_PI_MODE="$mode" FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_ARGS_LOG="$case_dir/args.log" FM_FAKE_ENTER_LOG="$case_dir/enter.log" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_BUSY_EVENT="$ROOT/bin/fm-busy-event.sh" \
    FM_FAKE_STATE_DIR="$home/state" FM_FAKE_ID="$id" \
    FM_FAKE_VIEWPORT_FAILS="${FM_FAKE_VIEWPORT_FAILS:-no}" \
    FM_PI_READY_POLLS=3 FM_PI_POLL_INTERVAL=0 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$project" --harness "$harness" "${delivery[@]}" 2>&1
}

assert_failed_cleanup() {
  local out=$1 id=$2
  assert_not_contains "$out" "spawned $id" "failed Pi readiness reported a successful spawn"
  assert_absent "$HOME_DIR/state/$id.meta" "failed Pi readiness kept provisional endpoint metadata"
  assert_grep 'kill-window' "$CASE_DIR/tmux-calls.log" \
    "failed Pi readiness did not close the launched endpoint"
  assert_grep 'failed: pi did not start processing its launch brief' "$HOME_DIR/state/$id.status" \
    "missing processing evidence did not leave a concrete failure record"
}

test_processing_receipt_is_independent_of_viewport() {
  local harness mode kind id rec out rc
  for harness in pi pi-signed; do
    for mode in started settled; do
      kind=ship
      [ "$mode" != settled ] || kind=scout
      id="$harness-$mode-$$"
      RUNTIME_TASK_TMPS+=("/tmp/fm-$id")
      rec=$(make_case "$harness-$mode" "$id")
      read_case "$rec"
      rc=0
      out=$(FM_FAKE_VIEWPORT_FAILS=yes run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJECT_DIR" \
        "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$mode" "$harness" "$kind") || rc=$?
      expect_code 0 "$rc" "$harness $mode should launch without viewport capture: $out"
      assert_contains "$out" "spawned $id harness=$harness kind=$kind" "launch did not preserve identity and kind"
      if [ "$mode" = settled ]; then
        assert_grep 'state=idle source=pi-ext event=agent-settled' "$HOME_DIR/state/$id.busy-state" \
          "a completed first turn did not prove readiness"
      else
        assert_grep 'state=busy source=pi-ext event=agent-start' "$HOME_DIR/state/$id.busy-state" \
          "launch succeeded without a processing receipt"
      fi
      [ "$(wc -l <"$CASE_DIR/enter.log" | tr -d ' ')" = 1 ] || fail "launch sent an extra trust key"
    done
  done
  pass "Pi and Pi-signed approve isolated ship/scout launches and prove processing without a viewport"
}

test_conversation_trust_words_do_not_veto_processing() {
  local id="pi-quoted-trust-$$" rec out rc=0
  RUNTIME_TASK_TMPS+=("/tmp/fm-$id")
  rec=$(make_case quoted-trust "$id")
  read_case "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJECT_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" \
    "$id" started pi) || rc=$?
  expect_code 0 "$rc" "conversation text should not veto the processing receipt: $out"
  pass "conversation trust words do not veto a current-generation processing receipt"
}

test_invalid_processing_evidence_fails() {
  local mode id rec out rc
  for mode in never-begins stale-callback stale-record wrong-source; do
    id="pi-$mode-$$"
    RUNTIME_TASK_TMPS+=("/tmp/fm-$id")
    rec=$(make_case "$mode" "$id")
    read_case "$rec"
    rc=0
    out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJECT_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" \
      "$id" "$mode" pi) || rc=$?
    [ "$rc" -ne 0 ] || fail "$mode should not prove processing"
    assert_failed_cleanup "$out" "$id"
  done
  pass "launch seeds, stale callbacks, stale records, and other sources cannot prove Pi readiness"
}

test_raw_pi_launch_refuses() {
  local harness id rec out rc
  for harness in pi pi-signed; do
    id="$harness-raw-$$"
    rec=$(make_case "$harness-raw" "$id")
    read_case "$rec"
    rc=0
    out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJECT_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" \
      "$id" started "$harness --offline") || rc=$?
    [ "$rc" -ne 0 ] || fail "raw Pi launch should refuse"
    assert_contains "$out" 'require canonical --harness pi or pi-signed' "raw launch lacked its actionable refusal"
    [ ! -s "$CASE_DIR/launch.log" ] || fail "raw Pi command was sent to the endpoint"
    assert_absent "$HOME_DIR/state/$id.meta" "raw Pi refusal published task metadata"
  done
  pass "raw Pi commands cannot bypass the trust and readiness launch template"
}

test_primary_path_never_receives_approval() {
  local id="pi-primary-$$" rec out rc=0
  rec=$(make_case primary-path "$id")
  read_case "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJECT_DIR" "$PROJECT_DIR" "$FAKEBIN_DIR" \
    "$id" started pi) || rc=$?
  [ "$rc" -ne 0 ] || fail "the primary project path should refuse"
  [ ! -s "$CASE_DIR/launch.log" ] || fail "an unvalidated primary path received Pi approval"
  assert_absent "$HOME_DIR/state/$id.meta" "primary path refusal published task metadata"
  pass "Pi approval is never launched when isolation validation fails"
}

test_processing_receipt_is_independent_of_viewport
test_conversation_trust_words_do_not_veto_processing
test_invalid_processing_evidence_fails
test_raw_pi_launch_refuses
test_primary_path_never_receives_approval
