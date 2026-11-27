#!/usr/bin/env bash
# bin/fm-claude-main.sh starts the main firstmate's Claude Code with the
# supervisor start cuts. A stand-in `claude` on PATH records its arguments and
# environment, so these cases pin what the real binary receives.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-main)
FAKEBIN=$TMP_ROOT/bin
mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
: >"$FM_TEST_ARGS"
for a in "$@"; do printf '%s\n' "$a" >>"$FM_TEST_ARGS"; done
printf '%s\n' "${CLAUDE_CODE_SEND_FEEDBACK:-unset}" >"$FM_TEST_ENV"
SH
chmod +x "$FAKEBIN/claude"

# run_main <case> [env assignments...] -- [claude args...]: run the start script
# against a home whose config is <case>/config; leaves <case>/args and <case>/env.
run_main() {
  local case=$1
  shift
  local -a envs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  [ "$#" -eq 0 ] || shift
  mkdir -p "$case/config"
  env -u FM_ALLOW_SUBAGENT PATH="$FAKEBIN:$PATH" FM_HOME="$case" \
    FM_TEST_ARGS="$case/args" FM_TEST_ENV="$case/env" ${envs[@]+"${envs[@]}"} \
    "$ROOT/bin/fm-claude-main.sh" "$@"
}

# arg_after <case> <flag>: print the argument that follows <flag>.
arg_after() {
  awk -v f="$2" 'prev == f { print; exit } { prev = $0 }' "$1/args"
}

TOOLS='Agent,Workflow,ScheduleWakeup,ListAgents,ReportFindings,mcp__claude-artifacts,Artifact,ArtifactComments,ArtifactData,ArtifactCheck'

test_default_start_carries_every_cut() {
  local c=$TMP_ROOT/default settings
  run_main "$c" -- --resume abc 'hello there'
  [ "$(cat "$c/env")" = 0 ] || fail "default: CLAUDE_CODE_SEND_FEEDBACK was not 0"
  [ "$(arg_after "$c" --disallowedTools)" = "$TOOLS" ] \
    || fail "default: hidden tools were '$(arg_after "$c" --disallowedTools)'"
  grep -qx -- --no-chrome "$c/args" || fail "default: --no-chrome missing"
  settings=$(arg_after "$c" --settings)
  printf '%s' "$settings" | jq -e '.feedbackDrafts == "off"
      and .disableClaudeAiConnectors == true
      and .skillOverrides["anthropic-skills:xlsx"] == "user-invocable-only"
      and .enabledPlugins["cowork-plugin-management@synced"] == false' >/dev/null \
    || fail "default: settings JSON was '$settings'"
  [ "$(tail -n 3 "$c/args" | tr '\n' '|')" = "--resume|abc|hello there|" ] \
    || fail "default: passed-through arguments were not last and intact"
  # The variadic tool list must be followed by another flag, never by a prompt.
  [ "$(awk 'prev == "--disallowedTools" { getline; print; exit } { prev = $0 }' "$c/args")" != 'hello there' ] \
    || fail "default: a prompt followed the tool list"
  pass "main start: the default start hides the unused tools, Chrome, connectors, skills, and plugins, and passes arguments through"
}

test_keep_file_and_subagent_exception() {
  local c=$TMP_ROOT/keep settings
  mkdir -p "$c/config"
  printf '%s\n' '# switched back' skills artifacts > "$c/config/supervisor-claude-keep"
  run_main "$c" FM_ALLOW_SUBAGENT=1 --
  [ "$(arg_after "$c" --disallowedTools)" = ReportFindings ] \
    || fail "keep: expected only ReportFindings hidden, got '$(arg_after "$c" --disallowedTools)'"
  settings=$(arg_after "$c" --settings)
  printf '%s' "$settings" | jq -e '(has("skillOverrides") | not) and .disableClaudeAiConnectors == true' >/dev/null \
    || fail "keep: settings JSON was '$settings'"
  pass "main start: kept cuts and FM_ALLOW_SUBAGENT=1 leave exactly those tools and settings in"
}

test_everything_kept_still_starts() {
  local c=$TMP_ROOT/all
  mkdir -p "$c/config"
  printf '%s\n' delegation report-findings artifacts chrome connectors skills plugins > "$c/config/supervisor-claude-keep"
  run_main "$c" --
  [ "$(tr '\n' '|' <"$c/args")" = '--settings|{"feedbackDrafts":"off"}|' ] \
    || fail "all kept: arguments were '$(tr '\n' '|' <"$c/args")'"
  pass "main start: with every cut kept it starts with only the feedback setting"
}

test_unknown_keep_name_refuses() {
  local c=$TMP_ROOT/bad out rc=0
  mkdir -p "$c/config"
  printf '%s\n' chrom > "$c/config/supervisor-claude-keep"
  out=$(run_main "$c" -- 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "bad keep: an unknown cut name must refuse the start"
  case "$out" in *"names 'chrom'"*) ;; *) fail "bad keep: refusal did not name the entry: $out" ;; esac
  [ ! -e "$c/args" ] || fail "bad keep: claude still started"
  pass "main start: an unknown name in the keep file refuses before claude starts"
}

test_default_start_carries_every_cut
test_keep_file_and_subagent_exception
test_everything_kept_still_starts
test_unknown_keep_name_refuses
