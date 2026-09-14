#!/bin/bash
# validate-brief.sh <issue-number> [dir] — validate brief-<N>.txt before it is
# posted as an agent-brief comment. Prints OK ... and exits 0, or INVALID ...
# and exits 1 — so `validate-brief.sh <N> && gh issue comment <N> --body-file
# brief-<N>.txt` cannot post a brief the readers will not see.
#
# What it checks is the marker, and only the marker. A brief's fields are prose
# written for whoever works the ticket and are not machine-read; the one part of it a
# script consumes is `<!-- agent-brief v1 -->`, which is how a reader tells a
# brief from any other comment (skills/triage/TICKET-BRIEF.md, *Where it is
# read from*). An unmarked brief posts clean and is then invisible to the
# resolver, so its `Locks:` line silently never takes effect — a failure that
# reads as a ticket that looks undeclared, never as an error.
#
# The marker must be a **line of its own**, exactly once. Not line 1: a posted
# brief may carry the AI-generated-during-triage disclaimer above it. Own-line
# is the same definition the readers select on, so anything this script accepts
# is a comment they will find; a marker quoted inside prose or backticks is not
# a marker, does not pass here, and is not read as one. Twice is a rejection
# too — two markers mean
# two briefs concatenated, and the reader would resolve from a blend of them.
#
# The contract is **per comment, not per issue** — this script reads one
# brief-<N>.txt and never queries the tracker, so it cannot see (and must not
# care) how many brief comments an issue already carries. That is deliberate:
# a second marked brief on an issue is the sanctioned post-dispatch amendment
# path (TICKET-BRIEF.md, *Where it is read from*), so do not "fix" this
# script into rejecting it.
#
# The file is per-issue by contract, for the same reason block-<N>.txt is: two
# scorers can be in flight in one working directory, and a shared brief.txt is a
# silent cross-write.
#
# Fails closed: no argument, a non-numeric issue, a missing or empty file are all
# rejections, never a pass.
set -u

marker='<!-- agent-brief v1 -->'

n="${1:-}"
[ -n "$n" ] || { echo "INVALID: usage: validate-brief.sh <issue-number> [dir]"; exit 1; }
n="${n#\#}"
dir="${2:-.}"
f="$dir/brief-$n.txt"

case "$n" in ''|*[!0-9]*) echo "INVALID: issue must be a number, got: $1"; exit 1 ;; esac
[ -f "$f" ] || { echo "INVALID: $f does not exist"; exit 1; }
[ -r "$f" ] || { echo "INVALID: $f is not readable"; exit 1; }
[ -s "$f" ] || { echo "INVALID: $f is empty"; exit 1; }

count=$(grep -c "^$marker\$" "$f") || count=0
case "$count" in
  1) ;;
  0)
    other=$(grep -o '<!--[[:space:]]*agent[ -]brief[^>]*-->' "$f" | head -n 1)
    if [ "$other" = "$marker" ]; then
      echo "INVALID: $f carries $marker only inside another line — it must be a line of its own"
    elif [ -n "$other" ]; then
      echo "INVALID: $f carries $other, not $marker"
    else
      echo "INVALID: $f has no $marker line — a brief without it is never read as one"
    fi
    exit 1
    ;;
  *)
    echo "INVALID: $f carries $count $marker lines — one brief per comment"
    exit 1
    ;;
esac

echo "OK brief #$n marker=agent-brief-v1 lines=$(wc -l < "$f" | tr -d ' ')"
exit 0
