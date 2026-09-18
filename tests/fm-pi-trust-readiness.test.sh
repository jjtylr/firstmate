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
prompt=${!#}
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
case "$FM_FAKE_PI_MODE" in never-begins|abort-during-readiness) exit 0 ;; esac
EXT_PATH="$extension" FM_FAKE_PI_PROMPT="$prompt" node --input-type=module <<'JS'
import { pathToFileURL } from "node:url";
import { readFileSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
const handlers = {};
const extension = await import(pathToFileURL(process.env.EXT_PATH).href);
extension.default({ on: (name, fn) => { handlers[name] = fn; } });
const state = process.env.FM_FAKE_STATE_DIR;
const id = process.env.FM_FAKE_ID;
const mode = process.env.FM_FAKE_PI_MODE;
const prompt = process.env.FM_FAKE_PI_PROMPT;
const record = `${state}/${id}.busy-state`;
const arm = () => execFileSync(process.env.FM_FAKE_BUSY_EVENT, ["arm", state, id]);
const before = (value) => handlers.before_agent_start?.({ prompt: value }, {});
const messageStart = (value) => handlers.message_start?.({
  message: { role: "user", content: [{ type: "text", text: value }] },
}, {});
if (mode === "unrelated-startup" || mode === "startup-then-brief") {
  await before("message queued by a trusted project extension");
  await handlers.agent_start({}, {});
  await messageStart("message queued by a trusted project extension");
  await handlers.agent_settled({}, { isIdle: () => true });
}
if (mode === "nested-unmarked") {
  await before("message queued by a trusted project extension");
  await before(prompt);
  await handlers.agent_start({}, {});
  await messageStart("message queued by a trusted project extension");
  await handlers.agent_settled({}, { isIdle: () => true });
} else if (mode === "wrong-source") {
  await handlers.agent_start({}, {});
  execFileSync(process.env.FM_FAKE_BUSY_EVENT, ["apply", state, id, "busy",
    "--current-gen", "--source", "fm-spawn", "--event", "agent-start"]);
} else if (mode !== "unrelated-startup") {
  await before(prompt);
  if (mode === "stale-callback") arm();
  await handlers.agent_start({}, {});
  await messageStart(prompt);
  if (mode === "settled") await handlers.agent_settled({}, { isIdle: () => true });
  if (mode === "stale-record") {
    const prior = readFileSync(record);
    arm();
    writeFileSync(record, prior);
  }
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
  *'#{pane_current_command}'*)
    if [ -n "${FM_FAKE_AGENT_STATE_FILE:-}" ] && [ "$(cat "$FM_FAKE_AGENT_STATE_FILE" 2>/dev/null)" = agent ]; then
      printf '%s\n' pi
    else
      printf '%s\n' zsh
    fi
    exit 0
    ;;
  *'#{pane_tty}'*) printf '\n'; exit 0 ;;
  *'#{cursor_y}'*) printf '1\n'; exit 0 ;;
  *'#{pane_id}'*) printf '%s\n' '%99'; exit 0 ;;
  *'#S'*) printf '%s\n' firstmate; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf '%s\n' '%99'; exit 0 ;;
  list-windows)
    [ "${FM_FAKE_EXISTING_ENDPOINT:-no}" != yes ] || printf 'fm-%s\n' "$FM_FAKE_ID"
    exit 0
    ;;
  kill-window)
    [ -z "${FM_FAKE_AGENT_STATE_FILE:-}" ] || printf '%s\n' dead >"$FM_FAKE_AGENT_STATE_FILE"
    exit 0
    ;;
  has-session|new-session|new-window) exit 0 ;;
  capture-pane)
    [ "${FM_FAKE_VIEWPORT_FAILS:-no}" != yes ] || exit 7
    if [ -n "${FM_FAKE_AGENT_STATE_FILE:-}" ]; then
      printf '╭────╮\n│    │\n╰────╯\n'
    else
      printf '%s\n' 'The brief quotes "Do not trust" and "Trust parent folder".'
    fi
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
        /quit) : >"$FM_FAKE_EXIT_PENDING" ;;
      esac
    elif [ -s "$FM_FAKE_LAUNCH_LOG" ]; then
      case " $* " in
        *' Escape '*) printf '%s\n' interrupt >>"$FM_FAKE_CONTROL_LOG" ;;
        *' Enter '*)
          printf '%s\n' enter >>"$FM_FAKE_ENTER_LOG"
          if [ -e "$FM_FAKE_EXIT_PENDING" ]; then
            printf '%s\n' dead >"$FM_FAKE_AGENT_STATE_FILE"
            rm -f "$FM_FAKE_EXIT_PENDING"
            printf '%s\n' exit >>"$FM_FAKE_CONTROL_LOG"
          elif [ ! -e "$FM_FAKE_LAUNCHED_MARKER" ]; then
            : >"$FM_FAKE_LAUNCHED_MARKER"
            [ -z "${FM_FAKE_AGENT_STATE_FILE:-}" ] || printf '%s\n' agent >"$FM_FAKE_AGENT_STATE_FILE"
            cd "$FM_FAKE_PANE_PATH" || exit 1
            bash -c "$(cat "$FM_FAKE_LAUNCH_LOG")"
          fi
          ;;
      esac
    fi
    ;;
esac
SH
  chmod +x "$fakebin/tmux"
  cat >"$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FAKE_PI_MODE:-}" = abort-during-readiness ] &&
  [ "$(cat "${FM_FAKE_AGENT_STATE_FILE:-/nonexistent}" 2>/dev/null)" = agent ] &&
  [ ! -e "$FM_FAKE_SIGNAL_MARKER" ]; then
  : >"$FM_FAKE_SIGNAL_MARKER"
  kill -TERM "$PPID"
fi
exit 0
SH
  chmod +x "$fakebin/sleep"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  ln -s "$JQ_BIN" "$fakebin/jq"
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 id=$2 case_dir home project worktree fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$home/projects/project"
  worktree="$case_dir/worktree"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' '- project [no-mistakes] - readiness fixture (added 2026-09-18)' >"$home/data/projects.md"
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
  : >"$case_dir/control.log"
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
    FM_FAKE_CONTROL_LOG="$case_dir/control.log" \
    FM_FAKE_AGENT_STATE_FILE="${FM_FAKE_AGENT_STATE_FILE:-}" \
    FM_FAKE_EXISTING_ENDPOINT="${FM_FAKE_EXISTING_ENDPOINT:-no}" \
    FM_FAKE_EXIT_PENDING="$case_dir/exit-pending" \
    FM_FAKE_LAUNCHED_MARKER="$case_dir/launched" \
    FM_FAKE_SIGNAL_MARKER="$case_dir/signal-sent" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_BUSY_EVENT="$ROOT/bin/fm-busy-event.sh" \
    FM_FAKE_STATE_DIR="$home/state" FM_FAKE_ID="$id" \
    FM_FAKE_VIEWPORT_FAILS="${FM_FAKE_VIEWPORT_FAILS:-no}" \
    FM_PI_READY_POLLS=3 FM_PI_POLL_INTERVAL=0 \
    FM_PI_STOP_POLLS=3 FM_PI_STOP_INTERVAL=0 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$project" --harness "$harness" "${delivery[@]}" 2>&1
}

run_relaunch() {
  local case_dir=$1 home=$2 worktree=$3 fakebin=$4 id=$5 mode=$6 harness=$7
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux TMUX='fake,1,0' FM_FAKE_PANE_PATH="$worktree" \
    FM_FAKE_PI_MODE="$mode" FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_ARGS_LOG="$case_dir/args.log" FM_FAKE_ENTER_LOG="$case_dir/enter.log" \
    FM_FAKE_CONTROL_LOG="$case_dir/control.log" \
    FM_FAKE_AGENT_STATE_FILE="$case_dir/agent-state" FM_FAKE_EXISTING_ENDPOINT=yes \
    FM_FAKE_EXIT_PENDING="$case_dir/exit-pending" \
    FM_FAKE_LAUNCHED_MARKER="$case_dir/launched" \
    FM_FAKE_SIGNAL_MARKER="$case_dir/signal-sent" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_BUSY_EVENT="$ROOT/bin/fm-busy-event.sh" \
    FM_FAKE_STATE_DIR="$home/state" FM_FAKE_ID="$id" \
    FM_PI_READY_POLLS=3 FM_PI_POLL_INTERVAL=0 \
    FM_PI_STOP_POLLS=3 FM_PI_STOP_INTERVAL=0 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" --relaunch --harness "$harness" 2>&1
}

prepare_relaunch() {
  local case_dir=$1 home=$2 project=$3 worktree=$4 id=$5 harness=$6
  {
    echo "window=firstmate:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$worktree"
    echo "project=$project"
    echo "harness=$harness"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
  } >"$home/state/$id.meta"
  printf '%s\n' dead >"$case_dir/agent-state"
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

assert_readiness_receipt() {
  local id=$1 receipt="$HOME_DIR/state/$1.pi-ready" gen="$HOME_DIR/state/$1.busy-gen"
  assert_present "$receipt" "successful Pi readiness did not persist its generation receipt"
  [ "$(cat "$receipt")" = "$(cat "$gen")" ] ||
    fail "Pi readiness receipt did not match the current busy generation"
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
      assert_readiness_receipt "$id"
      if [ "$mode" = settled ]; then
        assert_grep 'state=idle source=pi-ext event=agent-settled' "$HOME_DIR/state/$id.busy-state" \
          "a completed first turn did not prove readiness"
      else
        assert_grep 'state=busy source=pi-ext event=launch-message-start' "$HOME_DIR/state/$id.busy-state" \
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

test_readiness_requires_the_matching_launch_prompt() {
  local mode id rec out rc
  for mode in unrelated-startup nested-unmarked startup-then-brief; do
    id="pi-$mode-$$"
    RUNTIME_TASK_TMPS+=("/tmp/fm-$id")
    rec=$(make_case "$mode" "$id")
    read_case "$rec"
    rc=0
    out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJECT_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" \
      "$id" "$mode" pi) || rc=$?
    if [ "$mode" != startup-then-brief ]; then
      [ "$rc" -ne 0 ] || fail "$mode proved launch readiness without the token-bearing user message"
      assert_failed_cleanup "$out" "$id"
    else
      expect_code 0 "$rc" "the exact launch prompt did not prove readiness after startup activity: $out"
      assert_readiness_receipt "$id"
      assert_grep 'state=busy source=pi-ext event=launch-message-start' "$HOME_DIR/state/$id.busy-state" \
        "the causally matched launch event was not recorded"
    fi
  done
  pass "Pi readiness follows the exact token-bearing user message"
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

test_executable_harness_strings_refuse() {
  local raw id rec out rc n=0
  for raw in 'pi --offline' 'pi-signed --offline' 'env PI_OFFLINE=1 pi' \
    "bash -lc 'pi --offline'" "p=pi; \"\$p\"" 'custom-agent --flag'; do
    n=$((n + 1))
    id="raw-harness-$n-$$"
    rec=$(make_case "raw-harness-$n" "$id")
    read_case "$rec"
    rc=0
    out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJECT_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" \
      "$id" started "$raw") || rc=$?
    [ "$rc" -ne 0 ] || fail "executable harness string should refuse: $raw"
    assert_contains "$out" 'select an exact verified canonical adapter token' \
      "executable harness refusal lacked its actionable requirement"
    [ ! -s "$CASE_DIR/launch.log" ] || fail "executable harness string was sent to the endpoint: $raw"
    assert_no_grep 'new-window' "$CASE_DIR/tmux-calls.log" "executable harness string created an endpoint: $raw"
    assert_absent "$HOME_DIR/state/$id.meta" "executable harness refusal published task metadata"
  done
  pass "only exact verified canonical adapter tokens reach worker launch"
}

test_pi_trust_requires_the_exact_registered_project() {
  local id="pi-registration-$$" rec out rc rogue_project rogue_worktree
  rec=$(make_case registration "$id")
  read_case "$rec"
  rm -f "$HOME_DIR/data/projects.md"
  rc=0
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJECT_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" \
    "$id" started pi) || rc=$?
  [ "$rc" -ne 0 ] || fail "an unregistered project received Pi trust"
  assert_contains "$out" 'Pi worker trust requires exactly one valid registry entry' \
    "unregistered Pi refusal did not name the registry requirement"
  assert_no_grep 'new-window' "$CASE_DIR/tmux-calls.log" \
    "unregistered Pi project created an endpoint"
  [ ! -s "$CASE_DIR/launch.log" ] || fail "unregistered Pi project received a launch command"

  printf '%s\n' \
    '- project [no-mistakes] - readiness fixture (added 2026-09-18)' \
    '- project [direct-PR] - duplicate fixture (added 2026-09-18)' \
    >"$HOME_DIR/data/projects.md"
  rc=0
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJECT_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" \
    "$id" started pi) || rc=$?
  [ "$rc" -ne 0 ] || fail "a duplicate project registration received Pi trust"
  assert_contains "$out" 'has 2 registry entries' \
    "duplicate Pi refusal did not come from strict registry validation"
  assert_no_grep 'new-window' "$CASE_DIR/tmux-calls.log" \
    "duplicate Pi project registration created an endpoint"
  [ ! -s "$CASE_DIR/launch.log" ] || fail "duplicate Pi project registration received a launch command"

  printf '%s\n' '- project [no-mistakes] - readiness fixture (added 2026-09-18)' >"$HOME_DIR/data/projects.md"
  rogue_project="$CASE_DIR/rogue/project"
  rogue_worktree="$CASE_DIR/rogue-worktree"
  fm_git_worktree "$rogue_project" "$rogue_worktree" rogue-registration
  : >"$CASE_DIR/tmux-calls.log"
  rc=0
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$rogue_project" "$rogue_worktree" "$FAKEBIN_DIR" \
    "$id" started pi) || rc=$?
  [ "$rc" -ne 0 ] || fail "a same-named unregistered clone received Pi trust"
  assert_contains "$out" "requires the exact registered clone $HOME_DIR/projects/project" \
    "same-named clone refusal did not identify the registered path"
  assert_no_grep 'new-window' "$CASE_DIR/tmux-calls.log" \
    "same-named unregistered clone created an endpoint"
  [ ! -s "$CASE_DIR/launch.log" ] || fail "same-named unregistered clone received a launch command"
  pass "Pi trust accepts only the exact clone named by the project registry"
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

test_unrelated_repository_never_receives_approval() {
  local id="pi-unrelated-$$" rec out rc=0 unrelated unrelated_worktree
  rec=$(make_case unrelated-repository "$id")
  read_case "$rec"
  unrelated="$CASE_DIR/unrelated"
  unrelated_worktree="$CASE_DIR/unrelated-worktree"
  fm_git_worktree "$unrelated" "$unrelated_worktree" unrelated-repository
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJECT_DIR" "$unrelated_worktree" "$FAKEBIN_DIR" \
    "$id" started pi) || rc=$?
  [ "$rc" -ne 0 ] || fail "an unrelated repository should refuse"
  assert_contains "$out" 'belongs to a different Git repository' \
    "unrelated repository refusal did not name its identity mismatch"
  [ ! -s "$CASE_DIR/launch.log" ] || fail "an unrelated repository received Pi approval"
  assert_absent "$HOME_DIR/state/$id.meta" "unrelated repository refusal published task metadata"
  pass "Pi approval requires the isolated copy to share project repository identity"
}

test_failed_relaunch_stops_pi_and_preserves_endpoint() {
  local id="pi-relaunch-timeout-$$" rec out rc=0
  RUNTIME_TASK_TMPS+=("/tmp/fm-$id")
  rec=$(make_case relaunch-timeout "$id")
  read_case "$rec"
  prepare_relaunch "$CASE_DIR" "$HOME_DIR" "$PROJECT_DIR" "$WORKTREE_DIR" "$id" pi
  out=$(run_relaunch "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" \
    "$id" never-begins pi) || rc=$?
  [ "$rc" -ne 0 ] || fail "a Pi relaunch without processing evidence should fail"
  assert_present "$HOME_DIR/state/$id.meta" "failed relaunch discarded its task record"
  assert_no_grep 'kill-window' "$CASE_DIR/tmux-calls.log" \
    "failed relaunch destroyed its reusable endpoint"
  [ "$(cat "$CASE_DIR/agent-state")" = dead ] || fail "failed relaunch left Pi running"
  assert_grep interrupt "$CASE_DIR/control.log" "failed relaunch did not interrupt Pi"
  assert_grep exit "$CASE_DIR/control.log" "failed relaunch did not submit Pi's exit command"
  assert_absent "$HOME_DIR/state/$id.busy-state" "failed relaunch retained its busy generation"
  rm -f "$CASE_DIR/launched"
  : >"$CASE_DIR/launch.log"
  rc=0
  out=$(run_relaunch "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" \
    "$id" started pi) || rc=$?
  expect_code 0 "$rc" "the preserved endpoint should support another relaunch: $out"
  pass "failed Pi relaunch stops the process and preserves its reusable endpoint"
}

test_abort_during_readiness_cleans_launched_pi() {
  local id="pi-readiness-abort-$$" rec out rc=0
  RUNTIME_TASK_TMPS+=("/tmp/fm-$id")
  rec=$(make_case readiness-abort "$id")
  read_case "$rec"
  printf '%s\n' dead >"$CASE_DIR/agent-state"
  out=$(FM_FAKE_AGENT_STATE_FILE="$CASE_DIR/agent-state" \
    run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJECT_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" \
      "$id" abort-during-readiness pi) || rc=$?
  [ "$rc" -ne 0 ] || fail "a terminated readiness wait should fail"
  assert_absent "$HOME_DIR/state/$id.meta" "terminated readiness wait kept provisional metadata"
  assert_grep 'kill-window' "$CASE_DIR/tmux-calls.log" \
    "terminated readiness wait left its launched endpoint running"
  [ "$(cat "$CASE_DIR/agent-state")" = dead ] || fail "terminated readiness wait left Pi running"
  assert_not_contains "$out" "spawned $id" "terminated readiness wait reported success"
  pass "readiness interruption cleans up the launched Pi endpoint"
}

test_failed_final_commit_cleans_launched_pi() {
  local id="pi-commit-failure-$$" rec out rc=0
  RUNTIME_TASK_TMPS+=("/tmp/fm-$id")
  rec=$(make_case commit-failure "$id")
  read_case "$rec"
  rm -f "$HOME_DIR/config/backlog-backend"
  : >"$HOME_DIR/data/backlog.md"
  cat >"$FAKEBIN_DIR/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  --version:*) printf '%s\n' 'tasks-axi 0.2.4' ;;
  update:--help) printf '%s\n' 'usage: tasks-axi update --archive-body' ;;
  mv:--help) printf '%s\n' 'usage: tasks-axi mv [<id>...] --to <path-or-dir>' ;;
  show:*) printf '%s\n' '  state: queued' '  held: no' '  blocked: no' '  hold_kind: -' ;;
  start:*) printf '%s\n' 'commit unavailable' >&2; exit 1 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$FAKEBIN_DIR/tasks-axi"
  printf '%s\n' dead >"$CASE_DIR/agent-state"
  out=$(FM_FAKE_AGENT_STATE_FILE="$CASE_DIR/agent-state" \
    run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJECT_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" \
      "$id" started pi) || rc=$?
  [ "$rc" -ne 0 ] || fail "a failed final backlog commit should fail the spawn"
  assert_contains "$out" 'could not be moved to In flight' \
    "failed final commit did not report the ownership failure"
  assert_absent "$HOME_DIR/state/$id.meta" "failed final commit retained provisional metadata"
  assert_absent "$HOME_DIR/state/$id.busy-state" "failed final commit retained busy state"
  assert_grep 'kill-window' "$CASE_DIR/tmux-calls.log" \
    "failed final commit left its launched endpoint running"
  [ "$(cat "$CASE_DIR/agent-state")" = dead ] || fail "failed final commit left Pi running"
  assert_not_contains "$out" "spawned $id" "failed final commit reported success"
  pass "Pi launch cleanup remains owned until the final durable commit"
}

test_processing_receipt_is_independent_of_viewport
test_conversation_trust_words_do_not_veto_processing
test_readiness_requires_the_matching_launch_prompt
test_invalid_processing_evidence_fails
test_executable_harness_strings_refuse
test_pi_trust_requires_the_exact_registered_project
test_primary_path_never_receives_approval
test_unrelated_repository_never_receives_approval
test_failed_relaunch_stops_pi_and_preserves_endpoint
test_abort_during_readiness_cleans_launched_pi
test_failed_final_commit_cleans_launched_pi
