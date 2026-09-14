#!/bin/bash
# run-issue-open.sh — open this run's run issue, or refuse because one is open.
#
# Takes no arguments.
#
#   stdout   the new issue's number, alone. Findings go to stderr.
#   exit 0   the run issue was created; its number is on stdout, and stderr
#            carries RUNNER-OPENED and nothing else — a clean start has no
#            other finding to report, so it reports none
#   exit 1   refused or failed; stdout is empty
#            RUNNER-REFUSED  a run issue is already open, named by number.
#                            RUNNER-MULTIPLE precedes it when several are
#            RUNNER-FAILED   the create call failed, or answered unreadably
#            RUNNER-UNKNOWN  whether one is open could not be established.
#                            Printed once, by whichever script noticed
#
# **The refusal is the interlock, not a courtesy.** The PM closing the previous
# run's issue is the whole ack that a run was reviewed, so a runner that could
# open a second issue beside an open one would turn review-after-landing back
# into a convention. Stdout stays empty on refusal for the same reason: a caller
# writing `n=$(run-issue-open.sh)` gets nothing, never the live run's number.
#
# The issue carries the `run-log` label and **no state label** — that absence is
# what keeps it out of every stage's queue (ADR 0001). Adding a state label here
# would put the run's own log into the queue the run drains.
set -u

LABEL=run-log
TITLE_PREFIX='Drain run'

[ $# -eq 0 ] || {
  echo "RUNNER-FAILED: usage: run-issue-open.sh (no arguments)" >&2
  exit 1
}

# One definition of "the open run issue", shared with the gate and the runner.
#
# Its stderr is caught rather than passed through, because the same line means
# different things to the two scripts: `RUNNER-NO-RUN-ISSUE` is the find's
# answer and this script's **success precondition**, so relaying it would put a
# findings line on a clean start's happy path — one the PM then has to read as
# "nothing is wrong". Caught, then decided per path, and never dropped where it
# is real: RUNNER-MULTIPLE rides out with the refusal, and the unknown path
# forwards the find's own line, so RUNNER-UNKNOWN is printed exactly once
# whichever script noticed it.
here="$(cd "$(dirname "$0")" && pwd)"
finderr="$(mktemp "${TMPDIR:-/tmp}/run-issue-open.XXXXXX")" || {
  echo "RUNNER-FAILED: cannot create a temporary file to read the find's findings" >&2
  exit 1
}
open=$(bash "$here/run-issue-find.sh" 2>"$finderr")
found=$?
findings=$(cat "$finderr" 2>/dev/null)
rm -f "$finderr"

case $found in
  0)
    # Whatever the find found worth saying here is a real finding — several
    # open run issues is the one that matters, and it names them.
    [ -n "$findings" ] && printf '%s\n' "$findings" >&2
    echo "RUNNER-REFUSED: run issue #$open is still open — closing it is the ack that starts the next run" >&2
    exit 1
    ;;
  1)
    # None open: the only state a run may start from. The find's
    # RUNNER-NO-RUN-ISSUE is that answer, not a finding, so it stops here.
    ;;
  *)
    if [ -n "$findings" ]; then
      printf '%s\n' "$findings" >&2
    else
      echo "RUNNER-UNKNOWN: cannot establish whether a run issue is open" >&2
    fi
    exit 1
    ;;
esac

day=$(date -u +%Y-%m-%d)
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
title="$TITLE_PREFIX $day"

body="Headless drain run, started $started (UTC).

Every iteration's report is posted here as a comment, and the runner's stop
reason ends the run. Nothing the loop skipped, held, bounced or refused is
reported anywhere else.

**Closing this issue is the ack.** The runner refuses to start while it is
open, so read the comments below and close it when this run is reviewed.

Carries no state label on purpose: that absence is what keeps it out of every
loop stage's queue."

url=$(gh issue create --title "$title" --label "$LABEL" --body "$body") || {
  echo "RUNNER-FAILED: gh could not create the run issue" >&2
  exit 1
}

# `gh issue create` answers with the new issue's URL; the number is its last
# path segment. Anything else is an answer we cannot prove an issue from.
number="${url##*/}"
number="${number%%[!0-9]*}"
case "$number" in
  ''|*[!0-9]*)
    echo "RUNNER-FAILED: no issue number in what gh answered: $url" >&2
    exit 1
    ;;
esac

echo "RUNNER-OPENED: #$number \"$title\"" >&2
printf '%s\n' "$number"
exit 0
