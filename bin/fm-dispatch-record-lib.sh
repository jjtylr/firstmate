# shellcheck shell=bash
# fm-dispatch-record-lib.sh - shared writer for the per-dispatch record.
#
# docs/configuration.md "Dispatch record (data/dispatch-record.jsonl)" owns the
# record's purpose, location, events, and fields. This library owns only the
# file path and the append mechanics; bin/fm-dispatch-record.sh owns the
# spawn, relaunch, and outcome producers and the summary reader.
#
# Usage (source, then call):
#   fm_dispatch_record_path <data-dir>            print the record path
#   fm_dispatch_record_append <data-dir> <json>   append one record
#   fm_dispatch_record_has_task <data-dir> <task> 0 when any record names task
#
# fm_dispatch_record_append adds "v": 1 and "ts" (Unix seconds) to the given
# JSON object, compacts it to one line, and appends it with one write. A value
# that is not a JSON object with string "event" and "task" members is refused.
# It returns 1 on any failure and prints nothing on success; callers ignore a
# failure so the record never changes the outcome of the step it describes.
# Needs jq; without it every call returns 1.

fm_dispatch_record_path() {  # <data-dir>
  printf '%s/dispatch-record.jsonl\n' "${1%/}"
}

fm_dispatch_record_append() {  # <data-dir> <json-object>
  local data=$1 json=$2 path line now
  [ -n "$data" ] && [ -d "$data" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  path=$(fm_dispatch_record_path "$data")
  now=$(date +%s) || return 1
  line=$(jq -c --argjson ts "$now" '
    if type == "object" and (.event | type) == "string" and (.task | type) == "string"
    then {v: 1, ts: $ts} + . else error("not a dispatch record") end' <<<"$json" 2>/dev/null) || return 1
  [ -n "$line" ] || return 1
  case "$line" in *$'\n'*) return 1 ;; esac
  printf '%s\n' "$line" >> "$path" 2>/dev/null || return 1
}

fm_dispatch_record_has_task() {  # <data-dir> <task>
  local path
  path=$(fm_dispatch_record_path "$1")
  [ -f "$path" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -Rn --arg task "$2" '
    [inputs | (try fromjson catch null) | select(type == "object" and .task == $task)]
    | length > 0' "$path" 2>/dev/null | grep -qx true
}
