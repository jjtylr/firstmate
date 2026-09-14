#!/bin/bash
# decl-lib.sh — the jq that resolves a ticket's machine-readable declaration
# lines (`Area:`, `Locks:`) from its body and its agent briefs. It resolves any
# key it is handed, so a ticket still carrying a pre-ADR-0007 surface line
# costs it nothing: no caller asks for that key any more.
# **Sourced, never run**: it has no arguments, prints nothing of its own, and
# exits nothing.
#
#   . "$(dirname "$0")/decl-lib.sh"
#   jq "$DECL_JQ"'<the caller's own program>'
#
# `$DECL_JQ` is jq source text — two function definitions and nothing else, so
# it prefixes any program without changing what that program reads.
#
#   briefs($comments)  every agent brief on one issue, in document order, as a
#                      list of body strings. Only the body and marked briefs are
#                      declaration sources; an ordinary comment mentioning
#                      `Locks:` is discussion and must not move the value.
#   decl($srcs; $k)    the effective value of line `<k>:` across those sources —
#                      last non-empty wins, per line, independently — or null.
#
# The resolution order and the `<!-- agent-brief v1 -->` marker are specified in
# skills/triage/TICKET-BRIEF.md; this is that spec in jq, not a second one.
#
# **Two scripts resolve the same lines and must never disagree** —
# `pick.sh`, of the candidate it ranks and hands to the claim, and
# `check-declared-locks.sh`, of the ticket whose PR it audits. A second copy
# would read fine and drift silently, and the two answers disagreeing is
# precisely the state a declared-vs-measured comparison exists to detect. So
# there is one copy, here, on the same rule `locks-lib.sh` holds for the
# tables.
#
# Three forms are load-bearing; keep them under any edit:
#
#  - **Every brief, in document order — never just the last one.** A replacement
#    brief is the sanctioned post-dispatch amendment path, and it may restate
#    only the line that changes; binding only the last brief reverts the
#    unrestated line to the body's value, silently, in the unsafe direction
#    (issue #61). So `briefs` keeps the whole list and `decl` folds it.
#  - **A marker counts only on a line of its own**, which is what the write-side
#    validators enforce, so both sides share one definition of "marked". A
#    `contains()` substring test cannot tell the artifact from prose quoting it:
#    measured 2026-08-19, it read a triage discussion on #50 as a marked brief,
#    and because resolution takes the LAST non-empty value a quoting comment
#    posted after the real brief would silently override it.
#  - **Every matcher splits into lines first**, because jq's `$` anchors the end
#    of the whole string, not the end of a line (measured jq-1.7.1):
#    `test("^## Agent Brief$")` is false for every real comment, and it fails
#    silently by resolving from the body instead. The trailing `[ \t\r]*`
#    absorbs a CRLF body from the API.
#
# Legacy briefs predating the marker are matched on their `## Agent Brief`
# heading; drop that clause once no unmarked brief is still in flight.
set -u

# Read, never `$(cat <<'JQ' … )`: bash keeps parsing a heredoc body inside a
# command substitution, and the lone backtick in the `gsub` class below is then
# an unterminated command substitution — measured on bash 3.2, `unexpected EOF
# while looking for matching '`'`, with the whole library refusing to source.
# `read -d ''` stops at end of input and returns 1 there, which is the ordinary
# case, so the `|| :` is expected rather than defensive.
IFS= read -r -d '' DECL_JQ <<'JQ' || :
def briefs($comments):
  [ $comments[]?.body | select(type == "string")
    | select(any(split("\n")[];
                 test("^<!-- agent-brief v1 -->[ \t\r]*$")
                 or test("^#+[ \t]*Agent Brief[ \t\r]*$"))) ];
def decl($srcs; $k):
  [ $srcs[] | select(type == "string")
    | [ split("\n")[]
        | select(test("^[*_ \t]*" + $k + "[*_ \t]*:"))
        | sub("^[*_ \t]*" + $k + "[*_ \t]*:"; "")
        | gsub("[*`]"; "")
        | sub("^[ \t]+"; "") | sub("[ \t\r]+$"; "")
        | select(length > 0) ]
      | last // empty ]
  | last // null;
JQ
