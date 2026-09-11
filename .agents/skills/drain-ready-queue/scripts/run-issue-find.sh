#!/bin/bash
# run-issue-find.sh — the open run issue's number, or nothing.
#
# A run issue is the blackboard for one headless drain run: the `run-log`
# category label and no state label, so every stage's queue ignores it (ADR
# 0001's mechanism) while the label stays a deterministic selector. One open at
# a time, per repo.
#
#   stdout   the issue number, alone, and nothing else — so a caller can write
#            `n=$(run-issue-find.sh)`. Findings go to stderr.
#   exit 0   a run issue is open; its number is on stdout
#   exit 1   none is open; stdout is empty. RUNNER-NO-RUN-ISSUE on stderr
#   exit 2   the query itself failed. RUNNER-UNKNOWN on stderr
#
# **Exit 2 is not exit 1.** "Nobody answered" and "the tracker answered none"
# are the same silence, and collapsing them would let a network blip read as a
# clean slate — which is exactly the read that lets `run-issue-open.sh` open a
# second run issue over a live run's own. Same defect class as PICK-UNKNOWN.
#
# Several open run issues is a repo defect, not this script's call to fix: the
# lowest number — the oldest, the one whose closure is owed — goes to stdout and
# RUNNER-MULTIPLE names them all on stderr.
set -u

LABEL=run-log

raw=$(gh issue list --label "$LABEL" --state open --limit 50 --json number) || {
  echo "RUNNER-UNKNOWN: the run-issue query failed; whether a run is open is unknown" >&2
  exit 2
}
# gh prints `[]` for a match-nothing query, so empty output is not an empty
# queue — it is a `gh` that exited 0 and said nothing, and it must not read as
# "no run issue open".
[ -n "$raw" ] || {
  echo "RUNNER-UNKNOWN: the run-issue query returned nothing at all, not even an empty list" >&2
  exit 2
}

numbers=$(printf '%s\n' "$raw" | jq -r '[.[].number] | sort | .[]') || {
  echo "RUNNER-UNKNOWN: the run-issue query returned something that is not JSON" >&2
  exit 2
}

count=$(printf '%s\n' "$numbers" | grep -c '[0-9]')
if [ "$count" -eq 0 ]; then
  echo "RUNNER-NO-RUN-ISSUE: no open $LABEL issue" >&2
  exit 1
fi

if [ "$count" -gt 1 ]; then
  echo "RUNNER-MULTIPLE: $count open $LABEL issues ($(printf '%s\n' "$numbers" | sed 's/^/#/' | tr '\n' ' ' | sed 's/ $//')) — one at a time; close the extras" >&2
fi

printf '%s\n' "$numbers" | grep '[0-9]' | head -n 1
exit 0
