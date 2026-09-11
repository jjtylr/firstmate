#!/bin/bash
# pr-checks.sh <pr-number> — corroborate a recap's self-reported GATES: with
# what CI actually says about the PR. Prints one finding line and exits 0;
# a finding is output here, never a failure exit.
#
#   CHECKS-NONE               no checks are configured — nothing to corroborate
#   CHECKS-PASS:<n>           n checks, none failing or pending
#   CHECKS-PENDING:<names>    still running — re-run before relaying the recap
#   CHECKS-FAIL:<names>       failed or cancelled
#   CHECKS-UNKNOWN:<message>  gh could not answer (bad number, auth, outage)
#
# Classification reads the JSON, never the exit code. Measured 2026-08-19 with
# gh 2.97.0: plain `gh pr checks` exits 1 both for failing checks and for a PR
# with no checks at all, while `--json` exits 0 even when a check is failing.
# The exit code answers neither question; the buckets do.
set -u
pr="${1:?usage: pr-checks.sh <pr-number>}"

rows=$(gh pr checks "$pr" --json bucket,name 2>/dev/null)

if [ -z "$rows" ] || [ "$rows" = "[]" ]; then
  # Empty output means either "no checks configured" or "gh could not read the
  # PR". The rollup separates the two without matching on a message string,
  # which would break the day gh rewords it.
  rollup=$(gh pr view "$pr" --json statusCheckRollup --jq '.statusCheckRollup | length' 2>&1)
  if [ $? -ne 0 ]; then
    echo "CHECKS-UNKNOWN:$rollup"
  elif [ "$rollup" = "0" ]; then
    echo "CHECKS-NONE"
  else
    echo "CHECKS-UNKNOWN:rollup has $rollup entries but gh pr checks returned none"
  fi
  exit 0
fi

bad=$(printf '%s' "$rows" | jq -r '[.[] | select(.bucket == "fail" or .bucket == "cancel") | .name] | join(", ")')
pending=$(printf '%s' "$rows" | jq -r '[.[] | select(.bucket == "pending") | .name] | join(", ")')

if [ -n "$bad" ]; then
  echo "CHECKS-FAIL:$bad"
elif [ -n "$pending" ]; then
  echo "CHECKS-PENDING:$pending"
else
  echo "CHECKS-PASS:$(printf '%s' "$rows" | jq 'length')"
fi
