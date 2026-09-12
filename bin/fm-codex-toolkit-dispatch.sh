#!/usr/bin/env bash
# Firstmate dispatch adapter for the installed Codex toolkit operative role.
# Usage: bin/fm-codex-toolkit-dispatch.sh <ticket> <slug> <brief-file>
set -u

fail() {
  printf 'CODEX-OPERATIVE-REFUSED: %s\n' "$1" >&2
  exit 2
}

[ $# -eq 3 ] || fail 'usage: fm-codex-toolkit-dispatch.sh <ticket> <slug> <brief-file>'
ticket="${1#\#}"
slug="$2"
brief="$3"
case "$ticket" in ''|*[!0-9]*) fail "ticket must be a positive issue number, got: $1" ;; esac
[ "$ticket" -gt 0 ] 2>/dev/null || fail "ticket must be a positive issue number, got: $1"
case "$slug" in
  ''|[!a-z0-9]*|*[^a-z0-9-]*|*--*|*-) fail "slug must use lowercase letters, digits, and single interior hyphens, got: $slug" ;;
esac
[ -f "$brief" ] && [ -r "$brief" ] || fail "brief is not a readable file: $brief"

[ -n "${FM_HOME:-}" ] || fail 'FM_HOME must identify the Firstmate home'
[ -n "${FM_ROOT:-}" ] || fail 'FM_ROOT must identify the Firstmate repository'
[ -x "$FM_ROOT/bin/fm-spawn.sh" ] || fail "Firstmate dispatch owner is missing: $FM_ROOT/bin/fm-spawn.sh"

task_id="${FM_TASK_ID:-}"
[ -n "$task_id" ] || fail 'set FM_TASK_ID to the Firstmate task whose brief is being dispatched'
case "$task_id" in *[!A-Za-z0-9._=-]*) fail "invalid FM_TASK_ID: $task_id" ;; esac

recorded="$FM_HOME/data/$task_id/brief.md"
[ -f "$recorded" ] && [ -r "$recorded" ] ||
  fail "Firstmate brief is missing: $recorded; create it with bin/fm-brief.sh before dispatch"
if ! cmp -s "$brief" "$recorded"; then
  fail "the supplied brief does not match Firstmate's recorded brief: $recorded"
fi

project="${FM_TOOLKIT_PROJECT:-$FM_ROOT}"
mode="${FM_TOOLKIT_MODE:-direct-PR}"
yolo="${FM_TOOLKIT_YOLO:-off}"
case "$mode" in no-mistakes|direct-PR|local-only) ;; *) fail "invalid FM_TOOLKIT_MODE: $mode" ;; esac
case "$yolo" in on|off) ;; *) fail "invalid FM_TOOLKIT_YOLO: $yolo" ;; esac

# fm-spawn.sh owns harness-adapter selection, isolated worktree creation,
# permission/trust handling, and the durable task record. Subsequent progress
# is supervised through Firstmate rather than by this toolkit helper.
if ! "$FM_ROOT/bin/fm-spawn.sh" "$task_id" "$project" \
    --mode "$mode" --yolo "$yolo" --harness codex; then
  fail "Firstmate dispatch did not accept task $task_id"
fi
printf 'CODEX-OPERATIVE-DISPATCHED: #%s through Firstmate task %s\n' "$ticket" "$task_id"
