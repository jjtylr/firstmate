#!/bin/bash
# queue.sh [--ready] — open issues with no v1 score block, selected by the
# state this mode consumes: full mode takes the triage label, --ready takes
# the ready label (score-only mode). An allowlist on state, never a blocklist
# on categories (ADR 0001): a blocklist must be taught every category label
# anyone invents — a `brief` issue reached this queue 2026-08-19 because
# `brief` post-dated the old list. Set TRIAGE_LABEL / READY_LABEL for a
# remapped repo. needs-info is never in either queue: its scope is known
# wrong, so a score against it is false precision (ADR 0002).
#
# "Has a score block" means the marker on a line of its own — the definition
# validate-block.sh enforces. A substring test would count a comment merely
# quoting the marker, hiding an unscored ticket from this list. jq's `$` ends
# the whole string, not a line, so split first; `[ \t\r]*` absorbs a CRLF body.
#
# **A ticket carrying a lane claim is held out of the queue**, open or parked,
# with one `QUEUE-CLAIMED: #<n> "<title>" …` line per held ticket on **stderr**
# (stdout is parsed as JSON), lowest number first. This is the one seam where
# the scoring stage and the drain's lanes would otherwise touch: a claim is a
# dispatch already in flight or already worked and waiting on the PM, and a
# scorer sent at that ticket would rewrite a brief its operative is working
# from. Held, never dropped quietly — a claim nobody releases starves its
# ticket forever, and only the repetition of the finding says so.
#
# Whether a claim is open is asked of `claim-status.sh` — the single home for
# the release rule, in the drain skill's folder, which ships in the same plugin
# snapshot as this one — rather than re-implemented here, and only for issues
# that survived the scored filter and actually carry a claim marker, so an
# ordinary pass asks it about nothing. **A claim this pass cannot read holds
# its ticket too**, including when the drain skill's script is not there to ask:
# an unread claim is never a released one, the same reading pick.sh gets.
#
# Exits 0 whenever the listing ran — a held ticket is a finding for the PM, not
# an error. Exit 1 with `QUEUE-UNKNOWN` means the listing itself failed and
# there is no queue at all: jq on empty input prints nothing and exits 0, so a
# failed `gh` would otherwise read as a fully scored backlog and stop the batch.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
claim_status="$here/../../drain-ready-queue/scripts/claim-status.sh"
TRIAGE_LABEL="${TRIAGE_LABEL:-needs-triage}"
READY_LABEL="${READY_LABEL:-ready-for-agent}"
LABEL="$TRIAGE_LABEL"
[ "${1:-}" = "--ready" ] && LABEL="$READY_LABEL"

queue=$(
  gh issue list --state open --limit 300 --label "$LABEL" --json number,title,labels,comments \
  | jq '[.[] | . as $i
        | {n: $i.number, t: $i.title, l: [$i.labels[].name],
           scored: ([$i.comments[].body | select(type == "string")
                     | select(any(split("\n")[];
                                  test("^<!-- triage-score v1 -->[ \t\r]*$")))] | length > 0),
           claimed: ([$i.comments[].body | select(type == "string")
                      | select(any(split("\n")[];
                                   test("^<!-- lane-claim v1 -->[ \t\r]*$")))] | length > 0)}]
        | map(select(.scored | not))
        | sort_by(.n)'
) || exit 1
[ -n "$queue" ] || {
  echo "QUEUE-UNKNOWN: the issue listing failed; there is no queue to score" >&2
  exit 1
}

# The claim exclusion. One `claim-status.sh` call per claim-carrying issue,
# lowest number first. The loop reads from a here-document rather than a pipe:
# a piped `while` runs in a subshell, and `held` would come back empty with
# every claimed ticket still in the queue.
held=""
while IFS="$(printf '\t')" read -r cn ct; do
  [ -n "$cn" ] || continue
  status=""
  # `</dev/null` so the call can never eat the loop's own input.
  [ -r "$claim_status" ] && status=$(bash "$claim_status" "$cn" 2>/dev/null </dev/null)
  case "$status" in
    CLAIM-OPEN*)
      echo "QUEUE-CLAIMED: #$cn \"$ct\" held by an open lane claim — a dispatch for it is in flight, and scoring it now would amend a ticket already being worked" >&2
      held="$held $cn" ;;
    CLAIM-PARKED*)
      echo "QUEUE-CLAIMED: #$cn \"$ct\" held by a parked lane claim — its PR is with the PM, and scoring it now would amend a ticket already worked" >&2
      held="$held $cn" ;;
    CLAIM-RELEASED*|CLAIM-NONE*)
      : ;;
    *)
      echo "QUEUE-CLAIMED: #$cn \"$ct\" carries a lane claim this pass could not read; an unread claim is never a released one, so it is held" >&2
      held="$held $cn" ;;
  esac
done <<EOF
$(printf '%s\n' "$queue" | jq -r 'map(select(.claimed)) | .[] | "\(.n)\t\(.t)"')
EOF

printf '%s\n' "$queue" \
| jq --argjson held "[$(printf '%s' "$held" | sed 's/^ //; s/ /,/g')]" \
     'map(select(.n | IN($held[]) | not))'
