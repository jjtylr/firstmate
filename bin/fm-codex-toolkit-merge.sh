#!/usr/bin/env bash
# Firstmate merge adapter for the installed Codex toolkit.
set -u

failed() { echo "MERGE-FAILED:$1"; exit 1; }

pr="${1-}"
commit="${2-}"
method="${3-}"
policy="${4-}"
case "$pr" in ''|*[!0-9]*) failed 'usage: merge-pinned.sh <pr-number> <examined-commit> <merge-method> <merge-policy>' ;; esac
{ [ -n "$commit" ] && [ -n "$method" ] && [ -n "$policy" ]; } ||
  failed 'usage: merge-pinned.sh <pr-number> <examined-commit> <merge-method> <merge-policy>'
case "$commit" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) failed "'$commit' is not a full 40-character commit id — a pin must name the examined commit exactly; nothing was attempted" ;;
esac
case "$method" in squash|merge|rebase) ;; *) failed "merge_method '$method' is none of squash, merge, rebase — nothing was attempted" ;; esac

[ -n "${FM_ROOT:-}" ] || failed 'FM_ROOT must identify the Firstmate repository; nothing was attempted'
[ -x "$FM_ROOT/bin/fm-pr-merge.sh" ] ||
  failed "Firstmate merge owner is missing: $FM_ROOT/bin/fm-pr-merge.sh; nothing was attempted"
task_id="${FM_TASK_ID:-}"
[ -n "$task_id" ] || failed 'Firstmate merge authority requires FM_TASK_ID; nothing was attempted'

# This adapter deliberately does not invoke a forge merge subcommand. The Firstmate owner
# reads the canonical PR, current head, task hold, yolo posture, and live checks
# and records the outcome under its normal merge authority.
repo_url="$(gh repo view --json url -q .url 2>&1)"
[ $? -eq 0 ] && [ -n "$repo_url" ] ||
  failed "cannot read this repository URL from the host — $repo_url; nothing was attempted"
pr_url="$repo_url/pull/$pr"
case "$method" in
  squash) merge_arg=(--squash) ;;
  merge) merge_arg=(--merge) ;;
  rebase) merge_arg=(--rebase) ;;
esac
out="$(FM_ROOT="$FM_ROOT" FM_TASK_ID="$task_id" \
  "$FM_ROOT/bin/fm-pr-merge.sh" "$task_id" "$pr_url" -- "${merge_arg[@]}" 2>&1)"
code=$?
if [ "$code" -eq 0 ]; then
  echo "MERGE-PINNED:#$pr merged after Firstmate verified the live PR (examined $commit)"
  exit 0
fi
printf '%s\n' "$out" >&2
# The Firstmate owner has already classified its refusal. Preserve the toolkit
# pipeline's retry distinction only when the live head moved from its input.
after="$(gh pr view "$pr" --json state,headRefOid 2>&1)"
if [ $? -eq 0 ]; then
  state="$(printf '%s' "$after" | jq -r '.state // empty' 2>/dev/null)"
  head="$(printf '%s' "$after" | jq -r '.headRefOid // empty' 2>/dev/null)"
  if [ -n "$head" ] && [ "$head" != "$commit" ] && [ "$state" != MERGED ]; then
    echo "MERGE-PIN-REFUSED:#$pr head is now $head, not the examined $commit — Firstmate refused the stale merge request"
    exit 2
  fi
fi
failed "Firstmate merge owner refused PR #$pr; see its reported outcome"
