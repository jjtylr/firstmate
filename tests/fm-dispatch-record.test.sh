#!/usr/bin/env bash
# Behavior tests for bin/fm-dispatch-record.sh, the per-dispatch record's
# spawn, relaunch, and outcome writer and its summary reader. Every case drives
# the public argv interface against an isolated data directory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-dispatch-record.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-record)
DATA_DIR="$TMP_ROOT/data"
RECORD="$DATA_DIR/dispatch-record.jsonl"
mkdir -p "$DATA_DIR"

rec() { FM_HOME="$TMP_ROOT" FM_DATA_OVERRIDE="$DATA_DIR" "$TOOL" "$@"; }

# --- summary with no record ---------------------------------------------------
out=$(rec summary); code=$?
expect_code 0 "$code" "summary with no record exits 0"
assert_equals "dispatch-record: no records yet ($RECORD)" "$out" "summary names the missing record"
pass "summary: an absent record is reported, not an error"

# --- outcome for a task the record does not name writes nothing ---------------
rec outcome stranger merged; code=$?
expect_code 0 "$code" "an outcome for an unrecorded task exits 0"
assert_absent "$RECORD" "an outcome for an unrecorded task writes nothing"
pass "outcome: a task the record does not name gains no orphan outcome"

# --- spawned reads the task's dispatch resolution -----------------------------
mkdir -p "$DATA_DIR/fix-a"
printf '%s\n' '{"task":"fix-a","status":"clear","profile":{"harness":"claude","model":"sonnet","effort":"high"}}' \
  > "$DATA_DIR/fix-a/dispatch-resolution.json"
rec spawned fix-a --kind ship --project webapp --harness claude --model sonnet --effort high; code=$?
expect_code 0 "$code" "spawned exits 0"
assert_equals 'dispatch.spawned fix-a ship webapp claude sonnet high false clear true' \
  "$(tail -n 1 "$RECORD" | jq -r '"\(.event) \(.task) \(.kind) \(.project) \(.profile.harness) \(.profile.model) \(.profile.effort) \(.override) \(.resolution_status) \(.matches_resolution)"')" \
  "spawned records the launched profile and whether it matches the clear resolution"
assert_equals '1 number' "$(tail -n 1 "$RECORD" | jq -r '"\(.v) \(.ts | type)"')" "every line carries the format version and a time"
rec spawned fix-b --kind scout --project webapp --harness codex --model default --effort '' --override 'captain picked codex'
assert_equals 'scout null null true captain picked codex null null' \
  "$(tail -n 1 "$RECORD" | jq -r '"\(.kind) \(.profile.model) \(.profile.effort) \(.override) \(.override_reason) \(.resolution_status) \(.matches_resolution)"')" \
  "a default model or effort is null, and an override records its reason"
pass "spawned: launched profile, override, and resolution are recorded"

# --- relaunch then outcome ----------------------------------------------------
rec relaunched fix-a --harness claude --model opus --effort medium --via control
rec relaunched fix-a --harness claude --model opus --effort high --via control
rec outcome fix-a merged --pr https://github.com/acme/webapp/pull/7
assert_equals 'dispatch.outcome merged false https://github.com/acme/webapp/pull/7 2 claude/opus/high' \
  "$(tail -n 1 "$RECORD" | jq -r '"\(.event) \(.outcome) \(.forced) \(.pr) \(.relaunched) \(.relaunched_to.harness)/\(.relaunched_to.model)/\(.relaunched_to.effort)"')" \
  "an outcome counts the relaunches since the spawn and names the last one's profile"
rec outcome fix-b not_landed --forced
assert_equals 'not_landed true null 0 null' \
  "$(tail -n 1 "$RECORD" | jq -r '"\(.outcome) \(.forced) \(.pr) \(.relaunched) \(.relaunched_to)"')" \
  "a forced outcome with no relaunch records zero relaunches"
# A reused task id counts only the relaunches of its latest spawn.
rec spawned fix-a --kind ship --project webapp --harness claude --model sonnet --effort high
rec outcome fix-a landed_local
assert_equals '0 null' "$(tail -n 1 "$RECORD" | jq -r '"\(.relaunched) \(.relaunched_to)"')" "relaunches before the latest spawn are not counted"
pass "outcome: relaunch count and last relaunch profile come from the record"

# --- usage errors -------------------------------------------------------------
for args in "outcome fix-a done" "spawned fix-a --kind secondmate --project p --harness h" "spawned ../x --kind ship --project p --harness h" "relaunched fix-a --harness h --via elsewhere" "bogus"; do
  # shellcheck disable=SC2086 # each case is a word list on purpose
  rec $args >/dev/null 2>&1; code=$?
  expect_code 2 "$code" "usage error: $args"
done
pass "usage errors exit 2"

# --- summary counts -------------------------------------------------------------
{
  jq -cn '{v:1, ts:1, event:"dispatch.resolved", task:"fix-a", status:"clear", rule:"rule_4", rule_when:"A simple bug fix with a stated root cause.",
    shadow_tier:{choice:"light", confidence:0.9, probabilities:{light:0.9, standard:0.05, strong:0.05}}}'
  jq -cn '{v:1, ts:2, event:"dispatch.resolved", task:"fix-b", status:"off", rule:null, shadow_tier:null, shadow_tier_note:"not asked"}'
  jq -cn '{v:1, ts:3, event:"dispatch.resolved", task:"fix-c", status:"clear", rule:"rule_4", rule_when:"A simple bug fix with a stated root cause.",
    shadow_tier:{choice:"standard", confidence:0.6, probabilities:{light:0.2, standard:0.6, strong:0.2}}}'
  printf 'not json at all\n'
} >> "$RECORD"
out=$(rec summary); code=$?
expect_code 0 "$code" "summary exits 0"
assert_contains "$out" "dispatch-record: $RECORD" "summary names the record"
assert_contains "$out" '(1 unreadable line(s) skipped)' "summary counts unreadable lines"
assert_contains "$out" '  tasks: 3 resolved, 2 spawned, 1 relaunched, 2 with an outcome' "summary totals tasks"
assert_contains "$out" '    rule_4 (A simple bug fix with a stated root cause.): 2' "summary counts per rule"
assert_contains "$out" '    none (off): 1' "summary counts runs with no rule by status"
assert_contains "$out" '    light: 1' "summary counts per shadow tier"
assert_contains "$out" '    none (not asked): 1' "summary counts missing tier answers by note"
assert_contains "$out" '    landed_local: 1' "summary counts each task's latest outcome"
assert_contains "$out" '    not_landed: 1' "summary counts not-landed outcomes"
assert_not_contains "$out" 'merged' "a superseded outcome is not counted"
json=$(rec summary --json)
assert_equals '{"rule_4 (A simple bug fix with a stated root cause.)":2,"none (off)":1} {"landed_local":1,"not_landed":1}' \
  "$(jq -c '.rule, .outcome' <<<"$json" | paste -sd ' ' -)" "summary --json carries the same counts"
pass "summary: counts per rule, per shadow tier, and per outcome"

echo "# all fm-dispatch-record tests passed"
