# shellcheck shell=bash
# fm-dispatch-facts-lib.sh - declared job facts for typed dispatch resolution.
#
# docs/configuration.md "Typed dispatch resolution" owns what a declared fact
# means and how the resolver acts on one, and "Crew dispatch profiles" owns the
# rule `facts` field. This library owns only:
#
#   FM_FACTS_JQ            jq defs, prepended to a program that reads a
#                          crew-dispatch.json object, with $provider_re bound
#                          to FM_QUOTA_PROVIDER_ID_RE:
#                            fm_facts_err   structural error text, or empty
#                            fm_facts_excluded($declared)
#                                           rule ids ("rule_<n>") a declared
#                                           fact excludes through "not:<fact>"
#                            fm_facts_matched($declared)
#                                           [{rule, fact}] for every rule a
#                                           declared fact names, excluded ones
#                                           left out
#   fm_facts_read          read brief text on stdin; print one tab-separated
#                          line per declared-fact line, first of each kind:
#                            review-of <task id or PR URL>
#                            built-by <harness> <model>
#                            whole-spec
#                            cause-unknown
#   fm_facts_review_task   <data-dir> <state-dir> <task id or PR URL>: print the
#                          task id a "Review of:" value names, or exit 1
#   fm_facts_latest_profile <data-dir> <task>: print the harness and model of
#                          the task's latest dispatch.spawned or
#                          dispatch.relaunched record, tab-separated, or exit 1
#
# A fact name is whole-spec, cause-unknown, or review:<provider>, where
# <provider> is the quota-axi provider family of the model that built the
# reviewed work. The lines are written the way "Checkable failure:" is
# (bin/fm-tier-lib.sh): one line in `## Firstmate spec`, optionally indented
# or bulleted with "- ".

# shellcheck disable=SC2016,SC2034  # jq program text, not shell expansion; read by the sourcing consumers
FM_FACTS_JQ='
def fm_fact_ok($f):
  ($f | type) == "string" and
  (($f | ltrimstr("not:")) as $n |
    $n == "whole-spec" or $n == "cause-unknown" or
    (($n | startswith("review:")) and ($n | ltrimstr("review:") | test($provider_re))));
def fm_facts_err:
  [(.rules // [])[]? | objects | select(has("facts")) | .facts | arrays | .[] | select(fm_fact_ok(.) | not)] as $bad |
  if any((.rules // [])[]?; type == "object" and has("facts") and ((.facts | type) != "array" or (.facts | length) == 0)) then
    "rule facts must be a non-empty array when present"
  elif ($bad | length) > 0 then
    "unknown fact: " + ($bad | map(tojson) | unique | join(", ")) + " (facts are whole-spec, cause-unknown, and review:<provider>, each optionally prefixed not:)"
  else empty end;
def fm_facts_excluded($declared):
  [(.rules // []) | to_entries[]
    | select(any((.value.facts // [])[]; startswith("not:") and (ltrimstr("not:") as $n | any($declared[]; . == $n))))
    | "rule_\(.key + 1)"];
def fm_facts_matched($declared):
  fm_facts_excluded($declared) as $out |
  [(.rules // []) | to_entries[]
    | "rule_\(.key + 1)" as $id
    | select(any($out[]; . == $id) | not)
    | ([(.value.facts // [])[] | select(startswith("not:") | not) | select(. as $f | any($declared[]; . == $f))] | first) as $fact
    | select($fact != null)
    | {rule: $id, fact: $fact}];
'

fm_facts_read() {
  local line value seen=' '
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line#- }
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in
      'Review of: '*)
        value=${line#Review of: }
        value=${value#"${value%%[![:space:]]*}"}
        [ -n "$value" ] || continue
        case "$seen" in *' review-of '*) continue ;; esac
        seen="$seen review-of "
        printf 'review-of\t%s\n' "$value" ;;
      'Built by: '*)
        value=${line#Built by: }
        value=${value#"${value%%[![:space:]]*}"}
        case "$value" in ?*:?*) ;; *) continue ;; esac
        case "$value" in *[[:space:]]*) continue ;; esac
        case "$seen" in *' built-by '*) continue ;; esac
        seen="$seen built-by "
        printf 'built-by\t%s\t%s\n' "${value%%:*}" "${value#*:}" ;;
      'Job: whole spec')
        case "$seen" in *' whole-spec '*) continue ;; esac
        seen="$seen whole-spec "
        printf 'whole-spec\n' ;;
      'Cause: unknown')
        case "$seen" in *' cause-unknown '*) continue ;; esac
        seen="$seen cause-unknown "
        printf 'cause-unknown\n' ;;
    esac
  done
}

# A task id is taken as written; a PR URL names the task whose dispatch.outcome
# recorded that PR, else the task whose state record carries "pr=<url>".
fm_facts_review_task() {  # <data-dir> <state-dir> <task id or PR URL>
  local data=$1 state=$2 value=$3 path task meta
  case "$value" in
    *://*) ;;
    .*|*[!A-Za-z0-9._-]*) return 1 ;;
    *) printf '%s\n' "$value"; return 0 ;;
  esac
  path="${data%/}/dispatch-record.jsonl"
  if [ -f "$path" ] && command -v jq >/dev/null 2>&1; then
    task=$(jq -Rnr --arg pr "$value" '
      [inputs | (try fromjson catch null)
        | select(type == "object" and .event == "dispatch.outcome" and .pr == $pr and (.task | type) == "string")
        | .task] | last // empty' "$path" 2>/dev/null) || task=''
    if [ -n "$task" ]; then printf '%s\n' "$task"; return 0; fi
  fi
  [ -n "$state" ] && [ -d "$state" ] || return 1
  for meta in "${state%/}"/*.meta; do
    [ -f "$meta" ] || continue
    if grep -qxF "pr=$value" "$meta" 2>/dev/null; then
      task=${meta##*/}
      printf '%s\n' "${task%.meta}"
      return 0
    fi
  done
  return 1
}

fm_facts_latest_profile() {  # <data-dir> <task>
  local path="${1%/}/dispatch-record.jsonl" out
  [ -f "$path" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  out=$(jq -Rnr --arg task "$2" '
    [inputs | (try fromjson catch null)
      | select(type == "object" and .task == $task
          and (.event == "dispatch.spawned" or .event == "dispatch.relaunched")
          and (.profile.harness | type) == "string" and .profile.harness != "")
      | .profile] | last // empty
    | "\(.harness)\t\(.model // "")"' "$path" 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}
