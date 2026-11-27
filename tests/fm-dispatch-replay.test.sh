#!/usr/bin/env bash
# Behavior tests for bin/fm-dispatch-replay.sh: replaying a home's recorded
# dispatches against a proposed rules file. A fake curl answers each request
# from the brief (a "PICK:rule_<n>" marker, else default), so no case touches
# the network; the proposed file declares shared_quota, so no quota-axi call
# is made either.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-dispatch-replay.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-replay)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/curl.log"
PROPOSED="$TMP_ROOT/proposed.json"
RECORD="$HOME_DIR/data/dispatch-record.jsonl"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/data" "$HOME_DIR/state"

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=''
while [ $# -gt 0 ]; do
  case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac
done
body=$(cat)
printf 'request\n' >> "${FAKE_CURL_LOG:?}"
choice=$(jq -r '(.state.task.brief | capture("PICK:(?<r>rule_[0-9]+)") | .r) // "default"' <<<"$body")
jq -n --argjson body "$body" --arg choice "$choice" '
  ($body.questions.rule.criteria | keys) as $k |
  (if ($k | index([$choice])) then $choice else "default" end) as $c | ($k | length) as $n |
  {model: "jev-test", answers: {rule: {type: "choice", choice: $c, confidence: 0.7,
    probabilities: ($k | map({key: ., value: (if . == $c then 0.7 else (0.3 / ($n - 1)) end)}) | from_entries)}}}' > "$out"
printf 200
SH
chmod +x "$FAKEBIN/curl"
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
echo "quota-axi must not be called" >&2
exit 1
SH
chmod +x "$FAKEBIN/quota-axi"

cat > "$PROPOSED" <<'JSON'
{
  "shared_quota": true,
  "rules": [
    { "when": "Building a whole spec handed over entire.", "facts": ["whole-spec"], "approval": "captain",
      "use": { "harness": "claude", "model": "opus", "effort": "high" } },
    { "when": "Cross-family review of work an OpenAI model built.", "facts": ["review:codex"],
      "use": { "harness": "claude", "model": "opus", "effort": "high" } },
    { "when": "Cross-family review of work a Claude model built.", "facts": ["review:claude"],
      "use": { "harness": "pi", "model": "openai-codex/gpt-6.2-sol", "effort": "xhigh", "provider": "codex" } },
    { "when": "A simple bug fix with a stated root cause.", "facts": ["not:cause-unknown"],
      "use": { "harness": "pi", "model": "openai-codex/gpt-6-luna", "effort": "high", "provider": "codex" } }
  ],
  "default": { "harness": "pi", "model": "openai-codex/gpt-6.2-sol", "effort": "high", "provider": "codex" }
}
JSON

brief() {  # <task> <spec lines...>
  local task=$1
  shift
  mkdir -p "$HOME_DIR/data/$task"
  { printf '# Task\n## Captain'"'"'s intent\nDo the job.\n\n## Firstmate spec\n'; printf '%s\n' "$@"; } > "$HOME_DIR/data/$task/brief.md"
}
brief build-a 'Fix the pager. PICK:rule_4'
brief rev-a 'Review of: build-a'
brief spec-a 'Job: whole spec'
brief odd-a 'Find the stall. PICK:rule_4' 'Cause: unknown'
brief odd-b 'Tidy the docs. PICK:rule_2'
brief unf-a 'Something new.'
{
  printf '%s\n' \
    '{"v":1,"ts":100,"event":"dispatch.resolved","task":"build-a","project":"app","status":"clear","rule":"rule_4"}' \
    '{"v":1,"ts":101,"event":"dispatch.spawned","task":"build-a","project":"app","profile":{"harness":"claude","model":"opus","effort":"high"},"override":false,"matches_resolution":true}' \
    '{"v":1,"ts":150,"event":"dispatch.relaunched","task":"build-a","profile":{"harness":"pi","model":"openai-codex/gpt-6-luna","effort":"high"}}' \
    '{"v":1,"ts":200,"event":"dispatch.resolved","task":"rev-a","project":"app","status":"ambiguous","rule":"default"}' \
    '{"v":1,"ts":201,"event":"dispatch.spawned","task":"rev-a","project":"app","profile":{"harness":"pi","model":"openai-codex/gpt-6.2-sol","effort":"xhigh"},"override":true,"filed_rule":"rule_2"}' \
    '{"v":1,"ts":300,"event":"dispatch.resolved","task":"spec-a","project":"app","status":"ambiguous","rule":"rule_3"}' \
    '{"v":1,"ts":301,"event":"dispatch.spawned","task":"spec-a","project":"app","profile":{"harness":"claude","model":"opus","effort":"high"},"override":true,"filed_rule":"rule_1"}' \
    '{"v":1,"ts":400,"event":"dispatch.spawned","task":"odd-a","project":"app","profile":{"harness":"pi","model":"openai-codex/gpt-6.2-sol","effort":"high"},"override":true,"filed_rule":"default"}' \
    '{"v":1,"ts":500,"event":"dispatch.spawned","task":"odd-b","project":"app","profile":{"harness":"pi","model":"openai-codex/gpt-6-luna","effort":"high"},"override":true,"filed_rule":"rule_4"}' \
    '{"v":1,"ts":600,"event":"dispatch.resolved","task":"unf-a","project":"app","status":"clear","rule":"default"}' \
    '{"v":1,"ts":650,"event":"dispatch.spawned","task":"gone-a","project":"app","profile":{"harness":"claude","model":"opus"},"override":false,"matches_resolution":true}' \
    '{"v":1,"ts":700,"event":"dispatch.relaunched","task":"build-a","profile":{"harness":"claude","model":"opus","effort":"high"}}'
  printf 'not json\n'
} > "$RECORD"
cp "$RECORD" "$TMP_ROOT/record.before"

replay() { PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY=replay-key FAKE_CURL_LOG="$LOG" "$TOOL" "$@"; }

# --- a full replay -------------------------------------------------------------
rm -f "$LOG"
out=$(replay "$PROPOSED" --max-calls 20 2>&1); code=$?
expect_code 0 "$code" "a replay exits 0: $out"
assert_contains "$out" '  jobs: 6 replayed, 1 skipped without saved instructions, 0 past the cap' "every recorded job with saved instructions is replayed"
assert_contains "$out" '  jev_requests: 6 sent (cap 20 runs)' "the printed request count is the requests sent"
assert_equals 6 "$(wc -l < "$LOG" | tr -d ' ')" "one request per replayed job"
assert_contains "$out" '  filed: 5 of 6 replayed jobs have a filing on record' "the filing comes from --dispatch-rule or an accepted clear resolution"
assert_contains "$out" '  rule_agrees: proposed 4 of 5; default-for-everything 1 of 5' "agreement is shown beside the default-for-everything control"
assert_contains "$out" '  model_in_rule: proposed 2 of 5; default-for-everything 2 of 5' "the model that ran is checked against each side's profiles"
assert_contains "$out" '  decided_by_fact: 2' "declared facts settle the review and the whole spec"
# rev-a reviews build-a, which ran on Luna when rev-a was first resolved; the
# later restart on Opus is after that, so the replay must not see it.
assert_contains "$out" '  disagree: odd-b filed rule_4 proposed rule_2 (clear, by jev)' "a disagreement names both rules and who decided"
assert_contains "$out" '  unfiled: unf-a proposed default (clear, by jev)' "a job with no filing is listed apart"
assert_not_contains "$out" 'disagree: rev-a' "the review reads its builder as of the job, so it matches its filing"
assert_not_contains "$out" 'disagree: odd-a' "Cause: unknown takes the bug-fix rule away, so Jev's default matches the filing"
cmp -s "$TMP_ROOT/record.before" "$RECORD" || fail "the replay must not write to the home's dispatch record"
assert_absent "$HOME_DIR/data/rev-a/dispatch-resolution.json" "the replay must not write a task record in the home"
pass "replay: disagreements with the filing are reported beside the default control, from the job's own point in the record"

# --- the cap ---------------------------------------------------------------------
rm -f "$LOG"
out=$(replay "$PROPOSED" --max-calls 2 2>&1); code=$?
expect_code 0 "$code" "a capped replay exits 0"
assert_contains "$out" '  jobs: 2 replayed, 1 skipped without saved instructions, 4 past the cap' "jobs past the cap are counted, not run"
assert_contains "$out" '  jev_requests: 2 sent (cap 2 runs)' "the capped count is printed"
assert_equals 2 "$(wc -l < "$LOG" | tr -d ' ')" "no request past the cap"
rm -f "$LOG"
out=$(replay "$PROPOSED" --max-calls 0 2>&1); code=$?
expect_code 0 "$code" "a zero-cap listing exits 0"
assert_contains "$out" '  job: build-a' "a zero cap lists the jobs it would replay"
assert_contains "$out" '  jev_requests: 0 sent (cap 0 runs)' "a zero cap sends nothing"
assert_absent "$LOG" "a zero cap makes no request"
rm -f "$LOG"
out=$(replay "$PROPOSED" --max-calls 5 --task odd-b 2>&1)
assert_contains "$out" '  jobs: 1 replayed, 0 skipped without saved instructions, 0 past the cap' "--task limits the replay"
pass "replay: --max-calls caps the runs and --task limits them"

# --- usage and configuration errors ----------------------------------------------
replay "$PROPOSED" >/dev/null 2>&1; code=$?
expect_code 2 "$code" "--max-calls is required"
jq '.rules[0].facts = ["spec"]' "$PROPOSED" > "$TMP_ROOT/bad.json"
rm -f "$LOG"
out=$(replay "$TMP_ROOT/bad.json" --max-calls 5 2>&1); code=$?
expect_code 2 "$code" "a proposed file the resolver rejects exits 2"
assert_contains "$out" 'unknown fact: "spec"' "the resolver's reason is shown"
assert_absent "$LOG" "a rejected proposed file sends nothing"
pass "replay: usage and configuration errors exit 2 before any request"

echo "# all fm-dispatch-replay tests passed"
