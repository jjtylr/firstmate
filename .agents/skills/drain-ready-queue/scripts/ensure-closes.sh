#!/bin/bash
# ensure-closes.sh <pr-number> <issue-number>... — verify the PR body carries
# a closing keyword for every issue; append any that are missing. GitHub only
# links keyword-immediately-before-number, one keyword per issue.
set -u
pr="${1:?usage: ensure-closes.sh <pr-number> <issue-number>...}"; shift
[ $# -ge 1 ] || { echo "usage: ensure-closes.sh <pr-number> <issue-number>..." >&2; exit 2; }
body=$(gh pr view "$pr" --json body --jq .body) || exit 1
missing=""
for n in "$@"; do
  printf '%s' "$body" | grep -qiE "(close[sd]?|fix(e[sd])?|resolve[sd]?) #$n\b" \
    || missing="$missing
Closes #$n"
done
if [ -n "$missing" ]; then
  gh pr edit "$pr" --body "$body$missing" >/dev/null && echo "CLOSES-ADDED:$missing"
else
  echo "CLOSES-OK"
fi
