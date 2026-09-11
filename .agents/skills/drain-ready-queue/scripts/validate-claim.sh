#!/bin/bash
# validate-claim.sh <issue-number> [dir] — validate claim-<N>.txt before it is
# posted on the ticket. Prints OK ... and exits 0, or INVALID ... and exits 1 —
# so `validate-claim.sh <N> && gh issue comment <N> --body-file claim-<N>.txt`
# cannot post a malformed claim. Exactly one line per run, on stdout.
#
# This file is the `lane-claim` marker's machine-owned home
# (scripts/check-markers.sh): the canonical version is the one on the `marker`
# line below, read from here at run time. Eight other files restate the digit,
# and that checker holds every one of them to this line — the readers
# `pick.sh`, `claim-status.sh`, `check-capacity.sh`, `check-holds.sh`,
# `runner-gate.sh` and `skills/triage-and-score/scripts/queue.sh`, and the
# documents `CLAIM.md` and `SKILL.md`.
#
# The filename is per-ticket because this script opens `<dir>/claim-<N>.txt` —
# that is a contract with the caller, not the collision rule. What keeps two
# lanes apart is `[dir]`: ORCHESTRATION.md § 4 has each dispatch make its own
# directory with `mktemp -d` and pass it here, because the scratchpad the caller
# is handed is shared and a file written straight into it is a silent
# cross-write. `[dir]` defaults to `.` for an interactive run.
#
# **A claim is the dispatch, written down before it happens.** It says which
# ticket is being worked, on which branch, from which resolved declaration, on
# which date — so a second slot, a concurrent stage, or a restarted orchestrator
# reads the dispatch off the blackboard instead of inferring it. Two fields
# carry that weight and each is required:
#
#   LOCKS         the resolved `Locks:` snapshot the collision check cleared.
#                 `-` is the written form of "the ticket declares none"; a
#                 *missing* line is refused, because a claim with no snapshot
#                 cleared nothing and a later check cannot tell which of the two
#                 it meant.
#   DISPATCHED-ON the ISO dispatch date. The release check reads it: a ledger
#                 row releases a claim only from this date on, so a row left by
#                 an earlier run cannot release a fresh claim.
#
# A claim written before ADR 0007 also carries a surface line. The field was
# dropped, not forbidden: nothing reads it now and nothing rejects it either, so
# a claim still in flight when this landed passes here unchanged.
#
# The marker must be a **line of its own**, exactly once. Not line 1: the posted
# comment carries the AI-generated-during-the-drain-loop disclaimer above it, as
# the score block and the agent brief do. Own-line is the same definition
# `pick.sh` and `claim-status.sh` select on, so anything accepted here is a
# comment they will find, and a marker quoted inside prose is not one.
#
# Post-dispatch amendment never reaches back: the snapshot is what the check
# cleared, and a `Locks:` line amended afterwards is a fact about the next
# dispatch, not this one. Nothing here reads the issue body, which is what makes
# that true rather than merely intended.
#
# One line on stdout, always:
#   OK ticket=#<n> branch=<b> locks="<l>" dispatched-on=<d> released=<r|->
#   INVALID: <file> ...              the file is missing, unreadable, or empty
#   INVALID: <file> carries ...      the marker is absent, mid-line, or repeated
#   INVALID <field> ... — <summary>  a field is missing, doubled, or malformed
#
# Fails closed: a non-numeric issue, a missing, unreadable or empty file are all
# rejections, never a pass.
set -u
marker='<!-- lane-claim v1 -->'
n="${1:?usage: validate-claim.sh <issue-number> [dir]}"
n="${n#\#}"
dir="${2:-.}"
f="$dir/claim-$n.txt"
case "$n" in ''|*[!0-9]*) echo "INVALID: issue must be a number, got: $1"; exit 1 ;; esac
[ -f "$f" ] || { echo "INVALID: $f does not exist"; exit 1; }
[ -r "$f" ] || { echo "INVALID: $f is not readable"; exit 1; }
[ -s "$f" ] || { echo "INVALID: $f is empty"; exit 1; }

count=$(grep -c "^$marker\$" "$f") || count=0
case "$count" in
  1) ;;
  0)
    other=$(grep -o '<!--[[:space:]]*lane[ -]claim[^>]*-->' "$f" | head -n 1)
    if [ "$other" = "$marker" ]; then
      echo "INVALID: $f carries $marker only inside another line — it must be a line of its own"
    elif [ -n "$other" ]; then
      echo "INVALID: $f carries $other, not $marker"
    else
      echo "INVALID: $f has no $marker line — an unmarked claim holds nothing out of the pick"
    fi
    exit 1
    ;;
  *)
    echo "INVALID: $f carries $count $marker lines — one claim per ticket"
    exit 1
    ;;
esac

# Every field is read from a line of its own, for the same reason the marker is:
# a claim quoted in a following paragraph must not be able to restate it.
out=$(jq -Rrs --arg n "$n" '
    def vals($k): [ split("\n")[]
                    | select(test("^" + $k + ":"))
                    | sub("^" + $k + ":[ \t]*"; "") | sub("[ \t\r]+$"; "") ];
      (vals("TICKET"))        as $tv
    | (vals("BRANCH"))        as $bv
    | (vals("LOCKS"))         as $lv
    | (vals("DISPATCHED-ON")) as $dv
    | (vals("RELEASED"))      as $rv
    | ($tv | last // null) as $t
    | ($bv | last // null) as $b
    | ($lv | last // null) as $l
    | ($dv | last // null) as $d
    | ($rv | last // null) as $r
    | "ticket=\($t) branch=\($b) locks=\"\($l)\" dispatched-on=\($d) released=\($r // "-")"
      as $sum
    | if   ([$tv, $bv, $lv, $dv, $rv] | map(length) | max) > 1
      then "INVALID a field is written twice — one claim states each field once, so nothing downstream has to choose — \($sum)"
      elif ($t == null or $t == "")
      then "INVALID TICKET: #<n> is required — \($sum)"
      elif ($t != "#" + $n)
      then "INVALID TICKET field is \($t), validating #\($n) — \($sum)"
      elif ($b == null or $b == "")
      then "INVALID BRANCH: <slug> is required — the claim names the branch its worker owns — \($sum)"
      elif ($l == null or $l == "")
      then "INVALID LOCKS: <snapshot> is required — a claim with no lock snapshot cleared no collision check; write - for a ticket that declares none — \($sum)"
      elif ($d == null or $d == "")
      then "INVALID DISPATCHED-ON: <YYYY-MM-DD> is required — the release check dates the claim from it — \($sum)"
      elif ($d | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") | not)
      then "INVALID DISPATCHED-ON must be an ISO date, YYYY-MM-DD — \($sum)"
      else "OK \($sum)" end' < "$f")

echo "$out"
case "$out" in OK*) exit 0 ;; *) exit 1 ;; esac
