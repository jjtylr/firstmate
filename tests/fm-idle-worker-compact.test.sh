#!/usr/bin/env bash
# Behavior tests for idle worker compaction (bin/fm-warm-compact-lib.sh
# "Idle worker compaction", bin/fm-idle-worker-compact.sh, docs/configuration.md
# "Idle worker compaction"). Busy records, status files, and Claude transcripts
# are real files read by the real classifiers and bin/fm-context-size.sh; only
# the backend pane primitives are stubs that record every call, so each guard is
# proven by the absence of a typed /compact.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }

# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"
# shellcheck source=bin/fm-warm-compact-lib.sh
. "$ROOT/bin/fm-warm-compact-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-idle-worker-compact)
HOME_DIR="$TMP_ROOT/home"
CONFIG="$HOME_DIR/config"
STATE="$HOME_DIR/state"
DATA="$HOME_DIR/data"
ACCOUNT="$TMP_ROOT/claude"
WORKTREE="$TMP_ROOT/wt"
TRANSCRIPT_DIR="$ACCOUNT/projects/$(printf '%s' "$WORKTREE" | sed 's/[^A-Za-z0-9]/-/g')"
TRANSCRIPT="$TRANSCRIPT_DIR/session.jsonl"
CALLS="$TMP_ROOT/calls"
mkdir -p "$CONFIG" "$STATE" "$DATA" "$WORKTREE" "$TRANSCRIPT_DIR"

NOW=$(date +%s)
NATIVE=idle
COMPOSER=empty
SUBMIT_VERDICT=empty
fm_backend_target_exists() { return 0; }
fm_backend_busy_state() { printf '%s' "$NATIVE"; }
fm_backend_composer_state() { printf '%s' "$COMPOSER"; }
fm_backend_send_text_submit() { printf 'submit %s %s %s\n' "$1" "$2" "$3" >> "$CALLS"; printf '%s' "$SUBMIT_VERDICT"; }

iso() {  # <epoch>
  python3 -I -c 'import datetime, sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"))' "$1"
}

# A transcript whose last request is <request-age> seconds old and holds
# <tokens> of context; "marker" appends a compaction marker after it.
transcript() {  # <tokens> <request-age> [marker]
  {
    printf '{"type":"user","message":{"role":"user","content":"hi"},"timestamp":"%s"}\n' "$(iso $((NOW - $2 - 10)))"
    printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","model":"claude-opus-5-5","usage":{"input_tokens":10,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0}}}\n' \
      "$(iso $((NOW - $2)))" "$(($1 - 10))"
    [ "${3:-}" != marker ] || printf '{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","timestamp":"%s","compactMetadata":{"trigger":"auto"}}\n' "$(iso $((NOW - 60)))"
  } > "$TRANSCRIPT"
}

busy_record() {  # <state> <turn-end-epoch> [seq]
  printf 'v1 gen=g1 seq=%s state=%s source=claude-hook event=stop ts=%s\n' "${3:-4}" "$1" "$2" > "$STATE/w1.busy-state"
}

worker() {  # <kind> <harness>
  printf 'window=sess:w1\nbackend=herdr\nharness=%s\nkind=%s\nworktree=%s\naccount=%s\nbranch=fm/w1\nbusy_gen=g1\n' \
    "$2" "$1" "$WORKTREE" "$ACCOUNT" > "$STATE/w1.meta"
  printf 'g1\n' > "$STATE/w1.busy-gen"
}

# A worker idle 56 minutes at 200k: due under the defaults.
reset() {
  rm -f "$STATE"/w1.* "$STATE/idle-worker-compact.log" "$CONFIG/idle-worker-compact"
  : > "$CALLS"
  NATIVE=idle
  COMPOSER=empty
  SUBMIT_VERDICT=empty
  worker ship claude
  busy_record idle $((NOW - 3360))
  transcript 200000 3365
  printf 'working [at=%s]: building\n' $((NOW - 4000)) > "$STATE/w1.status"
}

run_worker() { fm_idle_compact_worker "$CONFIG" "$STATE" "$DATA" "$STATE/w1.meta" w1 "${1:-$NOW}"; }
submits() { wc -l < "$CALLS" | tr -d ' '; }

test_due_worker_gets_one_compact_with_keep_instructions() {
  reset
  assert_equals sent "$(run_worker)" 'a due idle worker is compacted'
  assert_equals 1 "$(submits)" 'exactly one submit'
  assert_contains "$(cat "$CALLS")" 'submit herdr sess:w1 /compact Keep exactly:' 'the submit is a /compact through the backend primitive'
  assert_contains "$(cat "$CALLS")" "$DATA/w1/launch-brief.md" 'it names the launch brief'
  assert_contains "$(cat "$CALLS")" "$STATE/w1.inbox" 'it names the steering inbox'
  assert_contains "$(cat "$CALLS")" "$STATE/w1.status" 'it names the status file'
  assert_contains "$(cat "$CALLS")" 'fm/w1' 'it names the branch'
  assert_contains "$(cat "$CALLS")" 'remaining steps' 'it keeps decisions and remaining steps'
  pass 'due worker is compacted once with keep instructions'
}

test_tick_entry_point_compacts_a_due_worker() {
  reset
  fm_idle_compact_tick "$CONFIG" "$STATE" "$DATA" "$NOW"
  assert_equals 1 "$(submits)" 'one pass types one /compact into the due worker'
  fm_idle_compact_tick "$CONFIG" "$STATE" "$DATA" $((NOW + 30))
  assert_equals 1 "$(submits)" 'a second pass in the same spell types nothing'
  pass 'tick compacts a due worker once'
}

test_due_window_is_55_to_58_minutes() {
  reset
  busy_record idle $((NOW - 3299))
  assert_equals young "$(run_worker)" 'under 55 minutes is not due'
  busy_record idle $((NOW - 3300))
  transcript 200000 3300
  assert_equals sent "$(run_worker)" 'at 55 minutes it is due'
  reset
  busy_record idle $((NOW - 3480))
  assert_equals late "$(run_worker)" 'at 58 minutes the window is missed'
  busy_record idle $((NOW - 9000))
  assert_equals late "$(run_worker)" 'a long-missed window does nothing'
  reset
  transcript 200000 3500
  assert_equals late "$(run_worker)" 'a last request past 58 minutes is cold'
  assert_equals 0 "$(submits)" 'nothing typed outside the window'
  pass 'due window'
}

test_small_context_is_not_compacted() {
  reset
  transcript 149999 3365
  assert_equals small "$(run_worker)" 'under 150k is not compacted'
  printf '# tuned\nmin-context-tokens=100000\n' > "$CONFIG/idle-worker-compact"
  assert_equals sent "$(run_worker)" 'the configured threshold applies'
  reset
  printf 'min-context-tokens=abc\n' > "$CONFIG/idle-worker-compact"
  transcript 149999 3365
  assert_equals small "$(run_worker)" 'an unusable threshold keeps the default'
  pass 'size guard'
}

test_switch_turns_it_off() {
  reset
  printf 'enabled=0\n' > "$CONFIG/idle-worker-compact"
  assert_equals off "$(run_worker)" 'enabled=0 turns it off'
  fm_idle_compact_tick "$CONFIG" "$STATE" "$DATA" "$NOW"
  assert_equals 0 "$(submits)" 'nothing typed while off'
  pass 'on/off switch'
}

test_once_per_idle_spell() {
  reset
  assert_equals sent "$(run_worker)" 'first attempt in the spell'
  fm_idle_compact_record_write "$STATE" w1 g1:4 "$NOW" 200000 failed
  assert_equals spell "$(run_worker $((NOW + 60)))" 'a failed attempt is never retried in its spell'
  busy_record idle $((NOW - 3360)) 9
  assert_equals sent "$(run_worker)" 'a new idle spell is eligible again'
  pass 'once per spell'
}

test_existing_compaction_is_not_repeated() {
  reset
  transcript 200000 3365 marker
  assert_equals compacted "$(run_worker)" 'a compaction after the last request (old size still recorded) is skipped'
  assert_equals 0 "$(submits)" 'nothing typed after a compaction'
  pass 'compaction-marker guard'
}

test_pause_ending_before_minute_60_is_skipped() {
  reset
  printf 'paused [at=%s]: own validation until %s\n' $((NOW - 3300)) "$(date -u -r $((NOW - 3360 + 3540)) +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d @$((NOW - 3360 + 3540)) +%Y-%m-%dT%H:%MZ)" > "$STATE/w1.status"
  assert_equals paused "$(run_worker)" 'a pause ending before the 60th minute is skipped'
  printf 'paused [at=%s]: review until %s\n' $((NOW - 3300)) "$(date -u -r $((NOW + 7200)) +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d @$((NOW + 7200)) +%Y-%m-%dT%H:%MZ)" > "$STATE/w1.status"
  assert_equals sent "$(run_worker)" 'a pause ending later is compacted'
  reset
  printf 'paused [at=%s]: waiting on review\n' $((NOW - 3300)) > "$STATE/w1.status"
  assert_equals sent "$(run_worker)" 'a pause with no end is compacted'
  pass 'pause guard'
}

test_busy_worker_is_never_typed_into() {
  reset
  busy_record busy $((NOW - 3360))
  assert_equals busy "$(run_worker)" 'a busy record holds it back'
  reset
  NATIVE=busy
  assert_equals busy "$(run_worker)" 'a native busy pane holds it back'
  reset
  for COMPOSER in pending pending-unproven unknown; do
    assert_equals composer "$(run_worker)" "composer $COMPOSER holds it back"
  done
  reset
  printf 'gX\n' > "$STATE/w1.busy-gen"
  assert_equals busy "$(run_worker)" 'a record from another incarnation proves nothing'
  assert_equals 0 "$(submits)" 'nothing typed into a busy or unproven worker'
  pass 'busy and composer guards'
}

test_only_claude_ship_and_scout_workers() {
  reset
  worker scout claude
  assert_equals sent "$(run_worker)" 'a scout is compacted'
  for spec in secondmate:claude ship:codex ship:pi scout:opencode; do
    reset
    worker "${spec%%:*}" "${spec#*:}"
    assert_equals skip "$(run_worker)" "$spec is never touched"
  done
  reset
  printf 'remote_host=far\n' >> "$STATE/w1.meta"
  assert_equals skip "$(run_worker)" 'a remote task is never touched'
  assert_equals 0 "$(submits)" 'nothing typed into a task that is not a local Claude worker'
  pass 'only Claude ship and scout workers'
}

test_changed_transcript_is_not_typed_into() {
  reset
  # The pane check runs between the idle read and the re-read; growing the
  # transcript there stands for a write that lands in that gap.
  fm_backend_composer_state() { printf '{}\n' >> "$TRANSCRIPT"; printf '%s' "$COMPOSER"; }
  local verdict
  fm_busy_classify_live() { printf '{}\n' >> "$TRANSCRIPT"; printf 'idle claude-hook'; }
  verdict=$(run_worker)
  unset -f fm_busy_classify_live
  # shellcheck source=bin/fm-busy-lib.sh
  . "$ROOT/bin/fm-busy-lib.sh"
  fm_backend_composer_state() { printf '%s' "$COMPOSER"; }
  assert_equals changed "$verdict" 'a transcript written since the idle read holds it back'
  assert_equals 0 "$(submits)" 'nothing typed into a changed transcript'
  pass 'unchanged-transcript guard'
}

test_confirmation_and_log() {
  reset
  assert_equals sent "$(run_worker)" 'compacted'
  assert_equals pending "$(fm_idle_compact_confirm "$STATE" "$STATE/w1.meta" w1 $((NOW + 30)))" 'no marker yet'
  printf '{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","timestamp":"%s","compactMetadata":{"trigger":"auto"}}\n' "$(iso $((NOW - 4000)))" >> "$TRANSCRIPT"
  assert_equals pending "$(fm_idle_compact_confirm "$STATE" "$STATE/w1.meta" w1 $((NOW + 30)))" 'a marker older than the /compact does not confirm it'
  # The marker lands just after the /compact; the reader ages it on the real
  # clock, so it is stamped now.
  printf '{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","timestamp":"%s","compactMetadata":{"trigger":"manual"}}\n' "$(iso "$NOW")" >> "$TRANSCRIPT"
  assert_equals compacted "$(fm_idle_compact_confirm "$STATE" "$STATE/w1.meta" w1 $((NOW + 60)))" 'a marker newer than the /compact confirms it'
  assert_equals "at=$NOW task=w1 tokens=200000 result=compacted" "$(cat "$STATE/idle-worker-compact.log")" 'the log records task, size, and when'
  assert_equals '' "$(fm_idle_compact_confirm "$STATE" "$STATE/w1.meta" w1 $((NOW + 90)))" 'a settled record is not confirmed again'
  reset
  assert_equals sent "$(run_worker)" 'compacted again'
  fm_idle_compact_tick "$CONFIG" "$STATE" "$DATA" $((NOW + FM_IDLE_COMPACT_CONFIRM_SECS))
  assert_contains "$(cat "$STATE/idle-worker-compact.log")" 'result=failed reason=no-marker' 'no marker in time is a failure'
  assert_equals 1 "$(submits)" 'the failure is never retried'
  reset
  SUBMIT_VERDICT=send-failed
  assert_equals failed "$(run_worker)" 'an unconfirmed submit fails'
  assert_contains "$(cat "$STATE/idle-worker-compact.log")" 'result=failed reason=submit-unconfirmed' 'and is logged'
  pass 'confirmation and log'
}

test_entry_script_runs_a_pass() {
  reset
  rm -f "$STATE/w1.meta"
  FM_HOME=$HOME_DIR "$ROOT/bin/fm-idle-worker-compact.sh" tick
  assert_equals 0 "$?" 'a pass with no workers exits 0'
  assert_absent "$STATE/.idle-worker-compact.lock" 'the pass releases its lock'
  FM_HOME=$HOME_DIR "$ROOT/bin/fm-idle-worker-compact.sh" bogus 2>/dev/null
  assert_equals 2 "$?" 'a usage error exits 2'
  pass 'entry script'
}

test_due_worker_gets_one_compact_with_keep_instructions
test_tick_entry_point_compacts_a_due_worker
test_due_window_is_55_to_58_minutes
test_small_context_is_not_compacted
test_switch_turns_it_off
test_once_per_idle_spell
test_existing_compaction_is_not_repeated
test_pause_ending_before_minute_60_is_skipped
test_busy_worker_is_never_typed_into
test_only_claude_ship_and_scout_workers
test_changed_transcript_is_not_typed_into
test_confirmation_and_log
test_entry_script_runs_a_pass
