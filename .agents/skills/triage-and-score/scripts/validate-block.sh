#!/bin/bash
# validate-block.sh <issue-number> [dir] — validate block-<N>.txt before it is
# posted. Prints OK ... and exits 0, or INVALID ... and exits 1 — so
# `validate-block.sh N && gh issue comment ...` cannot post a malformed block.
# The block file is per-issue by contract: scorers can run concurrently, and a
# shared block.txt measurably corrupted 4 of 56 scores (2026-08-18).
#
# The marker is checked first, and it is not decoration: every consumer selects
# the score comment on `<!-- triage-score v1 -->` (pick.sh, board.sh, queue.sh).
# A block whose fields all validate but whose marker is missing posts clean and
# is then invisible to the ranking query — the ticket degrades to ratio -1 and
# sorts last, indistinguishable from one nobody scored. Silent mis-ranking out
# of a validator that reported OK.
#
# It must be a **line of its own**, exactly once. Not line 1: the posted block
# carries the AI-generated-during-triage disclaimer above it. Own-line is the
# same definition the consumers select on, so anything accepted here is a
# comment they will find; a marker quoted inside prose or backticks is not one.
#
# Fails closed: a non-numeric issue, a missing, unreadable or empty file are all
# rejections, never a pass.
set -u
marker='<!-- triage-score v1 -->'
n="${1:?usage: validate-block.sh <issue-number> [dir]}"
n="${n#\#}"
dir="${2:-.}"
f="$dir/block-$n.txt"
case "$n" in ''|*[!0-9]*) echo "INVALID: issue must be a number, got: $1"; exit 1 ;; esac
[ -f "$f" ] || { echo "INVALID: $f does not exist"; exit 1; }
[ -r "$f" ] || { echo "INVALID: $f is not readable"; exit 1; }
[ -s "$f" ] || { echo "INVALID: $f is empty"; exit 1; }

count=$(grep -c "^$marker\$" "$f") || count=0
case "$count" in
  1) ;;
  0)
    other=$(grep -o '<!--[[:space:]]*triage[ -]score[^>]*-->' "$f" | head -n 1)
    if [ "$other" = "$marker" ]; then
      echo "INVALID: $f carries $marker only inside another line — it must be a line of its own"
    elif [ -n "$other" ]; then
      echo "INVALID: $f carries $other, not $marker"
    else
      echo "INVALID: $f has no $marker line — an unmarked block vanishes from the queue"
    fi
    exit 1
    ;;
  *)
    echo "INVALID: $f carries $count $marker lines — one block per issue"
    exit 1
    ;;
esac

out=$(jq -Rrs '(( capture("VALUE: (?<x>[0-9]+)") | .x | tonumber) // null) as $v
    | ((capture("AGENT-EFFORT: (?<x>[0-9]+)") | .x | tonumber) // null) as $e
    | ((capture("PM-COST: (?<x>[0-9]+)")     | .x | tonumber) // null) as $p
    | ((capture("VERIFIED: (?<x>[a-z/]+)")   | .x)           // null) as $ver
    | ((capture("SCORED-ON: (?<x>[0-9]{4}-[0-9]{2}-[0-9]{2})") | .x) // null) as $s
    | if ($v and $e and $p != null) and ($e > 0) and ($v <= 5) and ($e <= 5) and ($p <= 3)
         and ($ver as $x | ["yes","no","n/a"] | index($x)) and $s
      then "OK v=\($v) e=\($e) p=\($p) verified=\($ver) scored-on=\($s) ratio=\(($v / $e) * 10 | round / 10)"
      else "INVALID v=\($v) e=\($e) p=\($p) verified=\($ver) scored-on=\($s)" end' < "$f")
echo "$out"
case "$out" in OK*) exit 0 ;; *) exit 1 ;; esac
