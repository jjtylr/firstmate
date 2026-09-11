#!/bin/bash
# validate-verdict.sh <pr-number> [dir] — validate verdict-<pr>.txt before it is
# posted on the PR. Prints OK ... and exits 0, or INVALID ... and exits 1 — so
# `validate-verdict.sh <pr> && gh pr comment <pr> --body-file verdict-<pr>.txt`
# cannot post a malformed block. Exactly one line per run, on stdout.
#
# This file is the `verifier-verdict` marker's machine-owned home
# (scripts/check-markers.sh): the canonical version is the one on the accepting
# line below, read from here at run time by check-markers.sh and by
# merge-decision.sh. Nothing else in the plugin restates the digit.
#
# The filename is per-PR because this script opens `<dir>/verdict-<pr>.txt` —
# that is a contract with the caller, not the collision rule. What keeps two
# verifiers apart is `[dir]`: ORCHESTRATION.md § 4 has each dispatch make its own
# directory with `mktemp -d` and pass it here, because the scratchpad the caller
# is handed is shared and a file written straight into it is a silent
# cross-write. `[dir]` defaults to `.` for an interactive run.
#
# **A verdict is a claim about an identified tree.** EXAMINED-COMMIT carries the
# full 40-character commit the verifier actually had checked out, and it is
# required: without it a `pass` says a repository passed at some unnamed moment,
# which is not something a merge can rest on. A block under a superseded marker
# is refused outright rather than read — its verdict was never a claim about any
# particular commit, so there is no honest way to read it as one.
#
# **The verdict word is the merge input, so the two lines that earn it are
# checked too.** A `concerns` verdict parks the PR under every auto policy, and
# for a long time nothing read either line that produced the word. So `CONCERNS:`
# and `RECAP:` are fields now, not prose. Each concern opens with a scope tag,
# `[diff]` for the examined tree or `[adjacent #<n>]` for a finding beside it
# and the issue it went to, and carries `MEASURED: <command> -> <output>`.
# `RECAP:` states `corroborated | contradicted | unverifiable`, and a
# contradiction tags and measures itself on `RECAP-WHY` the same way. A `[diff]`
# element is then what the word `concerns` means: `concerns` without one is
# refused, and so is a `pass` that carries one.
#
# **Shape is the whole claim here. Truth is not.** A command that does not
# support its concern still passes, and so does an `[adjacent]` tag on something
# that does reach the diff. Judging that is the advisor's job. What this buys is
# that a verdict which parks a PR can no longer be written without running
# anything, which is how one drain run parked two PRs that had done their job.
#
# A `refused` verdict is exempt from the tag and the measurement, and from those
# only: it examined nothing, so it has nothing to measure. Its `CONCERNS` line
# carries the two commit ids, and its `RECAP` is `unverifiable`.
#
# Beyond shape, it refuses the combinations that make a verdict dishonest rather
# than merely wrong — a `pass` with an unmet criterion or a gate that did not
# pass, a failing gate under any verdict but `fail`, and a `refused` that claims
# to have measured something (a verifier refuses *because* the briefed commit is
# not what it has, so it examined no criterion, re-ran no gate, and corroborated
# no recap claim). Those are the rubber-stamp shapes, and a constraint that must
# hold regardless of the model's judgment belongs in a script, not in a paragraph
# asking it to be careful.
#
# Findings lines, one per run, and the path each one reports:
#   OK <summary>                                          the block may post
#   INVALID: pr must be a number, got: ...                argument
#   INVALID: <file> does not exist                        argument
#   INVALID: <file> is under the superseded marker ...    marker
#   INVALID: <file> does not open with the ...            marker
#   INVALID VERDICT must be ...                           field vocabulary
#   INVALID GATES must be ...                             field vocabulary
#   INVALID CRITERIA must be ...                          field shape
#   INVALID TICKET: #<n> and VERIFIED-ON: ... required    field presence
#   INVALID EXAMINED-COMMIT: <commit> is required         field presence
#   INVALID EXAMINED-COMMIT must be a full 40-character   field shape
#   INVALID PR field is ...                               field agreement
#   INVALID a pass needs every criterion met ...          dishonest shape
#   INVALID a failing gate cannot sit under verdict ...   dishonest shape
#   INVALID a refused verdict examined nothing ...        dishonest shape
#   INVALID RECAP: corroborated | ... is required         field presence
#   INVALID RECAP must be corroborated | ...              field vocabulary
#   INVALID CONCERNS: is required ...                     field presence
#   INVALID CONCERNS says "none" on one line ...          field agreement
#   INVALID a concern needs a leading scope tag ...       concern shape
#   INVALID the scope tag on a concern must be ...        concern shape
#   INVALID an [adjacent] concern must name the issue     concern shape
#   INVALID a concern needs a measurement ...             concern shape
#   INVALID a contradicted recap claim needs a RECAP-WHY  recap shape
#   INVALID a contradicted recap claim needs a leading    recap shape
#   INVALID a contradicted recap claim needs a measure    recap shape
#   INVALID a concerns verdict parks the PR ...           verdict agreement
#   INVALID a pass cannot carry a [diff] element ...      verdict agreement
set -u
pr="${1:?usage: validate-verdict.sh <pr-number> [dir]}"
pr="${pr#\#}"
dir="${2:-.}"
f="$dir/verdict-$pr.txt"

case "$pr" in ''|*[!0-9]*) echo "INVALID: pr must be a number, got: $1"; exit 1 ;; esac
[ -f "$f" ] || { echo "INVALID: $f does not exist"; exit 1; }

first=$(head -n 1 "$f")
case "$first" in
  '<!-- verifier-verdict v2 -->') ;;
  '<!-- verifier-verdict v'*'-->')
    echo "INVALID: $f is under the superseded marker '$first' — a verdict written before the examined-commit witness is not a claim about any tree, so re-verify, do not re-label"
    exit 1 ;;
  *)
    echo "INVALID: $f does not open with the verifier-verdict marker validate-verdict.sh carries"
    exit 1 ;;
esac

out=$(jq -Rrs --arg pr "$pr" '
    def tagtext: (capture("^[ \t]*\\[(?<t>[^]]*)\\]") | .t) // null;
    def scopeof: tagtext as $t
      | if   $t == null                             then "untagged"
        elif ($t | test("^diff$"))                  then "diff"
        elif ($t | test("^adjacent[ \t]+#[0-9]+$")) then "adjacent"
        elif ($t | test("^adjacent$"))              then "adjacent-unfiled"
        else "unknown" end;
    def measured: test("MEASURED:[ \t]*[^ \t].*(->|→)[ \t]*[^ \t]");
    def snip: sub("^[ \t]+"; "") | if length > 60 then .[0:57] + "..." else . end;
    def firstof(p): [.[] | select(p)] | if length == 0 then null else .[0] end;

    (gsub("\r"; "") | split("\n")) as $lines
  | ($lines | map(select(startswith("CONCERNS:")) | ltrimstr("CONCERNS:"))) as $call
  | ([$call[] | select(test("^[ \t]*none\\b"))])       as $cnone
  | ([$call[] | select(test("^[ \t]*none\\b") | not)]) as $creal
  | (($lines | map(select(startswith("RECAP-WHY:")) | ltrimstr("RECAP-WHY:"))) | firstof(true)) as $rw
  | (($lines | map(select(startswith("RECAP:")))) | firstof(true)) as $rline
  | ((($rline // "") | capture("^RECAP:[ \t]*(?<x>[a-z-]+)") | .x) // null) as $r
  | (if $r == "contradicted" and $rw != null then ($rw | scopeof) else null end) as $rscope
  | ([($creal[] | scopeof), $rscope] | any(. == "diff")) as $anydiff

  | ((capture("VERDICT: (?<x>[a-z-]+)")           | .x) // null) as $v
  | ((capture("GATES: (?<x>[a-z-]+)")             | .x) // null) as $g
  | ((capture("CRITERIA: (?<x>[0-9]+)/")          | .x | tonumber) // null) as $met
  | ((capture("CRITERIA: [0-9]+/(?<x>[0-9]+)")    | .x | tonumber) // null) as $tot
  | ((capture("TICKET: #(?<x>[0-9]+)")            | .x) // null) as $n
  | ((capture("PR: #(?<x>[0-9]+)")                | .x) // null) as $p
  | ((capture("VERIFIED-ON: (?<x>[0-9]{4}-[0-9]{2}-[0-9]{2})") | .x) // null) as $d
  | ((capture("EXAMINED-COMMIT:[ \t]*(?<x>[^\\n\\r]*)") | .x | sub("[ \t]+$"; "")) // null) as $c
  | "verdict=\($v) criteria=\($met)/\($tot) gates=\($g) ticket=#\($n) pr=#\($p) verified-on=\($d) examined-commit=\($c) recap=\($r) concerns=\($creal | length)"
    as $sum
  | if   ($v | IN("pass","concerns","fail","refused") | not)
    then "INVALID VERDICT must be pass | concerns | fail | refused — \($sum)"
    elif ($g | IN("pass","fail","not-rerun") | not)
    then "INVALID GATES must be pass | fail | not-rerun — \($sum)"
    elif ($met == null or $tot == null or $tot < 1 or $met > $tot)
    then "INVALID CRITERIA must be <met>/<total>, total >= 1, met <= total — \($sum)"
    elif ($n == null or $d == null)
    then "INVALID TICKET: #<n> and VERIFIED-ON: <YYYY-MM-DD> are required — \($sum)"
    elif ($c == null or $c == "")
    then "INVALID EXAMINED-COMMIT: <commit> is required — a verdict is a claim about an identified tree — \($sum)"
    elif ($c | test("^[0-9a-f]{40}$") | not)
    then "INVALID EXAMINED-COMMIT must be a full 40-character lowercase hex commit id, not an abbreviation — \($sum)"
    elif ($p != $pr)
    then "INVALID PR field is #\($p), validating #\($pr) — \($sum)"
    elif ($v == "pass" and ($met < $tot or $g != "pass"))
    then "INVALID a pass needs every criterion met and gates=pass — \($sum)"
    elif ($g == "fail" and $v != "fail")
    then "INVALID a failing gate cannot sit under verdict \($v) — \($sum)"
    elif ($v == "refused" and ($met != 0 or $g != "not-rerun" or ($r != null and $r != "unverifiable")))
    then "INVALID a refused verdict examined nothing — CRITERIA must be 0/<total>, GATES not-rerun and RECAP unverifiable — \($sum)"
    elif ($r == null)
    then "INVALID RECAP: corroborated | contradicted | unverifiable is required — the recap axis sets the verdict word, so it is a field, not prose — \($sum)"
    elif ($r | IN("corroborated","contradicted","unverifiable") | not)
    then "INVALID RECAP must be corroborated | contradicted | unverifiable — \($sum)"
    elif (($call | length) == 0)
    then "INVALID CONCERNS: is required — an absent field does not read as \"none\" — \($sum)"
    elif (($cnone | length) > 0 and ($creal | length) > 0)
    then "INVALID CONCERNS says \"none\" on one line and carries a concern on another — \($sum)"
    elif ($v != "refused" and ($creal | firstof(scopeof == "untagged")) != null)
    then "INVALID a concern needs a leading scope tag, [diff] or [adjacent #<n>] — got: \($creal | firstof(scopeof == "untagged") | snip) — \($sum)"
    elif ($v != "refused" and ($creal | firstof(scopeof == "unknown")) != null)
    then "INVALID the scope tag on a concern must be [diff] or [adjacent #<n>] — got: \($creal | firstof(scopeof == "unknown") | snip) — \($sum)"
    elif ($v != "refused" and ($creal | firstof(scopeof == "adjacent-unfiled")) != null)
    then "INVALID an [adjacent] concern must name the issue it was filed as, [adjacent #<n>] — got: \($creal | firstof(scopeof == "adjacent-unfiled") | snip) — \($sum)"
    elif ($v != "refused" and ($creal | firstof(measured | not)) != null)
    then "INVALID a concern needs a measurement, MEASURED: <command> -> <output> — got: \($creal | firstof(measured | not) | snip) — \($sum)"
    elif ($r == "contradicted" and $rw == null)
    then "INVALID a contradicted recap claim needs a RECAP-WHY line to carry its tag and its measurement — \($sum)"
    elif ($r == "contradicted" and ($rscope | IN("diff","adjacent","adjacent-unfiled") | not))
    then "INVALID a contradicted recap claim needs a leading scope tag on RECAP-WHY, [diff] when it changes what the PR does, [adjacent] when it does not — got: \($rw | snip) — \($sum)"
    elif ($r == "contradicted" and ($rw | measured | not))
    then "INVALID a contradicted recap claim needs a measurement on RECAP-WHY, MEASURED: <command> -> <output> — got: \($rw | snip) — \($sum)"
    elif ($v == "concerns" and ($anydiff | not))
    then "INVALID a concerns verdict parks the PR, so it needs one [diff] element — an adjacent finding is filed and reported, never a verdict — \($sum)"
    elif ($v == "pass" and $anydiff)
    then "INVALID a pass cannot carry a [diff] element — a concern about the examined tree is what the concerns verdict is for — \($sum)"
    else "OK \($sum)" end' < "$f")

echo "$out"
case "$out" in OK*) exit 0 ;; *) exit 1 ;; esac
