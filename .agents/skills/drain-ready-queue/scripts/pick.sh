#!/bin/bash
# pick.sh — the drain's ranked candidate list, best first. JSON array on
# stdout; take the first element. Set READY_LABEL to the repo's mapping
# (default ready-for-agent).
#
# Ranking: ratio (VALUE/AGENT-EFFORT from the last v1 score block) descending,
# ties on lower PM-COST, then lower issue number. Unscored or half-parseable
# blocks degrade to ratio -1 — visible at the bottom, never vanished.
#
# A candidate with an OPEN blocker is not dispatchable, so it is held out of
# the ranked array — but it is never dropped silently: one
# `PICK-BLOCKED: #<n> "<title>" blocked by open #<b>[, #<b>]` line goes to
# **stderr** per held ticket, lowest number first, for the cycle's findings
# lines. Stderr, because stdout is parsed as JSON. Exits 0 whenever the query
# ran — a held ticket is a finding for the PM, not an error; exit 1 means the
# listing itself failed and there is no candidate list at all.
#
# **A ticket carrying an open lane claim is held the same way**, with one
# `PICK-CLAIMED: #<n> "<title>" …` line per ticket on stderr — never dropped
# quietly, because a claim nobody releases starves its ticket forever and only
# the repetition says so. The claim is a dispatch already in flight: it exists
# from before the worker spawns, so this is what stops a second slot, a
# restarted orchestrator, or a concurrent stage from dispatching the same ticket
# twice.
#
# Whether a claim is open is asked of `claim-status.sh` — the single home for
# the release rule — rather than re-implemented here, and only for candidates
# that survived the blocker filter and actually carry a claim marker, so an
# ordinary cycle asks it about nothing. A parked claim answers CLAIM-PARKED and
# holds its ticket exactly as an open one does: the slot came back, the work did
# not. **A claim it cannot read holds the ticket too**: an unread claim is never
# a free one, the same reading `check-lock.sh` gets from an unread lock.
#
# Each entry also carries the ticket's resolved `area` and `locks` — the
# machine-readable declaration lines, read from the issue body and from
# every agent-brief comment, latest non-empty wins per line. `area` names the
# atlas area the ticket advances (skills/atlas/SCHEMA.md); it is null on every
# ticket that names none, which is every ticket in a repo with no atlas, and
# the drain passes it to the operative rather than acting on it. The body half
# of that read is what `PICK_SLIM` drops, below.
#
# **That resolution is not written here.** `decl-lib.sh` holds it — the brief
# collection and the last-non-empty fold both — and `check-declared-locks.sh`
# reads the same copy when it audits a PR against the `Locks:` line this script
# dispatched on. Two copies would read fine and drift silently, and the two
# disagreeing about one ticket is the state that audit exists to detect. The
# forms that must survive an edit are enumerated in that file's header, beside
# the code they constrain.
#
# Five forms are load-bearing here; keep them under any edit:
#  - count OPEN blockers, never blockedBy.totalCount (it counts resolved
#    blockers too, so a closed blocker would hide its ticket forever)
#  - bind every capture with // null and guard the divisor (a half-parseable
#    block must rank badly, not annihilate its object; AGENT-EFFORT: 0 must
#    not abort the listing)
#  - for the SCORE: `last` of a collected list, never .comments[]|select (one
#    row per matching comment lets a stale score outrank the fresh one). For
#    BRIEFS the opposite holds: keep the whole collected list and fold it —
#    `last` there loses an earlier brief's line that an amendment left standing
#  - apply the label exclusions BEFORE splitting blocked from dispatchable, so
#    a needs-info or spec ticket is not also reported as starving
#  - `comments` is in the field list on every path today, PICK_SLIM included,
#    and removing it takes more than an edit here. Measured 2026-08-27: three
#    consumers read it — the score that ranks, the briefs that declare, and the
#    lane-claim marker below. Drop it and a claimed ticket comes back
#    dispatchable: against a one-ticket claimed queue, a variant without it
#    answered `[13]` and no finding where this script answers `[]` and one
#    PICK-CLAIMED, which leaves `runner-gate.sh`'s claim-held stop unreachable.
#    So the field goes only behind a claim signal that reads something else, and
#    #207 carries that question with the four candidates measured so far
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/decl-lib.sh"
READY_LABEL="${READY_LABEL:-ready-for-agent}"
# MILESTONE narrows the queue to one milestone's tickets (ADR 0003) — a PM
# scoping the drain to one spec's slice, or a "general" bin, on a tracker too
# big to drain whole. Empty means no filter. Blocking edges and global locks
# stay global: a candidate inside the milestone still waits on an open
# blocker or a held lock outside it.
MILESTONE="${MILESTONE:-}"
# PICK_SLIM drops `body` from the query, and nothing else. `runner-gate.sh` sets
# it on its own call — the one whose whole array `runner.sh` discards to
# /dev/null — where `body` feeds `area` and `locks` and no caller
# reads them. Under the seam those two resolve from the agent briefs alone, so
# a ticket declaring only in its body reads null. That is right for the gate's
# call and wrong for the session's, which is why the seam is set per call rather
# than made the default. The empty value is the ordinary one.
PICK_SLIM="${PICK_SLIM:-}"
fields="number,title,labels,blockedBy,comments,updatedAt"
[ -n "$PICK_SLIM" ] || fields="$fields,body"
candidates=$(
  gh issue list --label "$READY_LABEL" --state open --limit 100 \
    ${MILESTONE:+--milestone "$MILESTONE"} \
    --json "$fields" \
  | jq "$DECL_JQ"'
        [.[] | . as $i
        | ([$i.comments[].body | select(type == "string")
            | select(any(split("\n")[];
                         test("^<!-- triage-score v1 -->[ \t\r]*$")))] | last // "") as $c
        | (briefs($i.comments)) as $bs
        | (($c | capture("VALUE: (?<x>[0-9]+)") | .x | tonumber) // null) as $v
        | (($c | capture("AGENT-EFFORT: (?<x>[0-9]+)") | .x | tonumber) // null) as $e
        | (($c | capture("PM-COST: (?<x>[0-9]+)") | .x | tonumber) // null) as $p
        | (($c | capture("SCORED-ON: (?<x>[0-9-]+)") | .x) // null) as $s
        | ([$i.comments[].body | select(type == "string")
            | select(any(split("\n")[];
                         test("^<!-- lane-claim v1 -->[ \t\r]*$")))] | length > 0) as $cl
        | {n: $i.number, t: $i.title, l: [$i.labels[].name], e: $e, p: $p, claimed: $cl,
           scored_on: $s, updated: ($i.updatedAt[:10]),
           area: decl([$i.body] + $bs; "Area"),
           locks: decl([$i.body] + $bs; "Locks"),
           open_blockers: [$i.blockedBy.nodes[] | select(.state == "OPEN") | .number],
           ratio: (if ($v != null and $e != null and $e > 0) then ($v / $e) else -1 end)}]
        | map(select(.l | any(. == "needs-info" or . == "ready-for-human"
                              or . == "spec" or startswith("wayfinder:")) | not))'
) || exit 1
# jq on empty input prints nothing and exits 0, so a failed `gh` would
# otherwise look like an empty-but-successful queue and stop the loop.
[ -n "$candidates" ] || {
  echo "PICK-UNKNOWN: the candidate listing failed; there is no queue to read" >&2
  exit 1
}

printf '%s\n' "$candidates" \
| jq -r 'map(select(.open_blockers | length > 0)) | sort_by(.n) | .[]
        | "PICK-BLOCKED: #\(.n) \"\(.t)\" blocked by open "
          + (.open_blockers | sort | map("#\(.)") | join(", "))' >&2

# The claim exclusion. One `claim-status.sh` call per unblocked candidate that
# carries a claim marker, lowest number first, so the findings lines come out in
# the same order the blocked ones do. The loop reads from a here-document rather
# than a pipe: a piped `while` runs in a subshell, and `held` would come back
# empty with every claimed ticket still in the array.
held=""
while IFS="$(printf '\t')" read -r cn ct; do
  [ -n "$cn" ] || continue
  # `</dev/null` so the call can never eat the loop's own input.
  status=$(bash "$here/claim-status.sh" "$cn" 2>/dev/null </dev/null)
  case "$status" in
    CLAIM-OPEN*)
      echo "PICK-CLAIMED: #$cn \"$ct\" held by an open lane claim — a dispatch for it is in flight, or its claim needs releasing" >&2
      held="$held $cn" ;;
    CLAIM-PARKED*)
      echo "PICK-CLAIMED: #$cn \"$ct\" held by a parked lane claim — its PR is with the PM, and the ticket comes back only when the claim is released" >&2
      held="$held $cn" ;;
    CLAIM-RELEASED*|CLAIM-NONE*)
      : ;;
    *)
      echo "PICK-CLAIMED: #$cn \"$ct\" carries a lane claim this cycle could not read; an unread claim is never a released one, so it is held" >&2
      held="$held $cn" ;;
  esac
done <<EOF
$(printf '%s\n' "$candidates" \
  | jq -r 'map(select((.open_blockers | length) == 0 and .claimed))
           | sort_by(.n) | .[] | "\(.n)\t\(.t)"')
EOF

printf '%s\n' "$candidates" \
| jq --argjson held "[$(printf '%s' "$held" | sed 's/^ //; s/ /,/g')]" \
     'map(select((.open_blockers | length) == 0 and (.n | IN($held[]) | not)))
     | sort_by(-.ratio, (.p // 9), .n)'
