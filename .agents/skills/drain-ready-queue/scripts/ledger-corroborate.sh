#!/bin/bash
# ledger-corroborate.sh [ledger-file] — derive from `gh` and `git` what each
# merged loop PR's outcome actually was, and hold the recorded ledger against
# it. A self-reported outcome is not evidence; this is the independent witness,
# and it is what makes slop and rework rates measurements rather than vibes.
#
# A loop PR is one whose head branch is `agent/*` — the branch the dispatch
# brief names. Rows come oldest first, one per merged loop PR:
#
#   LEDGER-ROW #<issue> #<pr> <merged-date> <derived> <recorded>
#
#   derived   merged-clean | reverted | superseded — the three states gh and git
#             can prove. `rework` (the PM asked for more fixes while the PR was
#             still open) leaves no trace on the merged PR, so it is never
#             derived and never contradicted. `bounced`, `stopped` and `died`
#             never reach a PR, so their rows are outside this script's
#             population entirely — it walks merged loop PRs, and matches a row
#             by its `pr` cell, which those rows carry as `-`.
#   recorded  the ledger's outcome for that PR, or `-` when it has no row.
#
# Then the findings, each of which the PM acts on — this script never edits:
#
#   LEDGER-ABSENT:<path>        no ledger yet. The rows above are exactly what a
#                               backfill would consume.
#   LEDGER-MISSING:#<pr>        a merged loop PR with no row.
#   LEDGER-MISMATCH:#<pr> …     a row the derivation contradicts: anything but
#                               `reverted` recorded for a reverted PR, or
#                               `merged-clean` where a later loop PR closed the
#                               same issue.
#   LEDGER-OK:<n>               n merged loop PRs, nothing contradicted.
#
# Findings exit 0, like every script in this skill. Exit 1 is reserved for not
# being able to do the job at all — no gh, no jq, an unreachable tracker. Fails
# closed on purpose: an unverifiable ledger must never read as a corroborated
# one.
set -u

fail() { echo "LEDGER-UNKNOWN: $1"; exit 1; }

command -v gh >/dev/null 2>&1 || fail "gh is not installed — nothing can be corroborated"
command -v jq >/dev/null 2>&1 || fail "jq is not installed — nothing can be corroborated"

. "$(dirname "$0")/repo-root-lib.sh"
root=$(repo_main_root) || root=""
ledger="${1:-${LEDGER_FILE:-}}"
if [ -z "$ledger" ]; then
  [ -n "$root" ] || fail "not a git repository, and no ledger path was given"
  ledger="$root/docs/agents/ledger.md"
fi

prs=$(gh pr list --state merged --limit 200 \
        --json number,headRefName,mergedAt,body,mergeCommit 2>&1) \
  || fail "gh pr list failed: $prs"
[ -n "$prs" ] || fail "gh pr list returned nothing"

# --- the loop PRs: number, merge date, merge commit, the issue it closes ------
loop=$(printf '%s' "$prs" | jq -r '
  [ .[] | select(.headRefName | startswith("agent/")) ]
  | sort_by(.number)[]
  | [ (.number | tostring),
      ((.mergedAt // "") | .[0:10] | if . == "" then "-" else . end),
      (.mergeCommit.oid // "-"),
      ((.body // "") | [ scan("(?i)close[sd]?[ \t]+#([0-9]+)") ] | flatten | (.[0] // "-"))
    ] | @tsv') || fail "could not parse gh output (jq)"

# --- what reverts what --------------------------------------------------------
# Two independent signals, because reverts arrive two ways: GitHub's Revert
# button (branch `revert-<pr>-<head>`, body "Reverts owner/repo#<pr>") and a
# hand-made revert commit, which carries "This reverts commit <sha>" and is
# matched against the reverted PR's merge commit.
reverted_prs=$(printf '%s' "$prs" | jq -r '
  .[]
  | [ (.headRefName | scan("^revert-([0-9]+)-")),
      ((.body // "") | scan("(?i)reverts[^0-9]*#([0-9]+)")) ]
  | flatten | .[]' 2>/dev/null | grep -E '^[0-9]+$' | sort -u)

reverted_shas=""
if [ -n "$root" ]; then
  reverted_shas=$(git -C "$root" log --grep='This reverts commit' --pretty=%B 2>/dev/null \
    | sed -n 's/^[[:space:]]*This reverts commit \([0-9a-f]\{7,40\}\).*/\1/p' | sort -u)
fi

is_reverted() {  # <pr> <merge-sha>
  printf '%s\n' "$reverted_prs" | grep -qxF "$1" && return 0
  [ "$2" != "-" ] || return 1
  for s in $reverted_shas; do
    case "$2" in "$s"*) return 0 ;; esac
    case "$s" in "$2"*) return 0 ;; esac
  done
  return 1
}

# A loop PR is superseded when a LATER loop PR closes the same issue — the shape
# a rework round leaves behind once it needed a second PR. Computed once, as a
# list, rather than by re-scanning inside the row loop: a nested read would eat
# the row loop's own input.
superseded_prs=$(printf '%s\n' "$loop" | awk -F'\t' '
  $4 != "-" && $1 != "" {
    pr = $1 + 0; iss = $4
    if (!(iss in newest) || pr > newest[iss]) newest[iss] = pr
    closes[pr] = iss
  }
  END { for (p in closes) if (newest[closes[p]] > p + 0) print p }' | sort -n)

is_superseded() {  # <pr>
  printf '%s\n' "$superseded_prs" | grep -qxF "$1"
}

recorded_for() {  # <pr> — the ledger's outcome cell, or `-`
  [ -f "$ledger" ] || { echo "-"; return; }
  awk -F'|' -v want="#$1" '
    /^\|/ {
      pr = $3; out = $6
      gsub(/^[ \t]+|[ \t]+$/, "", pr); gsub(/^[ \t]+|[ \t]+$/, "", out)
      if (pr == want && out != "") { print out; found = 1; exit }
    }
    END { if (!found) print "-" }' "$ledger"
}

# --- rows, then findings ------------------------------------------------------
have_ledger=1
[ -f "$ledger" ] || have_ledger=0

rows=0
findings=""
while IFS="$(printf '\t')" read -r pr merged sha issue; do
  [ -n "$pr" ] || continue
  rows=$((rows + 1))
  if is_reverted "$pr" "$sha"; then
    derived="reverted"
  elif is_superseded "$pr"; then
    derived="superseded"
  else
    derived="merged-clean"
  fi
  recorded="-"
  [ "$have_ledger" = 0 ] || recorded=$(recorded_for "$pr")
  issuecell="-"
  [ "$issue" = "-" ] || issuecell="#$issue"
  echo "LEDGER-ROW $issuecell #$pr $merged $derived $recorded"

  [ "$have_ledger" = 1 ] || continue
  if [ "$recorded" = "-" ]; then
    findings="$findings
LEDGER-MISSING:#$pr merged $merged, closing $issuecell, has no ledger row"
  elif [ "$derived" = "reverted" ] && [ "$recorded" != "reverted" ]; then
    findings="$findings
LEDGER-MISMATCH:#$pr recorded '$recorded' but the PR was reverted"
  elif [ "$derived" = "superseded" ] && [ "$recorded" = "merged-clean" ]; then
    findings="$findings
LEDGER-MISMATCH:#$pr recorded 'merged-clean' but a later loop PR closed $issuecell again"
  fi
done <<EOF
$loop
EOF

if [ "$rows" = 0 ]; then
  echo "LEDGER-OK:0 no merged loop PRs (head branch \`agent/*\`) to corroborate"
  exit 0
fi
if [ "$have_ledger" = 0 ]; then
  echo "LEDGER-ABSENT:$ledger — $rows merged loop PR(s) derived above, none recorded yet"
  exit 0
fi
if [ -n "$findings" ]; then
  printf '%s\n' "$findings" | grep .
  exit 0
fi
echo "LEDGER-OK:$rows merged loop PR(s), nothing contradicted"
exit 0
