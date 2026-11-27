#!/usr/bin/env bash
# tests/fm-spawn-compact-adviser-disable.test.sh - every agent this fleet
# launches must start with COMPACT_ADVISER_DISABLE=1 in its environment.
#
# The assertions never read bin/fm-spawn.sh's source. They drive the real spawn
# against a fake pane and a real isolated git worktree, then EXECUTE the launch
# command the pane actually received, under a synthetic pane environment, with
# the harness binary replaced by a probe that prints the environment it was
# started with. What the probe prints is what a real agent would have received.
#
# The remote second-mate route never reaches this path; its coverage lives in
# tests/fm-spawn-compact-adviser-disable-remote.test.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-compact-adviser)

# A synthetic pane value the launch must override rather than inherit: the
# switch is a floor, so a pane that already carries the wrong value still has to
# start its agent with 1.
CONTRARY=0

# make_case <name> <harness> <id>...
# Echoes "<case-dir>|<home>|<project>|<worktree>|<fakebin>|<launch-log>|<pane-log>".
make_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog panelog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  panelog="$case_dir/pane.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$panelog"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG <<EOF
$1
EOF
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# Replace the harness binary with a probe that reports the single environment
# fact under test, so executing the emitted launch answers "what would the agent
# have seen" rather than "what does the command text look like".
install_env_probe() {  # <fakebin> <harness> [variable]
  cat > "$1/$2" <<SH
#!/bin/sh
printf '%s\n' "\${${3:-COMPACT_ADVISER_DISABLE}-unset}"
SH
  chmod +x "$1/$2"
}

# Run the emitted launch command in a synthetic pane shell. The pane carries the
# CONTRARY value, so a launch that merely forwarded the ambient environment
# would be caught here rather than reported as a pass.
#   emitted_launch_env <fakebin> <launch-log>
emitted_launch_env() {
  local fakebin=$1 launchlog=$2 launch
  launch=$(cat "$launchlog")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$fakebin:$PATH" TERM=xterm \
    TMUX=synthetic-pane COMPACT_ADVISER_DISABLE="$CONTRARY" \
    /bin/sh -c "$launch"
}

# Source the staged launch command the way the pane shell does, then report the
# switch that shell is left holding. The pane receives no separate export lines:
# the sourced file is what sets its environment.
#   assert_pane_shell_keeps_switch <launch-log> <pane-log> <fakebin> <label>
assert_pane_shell_keeps_switch() {
  local launchlog=$1 panelog=$2 fakebin=$3 label=$4 kept
  ! grep -q '^export ' "$panelog" \
    || fail "$label: the pane shell must receive no separately typed export line"
  # shellcheck disable=SC2016 # Expands in the synthetic pane shell.
  kept=$(env -i HOME="$TMP_ROOT/pane-home" PATH="$fakebin:$PATH" TERM=xterm \
    TMUX=synthetic-pane COMPACT_ADVISER_DISABLE="$CONTRARY" \
    /bin/sh -c '. "$1" >/dev/null; printf %s "$COMPACT_ADVISER_DISABLE"' sh "$launchlog") \
    || fail "$label: sourcing the staged launch command failed"
  assert_equals 1 "$kept" "$label: the pane shell must keep the compact-adviser switch after sourcing"
}

test_ship_allowlist_absent() {
  local rec out status seen
  rec=$(make_case ship-open codex ship-open-a1)
  read_case "$rec"
  out=$(run_case_spawn ship-open-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "ship spawn without an allowlist should succeed: $out"
  install_env_probe "$FAKEBIN_DIR" codex
  assert_pane_shell_keeps_switch "$LAUNCH_LOG" "$PANE_LOG" "$FAKEBIN_DIR" "ship, allowlist absent"
  seen=$(emitted_launch_env "$FAKEBIN_DIR" "$LAUNCH_LOG") \
    || fail "ship, allowlist absent: the emitted launch failed to run"
  assert_equals 1 "$seen" \
    "a ship worker launched with the ambient environment must start with the compact adviser disabled"
  pass "ship launch with no allowlist starts its agent with the compact-adviser switch on"
}

test_ship_allowlist_enabled() {
  local rec out status seen launch
  rec=$(make_case ship-filtered codex ship-filtered-a1)
  read_case "$rec"
  # An empty file is the strictest opt-in: the launch keeps Firstmate's own
  # operational floor and nothing else, so it is where a floor either holds or
  # is lost.
  : > "$HOME_DIR/config/launch-env-allowlist"
  out=$(run_case_spawn ship-filtered-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "ship spawn under an allowlist should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" '/usr/bin/env -i' \
    "an enabled allowlist should launch under a cleared environment"
  install_env_probe "$FAKEBIN_DIR" codex
  assert_pane_shell_keeps_switch "$LAUNCH_LOG" "$PANE_LOG" "$FAKEBIN_DIR" "ship, allowlist enabled"
  seen=$(emitted_launch_env "$FAKEBIN_DIR" "$LAUNCH_LOG") \
    || fail "ship, allowlist enabled: the emitted launch failed to run"
  assert_equals 1 "$seen" \
    "a ship worker launched under the cleared allowlisted environment must still start with the compact adviser disabled"
  pass "ship launch under an enabled allowlist keeps the compact-adviser switch through the cleared environment"
}

# The launch command establishes the switch for the agent on its own, apart from
# the pane shell export heading the staged file: with that line removed and a
# contrary ambient value, the agent still starts with it on.
test_launch_command_carries_the_switch_without_the_pane_export() {
  local setting rec out status seen launch
  for setting in absent enabled; do
    rec=$(make_case "ship-nopane-$setting" codex "ship-nopane-$setting-a1")
    read_case "$rec"
    [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
    out=$(run_case_spawn "ship-nopane-$setting-a1" "$PROJ_DIR" --mode no-mistakes --yolo off)
    status=$?
    expect_code 0 "$status" "allowlist=$setting spawn should succeed: $out"
    install_env_probe "$FAKEBIN_DIR" codex
    launch=$(grep -vx 'export COMPACT_ADVISER_DISABLE=1' "$LAUNCH_LOG")
    seen=$(env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm \
      TMUX=synthetic-pane COMPACT_ADVISER_DISABLE="$CONTRARY" \
      /bin/sh -c "$launch") \
      || fail "allowlist=$setting: the emitted launch failed to run without the pane exports"
    assert_equals 1 "$seen" \
      "allowlist=$setting: the launch command alone must set the compact-adviser switch, overriding a contrary pane value"
  done
  pass "the launch command sets the switch on its own, whichever allowlist posture is in force"
}

test_secondmate_launch() {
  local setting rec sm out status seen
  for setting in absent enabled; do
    rec=$(make_case "secondmate-$setting" codex "sm-$setting")
    read_case "$rec"
    [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
    sm="$CASE_DIR/secondmate-home"
    mkdir -p "$sm/bin" "$sm/data"
    printf '# Firstmate\n' > "$sm/AGENTS.md"
    printf '%s\n' "sm-$setting" > "$sm/.fm-secondmate-home"
    printf 'charter for sm-%s\n' "$setting" > "$sm/data/charter.md"
    printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
    git -C "$sm" init -q -b main
    out=$(run_case_spawn "sm-$setting" "$sm" --secondmate)
    status=$?
    expect_code 0 "$status" "secondmate spawn with allowlist=$setting should succeed: $out"
    install_env_probe "$FAKEBIN_DIR" codex
    assert_pane_shell_keeps_switch "$LAUNCH_LOG" "$PANE_LOG" "$FAKEBIN_DIR" "secondmate, allowlist $setting"
    seen=$(emitted_launch_env "$FAKEBIN_DIR" "$LAUNCH_LOG") \
      || fail "secondmate, allowlist $setting: the emitted launch failed to run"
    assert_equals 1 "$seen" \
      "a secondmate launched with allowlist=$setting must start with the compact adviser disabled"
  done
  pass "a secondmate launch carries the compact-adviser switch in both allowlist postures"
}

# The steering doorbell names "$FM_TASK_INBOX" rather than a path, so every
# launch must hand its agent the absolute path of the task's own inbox. For a
# secondmate that inbox lives in the launching home's state, not its own. The
# cleared allowlist environment is where an ambient forward would be lost.
test_launch_exports_task_inbox() {
  local kind rec id sm out status seen want
  for kind in ship secondmate; do
    id="inbox-$kind-a1"
    rec=$(make_case "inbox-$kind" codex "$id")
    read_case "$rec"
    : > "$HOME_DIR/config/launch-env-allowlist"
    if [ "$kind" = ship ]; then
      out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
    else
      sm="$CASE_DIR/secondmate-home"
      mkdir -p "$sm/bin" "$sm/data"
      printf '# Firstmate\n' > "$sm/AGENTS.md"
      printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
      printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
      printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
      git -C "$sm" init -q -b main
      out=$(run_case_spawn "$id" "$sm" --secondmate)
    fi
    status=$?
    expect_code 0 "$status" "$kind spawn should succeed: $out"
    install_env_probe "$FAKEBIN_DIR" codex FM_TASK_INBOX
    seen=$(emitted_launch_env "$FAKEBIN_DIR" "$LAUNCH_LOG") \
      || fail "$kind: the emitted launch failed to run"
    want="$(cd "$HOME_DIR/state" && pwd -P)/$id.inbox"
    assert_equals "$want" "$seen" \
      "a $kind agent must start with FM_TASK_INBOX set to its absolute steering inbox"
  done
  pass "ship and secondmate launches export their absolute steering inbox as FM_TASK_INBOX"
}

# A pane does not inherit the spawner's FM_HOME, so every launch must set it:
# ships and scouts get the spawner's active home, which here differs from the
# code root, and a secondmate gets its own home. Without it a worker's bin/*.sh
# scripts would resolve their code root as the home.
test_launch_exports_active_home() {
  local kind rec id sm out status seen want
  for kind in ship scout secondmate; do
    id="home-$kind-a1"
    rec=$(make_case "home-$kind" codex "$id")
    read_case "$rec"
    : > "$HOME_DIR/config/launch-env-allowlist"
    want=$HOME_DIR
    case "$kind" in
    ship) out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off) ;;
    scout) out=$(run_case_spawn "$id" "$PROJ_DIR" --scout) ;;
    secondmate)
      sm="$CASE_DIR/secondmate-home"
      mkdir -p "$sm/bin" "$sm/data"
      printf '# Firstmate\n' > "$sm/AGENTS.md"
      printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
      printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
      printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
      git -C "$sm" init -q -b main
      want=$sm
      out=$(run_case_spawn "$id" "$sm" --secondmate)
      ;;
    esac
    status=$?
    expect_code 0 "$status" "$kind spawn should succeed: $out"
    install_env_probe "$FAKEBIN_DIR" codex FM_HOME
    seen=$(emitted_launch_env "$FAKEBIN_DIR" "$LAUNCH_LOG") \
      || fail "$kind: the emitted launch failed to run"
    [ "$seen" != "$ROOT" ] || fail "$kind: FM_HOME must not be the code root"
    assert_equals "$want" "$seen" "a $kind agent must start with FM_HOME set to its home"
  done
  pass "ship and scout launches export the active home as FM_HOME; a secondmate gets its own"
}

# --- relaunch ---------------------------------------------------------------
#
# bin/fm-control.sh relaunch stops the agent and rebuilds the launch through
# bin/fm-spawn.sh --relaunch, so this drives the operator-facing verb rather
# than the rebuild alone. The stub below models just enough pane lifecycle for
# that transaction: the harness exit command leaves a bare shell behind, and the
# launch literal starts the harness again.
make_relaunch_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
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
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'")
          staged=${payload#". '"}
          staged=${staged%"'"}
          [ ! -f "$staged" ] || { payload=$(cat "$staged"); printf '%s\n' "$payload" > "$D/launch"; }
          ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        *'encode launch-brief'*) printf 'codex' > "$D/command" ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

test_relaunch_rebuilds_the_switch() {
  local setting dir home proj wt id out status seen
  for setting in absent enabled; do
    id="relaunch-$setting-a1"
    dir="$TMP_ROOT/relaunch-$setting"
    home="$dir/home"
    proj="$dir/proj"
    wt="$dir/wt"
    mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$dir/fake"
    touch "$home/state/.last-watcher-beat"
    [ "$setting" = absent ] || : > "$home/config/launch-env-allowlist"
    make_relaunch_stub "$dir"
    fm_git_worktree "$proj" "$wt" "wt-relaunch-$setting"
    fm_test_spawn_brief "$home" "$id"
    : > "$dir/fake/literal"
    : > "$dir/fake/keys"
    printf 'codex' > "$dir/fake/command"
    printf '%s\n' "fm-$id" > "$dir/fake/windows"
    printf '%s' "$wt" > "$dir/fake/cwd"
    {
      echo "window=fmses:fm-$id"
      echo "endpoint_task_id=$id"
      echo "worktree=$wt"
      echo "project=$proj"
      echo "harness=codex"
      echo "kind=ship"
      echo "mode=no-mistakes"
      echo "yolo=off"
      echo "tasktmp=$dir/tasktmp"
      echo "model=default"
      echo "effort=default"
    } > "$home/state/$id.meta"

    mkdir -p "$dir/user-home"
    out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
      HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
      FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
      "$CONTROL" "$id" relaunch --note 'replacement continues the same task' 2>&1)
    status=$?
    expect_code 0 "$status" "relaunch with allowlist=$setting should succeed: $out"

    [ -s "$dir/fake/launch" ] || fail "relaunch with allowlist=$setting sent no replacement launch command"
    install_env_probe "$dir/fakebin" codex
    assert_pane_shell_keeps_switch "$dir/fake/launch" "$dir/fake/keys" "$dir/fakebin" "relaunch, allowlist $setting"
    seen=$(emitted_launch_env "$dir/fakebin" "$dir/fake/launch") \
      || fail "relaunch with allowlist=$setting: the replacement launch failed to run"
    assert_equals 1 "$seen" \
      "a relaunched agent with allowlist=$setting must start with the compact adviser disabled, exactly as a fresh spawn does"
  done
  pass "relaunch rebuilds the compact-adviser switch for the replacement agent in both allowlist postures"
}

# A command-prefix assignment only covers the first simple command. A raw
# compound launch such as `cd <dir> && <probe>` must still start the probe with
# both required environment values, so execute the pane's launch under a
# contrary ambient compact-adviser value.
test_raw_compound_launch_command_carries_the_switch() {
  local rec out status seen launch probe_dir
  rec=$(make_case raw-compound claude raw-compound-a1)
  read_case "$rec"
  printf '%s\n' '{"rules":[{"when":"current events","use":{"harness":"grok","model":"grok-4","effort":"high"}}],"default":{"harness":"codex","model":"gpt-5","effort":"medium"}}' \
    > "$HOME_DIR/config/crew-dispatch.json"
  mkdir -p "$HOME_DIR/data/raw-compound-a1"
  printf '%s\n' '{"task":"raw-compound-a1","status":"off","profile":null}' > "$HOME_DIR/data/raw-compound-a1/dispatch-resolution.json"

  probe_dir="$CASE_DIR/agent-cwd"
  mkdir -p "$probe_dir"
  cat > "$probe_dir/probe" <<'SH'
#!/bin/sh
printf '%s\n%s\n' "${COMPACT_ADVISER_DISABLE-unset}" "${FM_HOME-unset}"
SH
  chmod +x "$probe_dir/probe"

  out=$(run_case_spawn raw-compound-a1 "$PROJ_DIR" --mode no-mistakes --yolo off \
    "cd $probe_dir && ./probe")
  status=$?
  expect_code 0 "$status" "raw compound launch spawn should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  [ -n "$launch" ] || fail "raw compound launch spawn sent no launch command"
  seen=$(env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm \
    TMUX=synthetic-pane COMPACT_ADVISER_DISABLE="$CONTRARY" \
    /bin/sh -c "$launch") \
    || fail "raw compound launch: the emitted launch failed to run"
  assert_equals "1
$HOME_DIR" "$seen" \
    "a raw compound launch must start with COMPACT_ADVISER_DISABLE=1 and active FM_HOME, even after cd"
  pass "a compound raw launch carries COMPACT_ADVISER_DISABLE=1 and active FM_HOME"
}

# The staged launch file is the pane shell's only source of its pre-launch
# environment, so source it from a real shell and read back both what the agent
# started with and what the shell holds afterwards. The empty allowlist makes the
# shell's own variables the only route into the agent for GOTMPDIR, FM_TASK_ID,
# LAVISH_AXI_HOST, and TRACEPARENT.
test_sourced_launch_file_sets_each_pane_variable_under_its_condition() {
  local kind rec id sm out status seen values tasktmp want_task want_trace real_mv
  real_mv=$(command -v mv)
  for kind in ship scout secondmate unrecorded-trace; do
    id="env-$kind-a1"
    rec=$(make_case "env-$kind" codex "$id")
    read_case "$rec"
    : > "$HOME_DIR/config/launch-env-allowlist"
    : > "$HOME_DIR/config/trace-context"
    printf '100.99.161.42\n' > "$HOME_DIR/config/lavish-axi-host"
    printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
    printf '%s on\n' "$$" > "$HOME_DIR/state/.trace-context-effective"
    if [ "$kind" = unrecorded-trace ]; then
      cat > "$FAKEBIN_DIR/mv" <<SH
#!/bin/sh
for arg do case "\$arg" in *.meta.trace.*) exit 1 ;; esac; done
exec '$real_mv' "\$@"
SH
      chmod +x "$FAKEBIN_DIR/mv"
    fi
    case "$kind" in
    scout) out=$(run_case_spawn "$id" "$PROJ_DIR" --scout) ;;
    secondmate)
      sm="$CASE_DIR/secondmate-home"
      mkdir -p "$sm/bin" "$sm/data"
      printf '# Firstmate\n' > "$sm/AGENTS.md"
      printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
      printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
      printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
      git -C "$sm" init -q -b main
      out=$(run_case_spawn "$id" "$sm" --secondmate)
      ;;
    *) out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off) ;;
    esac
    status=$?
    expect_code 0 "$status" "$kind spawn should succeed: $out"
    ! grep -q '^export ' "$PANE_LOG" || fail "$kind: the pane must receive no separately typed export line"

    tasktmp=$(sed -n 's/^tasktmp=//p' "$HOME_DIR/state/$id.meta")
    [ -n "$tasktmp" ] || fail "$kind: the task record names no temp root"
    want_task=$id
    [ "$kind" != secondmate ] || want_task=unset
    want_trace=$(sed -n 's/^traceparent=//p' "$HOME_DIR/state/$id.meta")
    if [ "$kind" = unrecorded-trace ]; then
      [ -z "$want_trace" ] || fail "$kind: the carrier record was meant to fail"
      want_trace=unset
    else
      [ -n "$want_trace" ] || fail "$kind: the spawn recorded no trace carrier"
    fi
    values="$tasktmp/gotmp|1|100.99.161.42|$want_task|$want_trace"
    cat > "$FAKEBIN_DIR/codex" <<'SH'
#!/bin/sh
printf 'agent=%s|%s|%s|%s|%s\n' "${GOTMPDIR-unset}" "${COMPACT_ADVISER_DISABLE-unset}" \
  "${LAVISH_AXI_HOST-unset}" "${FM_TASK_ID-unset}" "${TRACEPARENT-unset}"
SH
    chmod +x "$FAKEBIN_DIR/codex"
    # shellcheck disable=SC2016 # Expands in the synthetic pane shell.
    seen=$(env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm TMUX=synthetic-pane \
      /bin/sh -c '. "$1"
printf "shell=%s|%s|%s|%s|%s\n" "${GOTMPDIR-unset}" "${COMPACT_ADVISER_DISABLE-unset}" \
  "${LAVISH_AXI_HOST-unset}" "${FM_TASK_ID-unset}" "${TRACEPARENT-unset}"' sh "$LAUNCH_LOG") \
      || fail "$kind: sourcing the staged launch command failed"
    assert_equals "agent=$values
shell=$values" "$seen" "$kind: the agent and the pane shell must both hold the pre-launch environment"
  done
  pass "the sourced launch file gives the agent and the pane shell each variable under its condition"
}

test_launch_preserves_literal_home_and_brief_paths() {
  local name rec id out status seen want brief
  for name in normal literal; do
    id="path-$name-a1"
    rec=$(make_case "path-$name" codex "$id")
    read_case "$rec"
    if [ "$name" = literal ]; then
      mv "$HOME_DIR" "$CASE_DIR/R&D \"double\" 'single' home"
      HOME_DIR="$CASE_DIR/R&D \"double\" 'single' home"
    fi
    out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
    status=$?
    expect_code 0 "$status" "$name path spawn should succeed: $out"
    # Capture the environment and final prompt received by the fake agent.
    cat > "$FAKEBIN_DIR/codex" <<'SH'
#!/bin/sh
printf '%s\n' "$FM_TASK_INBOX"
for arg do :; done
printf '%s\n' "$arg"
SH
    chmod +x "$FAKEBIN_DIR/codex"
    seen=$(emitted_launch_env "$FAKEBIN_DIR" "$LAUNCH_LOG") \
      || fail "$name path: the emitted launch failed to run"
    brief=$("$ROOT/bin/fm-operational-input.sh" encode launch-brief < "$HOME_DIR/data/$id/launch-brief.md")
    want="$(cd "$HOME_DIR/state" && pwd -P)/$id.inbox
$brief"
    assert_equals "$want" "$seen" "$name path: launch changed the home or brief bytes"
  done
  pass "launch preserves literal ampersands, quotes and spaces in home and brief paths"
}

test_launch_preserves_literal_home_and_brief_paths
test_ship_allowlist_absent
test_ship_allowlist_enabled
test_launch_command_carries_the_switch_without_the_pane_export
test_secondmate_launch
test_launch_exports_task_inbox
test_launch_exports_active_home
test_relaunch_rebuilds_the_switch
test_sourced_launch_file_sets_each_pane_variable_under_its_condition
test_raw_compound_launch_command_carries_the_switch
