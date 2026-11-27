#!/usr/bin/env bash
# Opt-in credentialed live guard for idle worker compaction
# (bin/fm-warm-compact-lib.sh "Idle worker compaction",
# bin/fm-idle-worker-compact.sh, docs/configuration.md "Idle worker compaction").
#
# Proves against the real installed Claude Code and Herdr, in an isolated Herdr
# lab session and a lab home (never a live fleet home, session, or worker):
#   1. a pass leaves a busy Claude worker alone;
#   2. a pass compacts the same worker once it is idle and due, through the
#      backend's submit primitive, and the compaction marker it waits for
#      appears in the worker's transcript and settles the record as compacted;
#   3. a steering message sent while that compaction runs is delivered and
#      acted on after it;
#   4. a later pass in the same idle spell types nothing more.
# The worker is wired like a spawned one (the per-task Claude busy hooks); the
# lab moves the busy record's turn-end time back 56 minutes instead of waiting
# an hour, and lowers min-context-tokens to 5000. Evidence lines start with "# ".
#
#   FM_IDLE_WORKER_COMPACT_LIVE_E2E=1 tests/fm-idle-worker-compact-herdr-live-e2e.test.sh
#
# FM_IDLE_WORKER_COMPACT_LIVE_MODEL (default haiku) picks the worker's model.
# Every Herdr call goes through bin/fm-herdr-lab.sh.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_IDLE_WORKER_COMPACT_LIVE_E2E claude herdr jq git

CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1)
HERDR_VERSION=$(herdr --version 2>/dev/null | head -n 1)
MODEL=${FM_IDLE_WORKER_COMPACT_LIVE_MODEL:-haiku}
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$LAB_HELPER" name fm-idle-worker-compact)
LAB=$(fm_test_tmproot fm-idle-worker-compact-live)
LAB=$(cd -P "$LAB" && pwd -P)
FM="$LAB/home"
WT="$LAB/wt"
PROJECTS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
POLLS=${FM_IDLE_WORKER_COMPACT_LIVE_POLLS:-3000}
ORIGINAL_PATH=$PATH
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE TMUX TMUX_PANE PI_CODING_AGENT NO_MISTAKES_GATE
while IFS= read -r name; do
  unset "$name"
done < <(env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_PID|CLAUDE_EFFORT|HERDR_[A-Z_]+)=' | cut -d= -f1 | sort -u)

evidence() { printf '# %s %s\n' "$(date '+%H:%M:%S')" "$*"; }

cleanup() {
  local rc=$?
  trap - EXIT
  "$LAB_HELPER" teardown "$SESSION" || rc=1
  rm -rf "${PROJECTS:?}/$(printf '%s' "$WT" | sed 's/[^A-Za-z0-9]/-/g')"
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

wait_until() {  # <polls of 0.1s> <command...>
  local limit=$1 i=0
  shift
  while [ "$i" -lt "$limit" ]; do
    "$@" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

lab() { "$LAB_HELPER" run "$SESSION" "$@"; }
screen() { lab pane read "$PANE" --source visible 2>/dev/null; }
transcript() { find "$PROJECTS/$(printf '%s' "$WT" | sed 's/[^A-Za-z0-9]/-/g')" -maxdepth 1 -name '*.jsonl' -print 2>/dev/null | head -n 1; }
boundaries() {
  local t
  t=$(transcript)
  [ -n "$t" ] || { echo 0; return; }
  jq -r 'select(.type == "system" and .subtype == "compact_boundary") | .uuid' "$t" 2>/dev/null | wc -l | tr -d ' '
}
busy_field() { sed -n "s/.* $1=\\([^ ]*\\).*/\\1/p" "$FM/state/w1.busy-state" 2>/dev/null; }
idle_after() { [ "$(busy_field state)" = idle ] && [ "$(busy_field seq)" -gt "$1" ]; }
is_busy() { [ "$(busy_field state)" = busy ]; }
pass_verdict() {  # one worker evaluation, as a pass makes it
  under_test bash -c '
    . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-backend.sh"; . "$1/bin/fm-busy-lib.sh"
    . "$1/bin/fm-classify-lib.sh"; . "$1/bin/fm-warm-compact-lib.sh"
    fm_idle_compact_worker "$2/config" "$2/state" "$2/data" "$2/state/w1.meta" w1 "$(date +%s)"' _ "$ROOT" "$FM"
}
tick() { under_test "$ROOT/bin/fm-idle-worker-compact.sh" tick; }
record() { sed -n "s/^$1=//p" "$FM/state/w1.idle-compact" 2>/dev/null; }
said_after_boundary() {  # <word>: an assistant reply after the compaction carries <word>
  local t
  t=$(transcript)
  [ -n "$t" ] || return 1
  jq -rs '(map(.type == "system" and .subtype == "compact_boundary") | rindex(true)) as $b
    | if $b == null then empty else .[$b + 1:][] end
    | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' "$t" 2>/dev/null \
    | grep -qF -- "$1"
}
diagnose() {
  printf -- '--- busy\n%s\n--- record\n%s\n--- log\n%s\n--- inbox\n%s\n--- screen\n%s\n' \
    "$(cat "$FM/state/w1.busy-state" 2>/dev/null)" "$(cat "$FM/state/w1.idle-compact" 2>/dev/null)" \
    "$(cat "$FM/state/idle-worker-compact.log" 2>/dev/null)" "$(find "$FM/state/w1.inbox" -type f 2>/dev/null)" \
    "$(screen | tail -n 25)"
}

# --- the lab home and worker ---------------------------------------------------

mkdir -p "$FM/state/w1.inbox/handled" "$FM/config" "$FM/data/w1" "$WT" "$LAB/bin"
git -C "$WT" init -q -b main
printf 'min-context-tokens=5000\n' > "$FM/config/idle-worker-compact"
printf 'Lab brief: nothing to build.\n' > "$FM/data/w1/launch-brief.md"
printf 'working [at=%s]: lab worker\n' "$(date +%s)" > "$FM/state/w1.status"
GEN=glab$$
printf '%s\n' "$GEN" > "$FM/state/w1.busy-gen"
hook() {  # <state> <event>
  printf "'%s/bin/fm-busy-event.sh' apply '%s/state' w1 %s --gen '%s' --source claude-hook --event %s 2>/dev/null || true" "$ROOT" "$FM" "$1" "$GEN" "$2"
}
mkdir -p "$WT/.claude"
jq -n --arg submit "$(hook busy user-prompt-submit)" --arg stop "$(hook idle stop)" \
  '{hooks: {UserPromptSubmit: [{hooks: [{type: "command", command: $submit}]}],
            Stop: [{hooks: [{type: "command", command: $stop}]}]}}' > "$WT/.claude/settings.local.json"
printf '#!/usr/bin/env bash\nexit 1\n' > "$LAB/bin/tmux"
cat > "$LAB/bin/herdr" <<SH
#!/usr/bin/env bash
set -euo pipefail
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = '$SESSION' ] || { echo 'wrapper refused foreign session' >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  [ "\${HERDR_SESSION:-}" = '$SESSION' ] || { echo 'wrapper requires the lab session' >&2; exit 98; }
fi
PATH='$ORIGINAL_PATH' exec '$LAB_HELPER' run '$SESSION' "\${args[@]}"
SH
chmod +x "$LAB/bin/tmux" "$LAB/bin/herdr"
# Only the code under test runs behind the lab wrapper; provisioning and the
# lab() calls use the helper with the real herdr.
under_test() { PATH="$LAB/bin:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_HOME=$FM "$@"; }

"$LAB_HELPER" provision "$SESSION" || fail "the Herdr lab session could not be provisioned"
OUT=$(lab workspace create --cwd "$WT" --label idle-worker --no-focus)
PANE=$(printf '%s' "$OUT" | jq -r '.result.root_pane.pane_id')
[ -n "$PANE" ] && [ "$PANE" != null ] || fail "the lab workspace has no pane"
printf 'window=%s:%s\nbackend=herdr\nherdr_session=%s\nherdr_pane_id=%s\nharness=claude\nkind=ship\nworktree=%s\nbranch=fm/lab\nbusy_gen=%s\n' \
  "$SESSION" "$PANE" "$SESSION" "$PANE" "$WT" "$GEN" > "$FM/state/w1.meta"

lab pane run "$PANE" 'echo MARK_$((6*7))' >/dev/null
shell_ready() { screen | grep -q MARK_42; }
wait_until 600 shell_ready || fail "the lab pane's shell never answered"
lab pane run "$PANE" "unset CLAUDECODE CLAUDE_PID; export CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false; exec claude --model $MODEL --effort low --dangerously-skip-permissions" >/dev/null

choose() {  # <screen> <option>: move the dialog cursor to <option> and confirm
  local cursor target moves key
  cursor=$(printf '%s\n' "$1" | grep -n '❯' | tail -n 1 | cut -d: -f1)
  target=$(printf '%s\n' "$1" | grep -nF -- "$2" | tail -n 1 | cut -d: -f1)
  [ -n "$cursor" ] && [ -n "$target" ] || return 0
  moves=$((target - cursor))
  key=Down
  [ "$moves" -ge 0 ] || { key=Up; moves=$((0 - moves)); }
  while [ "$moves" -gt 0 ]; do
    lab pane send-keys "$PANE" "$key" >/dev/null
    sleep 0.3
    moves=$((moves - 1))
  done
  lab pane send-keys "$PANE" Enter >/dev/null
  sleep 3
}
ready_composer() {
  [ "$(under_test bash -c '. "$1/bin/fm-backend.sh"; fm_backend_composer_state herdr "$2:$3"' _ "$ROOT" "$SESSION" "$PANE" 2>/dev/null)" = empty ]
}
i=0
while [ "$i" -lt 90 ]; do
  s=$(screen)
  case "$s" in
    *'Yes, I trust this folder'*) choose "$s" 'Yes, I trust this folder' ;;
    *'Yes, I accept'*) choose "$s" 'Yes, I accept' ;;
    *) ready_composer && break ;;
  esac
  sleep 1
  i=$((i + 1))
done
[ "$i" -lt 90 ] || fail "Claude never reached an idle empty composer"$'\n'"$(diagnose)"
sleep 2
INBOX="$FM/state/w1.inbox"
PROMPT="This is an isolated Firstmate test lab, not a real task. Reply with exactly READY now and use no tools. Later, whenever a message tells you an instruction is waiting, run \`cat $INBOX/*.msg\` once with the Bash tool, then reply with exactly the last word of that file and nothing else. When asked to sleep, run the given sleep command with the Bash tool and then reply with exactly SLEPT."
lab pane send-text "$PANE" "$PROMPT" >/dev/null
sleep 1
lab pane send-keys "$PANE" Enter >/dev/null
wait_until "$POLLS" idle_after 0 || fail "the setup turn never ended"$'\n'"$(diagnose)"
evidence "worker idle in Herdr pane $PANE ($CLAUDE_VERSION, $HERDR_VERSION, model $MODEL)"

# --- 1. a busy worker is left alone -------------------------------------------

seq=$(busy_field seq)
lab pane send-text "$PANE" 'Please sleep: sleep 25' >/dev/null
sleep 1
lab pane send-keys "$PANE" Enter >/dev/null
wait_until 300 is_busy || fail "the worker never went busy"$'\n'"$(diagnose)"
sleep 3
verdict=$(pass_verdict)
[ "$verdict" = busy ] || fail "a pass over a busy worker answered '$verdict', not busy"$'\n'"$(diagnose)"
tick
[ ! -e "$FM/state/w1.idle-compact" ] || fail "a pass acted on a busy worker"$'\n'"$(diagnose)"
evidence "busy worker: pass verdict $verdict, nothing typed"
wait_until "$POLLS" idle_after "$seq" || fail "the sleep turn never ended"$'\n'"$(diagnose)"

# --- 2. an idle, due worker is compacted once ------------------------------------

sleep 2
ts=$(busy_field ts)
sed -i.bak "s/ ts=$ts\$/ ts=$((ts - 3360))/" "$FM/state/w1.busy-state" && rm -f "$FM/state/w1.busy-state.bak"
evidence "busy record turn end moved back 56 minutes: $(cat "$FM/state/w1.busy-state")"
before=$(boundaries)
tick
[ "$(record result)" = pending ] || fail "the due idle worker was not compacted"$'\n'"$(diagnose)"
evidence "pass typed /compact (record: $(tr '\n' ' ' < "$FM/state/w1.idle-compact"))"
sent=$(record sent)
tick
[ "$(record sent)" = "$sent" ] || fail "a second pass typed again while the first compaction was pending"

# --- 3. a steer sent during the compaction ----------------------------------------

sleep 3
steer_busy=$(busy_field state)
WORD=PINEAPPLE$$
under_test "$ROOT/bin/fm-send.sh" w1 "Lab instruction. Last word: $WORD" >/dev/null 2>&1 \
  || fail "the steer was not recorded"$'\n'"$(diagnose)"
evidence "steer recorded while the worker read $steer_busy, $(( $(boundaries) - before )) new compaction marker(s) so far"
compacted_now() { [ "$(boundaries)" -gt "$before" ]; }
wait_until "$POLLS" compacted_now || fail "no compaction marker appeared"$'\n'"$(diagnose)"
evidence "compaction marker appeared ($(boundaries) in the transcript)"
tick
[ "$(record result)" = compacted ] || fail "the pass did not confirm the compaction"$'\n'"$(diagnose)"
evidence "log: $(cat "$FM/state/idle-worker-compact.log")"
if ! wait_until 1200 said_after_boundary "$WORD"; then
  evidence "the steer was not acted on within 120 s of the compaction; inbox: $(find "$INBOX" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ') unhandled"
  fail "a steer sent during the compaction was not delivered after it"$'\n'"$(diagnose)"
fi
evidence "the steer sent during the compaction was acted on after it"

# --- 4. once per spell ----------------------------------------------------------

worker_idle() { [ "$(busy_field state)" = idle ]; }
wait_until "$POLLS" worker_idle || true
tick
[ "$(boundaries)" = $((before + 1)) ] || fail "the worker was compacted more than once ($(( $(boundaries) - before )) markers)"
[ "$(grep -c . "$FM/state/idle-worker-compact.log")" = 1 ] || fail "a later pass logged another compaction"
evidence "four passes, one compaction"
echo "ok - idle worker compaction: busy worker left alone, due worker compacted once and confirmed, steer delivered after"
