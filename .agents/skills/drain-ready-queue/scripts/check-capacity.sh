#!/bin/bash
# check-capacity.sh — may another lane be claimed right now? No arguments, one
# question. The lane count was prose the orchestrator was asked to honour, and
# on 2026-09-05 a consumer repo dispatched four lanes in six seconds while
# `resolve-lanes.sh` printed 1. This is that count as an exit code.
#
#   stdout  exactly one verdict line — CAPACITY-FREE or CAPACITY-FULL.
#   stderr  exactly one CAPACITY-UNKNOWN line when the answer cannot be
#           measured, and then no verdict line at all.
#   exit 0  a slot is free: another lane may be claimed.
#   exit 1  no slot is free, **or** the answer could not be measured. Both exit
#           alike, because the unknown case holds — the reading `check-lock.sh`
#           and `check-holds.sh` already take. An unread capacity is never
#           a free slot.
#
# **The count in force is what `resolve-lanes.sh` prints**, asked of that script
# rather than re-parsed from the loop config, so the number this refuses on is
# the same number step 0c reported. Its `LANES-FALLBACK` line is step 0c's to
# relay and is dropped here, which is what keeps this script's stderr the
# unknown channel and nothing else. A reading it cannot use is already 1 there,
# so an answer outside `{1, 2, 3}` means the script itself did not run.
#
# **Occupied is open, unreleased, unparked lane claims.** Only claims: an open
# loop PR whose claim was released holds no slot at all. A global lock it holds
# is `check-holds.sh`'s business, on the next check in the chain.
#
#   - Whether a claim is released is asked of `claim-status.sh` — the single
#     home for the release rule, ledger row and `RELEASED:` annotation both —
#     never re-implemented here.
#   - **A parked claim does not occupy a lane.** Parking frees the lane slot and
#     leaves the claim in place, so the ticket stays out of the pick while its
#     slot comes back (MERGE-PIPELINE.md § What parking does). `claim-status.sh`
#     answers CLAIM-PARKED for it, and that verdict word — never the prose after
#     the dash — is what excludes it here. A free slot is not the whole answer:
#     `check-holds.sh` stops every lane while any claim is parked, so a
#     count reported here as free still reaches that hold.
#   - A claim that cannot be read refuses the whole count, because a slot is
#     free only when every open claim has been accounted for.
#
# **The open-claim window is bounded, and a full one refuses.** `gh` pages
# silently — measured on gh 2.98.0, `--limit` defaults to 30 for `issue list`
# and it never says it truncated — so a listing that came back at its limit is
# unread, and a claim past the cut would read as a free slot. Same 200-row
# window and same refusal `check-holds.sh` reads its two windows at. Past
# 200 open issues the drain holds instead of dispatching on a partial count:
# the ceiling costs throughput, never safety.
#
# Where it is called: ahead of the claim, at the head of SKILL.md step 4's
# chain, so a slot that is not free stops the chain with nothing posted. It is
# **not** inside `validate-claim.sh`: that script reads no host and no tracker,
# and it stays a pure file validator.
#
# The findings lines, all of them:
#
#   CAPACITY-FREE: <k> of <n> lanes occupied<, p parked> — a slot is free
#   CAPACITY-FULL: <k> of <n> lanes occupied<, p parked> — every lane is taken; the next ticket waits for a claim to be released
#   CAPACITY-UNKNOWN: ...   (stderr, exit 1)
#
# Environment: $LOOP_CONFIG reaches resolve-lanes.sh, $LEDGER_FILE reaches
# claim-status.sh, exactly as they do for check-holds.sh.
set -u

here="$(cd "$(dirname "$0")" && pwd)"

unknown() {
  echo "CAPACITY-UNKNOWN: $1" >&2
  exit 1
}

[ $# -eq 0 ] \
  || unknown "usage: check-capacity.sh takes no arguments — it reads the lane count and counts the open claims itself"

# --- the count in force -------------------------------------------------------
lanes="$(bash "$here/resolve-lanes.sh" 2>/dev/null)" \
  || unknown "resolve-lanes.sh did not run — the lane count in force cannot be read, and an unread capacity is never a free slot"
case "$lanes" in
  1|2|3) ;;
  *) unknown "resolve-lanes.sh answered '$lanes', which is no lane count in {1, 2, 3} — an unread capacity is never a free slot" ;;
esac

# --- the open claims ----------------------------------------------------------
WINDOW=200

issues="$(gh issue list --state open --limit "$WINDOW" --json number,comments 2>/dev/null)" \
  || unknown "the open issue list could not be read — open lane claims cannot be counted, and an uncounted lane is never a free one"
# jq on empty input prints nothing and exits 0, so a gh that failed without a
# non-zero exit would otherwise read as a repo carrying no claims at all.
[ -n "$issues" ] \
  || unknown "gh answered nothing for the open issue list, not even an empty list"

# A listing that reached the limit cannot be told from one that stopped just
# short of it, so both refuse. A non-numeric count refuses too: `gh` answering
# an error object rather than an array must never fall through as "few enough".
rows="$(printf '%s\n' "$issues" | jq -r 'if type == "array" then length else "" end' 2>/dev/null)"
case "$rows" in
  ''|*[!0-9]*) unknown "the open issue list did not answer with a row count — an uncountable window never frees a slot" ;;
esac
[ "$rows" -lt "$WINDOW" ] \
  || unknown "the open issue list came back at its $WINDOW-row limit — gh truncates silently, so a claim past the cut cannot be told from one that is not there, and an unread lane is never a free one"

# The marker counts only on a line of its own, and jq's `$` anchors the whole
# string rather than a line — so the matcher splits into lines first, exactly as
# pick.sh, claim-status.sh and check-holds.sh do.
claimed="$(printf '%s\n' "$issues" | jq -r '
  [ .[] | select([ .comments[]?.body | select(type == "string")
                   | select(any(split("\n")[]; test("^<!-- lane-claim v1 -->[ \t\r]*$"))) ] | length > 0)
    | .number ] | sort | .[]' 2>/dev/null)" \
  || unknown "the open issue list is not JSON this check can read"

occupied=0
parked=0
while IFS= read -r cn; do
  [ -n "$cn" ] || continue
  status="$(bash "$here/claim-status.sh" "$cn" 2>/dev/null </dev/null)"
  case "$status" in
    CLAIM-RELEASED*|CLAIM-NONE*) ;;
    CLAIM-PARKED*) parked=$((parked + 1)) ;;
    CLAIM-OPEN*) occupied=$((occupied + 1)) ;;
    *) unknown "#$cn carries a lane claim this check could not read — an unread claim is never a released one, and a slot is free only when every claim has been counted" ;;
  esac
done <<EOF
$claimed
EOF

# --- the verdict --------------------------------------------------------------
say=""
[ "$parked" = 0 ] || say=", $parked parked"

if [ "$occupied" -lt "$lanes" ]; then
  printf 'CAPACITY-FREE: %s of %s lanes occupied%s — a slot is free\n' "$occupied" "$lanes" "$say"
  exit 0
fi

printf 'CAPACITY-FULL: %s of %s lanes occupied%s — every lane is taken; the next ticket waits for a claim to be released\n' \
  "$occupied" "$lanes" "$say"
exit 1
