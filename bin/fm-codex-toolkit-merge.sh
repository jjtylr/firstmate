#!/usr/bin/env bash
# Firstmate merge adapter for the installed Codex toolkit.
# Usage: bin/fm-codex-toolkit-merge.sh <pr-number> <examined-commit> <merge-method> <merge-policy>
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
policy_owner="$FM_ROOT/.agents/skills/drain-ready-queue/scripts/merge-decision.sh"
[ -f "$policy_owner" ] ||
  failed "Firstmate merge policy owner is missing: $policy_owner; nothing was attempted"
case "$(bash "$policy_owner" pass CHECKS-PASS "$policy" 2>/dev/null)" in
  *'is not an auto policy the catalog carries'*)
    failed "merge_policy '$policy' is not an auto policy the catalog carries — under it the loop never merges; nothing was attempted" ;;
  MERGE-ALLOWED*|MERGE-REFUSED:*) ;;
  *)
    failed "the merge policy owner did not answer whether '$policy' is an auto policy — an unread policy is never an auto one; nothing was attempted" ;;
esac
task_id="${FM_TASK_ID:-}"
[ -n "$task_id" ] || failed 'Firstmate merge authority requires FM_TASK_ID; nothing was attempted'
[ -n "${FM_HOME:-}" ] || failed 'Firstmate merge authority requires FM_HOME; nothing was attempted'
meta="$FM_HOME/state/$task_id.meta"
[ -f "$meta" ] && [ ! -L "$meta" ] ||
  failed "Firstmate task metadata is unavailable for $task_id; nothing was attempted"
yolo="$(grep '^yolo=' "$meta" | tail -n 1 | cut -d= -f2- || true)"
if [ "$yolo" != on ]; then
  [ -x "$FM_ROOT/bin/fm-captain-hold.sh" ] ||
    failed 'Firstmate captain-release owner is unavailable; nothing was attempted'
  approval_out="$(FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-captain-hold.sh" released "$task_id" 2>&1)"
  approval_code=$?
  case "$approval_code" in
    0) ;;
    1) failed "task $task_id has yolo=$yolo and no durable captain release; nothing was attempted" ;;
    *) failed "cannot establish captain merge authority for task $task_id — $approval_out; nothing was attempted" ;;
  esac
fi

# This adapter deliberately does not invoke a forge merge subcommand. The Firstmate owner
# reads the canonical PR, current head, task hold, yolo posture, and live checks
# and records the outcome under its normal merge authority.
repo_url="$(gh repo view --json url -q .url 2>&1)"
[ $? -eq 0 ] && [ -n "$repo_url" ] ||
  failed "cannot read this repository URL from the host — $repo_url; nothing was attempted"
pr_url="$repo_url/pull/$pr"
case "$method" in
  squash)
    subject="$(gh pr view "$pr" --json commits --jq '.commits[0].messageHeadline // empty' 2>&1)"
    subject_code=$?
    [ "$subject_code" -eq 0 ] && [ -n "$subject" ] ||
      failed "cannot read PR #$pr's first commit subject from the host — $subject; nothing was attempted"
    merge_arg=(--squash --subject "$subject (#$pr)")
    ;;
  merge) merge_arg=(--merge) ;;
  rebase) merge_arg=(--rebase) ;;
esac
out="$(FM_ROOT="$FM_ROOT" FM_TASK_ID="$task_id" \
  "$FM_ROOT/bin/fm-pr-merge.sh" "$task_id" "$pr_url" \
  --expected-head "$commit" -- "${merge_arg[@]}" 2>&1)"
code=$?
if [ "$code" -eq 0 ]; then
  after="$(gh pr view "$pr" --json state,headRefOid 2>&1)"
  [ $? -eq 0 ] || failed "Firstmate accepted PR #$pr, but its outcome could not be read from the host — $after"
  state="$(printf '%s' "$after" | jq -r '.state // empty' 2>/dev/null)"
  head="$(printf '%s' "$after" | jq -r '.headRefOid // empty' 2>/dev/null)"
  [ "$state" = MERGED ] ||
    failed "Firstmate accepted PR #$pr, but it has not landed (state=$state, head=$head)"
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
