#!/bin/bash
# check-holds.sh <issue-number> <locks-decl> — may this candidate take a
# lane while other work is in flight?
#
# The declaration is the one pick.sh already resolved — its `locks` field, `-`
# for a ticket that declares none — never a re-read of the issue body. What this
# check clears is what the claim then snapshots (CLAIM.md), so the two can never
# describe different dispatches.
#
# **Two holds, and no others** (ADR 0007). A candidate is held by a global lock
# another lane already holds, and by any parked PR waiting on the PM. File
# overlap is not a hold: two tickets may run together whatever they touch,
# because the serialized merge pipeline resolves the overlap at landing, where
# the file lists exist.
#
# **The lock hold reads two windows, and both every run.** An open lane claim
# carries the snapshot of a dispatch that may not have pushed anything yet; an
# open loop PR carries a measured file list the lock globs match. Reading one
# without the other leaves a hole exactly as long as a worker's first edit.
#
# **The park hold reads the claims alone.** A parked PR fell to the PM — an
# update conflict, a pin refused twice, `concerns`, `fail` — and until the PM
# clears it no lane fills at all, whatever it would touch. Parking annotates the
# claim with a `PARKED:` line, which `claim-status.sh` answers CLAIM-PARKED for,
# so the claim listing this check already reads answers it at no extra host
# call. The hold is printed every cycle, because a park nobody clears stops the
# run and only the repetition says so.
#
#   stdout  zero or more COLLISION-UNRESOLVED lines, then exactly one verdict
#           line — COLLISION-CLEAR or COLLISION-HELD — last.
#   stderr  exactly one COLLISION-UNKNOWN line when the answer cannot be
#           measured, and then no verdict line at all.
#   exit 0  free to dispatch: no shared global lock, no parked claim.
#   exit 1  held. A hold and an unreadable listing exit alike, because under
#           more than one lane the unknown case holds instead of dispatching
#           (spec #96): a listing or API failure is a hold, never a clear.
#
# **One COLLISION-HELD line, the first reason found**, in this order: a parked
# claim, then a shared global lock (claims ascending, then PRs ascending). A
# held candidate is skipped whatever the reason, so a second line would add
# noise, not a decision.
#
# **Normalization.** A declaration is a comma-separated list; each name is
# trimmed and lowercased, and `-`, `none` and `n/a` are the written forms of
# "declares none". Names are compared to each other; the `global_locks` table is
# what turns an open PR's measured paths into the locks it holds. Reading the
# table and matching its globs is `locks-lib.sh`, sourced below and shared
# with `check-declared-locks.sh` — the check that holds a candidate and the
# check that audits its PR must never answer differently about a path.
#
# **Unknown holds, never clears:**
#   - a claim, an issue listing or a PR listing that cannot be read is the
#     unknown case, and the unknown case holds;
#   - a listing that came back **at** its row limit may have been cut short, so
#     it holds too. `gh` pages silently: measured on gh 2.98.0, `--limit`
#     defaults to 30 for both `pr list` and `issue list`, and neither says it
#     truncated. Both listings therefore pass an explicit limit and refuse to
#     clear a lane on a window that reached it;
#   - an open PR whose own file list came back cut short holds as well, and it
#     holds the whole cycle rather than its own row. `gh --json files` returns at
#     most 100 file rows per PR and says nothing either (measured on gh 2.98.0:
#     kubernetes/kubernetes#141226, 301 changed, 100 returned, exit 0), so the
#     row's `changedFiles` total is held up against the number of rows returned
#     and any disagreement — a missing or non-numeric total included — refuses.
#     The verdict is derived from every open PR at once, so one unreadable PR
#     leaves it unestablished.
#
# Those last two are the only ways a script whose contract is "unknown holds"
# could read CLEAR while a held lock sat past a cut.
#
# A declared lock no row of the table carries is reported and then compared by
# name alone. It is not a hold on its own: two lanes declaring the same
# unregistered name still serialize, and a name nobody else declares still
# dispatches.
#
# The findings lines, all of them:
#
#   COLLISION-CLEAR: #<n> — no shared global lock with <k> in flight, and no parked claim
#   COLLISION-HELD: #<n> — #<m> carries a parked claim; no lane fills until the PM clears it
#   COLLISION-HELD: #<n> — global lock <lock> is also held by <holder>
#   COLLISION-UNRESOLVED: #<n> declares lock '<l>' — no row of the global_locks table in <config> carries it; it is compared by name alone
#   COLLISION-UNKNOWN: ...    (stderr, exit 1)
#
# A holder is `#<m> (claim)` or `PR #<p>`.
#
# Whether a claim is open, parked or released is asked of `claim-status.sh` —
# the single home for the release rule — rather than re-implemented here, and
# only for open issues that actually carry the marker, so an ordinary cycle asks
# it about nothing. Parkedness is decided on that script's verdict word, never
# on its prose.
#
# The honest bounds, both of them:
#
#   - A measured path containing a space is split on it, so such a path matches
#     no lock glob. Fail-safe only for the file overlap this check no longer
#     reads; for a lock it is a real gap, and no path in this fleet has a space
#     yet.
#   - The in-flight window is 200 open PRs and 200 open issues. Past that the
#     drain holds every candidate rather than reading a partial window as
#     clear, so the ceiling costs throughput and never safety. Raising it is one
#     number here; the issue listing is the expensive half, because finding a
#     claim needs every open issue's comments.
#
# Environment: $LOOP_CONFIG relocates docs/agents/loop.md, as it does for
# resolve-lanes.sh; $LEDGER_FILE reaches claim-status.sh.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
. "$here/locks-lib.sh"

unknown() {
  echo "COLLISION-UNKNOWN: $1" >&2
  exit 1
}

[ $# -eq 2 ] \
  || unknown "usage: check-holds.sh <issue-number> <locks-decl>"
n="${1#\#}"
case "$n" in
  ''|*[!0-9]*) unknown "usage: check-holds.sh <issue-number> <locks-decl>, got issue: $1" ;;
esac

# --- the table ----------------------------------------------------------------
# `locks_load` sets $LOCKS_CONFIG whether or not it could read one, so the
# refusal can name the path it looked at.
locks_load \
  || unknown "no loop config at $LOCKS_CONFIG — the global_locks table cannot be read, and an unread table shows no lock held or free"
config="$LOCKS_CONFIG"

# --- the candidate ------------------------------------------------------------
unresolved=""
cand_locks=""
while IFS= read -r l; do
  [ -n "$l" ] || continue
  case " $cand_locks " in *" $l "*) ;; *) cand_locks="$cand_locks $l" ;; esac
  printf '%s\n' "$LOCKS_TABLE" | cut -d"$TAB" -f1 | grep -qxF "$l" && continue
  unresolved="${unresolved}COLLISION-UNRESOLVED: #$n declares lock '$l' — no row of the global_locks table in $config carries it; it is compared by name alone
"
done <<EOF
$(norm_list "$2")
EOF

# --- what is in flight --------------------------------------------------------
# One record per holder: <label>\t<locks|->, claims first and both groups
# ascending, so the reason named for a hold is the same one every run.
inflight=""
# The lowest-numbered ticket whose claim is parked, or empty. One park stops the
# whole run, so the first one found is the whole finding.
parked=""

# The row limit both listings are read at, and the count at which a listing is
# refused. `gh` truncates to its limit and says nothing about it, so a window
# that comes back exactly full is one that may have been cut short — and a
# partial window is the only shape that could clear a lane while a hold sat past
# the cut.
WINDOW=200

# A listing that reached the limit cannot be told from one that stopped just
# short of it, so both hold. Refuses a non-numeric count too: `gh` reporting an
# error object rather than an array must never fall through as "few enough".
refuse_if_truncated() { # <count> <what>
  case "$1" in
    ''|*[!0-9]*) unknown "the open $2 list did not answer with a row count — an uncountable window never clears a lane" ;;
  esac
  [ "$1" -lt "$WINDOW" ] \
    || unknown "the open $2 list came back at its $WINDOW-row limit — gh truncates silently, so whether more work is in flight past the cut cannot be told, and a window that may have truncated never clears a lane"
}

# The second truncation axis, one level down: a single row's file list. `gh
# --json files` returns at most 100 file rows per PR and says nothing when it
# cuts the rest, so a PR holding a lock only through its 101st file would read as
# holding none. `changedFiles` is the row's own true total, and a row where the
# two disagree is unread. One such row refuses the whole cycle rather than that
# row alone, because the verdict is derived from every open PR at once.
refuse_if_files_cut() { # <pr-list-json>
  local nc cut
  nc="$(printf '%s\n' "$1" | jq -r \
    '[.[] | select((.changedFiles | type) != "number") | .number] | .[0] // ""' 2>/dev/null)"
  [ -z "$nc" ] \
    || unknown "PR #$nc carries no numeric changedFiles total — whether its file list came back whole cannot be told, and a window that may have truncated never clears a lane"
  cut="$(printf '%s\n' "$1" | jq -r \
    '[.[] | select(.changedFiles != ([.files[]?] | length))] | .[0]
     | if . == null then "" else "\(.number) \(.changedFiles) \([.files[]?] | length)" end' 2>/dev/null)"
  [ -n "$cut" ] || return 0
  set -- ${cut}
  unknown "PR #$1 came back with a truncated file list — $2 files changed, $3 rows returned; gh caps at 100 rows per PR and says nothing, so a lock it holds past the cut cannot be told from one it never held"
}

issues="$(gh issue list --state open --limit "$WINDOW" --json number,comments 2>/dev/null)" \
  || unknown "the open issue list could not be read — open lane claims cannot be enumerated, and under lanes the unknown case holds"
# jq on empty input prints nothing and exits 0, so a gh that failed without a
# non-zero exit would otherwise read as a repo carrying no claims at all.
[ -n "$issues" ] \
  || unknown "gh answered nothing for the open issue list, not even an empty list"

# Counted before the claims are read, so a truncated window costs one jq rather
# than a claim-status.sh call per marked issue.
refuse_if_truncated \
  "$(printf '%s\n' "$issues" | jq -r 'if type == "array" then length else "" end' 2>/dev/null)" \
  issue

# The marker counts only on a line of its own, and jq's `$` anchors the whole
# string rather than a line — so every matcher here splits into lines first,
# exactly as pick.sh and claim-status.sh do.
#
# The candidate's own claim is **not** excluded from the park scan the way it is
# from the lock comparison: a run whose own ticket is parked is a run that stops.
# It is excluded from the lock comparison because a ticket cannot hold a lock
# against itself.
claimed="$(printf '%s\n' "$issues" | jq -r '
  [ .[] | select([ .comments[]?.body | select(type == "string")
                   | select(any(split("\n")[]; test("^<!-- lane-claim v1 -->[ \t\r]*$"))) ] | length > 0)
    | .number ] | sort | .[]' 2>/dev/null)" \
  || unknown "the open issue list is not JSON this check can read"

while IFS= read -r cn; do
  [ -n "$cn" ] || continue
  status="$(bash "$here/claim-status.sh" "$cn" 2>/dev/null </dev/null)"
  case "$status" in
    CLAIM-RELEASED*|CLAIM-NONE*) continue ;;
    CLAIM-PARKED*) [ -n "$parked" ] || parked="$cn"; continue ;;
    CLAIM-OPEN*) ;;
    *) unknown "#$cn carries a lane claim this cycle could not read — an unread claim is never a released one, and under lanes the unknown case holds" ;;
  esac
  [ "$cn" != "$n" ] || continue
  clocks="$(printf '%s\n' "$status" | sed -n 's/.*, locks "\([^"]*\)".*/\1/p')"
  hl="$(norm_list "$clocks" | tr '\n' ' ')"
  hl="${hl% }"
  [ -n "$hl" ] || hl="-"
  inflight="${inflight}#$cn (claim)${TAB}${hl}
"
done <<EOF
$claimed
EOF

prs="$(gh pr list --state open --author "@me" --limit "$WINDOW" --json number,headRefName,changedFiles,files 2>/dev/null)" \
  || unknown "the open PR list could not be read — the pushed-and-waiting window cannot be measured, and under lanes the unknown case holds"
[ -n "$prs" ] \
  || unknown "gh answered nothing for the open PR list, not even an empty list"

refuse_if_truncated \
  "$(printf '%s\n' "$prs" | jq -r 'if type == "array" then length else "" end' 2>/dev/null)" \
  PR

refuse_if_files_cut "$prs"

pr_rows="$(printf '%s\n' "$prs" | jq -r 'sort_by(.number) | .[]
  | "\(.number)\t" + ([.files[]?.path] | unique | join(" "))' 2>/dev/null)" \
  || unknown "the open PR list is not JSON this check can read"

while IFS="$TAB" read -r pnum ppaths; do
  [ -n "$pnum" ] || continue
  hl=""
  for p in ${ppaths:-}; do
    while IFS= read -r lk; do
      [ -n "$lk" ] || continue
      case " $hl " in *" $lk "*) ;; *) hl="$hl $lk" ;; esac
    done <<EOF
$(path_locks "$(lower "$p")")
EOF
  done
  hl="${hl# }"
  [ -n "$hl" ] || hl="-"
  inflight="${inflight}PR #$pnum${TAB}${hl}
"
done <<EOF
$pr_rows
EOF

[ -z "$unresolved" ] || printf '%s' "$unresolved"

# --- the verdict --------------------------------------------------------------
held_count="$(printf '%s' "$inflight" | grep -c .)"

# 1. a parked claim stops every lane, whatever anything declares.
if [ -n "$parked" ]; then
  printf 'COLLISION-HELD: #%s — #%s carries a parked claim; no lane fills until the PM clears it\n' \
    "$n" "$parked"
  exit 1
fi

# 2. a shared global lock.
verdict=""
while IFS="$TAB" read -r label hl; do
  [ -n "$label" ] || continue
  [ -n "$verdict" ] && continue
  for cl in $cand_locks; do
    for h in $hl; do
      [ "$cl" = "$h" ] || continue
      verdict="COLLISION-HELD: #$n — global lock $cl is also held by $label"
      break
    done
    [ -n "$verdict" ] && break
  done
done <<EOF
$inflight
EOF

if [ -z "$verdict" ]; then
  printf 'COLLISION-CLEAR: #%s — no shared global lock with %s in flight, and no parked claim\n' \
    "$n" "$held_count"
  exit 0
fi

printf '%s\n' "$verdict"
exit 1
