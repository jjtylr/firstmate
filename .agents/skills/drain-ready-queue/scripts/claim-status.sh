#!/bin/bash
# claim-status.sh <issue-number> — is this ticket's lane claim open, parked,
# released, or absent? The release check: one reader, one answer, read off the
# blackboard rather than held by whoever posted the claim.
#
#   stdout   exactly one CLAIM-* line, the answer
#   stderr   one CLAIM-UNKNOWN line when the answer cannot be measured
#   exit 0   the question was answered
#   exit 1   it was not — an unread claim is never a released one
#
# **Release is deterministic, and the ledger row is the release.** A claim is
# released when its ticket's ledger row is written, whatever the row says
# happened, so no PM action stands between a finished ticket and its slot
# coming back. This script reads a row's issue and its date and never its
# outcome word, which is why a sixth word cost it no change. The cycle that
# establishes a dead worker writes a `died` row, and the claim is released on
# the next read (#213). The second path is by hand: a `RELEASED:` line annotated
# onto the claim comment, which is what a PM releasing a **parked** claim
# writes, the one claim no row is coming for. Nothing else releases a claim; in
# particular the `claimed` label does not, because no script here reads a label
# at all (LABELS.md — the label mirrors the claim for human eyes, and where the
# two disagree the claim wins).
#
# **A ledger row releases a claim only from the claim's own date on.** A ticket
# the PM re-readies after a stop or a bounce already carries a row, and a plain
# "has a row" test would release its next claim the moment it was posted. The
# comparison is on the row's `dispatched` cell against the claim's
# DISPATCHED-ON, both ISO, both compared as strings. The honest bound: a ticket
# stopped and re-claimed on the *same day* reads as released by the earlier
# row. Same-day re-dispatch of a stopped ticket is the one shape this cannot
# tell apart, and it degrades toward releasing a claim, so the PM sees it as a
# ticket back in the pick rather than as a lane that never came back.
#
# **A parked claim is unreleased, and carries its own verdict word.** When a PR
# falls to the PM — an update conflict, a pin refused twice, `concerns`, `fail`
# — its lane slot comes back but its ticket must not: the PR is still open and
# the work is still unfinished (MERGE-PIPELINE.md, SCHEDULER.md). So parking
# annotates the claim with a `PARKED: <why>` line, which is **not** a release.
# The answer is CLAIM-PARKED — unreleased, so the ticket stays out of the pick
# exactly as an open claim does, and named apart so that every reader decides
# parkedness on the verdict word and never on the prose after the dash.
# `check-capacity.sh` frees the slot on that word; `check-holds.sh` stops
# every lane on it until the PM clears the park. `RELEASED` still wins if both
# are present — the PM's own word ends the claim whatever else is written on it.
#
# **The last marked comment is the claim.** Same rule every consumer of a marked
# artifact here runs on, and the marker counts only on a line of its own — a
# comment quoting the claim in prose is not a claim.
#
# The findings lines, all of them:
#
#   CLAIM-NONE: #<n> carries no lane-claim comment — nothing holds it out of the pick
#   CLAIM-OPEN: #<n> claimed <date> on branch <b>, locks "<l>" — no ledger row dated <date> or later, and no RELEASED line on the claim
#   CLAIM-OPEN: #<n> carries a claim with no readable DISPATCHED-ON — a claim that cannot be read is never a released one
#   CLAIM-PARKED: #<n> claimed <date> on branch <b>, locks "<l>" — parked: <text>; the ticket stays out of the pick and its lane slot is free
#   CLAIM-RELEASED: #<n> claimed <date> on branch <b> — released by hand: <text>
#   CLAIM-RELEASED: #<n> claimed <date> on branch <b> — released by its ledger row, dispatched <rowdate>, in <ledger>
#   CLAIM-UNKNOWN: ...   (stderr, exit 1)
#
# Environment: $LEDGER_FILE relocates the ledger, as it does for
# ledger-append.sh; otherwise <repo root>/docs/agents/ledger.md.
set -u

unknown() {
  echo "CLAIM-UNKNOWN: $1" >&2
  exit 1
}

[ $# -eq 1 ] || unknown "usage: claim-status.sh <issue-number>"
n="${1#\#}"
case "$n" in ''|*[!0-9]*) unknown "usage: claim-status.sh <issue-number>, got: $1" ;; esac

comments=$(gh issue view "$n" --json comments 2>/dev/null) \
  || unknown "#$n — the comment listing failed; an unread claim is never a released one"
# jq on empty input prints nothing and exits 0, so a `gh` that failed without a
# non-zero exit would otherwise read as a ticket carrying no claim at all.
[ -n "$comments" ] \
  || unknown "#$n — the comment listing returned nothing; an unread claim is never a released one"

claim=$(printf '%s\n' "$comments" | jq -r '
  [ .comments[].body | select(type == "string")
    | select(any(split("\n")[]; test("^<!-- lane-claim v1 -->[ \t\r]*$"))) ] | last // ""') \
  || unknown "#$n — the comments could not be read as JSON"

if [ -z "$claim" ]; then
  echo "CLAIM-NONE: #$n carries no lane-claim comment — nothing holds it out of the pick"
  exit 0
fi

# The same line-anchored field read validate-claim.sh accepts on, so a claim
# this reports on is one that validator passed.
#
# **One value per line, read one `read` at a time.** The compact form —
# tab-separated into a single `read` — silently shifts every field left past an
# empty one, because tab is an IFS whitespace character and bash collapses runs
# of it: a claim with an empty LOCKS would have its RELEASED text land in
# `locks`, and the release would be lost. A held ticket held forever, out of a
# script that reported it cleanly.
fields=$(printf '%s\n' "$claim" | jq -Rrs '
    def vals($k): [ split("\n")[]
                    | select(test("^" + $k + ":"))
                    | sub("^" + $k + ":[ \t]*"; "") | sub("[ \t\r]+$"; "") ];
    [ (vals("DISPATCHED-ON") | last // ""), (vals("BRANCH") | last // ""),
      (vals("LOCKS") | last // ""), (vals("RELEASED") | last // ""),
      (vals("PARKED") | last // "") ] | .[]') \
  || unknown "#$n — the claim comment could not be read"

date=""; branch=""; locks=""; released=""; parked=""
{
  IFS= read -r date
  IFS= read -r branch
  IFS= read -r locks
  IFS= read -r released
  IFS= read -r parked
} <<EOF
$fields
EOF
what="#$n claimed $date on branch $branch"

if [ -n "$released" ]; then
  echo "CLAIM-RELEASED: $what — released by hand: $released"
  exit 0
fi

case "$date" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *)
    echo "CLAIM-OPEN: #$n carries a claim with no readable DISPATCHED-ON — a claim that cannot be read is never a released one"
    exit 0 ;;
esac

. "$(dirname "$0")/repo-root-lib.sh"
ledger="${LEDGER_FILE:-}"
if [ -z "$ledger" ]; then
  root=$(repo_main_root) || root=""
  [ -z "$root" ] || ledger="$root/docs/agents/ledger.md"
fi

row=""
if [ -n "$ledger" ] && [ -f "$ledger" ]; then
  # Column 2 is the issue and column 4 the dispatch date, under the same `|`
  # split ledger-append.sh and ledger-corroborate.sh read rows with. The `""`
  # concatenations force a string comparison: awk would otherwise decide for
  # itself whether an ISO date is a number.
  row=$(awk -F'|' -v want="#$n" -v since="$date" '
    /^\|[ \t]*#[0-9]/ {
      i = $2; gsub(/^[ \t]+|[ \t]+$/, "", i)
      d = $4; gsub(/^[ \t]+|[ \t]+$/, "", d)
      if (i == want && d "" >= since "") { print d; exit }
    }' "$ledger")
fi

if [ -n "$row" ]; then
  echo "CLAIM-RELEASED: $what — released by its ledger row, dispatched $row, in $ledger"
  exit 0
fi

if [ -n "$parked" ]; then
  echo "CLAIM-PARKED: $what, locks \"$locks\" — parked: $parked; the ticket stays out of the pick and its lane slot is free"
  exit 0
fi

echo "CLAIM-OPEN: $what, locks \"$locks\" — no ledger row dated $date or later, and no RELEASED line on the claim"
exit 0
