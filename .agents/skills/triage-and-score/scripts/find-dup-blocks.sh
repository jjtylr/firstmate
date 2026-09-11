#!/bin/bash
# find-dup-blocks.sh — detector for cross-issue score corruption: identical
# posted blocks on different issues, compared by content, never by length
# (two unrelated blocks in the measured batch were both 3,163 bytes). A
# partial collision shares the scored content but not the whole body, so also
# grep issues for a doubled AI-generated-during-triage disclaimer line.
#
# The marker counts only on a line of its own — the definition validate-block.sh
# enforces. A substring test drags in comments that merely quote the marker, and
# two of those would report as a duplicate block. jq's `$` ends the whole string,
# not a line, so split first; `[ \t\r]*` absorbs a CRLF body.
set -u
gh issue list --state open --limit 300 --json number,comments \
  --jq '.[] as $i | $i.comments[] | select(.body | type == "string")
        | select(any(.body | split("\n")[];
                     test("^<!-- triage-score v1 -->[ \t\r]*$")))
        | "\($i.number)\t\(.body|@base64)"' \
| awk -F'\t' '{if(seen[$2]!="") print "DUP: #"seen[$2]" #"$1; else seen[$2]=$1}'
