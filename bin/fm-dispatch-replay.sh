#!/usr/bin/env bash
# fm-dispatch-replay.sh - replay this home's recorded dispatches against a
# proposed config/crew-dispatch.json and report where it disagrees with how
# firstmate filed each job, beside a "default profile for everything" control.
#
# Usage:
#   fm-dispatch-replay.sh <proposed-crew-dispatch.json> --max-calls <n> [--task <id>]...
#
# docs/configuration.md "Typed dispatch resolution" owns what the replay is for
# and how to read it; this header owns the flags and output.
#
# Jobs: every task the home's dispatch record (data/dispatch-record.jsonl, or
#   under FM_DATA_OVERRIDE) names with a dispatch.resolved or dispatch.spawned
#   line and whose saved instructions data/<task>/brief.md still exist, oldest
#   first; --task limits the replay to the named tasks. A task without saved
#   instructions is counted as skipped.
# Each job runs bin/fm-dispatch-resolve.sh once on a copy of its brief, with
#   FM_CONFIG_OVERRIDE naming a scratch config directory that holds the
#   proposed file (plus copies of this home's dispatch-never-send and
#   dispatch-credential-sources.json when present), and FM_DATA_OVERRIDE naming
#   a scratch data directory whose dispatch record holds only this home's lines
#   from before the job's first line, so a "Review of:" lookup sees what it
#   would have seen then. Nothing is written to this home's records; the
#   resolver's own record lines land in the scratch copy and are read back.
#   The project sent is the one the job's record names.
# Cost: each run sends at most one Jev request, plus one retry when a provider
#   rejects the two-question request. --max-calls caps the number of runs; a
#   job past the cap is counted, not run. --max-calls 0 lists the jobs and
#   sends nothing. The count printed is of requests actually sent, read from
#   each run's shadow_tier_note.
# Filing: the rule firstmate recorded with fm-spawn.sh --dispatch-rule on the
#   job's latest dispatch.spawned line; else, for a spawn that took a clear
#   resolution without override, that resolution's rule; else none, and the job
#   counts as unfiled. Rules compare by position (rule_<n>) and default, so a
#   proposed file that reorders its rules must be read with that in mind.
# Control: "default for everything" files every job under default; its model
#   check uses the proposed file's default profiles, or its standard tier when
#   it declares no default.
#
# Output (stdout):
#   dispatch-replay:
#     config: <path>
#     jobs: <n> replayed, <n> skipped without saved instructions, <n> past the cap
#     jev_requests: <n> sent (cap <n> runs)
#     filed: <n> of <n> replayed jobs have a filing on record
#     rule_agrees: proposed <n> of <filed>; default-for-everything <n> of <filed>
#     model_in_rule: proposed <n> of <spawned>; default-for-everything <n> of <spawned>
#     decided_by_fact: <n>
#     disagree: <task> filed <rule> proposed <rule> (<status>, by <jev|fact[ <fact>]>)
#     unfiled: <task> proposed <rule> (<status>, by ...)
#     job: <task> (with --max-calls 0, one per job that would run)
#   model_in_rule counts jobs whose latest spawn profile (harness and model) is
#   one of the replayed rule's profiles, or of the control's.
#
# Exit status: 0 on a finished replay; 2 on a usage error, an unreadable
# record or proposed file, or a proposed file the resolver rejects.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
HOME_CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RESOLVE="$SCRIPT_DIR/fm-dispatch-resolve.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}
die() { printf 'error: %s\n' "$1" >&2; exit 2; }

PROPOSED='' MAX_CALLS='' TASKS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --max-calls) [ $# -ge 2 ] || die "--max-calls needs a value"; MAX_CALLS=$2; shift 2 ;;
    --task) [ $# -ge 2 ] || die "--task needs a value"; TASKS+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$PROPOSED" ] || die "one proposed config only"; PROPOSED=$1; shift ;;
  esac
done
[ -n "$PROPOSED" ] || die "a proposed crew-dispatch.json is required (see --help)"
case "$MAX_CALLS" in ''|*[!0-9]*) die "--max-calls <n> is required: the most resolver runs, each one Jev request" ;; esac
command -v jq >/dev/null 2>&1 || die "jq required"
[ -f "$PROPOSED" ] && [ -r "$PROPOSED" ] || die "proposed config not readable: $PROPOSED"
jq -e 'type == "object"' "$PROPOSED" >/dev/null 2>&1 || die "proposed config is not a JSON object: $PROPOSED"
RECORD="${DATA%/}/dispatch-record.jsonl"
[ -f "$RECORD" ] && [ -r "$RECORD" ] || die "no readable dispatch record: $RECORD"

SCRATCH=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/config" || die "could not make the scratch config"
cp "$PROPOSED" "$SCRATCH/config/crew-dispatch.json" || die "could not copy $PROPOSED"
for f in dispatch-never-send dispatch-credential-sources.json; do
  if [ -e "$HOME_CONFIG/$f" ]; then cp "$HOME_CONFIG/$f" "$SCRATCH/config/$f" || die "could not copy $HOME_CONFIG/$f"; fi
done

# Every recorded job, oldest first: its first line's time, project, latest
# spawn profile, and filing.
JOBS=$(jq -Rnc --argjson only "$(printf '%s\n' "${TASKS[@]+"${TASKS[@]}"}" | jq -Rsc 'split("\n") | map(select(length > 0))')" '
  [inputs | (try fromjson catch null) | select(type == "object" and (.task | type) == "string" and (.ts | type) == "number")] as $all |
  [$all[] | select(.event == "dispatch.resolved" or .event == "dispatch.spawned") | .task] as $named |
  ($named | reduce .[] as $t ([]; if index([$t]) then . else . + [$t] end)) as $tasks |
  [$tasks[] | select(($only | length) == 0 or (. as $t | $only | index([$t]))) | . as $t |
    [$all[] | select(.task == $t)] as $mine |
    ([$mine[] | select(.event == "dispatch.spawned")] | last) as $spawn |
    ([$mine[] | select(.event == "dispatch.resolved" and ($spawn == null or .ts <= $spawn.ts))] | last) as $res |
    {task: $t, first_ts: ($mine | map(.ts) | min),
     project: ($res.project // $spawn.project // null),
     ran: ($spawn.profile // null),
     filed: (if $spawn == null then null
       elif ($spawn.filed_rule | type) == "string" then $spawn.filed_rule
       elif $spawn.override == false and $spawn.matches_resolution == true and ($res.rule | type) == "string" then $res.rule
       else null end)}]
  | sort_by(.first_ts)' "$RECORD" 2>/dev/null) || die "could not read the dispatch record: $RECORD"

runs=0 requests=0 skipped=0 past_cap=0 RESULTS='[]' LISTED=()
while IFS= read -r job; do
  [ -n "$job" ] || continue
  task=$(jq -r .task <<<"$job")
  brief="${DATA%/}/$task/brief.md"
  if [ ! -f "$brief" ]; then skipped=$((skipped + 1)); continue; fi
  if [ "$runs" -ge "$MAX_CALLS" ]; then
    past_cap=$((past_cap + 1))
    [ "$MAX_CALLS" -ne 0 ] || LISTED+=("$task")
    continue
  fi
  runs=$((runs + 1))
  run_data="$SCRATCH/data-$runs"
  mkdir -p "$run_data/$task" || die "could not make a scratch data directory"
  cp "$brief" "$run_data/$task/brief.md" || die "could not copy $brief"
  first_ts=$(jq -r .first_ts <<<"$job")
  jq -Rr --argjson before "$first_ts" '
    . as $line | (try fromjson catch null) | select(type == "object" and (.ts | type) == "number" and .ts < $before) | $line' \
    "$RECORD" > "$run_data/dispatch-record.jsonl" 2>/dev/null || die "could not copy the dispatch record"
  project=$(jq -r '.project // ""' <<<"$job")
  args=("$run_data/$task/brief.md")
  [ -z "$project" ] || args+=(--project "$project")
  FM_HOME=$FM_HOME FM_DATA_OVERRIDE=$run_data FM_CONFIG_OVERRIDE=$SCRATCH/config \
    "$RESOLVE" "${args[@]}" > "$SCRATCH/out" 2> "$SCRATCH/err"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    printf 'error: the resolver rejected the proposed config: %s\n' "$(tail -n 1 "$SCRATCH/err")" >&2
    exit 2
  fi
  line=$(jq -Rnc --arg task "$task" '[inputs | (try fromjson catch null) | select(type == "object" and .event == "dispatch.resolved" and .task == $task)] | last // {}' \
    "$run_data/dispatch-record.jsonl" 2>/dev/null) || line='{}'
  case "$(jq -r '.shadow_tier_note // "not asked"' <<<"$line")" in
    'not asked') ;;
    *retried*) requests=$((requests + 2)) ;;
    *) requests=$((requests + 1)) ;;
  esac
  RESULTS=$(jq -c --argjson job "$job" --argjson line "$line" '. + [$job + {got: $line}]' <<<"$RESULTS")
  rm -rf "$run_data"
done < <(jq -c '.[]' <<<"$JOBS")

if [ "$MAX_CALLS" -eq 0 ]; then
  printf 'dispatch-replay:\n  config: %s\n  jobs: 0 replayed, %s skipped without saved instructions, %s past the cap\n  jev_requests: 0 sent (cap 0 runs)\n' \
    "$PROPOSED" "$skipped" "$past_cap"
  for t in "${LISTED[@]+"${LISTED[@]}"}"; do printf '  job: %s\n' "$t"; done
  exit 0
fi

jq -r --slurpfile cfg "$PROPOSED" --arg config "$PROPOSED" --argjson skipped "$skipped" --argjson past "$past_cap" \
  --argjson requests "$requests" --argjson cap "$MAX_CALLS" '
  ($cfg[0]) as $c |
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  def control_use: if $c | has("default") then profiles($c.default) else profiles($c.tiers.standard.use // null) end;
  def rule_use($rule; $tier):
    if ($rule | type) != "string" then []
    elif $rule == "default" then (if ($tier | type) == "string" then profiles($c.tiers[$tier].use // null) else control_use end)
    else profiles(($c.rules // [])[($rule | ltrimstr("rule_") | tonumber) - 1].use // null) end;
  def runs_in($ran; $use): $ran != null and any($use[]; .harness == $ran.harness and ((.model // null) == ($ran.model // null)));
  def by($g): if $g.decided_by == "fact" then "fact \($g.fact // "")" else ($g.decided_by // "no answer") end;
  def show($v): if $v == null then "none" else $v end;
  . as $rs |
  [$rs[] | select(.filed != null)] as $filed |
  [$rs[] | select(.ran != null)] as $ran |
  "dispatch-replay:",
  "  config: \($config)",
  "  jobs: \($rs | length) replayed, \($skipped) skipped without saved instructions, \($past) past the cap",
  "  jev_requests: \($requests) sent (cap \($cap) runs)",
  "  filed: \($filed | length) of \($rs | length) replayed jobs have a filing on record",
  "  rule_agrees: proposed \([$filed[] | select(.got.rule == .filed)] | length) of \($filed | length); default-for-everything \([$filed[] | select(.filed == "default")] | length) of \($filed | length)",
  "  model_in_rule: proposed \([$ran[] | select(runs_in(.ran; rule_use(.got.rule; .got.tier)))] | length) of \($ran | length); default-for-everything \([$ran[] | select(runs_in(.ran; control_use))] | length) of \($ran | length)",
  "  decided_by_fact: \([$rs[] | select(.got.decided_by == "fact")] | length)",
  ($filed[] | select(.got.rule != .filed)
    | "  disagree: \(.task) filed \(.filed) proposed \(show(.got.rule)) (\(show(.got.status)), by \(by(.got)))"),
  ($rs[] | select(.filed == null)
    | "  unfiled: \(.task) proposed \(show(.got.rule)) (\(show(.got.status)), by \(by(.got)))")
' <<<"$RESULTS"
