#!/usr/bin/env bash
# fm-tier.sh - read a job's worker tier, find jobs that are due one step up,
# and restart a job fresh one tier up.
#
# docs/configuration.md "Worker tiers" owns the tier table, the triggers, and
# the step-up limits. bin/fm-tier-lib.sh owns the table's shared validation.
# This header owns the subcommands:
#
# Usage:
#   fm-tier.sh of <task>
#   fm-tier.sh due [--once] [<task>...]
#   fm-tier.sh step-up <task> --trigger <trigger> [--detail <text>]
#       [--notes-file <path>] [--by-firstmate] [--dry-run]
#   fm-tier.sh arm
#
#   of       Prints the job's tier (read from the harness, model, and effort
#            its task record names, matched exactly against the tier table),
#            the tier above it, its time budget and elapsed time, and whether
#            its one automatic step up is spent.
#   due      Prints one line per running ship or scout (or per named task)
#            that is due its automatic step up, naming the trigger and the
#            command to run:
#              failed        the worker's latest status line is failed:
#              blocked       the worker's latest status line is blocked:
#              check-failed-twice  state/pr-health.json shows one check of
#                            the task's PR failing at two different commits
#              over-budget   the worker has run past its tier's
#                            budget_minutes and its latest line is not done:,
#                            paused:, or needs-decision:
#            Only a status line stamped at or after the current worker's
#            launch counts. A job whose automatic step is spent, whose next
#            tier is top, or whose profile is not a tier profile is never due:
#            those are firstmate's call. With --once, a line already printed
#            for the same task, trigger, and evidence is not printed again
#            (state/.tier-due-seen), so a watcher check wakes once per event.
#   step-up  Restarts the job fresh one tier up: chooses the next tier's
#            profile with `fm-dispatch-resolve.sh --tier <next>` (the same
#            quota-aware choice as any profile array), then runs
#            `fm-control.sh <task> relaunch --harness --model --effort
#            --note-file`, whose note (appended to the job's unchanged
#            instructions) names the step, the trigger, the previous worker's
#            profile and latest status reports, and any --notes-file text.
#            Triggers are the four above plus review-class-a (a review found
#            a class-A defect the worker could not fix in its round), which
#            only firstmate's judgement can name. On success it appends one
#            dispatch.stepped_up line to the dispatch record.
#            Refusals, with nothing changed: the profile is not a tier
#            profile; the job is on top; the next tier is top (the captain
#            approves each top job); the job's automatic step is spent and
#            --by-firstmate was not given (a second step is firstmate's
#            call); the dispatch record cannot be read; the next tier's
#            choice is not clear; another step up of the job is in progress.
#            --dry-run prints the chosen profile and the note and changes
#            nothing.
#   arm      Writes state/tier-step.check.sh, which runs `due --once`, and
#            binds it through fm-check-register.sh, so the watcher's check
#            sweep wakes firstmate when a job is due.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_DATA_OVERRIDE, and
#   FM_CONFIG_OVERRIDE resolve the home as the other scripts do.
#   FM_TIER_CONTROL_BIN replaces bin/fm-control.sh for tests.
#
# Exit status: 0 on success, on a dry run, and when nothing is due; 1 on a
#   refusal or a failed relaunch; 2 on a usage or configuration error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RULES="$CONFIG/crew-dispatch.json"
CONTROL_BIN="${FM_TIER_CONTROL_BIN:-$SCRIPT_DIR/fm-control.sh}"

# shellcheck source=bin/fm-tier-lib.sh
. "$SCRIPT_DIR/fm-tier-lib.sh"
# shellcheck source=bin/fm-dispatch-record-lib.sh
. "$SCRIPT_DIR/fm-dispatch-record-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
  exit 2
}
die() { printf 'error: %s\n' "$1" >&2; exit 2; }
refuse() { printf 'tier step-up refused: %s\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq required"

TRIGGERS='failed blocked check-failed-twice over-budget review-class-a'
trigger_text() {
  case "$1" in
    failed) echo "the worker reported failed" ;;
    blocked) echo "the worker reported blocked" ;;
    check-failed-twice) echo "the same required check failed twice" ;;
    over-budget) echo "the job ran past its tier's time budget" ;;
    review-class-a) echo "a review found a class-A defect the worker could not fix in its round" ;;
  esac
}

# ---- the tier table ------------------------------------------------------------
load_tiers() {
  local err
  [ -f "$RULES" ] || die "no tier table: $RULES does not exist"
  err=$(jq -r "$FM_TIER_JQ"'
    if type != "object" then "top-level value must be an object"
    elif (.tiers | type) != "object" then "no tiers declared"
    else (fm_tier_err // empty) end' "$RULES" 2>/dev/null) || die "malformed rules file: $RULES (not JSON)"
  [ -z "$err" ] || die "tier table in $RULES: $err"
}

tier_of_profile() {  # <harness> <model> <effort>
  jq -r --arg h "$1" --arg m "$2" --arg e "$3" "$FM_TIER_JQ"'fm_tier_of($h; $m; $e) // ""' "$RULES"
}

# The next tier present in the table above <tier>, or empty.
tier_above() {  # <tier>
  local seen=0 t
  for t in $FM_TIER_ORDER; do
    if [ "$seen" = 1 ] && jq -e --arg t "$t" '.tiers | has($t)' "$RULES" >/dev/null 2>&1; then
      printf '%s\n' "$t"
      return 0
    fi
    [ "$t" = "$1" ] && seen=1
  done
  return 0
}

tier_budget() {  # <tier> -> minutes, or empty
  jq -r --arg t "$1" '.tiers[$t].budget_minutes // empty' "$RULES"
}

# ---- one task's records --------------------------------------------------------
TASK='' META='' T_KIND='' T_HARNESS='' T_MODEL='' T_EFFORT='' T_TIER='' T_NEXT=''
T_LAUNCH='' STEPS_JSON='' T_STATUS=''
load_task() {  # <task>
  TASK=$1
  fm_pr_task_id_valid "$TASK" || die "invalid task id: $TASK"
  META="$STATE/$TASK.meta"
  [ -f "$META" ] || die "no task record for $TASK in this home: $META"
  T_KIND=$(fm_meta_get "$META" kind)
  T_HARNESS=$(fm_meta_get "$META" harness)
  T_MODEL=$(fm_meta_get "$META" model)
  T_EFFORT=$(fm_meta_get "$META" effort)
  T_STATUS="$STATE/$TASK.status"
  T_TIER=''
  T_NEXT=''
  if [ -n "$T_HARNESS" ] && [ -n "$T_MODEL" ] && [ -n "$T_EFFORT" ]; then
    T_TIER=$(tier_of_profile "$T_HARNESS" "$T_MODEL" "$T_EFFORT")
  fi
  [ -z "$T_TIER" ] || T_NEXT=$(tier_above "$T_TIER")
  load_record
}

# The current worker's launch time and this job's step-up history, read from
# the dispatch record since the task's latest dispatch.spawned. STEPS_JSON is
# empty when the record exists but cannot be read, so no limit is ever proven
# from a record nobody could read.
load_record() {
  local path gen
  path=$(fm_dispatch_record_path "$DATA")
  T_LAUNCH=''
  STEPS_JSON='{"automatic":0,"total":0,"last":null,"launch":null}'
  if [ -e "$path" ]; then
    STEPS_JSON=$(jq -Rnc --arg task "$TASK" '
      [inputs | (try fromjson catch null) | select(type == "object" and .task == $task)] as $mine
      | ([$mine | to_entries[] | select(.value.event == "dispatch.spawned") | .key] | last // -1) as $start
      | [$mine | to_entries[] | select(.key >= $start) | .value] as $cur
      | [$cur[] | select(.event == "dispatch.stepped_up")] as $steps
      | {automatic: ([$steps[] | select(.automatic == true)] | length),
         total: ($steps | length),
         last: ($steps | last // null),
         launch: ([$cur[] | select(.event == "dispatch.spawned" or .event == "dispatch.relaunched") | .ts | numbers] | last // null)}' \
      "$path" 2>/dev/null) || STEPS_JSON=''
  fi
  if [ -n "$STEPS_JSON" ]; then
    T_LAUNCH=$(jq -r '.launch // empty' <<<"$STEPS_JSON")
  fi
  if [ -z "$T_LAUNCH" ]; then
    gen=$(fm_meta_get "$META" spawn_gen)
    gen=${gen#s}
    gen=${gen%%.*}
    case "$gen" in ''|*[!0-9]*) ;; *) T_LAUNCH=$gen ;; esac
  fi
}

automatic_spent() {
  [ -n "$STEPS_JSON" ] && [ "$(jq -r '.automatic' <<<"$STEPS_JSON")" -gt 0 ]
}

# ---- trigger detection ---------------------------------------------------------
# Prints "<trigger>\t<evidence signature>\t<detail>" for the first trigger that
# holds for the loaded task, or nothing.
detect_trigger() {
  local line verb at now budget elapsed pr health
  line=$(last_crew_status_line "$T_STATUS")
  verb=''
  at=''
  if [ -n "$line" ]; then
    status_line_verb "$line" verb
    at=$(status_line_at_epoch "$line") || at=''
  fi
  if [ -n "$at" ] && [ -n "$T_LAUNCH" ] && [ "$at" -ge "$T_LAUNCH" ]; then
    case "$verb" in
      failed|blocked)
        printf '%s\t%s\t%s\n' "$verb" "$at" "$(status_line_note "$line" | cut -c1-160)"
        return 0 ;;
    esac
  fi
  pr=$(fm_meta_get "$META" pr)
  health="$STATE/pr-health.json"
  if [ -n "$pr" ] && [ -f "$health" ]; then
    jq -r --arg url "$pr" '
      select(.schema == "fm-pr-health.v1") | (.prs[$url].checks // [])
      | group_by(.name) | map(select(([.[].head] | unique | length) >= 2)) | first // empty
      | "check-failed-twice\t\(.[0].name):\([.[].head] | unique | length)\tcheck \(.[0].name) failed at \([.[].head] | unique | length) commits"' \
      "$health" 2>/dev/null | head -n 1 | grep . && return 0
  fi
  budget=$(tier_budget "$T_TIER")
  if [ -n "$budget" ] && [ -n "$T_LAUNCH" ]; then
    case "$verb" in done|paused|needs-decision) return 0 ;; esac
    now=$(date +%s)
    elapsed=$(( (now - T_LAUNCH) / 60 ))
    if jq -en --argjson e "$elapsed" --argjson b "$budget" '$e > $b' >/dev/null; then
      printf 'over-budget\t%s\t%s\n' "$T_LAUNCH" "running ${elapsed}m against a ${budget}m budget"
    fi
  fi
  return 0
}

cmd_due() {
  local once=0 tasks=() t found seen_file sig trigger detail key
  while [ $# -gt 0 ]; do
    case "$1" in
      --once) once=1; shift ;;
      -*) usage ;;
      *) tasks+=("$1"); shift ;;
    esac
  done
  load_tiers
  if [ "${#tasks[@]}" -eq 0 ]; then
    for t in "$STATE"/*.meta; do
      [ -f "$t" ] || continue
      case "$(fm_meta_get "$t" kind)" in ship|scout) tasks+=("$(basename "$t" .meta)") ;; esac
    done
  fi
  seen_file="$STATE/.tier-due-seen"
  for t in "${tasks[@]+"${tasks[@]}"}"; do
    load_task "$t"
    case "$T_KIND" in ship|scout) ;; *) continue ;; esac
    [ -n "$T_TIER" ] && [ -n "$T_NEXT" ] && [ "$T_NEXT" != top ] || continue
    [ -n "$STEPS_JSON" ] || continue
    automatic_spent && continue
    found=$(detect_trigger)
    [ -n "$found" ] || continue
    IFS=$'\t' read -r trigger sig detail <<<"$found"
    key="$TASK"$'\t'"$trigger"$'\t'"$sig"
    if [ "$once" = 1 ]; then
      if [ -f "$seen_file" ] && grep -qxF -- "$key" "$seen_file" 2>/dev/null; then continue; fi
      printf '%s\n' "$key" >> "$seen_file" 2>/dev/null || true
    fi
    printf 'tier-step-up due: %s %s on %s (%s); run bin/fm-tier.sh step-up %s --trigger %s\n' \
      "$TASK" "$trigger" "$T_TIER" "$detail" "$TASK" "$trigger"
  done
  return 0
}

cmd_of() {
  [ $# -eq 1 ] || usage
  load_tiers
  load_task "$1"
  local budget elapsed='-' spent
  budget=$(tier_budget "${T_TIER:-none}")
  [ -z "$T_LAUNCH" ] || elapsed="$(( ($(date +%s) - T_LAUNCH) / 60 ))m"
  if [ -z "$STEPS_JSON" ]; then spent='unknown (dispatch record unreadable)'
  elif automatic_spent; then spent=yes
  else spent=no; fi
  printf 'tier:\n  task: %s\n  profile: %s %s %s\n  tier: %s\n  above: %s\n  budget: %s\n  elapsed: %s\n  automatic step spent: %s\n' \
    "$TASK" "${T_HARNESS:--}" "${T_MODEL:--}" "${T_EFFORT:--}" "${T_TIER:-none (not a tier profile)}" \
    "${T_NEXT:--}" "${budget:+${budget}m}" "$elapsed" "$spent"
}

# ---- step up -------------------------------------------------------------------
LOCK=''
cmd_step_up() {
  local trigger='' detail='' notes='' by_fm=0 dry=0 out status profile h m e note lock_dir record
  [ $# -ge 1 ] || usage
  local task=$1
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --trigger) [ $# -ge 2 ] || usage; trigger=$2; shift 2 ;;
      --detail) [ $# -ge 2 ] || usage; detail=$2; shift 2 ;;
      --notes-file) [ $# -ge 2 ] || usage; notes=$2; shift 2 ;;
      --by-firstmate) by_fm=1; shift ;;
      --dry-run) dry=1; shift ;;
      *) usage ;;
    esac
  done
  case " $TRIGGERS " in *" $trigger "*) [ -n "$trigger" ] || usage ;; *) die "unknown trigger '$trigger' (one of: $TRIGGERS)" ;; esac
  [ -z "$notes" ] || [ -r "$notes" ] || die "notes file not readable: $notes"
  case "$detail" in *[![:print:]]*) die "--detail must be one printable line" ;; esac
  load_tiers
  load_task "$task"
  case "$T_KIND" in ship|scout) ;; *) refuse "$TASK is a ${T_KIND:-task with no kind}; only a ship or scout steps up a tier" ;; esac
  [ -n "$T_TIER" ] || refuse "$TASK runs ${T_HARNESS:-?} ${T_MODEL:-default} ${T_EFFORT:-default}, which is not a profile in the tier table; choose its next profile by hand"
  [ "$T_TIER" != top ] || refuse "$TASK is already on the top tier"
  [ -n "$T_NEXT" ] || refuse "no tier above $T_TIER is configured"
  [ "$T_NEXT" != top ] || refuse "the tier above $T_TIER is top, and the captain approves each top job; ask the captain before moving $TASK"
  [ -n "$STEPS_JSON" ] || refuse "the dispatch record cannot be read, so this job's step-up limit cannot be checked"
  if automatic_spent && [ "$by_fm" = 0 ]; then
    refuse "$TASK already had its one automatic step up ($(jq -r '.last | "\(.from_tier) to \(.to_tier), \(.trigger)"' <<<"$STEPS_JSON")); a second step is firstmate's call: rerun with --by-firstmate"
  fi

  lock_dir="$STATE/.tier-step-$TASK.lock"
  if [ "$dry" = 0 ]; then
    mkdir "$lock_dir" 2>/dev/null || refuse "another step up of $TASK is in progress ($lock_dir)"
    LOCK=$lock_dir
    trap '[ -z "$LOCK" ] || rmdir "$LOCK" 2>/dev/null' EXIT
  fi

  out=$(FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-dispatch-resolve.sh" --tier "$T_NEXT" 2>&1)
  status=$(sed -n 's/^  status: //p' <<<"$out" | head -n 1)
  profile=$(sed -n 's/^  profile: //p' <<<"$out" | head -n 1)
  if [ "$status" != clear ] || [ -z "$profile" ]; then
    printf '%s\n' "$out" >&2
    refuse "the $T_NEXT tier's choice is ${status:-unavailable}, not clear; choose $TASK's next profile by hand"
  fi
  # The resolver prints the chosen profile as shell-quoted flags; read it back
  # as the tier profile it names, never by splitting the line.
  IFS=$'\t' read -r h m e < <(jq -r --arg t "$T_NEXT" --arg p "$profile" "$FM_TIER_JQ"'
    [fm_tier_as_list(.tiers[$t].use)[]
     | select("--harness \(.harness | @sh) --model \(.model | @sh) --effort \(.effort | @sh)" == $p)]
    | first // empty | [.harness, .model, .effort] | @tsv' "$RULES" 2>/dev/null) || true
  [ -n "$h" ] && [ -n "$m" ] && [ -n "$e" ] || refuse "the $T_NEXT tier's choice ($profile) is not one of its profiles"

  note=$(mktemp) || die "mktemp failed"
  {
    printf 'You are a fresh worker one tier up: this job moved from the %s tier (%s %s %s) to the %s tier, because %s.\n' \
      "$T_TIER" "$T_HARNESS" "$T_MODEL" "$T_EFFORT" "$T_NEXT" "$(trigger_text "$trigger")"
    [ -z "$detail" ] || printf 'Detail: %s\n' "$detail"
    printf 'Your instructions above are unchanged. The previous worker'"'"'s commits and uncommitted changes are in this local copy: review them before building on them, and redo what looks wrong.\n'
    if [ -s "$T_STATUS" ]; then
      printf '\nThe previous worker'"'"'s latest status reports, newest last:\n'
      tail -n 12 "$T_STATUS" | sed 's/^/    /'
    fi
    if [ -n "$notes" ]; then
      printf '\nFirstmate'"'"'s notes from the previous worker'"'"'s run:\n'
      cat "$notes"
    fi
  } > "$note"

  if [ "$dry" = 1 ]; then
    printf 'tier step-up (dry run): %s %s -> %s: --harness %s --model %s --effort %s\n' "$TASK" "$T_TIER" "$T_NEXT" "$h" "$m" "$e"
    printf 'note:\n'
    sed 's/^/  /' "$note"
    rm -f "$note"
    return 0
  fi

  if ! "$CONTROL_BIN" "$TASK" relaunch --harness "$h" --model "$m" --effort "$e" --note-file "$note"; then
    rm -f "$note"
    printf 'tier step-up failed: the relaunch of %s did not complete; nothing was recorded\n' "$TASK" >&2
    exit 1
  fi
  rm -f "$note"
  record=$(jq -cn --arg task "$TASK" --arg from "$T_TIER" --arg to "$T_NEXT" --arg trigger "$trigger" \
    --arg detail "$detail" --argjson automatic "$([ "$by_fm" = 1 ] && echo false || echo true)" \
    --arg fh "$T_HARNESS" --arg fm "$T_MODEL" --arg fe "$T_EFFORT" --arg th "$h" --arg tm "$m" --arg te "$e" '
    {event: "dispatch.stepped_up", task: $task, from_tier: $from, to_tier: $to, trigger: $trigger,
     detail: (if $detail == "" then null else $detail end), automatic: $automatic,
     from_profile: {harness: $fh, model: $fm, effort: $fe}, to_profile: {harness: $th, model: $tm, effort: $te}}')
  fm_dispatch_record_append "$DATA" "$record" \
    || echo "tier step-up: could not append to $(fm_dispatch_record_path "$DATA"); the step is not recorded" >&2
  printf 'stepped up: %s %s -> %s (--harness %s --model %s --effort %s), trigger %s\n' "$TASK" "$T_TIER" "$T_NEXT" "$h" "$m" "$e" "$trigger"
}

cmd_arm() {
  local staged check="$STATE/tier-step.check.sh"
  [ $# -eq 0 ] || usage
  load_tiers
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory unavailable"
  fm_pr_regular_destination_on_device_or_absent "$check" "$(fm_pr_file_device "$STATE")" \
    || die "unsafe check destination: $check"
  staged=$(umask 077; mktemp "$STATE/.tier-step-check.XXXXXX") || die "mktemp failed"
  printf '%s\n' '#!/usr/bin/env bash' \
    "export FM_HOME=$(printf '%q' "$FM_HOME")" \
    "export FM_STATE_OVERRIDE=$(printf '%q' "$STATE")" \
    "export FM_DATA_OVERRIDE=$(printf '%q' "$DATA")" \
    "export FM_CONFIG_OVERRIDE=$(printf '%q' "$CONFIG")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-tier.sh") due --once" > "$staged"
  chmod 700 "$staged"
  mv -f -- "$staged" "$check"
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" tier-step
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case "$cmd" in
  of) cmd_of "$@" ;;
  due) cmd_due "$@" ;;
  step-up) cmd_step_up "$@" ;;
  arm) cmd_arm "$@" ;;
  -h|--help) usage ;;
  *) usage ;;
esac
exit 0
