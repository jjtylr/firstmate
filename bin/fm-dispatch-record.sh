#!/usr/bin/env bash
# fm-dispatch-record.sh - write and read the per-dispatch record.
#
# docs/configuration.md "Dispatch record (data/dispatch-record.jsonl)" owns the
# record's purpose, location, events, and fields. bin/fm-dispatch-record-lib.sh
# owns the path and the append. This header owns these subcommands:
#
# Usage:
#   fm-dispatch-record.sh spawned <task> --kind <ship|scout> --project <name>
#       --harness <h> [--model <m>] [--effort <e>] [--override <reason>]
#   fm-dispatch-record.sh relaunched <task> --harness <h> [--model <m>]
#       [--effort <e>] [--via <control|spawn>]
#   fm-dispatch-record.sh outcome <task> <merged|landed_local|report_done|not_landed>
#       [--forced] [--pr <url>]
#   fm-dispatch-record.sh summary [--json]
#
# Producers:
#   bin/fm-dispatch-resolve.sh  dispatch.resolved (through the library)
#   bin/fm-spawn.sh             spawned (fresh ship and scout launches) and
#                               relaunched (every --relaunch of one)
#   bin/fm-teardown.sh          outcome (ship and scout cleanup)
#   bin/fm-tier.sh              dispatch.stepped_up (through the library)
#
# spawned also copies the status and profile from the task's
# data/<task>/dispatch-resolution.json when one exists, and says whether the
# launched profile matches a clear resolution. An empty or "default" model or
# effort is recorded as null.
# outcome writes only when the record already names the task, so a task that
# predates the record, or a home that never resolved or spawned it, gains no
# orphan outcome. It also records how many relaunched records follow the task's
# latest spawned record and the profile of the last of them.
# summary reads every line, skips lines that are not JSON objects (and counts
# them), and prints counts per rule, per shadow tier, and per tier taken over
# each task's latest dispatch.resolved record, per step up (from, to, and
# trigger) over every dispatch.stepped_up record, and per outcome over each
# spawned or closed task's latest outcome ("no outcome yet" while none).
# --json prints the same counts as one JSON object.
#
# Environment: FM_HOME and FM_DATA_OVERRIDE resolve the data directory exactly
# as bin/fm-spawn.sh does.
#
# Exit status: 0 on success, on a skipped outcome, and when summary finds no
# record; 2 on a usage error; 1 when a record could not be written or read.
# Producers ignore a failure so it never changes theirs.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-dispatch-record-lib.sh
. "$SCRIPT_DIR/fm-dispatch-record-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
  exit 2
}

task_ok() {
  case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

command -v jq >/dev/null 2>&1 || { echo "error: jq required" >&2; exit 1; }

cmd=${1:-}
[ $# -gt 0 ] && shift
TASK='' KIND='' PROJECT='' HARNESS='' MODEL='' EFFORT='' OVERRIDE='' OVERRIDE_SET=0
VIA='' OUTCOME='' FORCED=false PR='' JSON=0
case "$cmd" in
  spawned|relaunched|outcome)
    task_ok "${1:-}" || usage
    TASK=$1; shift ;;
  summary) ;;
  -h|--help) usage ;;
  *) usage ;;
esac
if [ "$cmd" = outcome ]; then
  case "${1:-}" in merged|landed_local|report_done|not_landed) OUTCOME=$1; shift ;; *) usage ;; esac
fi
while [ $# -gt 0 ]; do
  case "$cmd:$1" in
    spawned:--kind) [ $# -ge 2 ] || usage; KIND=$2; shift 2 ;;
    spawned:--project) [ $# -ge 2 ] || usage; PROJECT=$2; shift 2 ;;
    spawned:--override) [ $# -ge 2 ] || usage; OVERRIDE=$2; OVERRIDE_SET=1; shift 2 ;;
    spawned:--harness|relaunched:--harness) [ $# -ge 2 ] || usage; HARNESS=$2; shift 2 ;;
    spawned:--model|relaunched:--model) [ $# -ge 2 ] || usage; MODEL=$2; shift 2 ;;
    spawned:--effort|relaunched:--effort) [ $# -ge 2 ] || usage; EFFORT=$2; shift 2 ;;
    relaunched:--via) [ $# -ge 2 ] || usage; VIA=$2; shift 2 ;;
    outcome:--forced) FORCED=true; shift ;;
    outcome:--pr) [ $# -ge 2 ] || usage; PR=$2; shift 2 ;;
    summary:--json) JSON=1; shift ;;
    *) usage ;;
  esac
done

# A launch flag left at its harness default is recorded as null.
profile_json() {
  jq -cn --arg h "$HARNESS" --arg m "$MODEL" --arg e "$EFFORT" '
    def opt($v): if $v == "" or $v == "default" then null else $v end;
    {harness: $h, model: opt($m), effort: opt($e)}'
}

case "$cmd" in
  spawned)
    case "$KIND" in ship|scout) ;; *) usage ;; esac
    [ -n "$PROJECT" ] && [ -n "$HARNESS" ] || usage
    resolution=null
    res_path="$DATA/$TASK/dispatch-resolution.json"
    if [ -f "$res_path" ]; then
      resolution=$(jq -c --arg task "$TASK" '
        select(type == "object" and .task == $task) | {status, profile}' "$res_path" 2>/dev/null) || resolution=null
      [ -n "$resolution" ] || resolution=null
    fi
    record=$(jq -cn --arg task "$TASK" --arg kind "$KIND" --arg project "$PROJECT" \
      --argjson profile "$(profile_json)" --argjson resolution "$resolution" \
      --arg override "$OVERRIDE" --argjson override_set "$OVERRIDE_SET" '
      {event: "dispatch.spawned", task: $task, kind: $kind, project: $project,
       profile: $profile,
       override: ($override_set == 1), override_reason: (if $override_set == 1 then $override else null end),
       resolution_status: ($resolution.status // null),
       resolution_profile: ($resolution.profile // null),
       matches_resolution: (if ($resolution.status // null) == "clear" and ($resolution.profile | type) == "object"
         then ($resolution.profile.harness == $profile.harness
           and (($resolution.profile.model // null) == null or $resolution.profile.model == $profile.model)
           and (($resolution.profile.effort // null) == null or $resolution.profile.effort == $profile.effort))
         else null end)}') || exit 1
    fm_dispatch_record_append "$DATA" "$record" || exit 1
    ;;
  relaunched)
    [ -n "$HARNESS" ] || usage
    case "$VIA" in ''|control|spawn) ;; *) usage ;; esac
    record=$(jq -cn --arg task "$TASK" --argjson profile "$(profile_json)" --arg via "$VIA" '
      {event: "dispatch.relaunched", task: $task, profile: $profile,
       via: (if $via == "" then null else $via end)}') || exit 1
    fm_dispatch_record_append "$DATA" "$record" || exit 1
    ;;
  outcome)
    fm_dispatch_record_has_task "$DATA" "$TASK" || exit 0
    path=$(fm_dispatch_record_path "$DATA")
    relaunch=$(jq -Rnc --arg task "$TASK" '
      [inputs | (try fromjson catch null) | select(type == "object" and .task == $task)] as $mine
      | ([$mine | to_entries[] | select(.value.event == "dispatch.spawned") | .key] | last // -1) as $start
      | [$mine | to_entries[] | select(.key > $start and .value.event == "dispatch.relaunched") | .value]
      | {relaunched: length, relaunched_to: (last.profile // null)}' "$path" 2>/dev/null) || exit 1
    record=$(jq -cn --arg task "$TASK" --arg outcome "$OUTCOME" --argjson forced "$FORCED" \
      --arg pr "$PR" --argjson relaunch "$relaunch" '
      {event: "dispatch.outcome", task: $task, outcome: $outcome, forced: $forced,
       pr: (if $pr == "" then null else $pr end)} + $relaunch') || exit 1
    fm_dispatch_record_append "$DATA" "$record" || exit 1
    ;;
  summary)
    path=$(fm_dispatch_record_path "$DATA")
    if [ ! -e "$path" ]; then
      if [ "$JSON" = 1 ]; then
        jq -cn --arg path "$path" '{path: $path, records: 0}'
      else
        printf 'dispatch-record: no records yet (%s)\n' "$path"
      fi
      exit 0
    fi
    [ -r "$path" ] || { echo "error: dispatch record not readable: $path" >&2; exit 1; }
    counts=$(jq -Rn --arg path "$path" '
      [inputs | select(length > 0) | (try fromjson catch null)] as $all
      | [$all[] | select(type == "object")] as $recs
      | def latest($event): [$recs[] | select(.event == $event)] | group_by(.task) | map(last);
      def tally(f): group_by(f) | map({key: (.[0] | f), value: length}) | sort_by(-.value, .key) | from_entries;
      latest("dispatch.resolved") as $resolved
      | latest("dispatch.spawned") as $spawned
      | latest("dispatch.outcome") as $outcomes
      | ($outcomes | map({key: .task, value: .outcome}) | from_entries) as $by_task
      | {path: $path,
         records: ($recs | length),
         unreadable: ([$all[] | select(type != "object")] | length),
         tasks: {
           resolved: ($resolved | length),
           spawned: ($spawned | length),
           relaunched: ([$recs[] | select(.event == "dispatch.relaunched") | .task] | unique | length),
           with_outcome: ($outcomes | length)},
         rule: ($resolved | tally(
           if (.rule | type) == "string"
           then .rule + (if (.rule_when | type) == "string" then " (" + .rule_when[0:50] + ")" else "" end)
           else "none (" + (.status // "unknown") + ")" end)),
         shadow_tier: ($resolved | tally(
           if (.shadow_tier.choice | type) == "string" then .shadow_tier.choice
           else "none (" + (.shadow_tier_note // "not asked") + ")" end)),
         tier: ($resolved | map(select((.tier | type) == "string")) | tally(.tier)),
         step_up: ([$recs[] | select(.event == "dispatch.stepped_up")]
           | tally("\(.from_tier // "?") -> \(.to_tier // "?") (\(.trigger // "?")\(if .automatic == false then ", by firstmate" else "" end))")),
         outcome: ([$spawned[].task, $outcomes[].task] | unique
           | map($by_task[.] // "no outcome yet") | tally(.))}' "$path" 2>/dev/null) \
      || { echo "error: could not read dispatch record: $path" >&2; exit 1; }
    if [ "$JSON" = 1 ]; then
      printf '%s\n' "$counts"
    else
      jq -r '
        def flat: tostring | gsub("[\t\r\n]"; " ");
        def section($name; $obj):
          "  \($name):", (if ($obj | length) == 0 then "    (none)" else ($obj | to_entries[] | "    \(.key | flat): \(.value)") end);
        "dispatch-record: \(.path)",
        "  records: \(.records)" + (if .unreadable > 0 then " (\(.unreadable) unreadable line(s) skipped)" else "" end),
        "  tasks: \(.tasks.resolved) resolved, \(.tasks.spawned) spawned, \(.tasks.relaunched) relaunched, \(.tasks.with_outcome) with an outcome",
        section("rule"; .rule),
        section("shadow_tier"; .shadow_tier),
        section("tier"; .tier),
        section("step_up"; .step_up),
        section("outcome"; .outcome)' <<<"$counts"
    fi
    ;;
esac
exit 0
