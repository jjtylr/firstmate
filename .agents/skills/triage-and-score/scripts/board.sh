#!/bin/bash
# board.sh — every posted v1 score read back from the tracker, ranked. The
# consumer-side defence: a half-parseable block degrades to a visible
# ratio -1 (every capture bound with // null, divisor guarded) and only the
# LAST block per issue counts (a stale score must not outrank the fresh one).
#
# The marker counts only on a line of its own — same definition the write-side
# validator enforces. A substring test reads a comment quoting the marker as a
# score block, so an unscored ticket shows up scored. jq's `$` ends the whole
# string, not a line, so split first; `[ \t\r]*` absorbs a CRLF body.
set -u
gh issue list --state open --limit 300 --json number,title,labels,comments \
| jq '[.[] | . as $i
      | ([$i.comments[].body | select(type == "string")
          | select(any(split("\n")[];
                       test("^<!-- triage-score v1 -->[ \t\r]*$")))] | last // "") as $c
      | select($c != "")
      | (($c | capture("VALUE: (?<x>[0-9]+)") | .x | tonumber) // null) as $v
      | (($c | capture("AGENT-EFFORT: (?<x>[0-9]+)") | .x | tonumber) // null) as $e
      | (($c | capture("PM-COST: (?<x>[0-9]+)") | .x | tonumber) // null) as $p
      | (($c | capture("VERIFIED: (?<x>[a-z/]+)") | .x) // null) as $ver
      | (($c | capture("SCORED-ON: (?<x>[0-9-]+)") | .x) // null) as $s
      | {n: $i.number, t: $i.title, l: [$i.labels[].name],
         v: $v, e: $e, p: $p, verified: $ver, scored_on: $s,
         ratio: (if ($v != null and $e != null and $e > 0) then ($v / $e) else -1 end)}]
      | sort_by(-.ratio, (.p // 9))'
