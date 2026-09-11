#!/bin/bash
# check-declared-locks.sh <issue-number> <pr-number> — did this PR touch a
# global lock its own ticket never declared?
#
# The lock rule has two halves, and only the holder half was ever measured.
# `check-lock.sh` reads every open loop PR's real file list and matches it
# against the registered globs, so an open PR cannot hide a lock it holds. The
# candidate half reads the ticket's `Locks:` line, and that line is written at
# triage, before any file list exists — so any scope change during
# implementation silently invalidates it. Merged #136 is the live instance: its
# ticket said `Locks: none` and PR #138 touched `CONTEXT.md` and
# `docs/agents/loop.md`, two registered locks. Nothing anywhere said so.
#
# **This is a detector, not a guard.** It names a mis-declaration; it blocks
# nothing, reverts nothing and merges nothing. The exit code is a signal for the
# caller to relay, and what the drain does with it is SKILL.md's step 5.
#
#   stdout  zero or more LOCKS-UNRESOLVED lines, then zero or more
#           LOCKS-UNDECLARED lines, then exactly one verdict line —
#           LOCKS-MATCH or LOCKS-MISMATCH — last.
#   stderr  exactly one LOCKS-UNKNOWN line when the answer cannot be measured,
#           and then no verdict line at all.
#   exit 0  every lock this PR matched was declared by its ticket.
#   exit 1  a lock was matched and not declared, or the comparison could not be
#           made. Both exit alike: a comparison that did not run has not shown
#           the declaration true, and an unread lock is never a free one — the
#           reading `check-lock.sh` already takes.
#
# **It reads the PR's measured file list, never the ticket's declaration, for
# the measured side.** That is the whole point: a check that took the lock set
# from the `Locks:` line would inherit the error it exists to find.
#
# **A file list that came back cut short is unknown, never clean.** `gh --json
# files` returns at most 100 file rows per PR and says nothing when it drops the
# rest (measured on gh 2.98.0: kubernetes/kubernetes#141226, 301 changed, 100
# returned, exit 0). Reading a partial list as whole can only lose a lock, so a
# held lock would print LOCKS-MATCH at exit 0. The PR's own `changedFiles` total
# is therefore held up against the number of rows returned, and LOCKS-UNKNOWN
# names the PR, the true total and the returned length. A payload carrying no
# numeric `changedFiles` refuses the same way: an uncounted list is never a
# complete one.
#
# The test is measured ⊆ declared, so **over-declaration is not a finding**. A
# ticket that declared a lock its PR never touched cost throughput and
# endangered nothing.
#
# The findings lines, all of them:
#
#   LOCKS-MATCH: #<n> PR #<p> — measured <m> within declared <d>; nothing undeclared
#   LOCKS-MISMATCH: #<n> PR #<p> — declared <d>, measured <m>; undeclared <u>
#   LOCKS-UNDECLARED: #<n> PR #<p> — lock <lock> matched by <path>[, <path>], and the ticket declares <d>
#   LOCKS-UNRESOLVED: #<n> declares lock '<l>' — no row of the global_locks table in <config> carries it
#   LOCKS-UNKNOWN: ...    (stderr, exit 1)
#
# One LOCKS-UNDECLARED line per undeclared lock, in the order the PR's paths
# matched them, each naming every path of that PR that matched the glob. `-` is
# the written form of an empty set on either side.
#
# **An empty or absent `global_locks` table is a clean exit, not a failure.** No
# row matches anything, so the measured set is empty, the verdict is
# LOCKS-MATCH, and the declared names are not reported as unresolvable either —
# a repo that registered no locks has opted out, and one line per declared name
# would be noise about that choice rather than a defect. A config that cannot be
# read at all is the unknown case instead: an unread table shows nothing.
#
# The globs are matched through `locks-lib.sh`'s `path_locks`, the one copy
# `check-holds.sh` already reads an open PR's files with, so the check that
# holds a candidate and the check that audits its PR can never disagree about a
# path. The ticket's effective `Locks:` value is resolved through
# `decl-lib.sh` — issue body plus every marked agent brief, last non-empty wins
# per line (skills/triage/TICKET-BRIEF.md) — the same copy `pick.sh` dispatched
# on. The claim is deliberately not the source here: a claim snapshots what the
# collision check cleared, and this check asks whether the *ticket's* own
# declaration survived the work.
#
# Environment: $LOOP_CONFIG relocates docs/agents/loop.md, as it does for
# check-holds.sh.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
. "$here/locks-lib.sh"
. "$here/decl-lib.sh"

unknown() {
  echo "LOCKS-UNKNOWN: $1" >&2
  exit 1
}

[ $# -eq 2 ] \
  || unknown "usage: check-declared-locks.sh <issue-number> <pr-number>"
n="${1#\#}"
p="${2#\#}"
case "$n" in
  ''|*[!0-9]*) unknown "usage: check-declared-locks.sh <issue-number> <pr-number>, got issue: $1" ;;
esac
case "$p" in
  ''|*[!0-9]*) unknown "usage: check-declared-locks.sh <issue-number> <pr-number>, got pr: $2" ;;
esac

locks_load \
  || unknown "no loop config at $LOCKS_CONFIG — the global_locks table cannot be read, and an unread table shows no lock held or free"
config="$LOCKS_CONFIG"

# --- what the ticket declared -------------------------------------------------
issue="$(gh issue view "$n" --json body,comments 2>/dev/null)" \
  || unknown "#$n — its body and comments could not be read, so what it declared cannot be recovered"
[ -n "$issue" ] \
  || unknown "gh answered nothing for #$n, not even an empty object"

declared_raw="$(printf '%s\n' "$issue" | jq -r "$DECL_JQ"'
  (briefs(.comments)) as $bs | decl([.body] + $bs; "Locks") // ""' 2>/dev/null)" \
  || unknown "#$n — its body and comments are not JSON this check can read"

unresolved=""
decl=""
while IFS= read -r l; do
  [ -n "$l" ] || continue
  case " $decl " in *" $l "*) ;; *) decl="$decl $l" ;; esac
  # Reported only where the repo registered locks at all; see the header.
  [ -n "$LOCKS_TABLE" ] || continue
  printf '%s\n' "$LOCKS_TABLE" | cut -d"$TAB" -f1 | grep -qxF "$l" && continue
  unresolved="${unresolved}LOCKS-UNRESOLVED: #$n declares lock '$l' — no row of the global_locks table in $config carries it
"
done <<EOF
$(norm_list "$declared_raw")
EOF

# --- what the PR measured -----------------------------------------------------
files="$(gh pr view "$p" --json changedFiles,files 2>/dev/null)" \
  || unknown "PR #$p — its file list could not be read, and an unmeasured PR cannot show a declaration held"
[ -n "$files" ] \
  || unknown "gh answered nothing for PR #$p's file list, not even an empty one"

# `gh --json files` caps at 100 file rows and says nothing when it cuts the
# rest, so the PR's own changedFiles total is held up against the number of rows
# returned. A partial list can only ever miss a lock, never invent one.
counts="$(printf '%s\n' "$files" | jq -r \
  'if (.changedFiles | type) == "number"
   then "\(.changedFiles) \([.files[]?] | length)" else "" end' 2>/dev/null)"
case "$counts" in
  ''|*[!0-9\ ]*) unknown "PR #$p carries no numeric changedFiles total — whether its file list came back whole cannot be told, and an unread lock is never a free one" ;;
esac
[ "${counts%% *}" = "${counts##* }" ] \
  || unknown "PR #$p came back with a truncated file list — ${counts%% *} files changed, ${counts##* } rows returned; gh caps at 100 rows per PR, so a lock held by a path past the cut would read as free"

paths="$(printf '%s\n' "$files" | jq -r '[.files[]?.path] | unique | .[]' 2>/dev/null)" \
  || unknown "PR #$p — its file list is not JSON this check can read"

# One `<lock><TAB><path>` line per match, so the paths behind a lock can be
# named without an associative array (bash 3.2).
hits=""
meas=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  while IFS= read -r lk; do
    [ -n "$lk" ] || continue
    hits="${hits}${lk}${TAB}${path}
"
    case " $meas " in *" $lk "*) ;; *) meas="$meas $lk" ;; esac
  done <<EOF2
$(path_locks "$(lower "$path")")
EOF2
done <<EOF
$paths
EOF

# --- the verdict --------------------------------------------------------------
show() { # <space-separated set>
  local v="${1# }"
  [ -n "$v" ] || { printf '%s' '-'; return 0; }
  printf '%s' "${v// /, }"
}

# Everything the measured set carries that the declared set does not. Nothing
# flows the other way: over-declaration is not a hazard, so it is not a finding.
undeclared=""
for m in $meas; do
  case " $decl " in
    *" $m "*) ;;
    *) undeclared="$undeclared $m" ;;
  esac
done

[ -z "$unresolved" ] || printf '%s' "$unresolved"

for u in $undeclared; do
  ps="$(printf '%s' "$hits" | grep "^$u$TAB" | cut -d"$TAB" -f2- | tr '\n' ' ')"
  printf 'LOCKS-UNDECLARED: #%s PR #%s — lock %s matched by %s, and the ticket declares %s\n' \
    "$n" "$p" "$u" "$(show " ${ps% }")" "$(show "$decl")"
done

if [ -z "$undeclared" ]; then
  printf 'LOCKS-MATCH: #%s PR #%s — measured %s within declared %s; nothing undeclared\n' \
    "$n" "$p" "$(show "$meas")" "$(show "$decl")"
  exit 0
fi

printf 'LOCKS-MISMATCH: #%s PR #%s — declared %s, measured %s; undeclared %s\n' \
  "$n" "$p" "$(show "$decl")" "$(show "$meas")" "$(show "$undeclared")"
exit 1
