#!/usr/bin/env bash
# Behavior tests for the worker tier table: bin/fm-dispatch-resolve.sh picking
# a tier for a job no rule matches, its --tier mode, and bin/fm-tier.sh finding
# a job due one step up and restarting it one tier up.
#
# Jev is a fake curl that answers with a canned rule and tier answer, quota-axi
# is a fake that serves one fixture, and the relaunch is a fake fm-control.sh
# (FM_TIER_CONTROL_BIN) that records its argv and moves the task record to the
# new profile the way a real relaunch does. No case touches the network or a
# real agent.
set -u
unset TYPESAFE_BASE FM_DISPATCH_PROVIDER FM_DISPATCH_MODEL

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESOLVE="$ROOT/bin/fm-dispatch-resolve.sh"
TIER="$ROOT/bin/fm-tier.sh"
RECORD_TOOL="$ROOT/bin/fm-dispatch-record.sh"
TMP_ROOT=$(fm_test_tmproot fm-tier)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/log"
RESPONSE="$TMP_ROOT/response.json"
QUOTA="$TMP_ROOT/quota.json"
RULES="$HOME_DIR/config/crew-dispatch.json"
DATA="$HOME_DIR/data"
STATE="$HOME_DIR/state"
RECORD="$DATA/dispatch-record.jsonl"
mkdir -p "$HOME_DIR/config" "$DATA" "$STATE" "$LOG"

cat > "$RULES" <<'JSON'
{
  "rules": [
    { "when": "The task generates images.", "use": { "harness": "codex", "model": "gpt-5.6-sol" } }
  ],
  "default": { "harness": "pi", "model": "openai-codex/gpt-6.1-sol", "effort": "high", "provider": "codex" },
  "tiers": {
    "light": { "budget_minutes": 60, "use": [
      { "harness": "claude", "model": "claude-haiku-5-5", "effort": "high" },
      { "harness": "pi", "model": "openai-codex/gpt-6-luna", "effort": "high", "provider": "codex" } ] },
    "standard": { "budget_minutes": 180, "use": [
      { "harness": "claude", "model": "claude-sonnet-5-5", "effort": "high" },
      { "harness": "pi", "model": "openai-codex/gpt-6.2-sol", "effort": "high", "provider": "codex" } ] },
    "strong": { "budget_minutes": 360, "use": [
      { "harness": "claude", "model": "claude-opus-5-5", "effort": "high" },
      { "harness": "pi", "model": "openai-codex/gpt-6.2-sol", "effort": "xhigh", "provider": "codex" } ] },
    "top": { "use": { "harness": "claude", "model": "claude-fable-5-2", "effort": "xhigh" } }
  }
}
JSON
BASE_RULES="$TMP_ROOT/rules.json"
cp "$RULES" "$BASE_RULES"

write_quota() {  # <claude spendPriority> <codex spendPriority>
  cat > "$QUOTA" <<JSON
{ "generatedAt": "2030-01-01T00:00:00Z", "schemaVersion": 5, "providers": [
  { "provider": "claude", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
    { "scope": "all_models", "status": "known", "effectivePercentRemaining": 70, "runway": { "status": "through_reset" }, "selection": { "spendPriority": $1 } } ] } },
  { "provider": "codex", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
    { "scope": "all_models", "status": "known", "effectivePercentRemaining": 70, "runway": { "status": "through_reset" }, "selection": { "spendPriority": $2 } } ] } } ] }
JSON
}
write_quota 0.5 0.2

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=''
while [ $# -gt 0 ]; do
  case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac
done
cat > "${FAKE_LOG:?}/body"
printf 'call\n' >> "$FAKE_LOG/curl.calls"
[ "${FAKE_CURL_FAIL:-0}" = 1 ] && exit 7
cp "${FAKE_RESPONSE:?}" "$out"
printf 200
SH
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --json ] || exit 2
cat "${FAKE_QUOTA:?}"
SH
# The relaunch stand-in: records argv, then moves the task record to the new
# profile and appends dispatch.relaunched, as fm-control.sh relaunch does
# through fm-spawn.sh --relaunch.
cat > "$FAKEBIN/fake-control" <<'SH'
#!/usr/bin/env bash
set -u
id=$1; shift
printf '%s\n' "$id $*" >> "${FAKE_LOG:?}/control.calls"
[ "${FAKE_CONTROL_FAIL:-0}" = 1 ] && exit 1
h='' m='' e='' note=''
while [ $# -gt 0 ]; do
  case "$1" in
    --harness) h=$2; shift 2 ;; --model) m=$2; shift 2 ;; --effort) e=$2; shift 2 ;;
    --note-file) note=$2; shift 2 ;; *) shift ;;
  esac
done
cp "$note" "$FAKE_LOG/note.$id"
meta="$FM_STATE_OVERRIDE/$id.meta"
grep -v -e '^harness=' -e '^model=' -e '^effort=' "$meta" > "$meta.new"
printf 'harness=%s\nmodel=%s\neffort=%s\n' "$h" "$m" "$e" >> "$meta.new"
mv "$meta.new" "$meta"
"$FAKE_RECORD_TOOL" relaunched "$id" --harness "$h" --model "$m" --effort "$e" --via control
SH
chmod +x "$FAKEBIN/curl" "$FAKEBIN/quota-axi" "$FAKEBIN/fake-control"

export FAKE_LOG="$LOG" FAKE_RESPONSE="$RESPONSE" FAKE_QUOTA="$QUOTA" FAKE_RECORD_TOOL="$RECORD_TOOL"
BASE_PATH=$PATH

# respond <rule choice> <tier answer JSON, or empty for none>
respond() {
  local rule=$1 tier=${2:-}
  jq -n --arg rule "$rule" --argjson tier "${tier:-null}" '
    {model: "jev-1.14.0",
     answers: ({rule: {type: "choice", choice: $rule, confidence: 0.9,
       probabilities: (if $rule == "rule_1" then {rule_1: 0.9, default: 0.1} else {rule_1: 0.1, default: 0.9} end)}}
       + (if $tier == null then {} else {tier: $tier} end)),
     usage: {input_tokens: 10, output_tokens: 5}}' > "$RESPONSE"
}
tier_answer() {  # <choice> <confidence> <light> <standard> <strong>
  printf '{"type":"choice","choice":"%s","confidence":%s,"probabilities":{"light":%s,"standard":%s,"strong":%s}}' "$@"
}

# brief <task> [checkable-failure line]
brief() {
  mkdir -p "$DATA/$1"
  {
    printf '# Task\n## Captain'"'"'s intent\nRename the pager flag.\n\n## Firstmate spec\nRename --old to --new in bin/pager.sh.\n'
    [ -z "${2:-}" ] || printf '%s\n' "$2"
  } > "$DATA/$1/brief.md"
}

out='' code=0
resolve() {  # <task>
  out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY=test-key "$RESOLVE" "$DATA/$1/brief.md" --project pager 2>"$LOG/stderr")
  code=$?
}
tier_tool() {
  out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_TIER_CONTROL_BIN="$FAKEBIN/fake-control" "$TIER" "$@" 2>"$LOG/stderr")
  code=$?
}
err() { cat "$LOG/stderr"; }
last_resolved() { jq -c 'select(.event == "dispatch.resolved")' "$RECORD" | tail -n 1; }
control_calls() { [ -f "$LOG/control.calls" ] && wc -l < "$LOG/control.calls" | tr -d ' ' || echo 0; }

CHECK='Checkable failure: tests: tests/pager.test.sh fails while the old flag remains.'

test_default_job_takes_standard() {
  brief std
  respond default "$(tier_answer standard 0.8 0.1 0.8 0.1)"
  resolve std
  expect_code 0 "$code" "resolve exits 0"
  assert_contains "$out" '  status: clear' "a default job resolves"
  assert_contains "$out" '  tier: standard (Jev picked standard)' "the tier and why are printed"
  assert_contains "$out" "  profile: --harness 'claude' --model 'claude-sonnet-5-5' --effort 'high'" \
    "the profile comes from the standard tier, not the default entry, and quota picks the family"
  assert_equals 'standard' "$(jq -r .tier "$DATA/std/dispatch-resolution.json")" "the task record names the tier"
  assert_equals 'standard Jev picked standard null' "$(last_resolved | jq -r '"\(.tier) \(.tier_reason) \(.checkable_failure)"')" \
    "the dispatch record keeps the pick beside the shadow answer"
  assert_equals 'standard' "$(last_resolved | jq -r .shadow_tier.choice)" "the stage-0 shadow answer is still recorded"
  write_quota 0.1 0.6
  resolve std
  assert_contains "$out" "  profile: --harness 'pi' --model 'openai-codex/gpt-6.2-sol' --effort 'high'" \
    "the existing quota choice picks the family within the tier"
  write_quota 0.5 0.2
  pass "tier pick: a job no rule matches takes its profile from the tier, family by the existing quota choice"
}

test_rule_job_ignores_tier() {
  brief img "$CHECK"
  respond rule_1 "$(tier_answer light 0.95 0.95 0.04 0.01)"
  resolve img
  assert_contains "$out" "  profile: --harness 'codex' --model 'gpt-5.6-sol'" "a rule match keeps its own profile"
  assert_not_contains "$out" '  tier:' "a rule match prints no tier"
  assert_equals 'null' "$(jq -r .tier "$DATA/img/dispatch-resolution.json")" "a rule match records no tier"
  assert_equals 'null light' "$(last_resolved | jq -r '"\(.tier) \(.shadow_tier.choice)"')" "the tier answer stays shadow for a rule match"
  pass "tier pick: a job that matches a special rule ignores the tier answer"
}

test_light_gate() {
  brief lit "$CHECK"
  respond default "$(tier_answer light 0.85 0.85 0.1 0.05)"
  resolve lit
  assert_contains "$out" "  profile: --harness 'claude' --model 'claude-haiku-5-5' --effort 'high'" \
    "light probability 0.85 with a checkable failure takes light"
  assert_contains "$out" 'is 0.8 or more and the brief names a checkable failure (tests)' "the reason names both conditions"
  assert_equals 'light tests' "$(last_resolved | jq -r '"\(.tier) \(.checkable_failure)"')" "the record keeps the tier and the failure kind only"
  assert_not_contains "$(last_resolved)" 'pager.test.sh' "the record never holds the brief's text"

  respond default "$(tier_answer light 0.8 0.8 0.15 0.05)"
  resolve lit
  assert_contains "$out" "--model 'claude-haiku-5-5'" "exactly 0.8 is enough"

  respond default "$(tier_answer light 0.79 0.79 0.2 0.01)"
  resolve lit
  assert_contains "$out" "--model 'claude-sonnet-5-5'" "light below 0.8 stays standard"
  assert_contains "$out" 'is below 0.8: standard' "the reason says why"

  brief lit2
  respond default "$(tier_answer light 0.95 0.95 0.04 0.01)"
  resolve lit2
  assert_contains "$out" "--model 'claude-sonnet-5-5'" "light without a checkable failure stays standard"
  assert_contains "$out" 'names no checkable failure: standard' "the reason says the failure line is missing"

  brief lit3 'Checkable failure: vibes: it will look right'
  resolve lit3
  assert_contains "$out" "--model 'claude-sonnet-5-5'" "a failure line of an unknown kind does not count"
  brief lit4 '- Checkable failure: runbook: step 4 of the deploy runbook reports the version'
  resolve lit4
  assert_contains "$out" "--model 'claude-haiku-5-5'" "a runbook failure line, as a list item, counts"
  pass "tier pick: light only at probability 0.8 or more with a checkable failure (tests, check, or runbook)"
}

test_strong_and_fallbacks() {
  brief str
  respond default "$(tier_answer strong 0.7 0.05 0.25 0.7)"
  resolve str
  assert_contains "$out" "--model 'claude-opus-5-5' --effort 'high'" "strong at the confidence floor or above takes strong"
  respond default "$(tier_answer strong 0.5 0.1 0.4 0.5)"
  resolve str
  assert_contains "$out" "--model 'claude-sonnet-5-5'" "an unsure strong pick stays standard"
  assert_contains "$out" 'is below 0.6: standard' "the reason names the floor"
  respond default ''
  resolve str
  assert_contains "$out" "--model 'claude-sonnet-5-5'" "no tier answer is standard"
  assert_contains "$out" 'no usable tier answer (absent): standard' "the reason says the answer was absent"
  respond default '{"type":"choice","choice":"medium","confidence":0.9,"probabilities":{"light":0.05,"standard":0.05,"strong":0.9}}'
  resolve str
  assert_contains "$out" 'no usable tier answer (malformed): standard' "a malformed answer is standard"
  respond default '{"type":"choice","choice":"top","confidence":0.99,"probabilities":{"light":0.0,"standard":0.01,"strong":0.0,"top":0.99}}'
  resolve str
  assert_contains "$out" "--model 'claude-sonnet-5-5'" "an answer naming top is malformed, so standard: Jev never picks top"
  assert_not_contains "$out" 'fable' "top is never resolved from Jev"
  respond default "$(tier_answer strong 0.9 0.05 0.05 0.9)"
  FAKE_CURL_FAIL=1 resolve str
  assert_contains "$out" '  status: error' "an unreachable Jev is an error outcome"
  assert_not_contains "$out" '  profile:' "an unreachable Jev resolves no profile, so firstmate's intake takes standard"
  out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY='' "$RESOLVE" "$DATA/str/brief.md" --project pager 2>&1)
  assert_contains "$out" 'dispatch-resolve: off' "Jev off is off, unchanged"
  pass "tier pick: strong needs Jev's confident pick; absent, malformed, top, unreachable, and off never go below or above standard"
}

test_tier_mode() {
  : > "$LOG/curl.calls"
  out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" "$RESOLVE" --tier strong 2>&1); code=$?
  expect_code 0 "$code" "tier mode exits 0"
  assert_contains "$out" '  status: clear' "tier mode resolves a tier"
  assert_contains "$out" "  profile: --harness 'claude' --model 'claude-opus-5-5' --effort 'high'" "tier mode uses the quota choice"
  assert_equals '' "$(cat "$LOG/curl.calls")" "tier mode sends no model request and needs no key"
  out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" "$RESOLVE" --tier top 2>&1)
  assert_contains "$out" '  status: escalate' "top always escalates"
  assert_contains "$out" "needs the captain's approval for each job" "the reason names the captain"
  assert_not_contains "$out" '  profile:' "top yields no profile"
  out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" "$RESOLVE" --tier huge 2>&1); code=$?
  expect_code 2 "$code" "an unknown tier is a usage error"
  pass "tier mode: one tier through the same chooser, no model call, top escalates"
}

test_schema_errors() {
  local bad
  for bad in \
    'del(.tiers.standard)@@tiers needs a standard tier' \
    '.tiers.huge = .tiers.light@@unknown tier: huge' \
    'del(.tiers.light.use[0].effort)@@needs model and effort' \
    '.tiers.light.use[0] = .tiers.strong.use[0]@@may appear in one tier only' \
    '.tiers.light.budget_minutes = -5@@budget_minutes must be a positive number' \
    'del(.tiers.light.use[1].provider)@@tier profiles whose harness lacks one authoritative provider family require provider: pi'; do
    jq "${bad%%@@*}" "$BASE_RULES" > "$RULES"
    brief bad
    respond default "$(tier_answer standard 0.8 0.1 0.8 0.1)"
    resolve bad
    expect_code 2 "$code" "a malformed tier table is a configuration error (${bad%%@@*})"
    assert_contains "$(err)" "${bad#*@@}" "the error names the problem (${bad#*@@})"
  done
  cp "$BASE_RULES" "$RULES"
  pass "schema: a malformed tier table is an actionable configuration error, never selected around"
}

# ---- fm-tier.sh ----------------------------------------------------------------

# job <task> <harness> <model> <effort> [launch-ts]: a running ship on that
# profile, spawned (in the dispatch record) at launch-ts (default now).
job() {
  local id=$1 ts=${5:-$(date +%s)}
  fm_write_meta "$STATE/$id.meta" "kind=ship" "harness=$2" "model=$3" "effort=$4" "worktree=$TMP_ROOT/wt-$id" "spawn_gen=s$ts.1.1"
  : > "$STATE/$id.status"
  jq -cn --arg id "$id" --argjson ts "$ts" --arg h "$2" --arg m "$3" --arg e "$4" \
    '{v: 1, ts: $ts, event: "dispatch.spawned", task: $id, kind: "ship", project: "pager", profile: {harness: $h, model: $m, effort: $e}}' >> "$RECORD"
}
status() {  # <task> <verb> <seconds ago> <text>
  printf '%s [at=%s]: %s\n' "$2" "$(( $(date +%s) - $3 ))" "$4" >> "$STATE/$1.status"
}
steps() { jq -c --arg t "$1" 'select(.event == "dispatch.stepped_up" and .task == $t)' "$RECORD" | wc -l | tr -d ' '; }

test_of() {
  job of1 claude claude-sonnet-5-5 high
  tier_tool of of1
  assert_contains "$out" '  tier: standard' "of reads the tier from the profile"
  assert_contains "$out" '  above: strong' "of names the tier above"
  assert_contains "$out" '  budget: 180m' "of names the budget"
  assert_contains "$out" '  automatic step spent: no' "a fresh job has its step"
  job of2 claude claude-opus-5-5 medium
  tier_tool of of2
  assert_contains "$out" 'none (not a tier profile)' "a profile outside the table has no tier"
  pass "of: a job's tier comes from its recorded profile"
}

test_due_detection() {
  rm -f "$STATE"/*.meta "$STATE"/*.status "$STATE/.tier-due-seen"
  job d-blocked claude claude-sonnet-5-5 high
  status d-blocked blocked 0 'cannot work out the parser'
  job d-failed pi openai-codex/gpt-6-luna high
  status d-failed failed 0 'tests still fail'
  job d-stale claude claude-sonnet-5-5 high
  status d-stale blocked 3600 'an old blocker'
  job d-resolved claude claude-sonnet-5-5 high
  status d-resolved blocked 0 'needs a decision'
  printf 'resolved [at=%s]: answered\n' "$(date +%s)" >> "$STATE/d-resolved.status"
  printf 'working [at=%s]: back at it\n' "$(date +%s)" >> "$STATE/d-resolved.status"
  job d-budget claude claude-haiku-5-5 high "$(( $(date +%s) - 61 * 60 ))"
  job d-waiting claude claude-haiku-5-5 high "$(( $(date +%s) - 61 * 60 ))"
  status d-waiting paused 0 'waiting on the pipeline'
  job d-strong claude claude-opus-5-5 high
  status d-strong failed 0 'gave up'
  job d-check claude claude-sonnet-5-5 high
  printf 'pr=https://github.com/acme/pager/pull/9\n' >> "$STATE/d-check.meta"
  printf '%s\n' '{"schema":"fm-pr-health.v1","prs":{"https://github.com/acme/pager/pull/9":{"checks":[{"head":"aaa","name":"test"},{"head":"bbb","name":"test"},{"head":"bbb","name":"lint"}]}},"branches":{}}' > "$STATE/pr-health.json"
  tier_tool due
  expect_code 0 "$code" "due exits 0"
  assert_contains "$out" 'tier-step-up due: d-blocked blocked on standard (cannot work out the parser); run bin/fm-tier.sh step-up d-blocked --trigger blocked' "a fresh blocked report is due"
  assert_contains "$out" 'tier-step-up due: d-failed failed on light' "a fresh failed report is due"
  assert_contains "$out" 'tier-step-up due: d-budget over-budget on light (running 61m against a 60m budget)' "a job past its budget is due"
  assert_contains "$out" 'tier-step-up due: d-check check-failed-twice on standard (check test failed at 2 commits)' "one check failing at two commits is due"
  assert_not_contains "$out" 'd-stale' "a report from before the current worker's launch is not due"
  assert_not_contains "$out" 'd-resolved' "a resolved blocker is not due"
  assert_not_contains "$out" 'd-waiting' "a declared wait does not run down the budget"
  assert_not_contains "$out" 'd-strong' "a strong job is never due: the tier above is top"
  assert_equals 4 "$(printf '%s\n' "$out" | grep -c '^tier-step-up due:')" "exactly four jobs are due"
  tier_tool due --once
  assert_equals 4 "$(printf '%s\n' "$out" | grep -c '^tier-step-up due:')" "the first --once pass prints each due job"
  tier_tool due --once
  assert_equals '' "$out" "a second --once pass prints nothing new"
  status d-blocked blocked 0 'blocked again, a new event'
  sleep 1
  status d-blocked blocked 0 'blocked once more'
  tier_tool due --once
  assert_contains "$out" 'd-blocked blocked' "a new blocked event is reported once more"
  rm -f "$STATE/pr-health.json"
  pass "due: blocked, failed, check failed twice, and over budget are detected from the home's own records, once each"
}

test_each_trigger_steps_once() {
  local trigger id n=0
  rm -f "$LOG/control.calls"
  for trigger in failed blocked check-failed-twice over-budget review-class-a; do
    n=$((n + 1))
    id="t-$trigger"
    job "$id" claude claude-sonnet-5-5 high
    status "$id" working 0 'first worker notes: parser half done'
    tier_tool step-up "$id" --trigger "$trigger" --detail "from the test"
    expect_code 0 "$code" "$trigger steps up"
    assert_contains "$out" "stepped up: $id standard -> strong (--harness claude --model claude-opus-5-5 --effort high), trigger $trigger" "$trigger restarts one tier up"
    assert_equals "$n" "$(control_calls)" "$trigger relaunches exactly once"
    assert_equals 1 "$(steps "$id")" "$trigger records exactly one step"
    assert_equals "standard strong $trigger true claude-sonnet-5-5 claude-opus-5-5" \
      "$(jq -r --arg t "$id" 'select(.event == "dispatch.stepped_up" and .task == $t) | "\(.from_tier) \(.to_tier) \(.trigger) \(.automatic) \(.from_profile.model) \(.to_profile.model)"' "$RECORD")" \
      "$trigger: the step is in the stage-0 record"
  done
  assert_contains "$(tail -n 1 "$LOG/control.calls")" 't-review-class-a relaunch --harness claude --model claude-opus-5-5 --effort high --note-file' \
    "the restart goes through fm-control.sh relaunch with the new profile and a note"
  assert_contains "$(cat "$LOG/note.t-blocked")" 'moved from the standard tier (claude claude-sonnet-5-5 high) to the strong tier, because the worker reported blocked' \
    "the note names the step and its trigger"
  assert_contains "$(cat "$LOG/note.t-blocked")" 'first worker notes: parser half done' "the note carries the first worker's reports"
  pass "step-up: each trigger restarts the job exactly once, one tier up, and records it"
}

test_limits() {
  rm -f "$LOG/control.calls"
  job lim claude claude-haiku-5-5 high
  tier_tool step-up lim --trigger failed
  assert_contains "$out" 'stepped up: lim light -> standard' "the first automatic step runs"
  tier_tool step-up lim --trigger failed
  expect_code 1 "$code" "a second automatic step is refused"
  assert_contains "$(err)" "already had its one automatic step up (light to standard, failed); a second step is firstmate's call" "the refusal names the earlier step"
  assert_equals 1 "$(control_calls)" "a refused second step relaunches nothing"
  tier_tool due lim
  assert_equals '' "$out" "a job whose automatic step is spent is never due"
  printf '%s\n' 'Firstmate: the parser needs a rewrite, not a patch.' > "$TMP_ROOT/notes"
  tier_tool step-up lim --trigger failed --by-firstmate --notes-file "$TMP_ROOT/notes"
  assert_contains "$out" 'stepped up: lim standard -> strong' "firstmate's own second step runs"
  assert_equals 'false' "$(jq -r 'select(.event == "dispatch.stepped_up" and .task == "lim")' "$RECORD" | jq -rs 'last.automatic')" "firstmate's step is recorded as not automatic"
  assert_contains "$(cat "$LOG/note.lim")" 'the parser needs a rewrite' "firstmate's notes reach the new worker"
  tier_tool step-up lim --trigger failed --by-firstmate
  expect_code 1 "$code" "moving into top is refused"
  assert_contains "$(err)" "the tier above strong is top, and the captain approves each top job" "the refusal names the captain"
  job topjob claude claude-fable-5-2 xhigh
  tier_tool step-up topjob --trigger failed --by-firstmate
  expect_code 1 "$code" "a top job is refused"
  assert_contains "$(err)" "already on the top tier" "the refusal says so"
  job loose claude claude-opus-5-5 low
  tier_tool step-up loose --trigger failed
  expect_code 1 "$code" "a profile outside the table is refused"
  assert_contains "$(err)" "not a profile in the tier table" "the refusal says why"
  assert_equals 2 "$(control_calls)" "no refusal relaunched anything"
  job fresh claude claude-haiku-5-5 high
  : > "$LOG/control.calls"
  FAKE_CONTROL_FAIL=1 tier_tool step-up fresh --trigger failed
  expect_code 1 "$code" "a failed relaunch fails the step"
  assert_equals 0 "$(steps fresh)" "a failed relaunch records no step, so the job keeps its automatic step"
  tier_tool step-up fresh --trigger failed --dry-run
  expect_code 0 "$code" "a dry run exits 0"
  assert_contains "$out" 'tier step-up (dry run): fresh light -> standard: --harness claude --model claude-sonnet-5-5 --effort high' "a dry run prints the choice"
  assert_equals 0 "$(steps fresh)" "a dry run records nothing"
  local summary
  summary=$(FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$DATA" "$RECORD_TOOL" summary --json)
  assert_equals '1 1' "$(jq -r '"\(.step_up["light -> standard (failed)"]) \(.step_up["standard -> strong (failed, by firstmate)"])"' <<<"$summary")" \
    "the summary counts each step up by tiers and trigger"
  assert_equals 'true' "$(jq -r '.tier.standard > 0 and .tier.light > 0' <<<"$summary")" "the summary counts the tier each resolved job took"
  pass "limits: one automatic step per job, a second only as firstmate's call, never into top"
}

fm_test_run test_default_job_takes_standard test_rule_job_ignores_tier test_light_gate \
  test_strong_and_fallbacks test_tier_mode test_schema_errors test_of test_due_detection \
  test_each_trigger_steps_once test_limits
