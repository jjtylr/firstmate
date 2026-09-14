#!/bin/bash
# ledger-append.sh [--commit] [--push] <issue> <pr|-> <outcome> [verdict|-] [tokens|-] [date|-] [lanes|-]
#
# Append one outcome-ledger row for a ticket that just left the queue, creating
# the ledger with its version marker when it is not there yet. The format is the
# script's to compose, never the caller's — a ledger whose rows drift in shape
# stops being an instrument and becomes prose.
#
#   outcome  merged-clean | rework | reverted | bounced | stopped | died — the
#            only judgment. `stopped` is a STOPPED recap; `bounced` is the
#            effort bounce alone, nothing attempted; `died` is a dispatch whose
#            run ended before it opened a PR, established dead by a pid
#            measured gone.
#   verdict  the verifier's verdict — pass | concerns | fail | refused; `-` when
#            none ran
#   tokens   what the harness reported for the dispatch; `-` when it reported none
#   date     the dispatch date, ISO; defaults to today
#   lanes    the `max_lanes` in force when this ticket was dispatched — what
#            `resolve-lanes.sh` printed, so 1, 2 or 3; `-` when it was not
#            recorded. This is what separates the parallel population from the
#            serial baseline it is judged against, so it is a fact about the run
#            rather than about the ticket. A value outside that vocabulary is
#            refused: a cell nothing can read is worse than an empty one.
#
# Both flags are read from **any** position and removed before the positionals
# are parsed, because the verdict cell is free text: under leading-flag-only
# parsing a trailing `--commit` would be written into the ledger as the verdict
# word.
#
#   --commit  with the ledger path carrying uncommitted changes, commit that one
#             path — see `commit_row` for what it does and does not touch.
#   --push    send the committed row to the branch's upstream, syncing first if
#             the push is refused. Implies --commit: a row that is not committed
#             cannot be pushed. See `push_row` for the bounds.
#
# A row that stays in this checkout is a blackboard of one, so landing it is the
# script's work and not a line of doctrine an orchestrator has to execute
# faithfully. Neither flag can turn a failure into an error: git problems are
# findings, and the caller decides what to do about them.
#
# Exits 0 having printed one finding line — more when it rewrote the file first,
# the LEDGER-MIGRATED and LEDGER-COLUMN-ADDED lines below and then one of these:
#   LEDGER-APPENDED:#<issue> …   the row was written
#   LEDGER-DUPLICATE:#<issue>    this issue+PR already has a row; nothing written,
#                                so re-running an iteration cannot double-count.
#                                Only rows carrying a PR dedupe. A row whose `pr`
#                                cell is `-` — `stopped`, `bounced`, `died` — is
#                                never deduped: that cell cannot tell two no-PR
#                                events apart, and a re-readied ticket can
#                                honestly stop, bounce or die again, which the
#                                STOPPED streak, the death streak and the bounce
#                                rate all have to see.
#
# Under the flags, further lines follow either of those. All of them exit 0 —
# the row is on disk whatever git did:
#   LEDGER-COMMITTED:<path> …    committed, and the line **names the branch** the
#                                row landed on: a row committed onto an agent
#                                branch instead of the base branch is the
#                                measured failure, and it has to be loud.
#   LEDGER-COMMIT-FAILED:<path> … the commit could not run; the row is written
#                                and uncommitted, with git's reason quoted.
#   LEDGER-PUSHED:<remote>/<branch> … the row reached the upstream, and the line
#                                says whether a sync was needed to get it there.
#   LEDGER-PUSH-FAILED: …        the row is committed but did not leave this
#                                checkout, with git's reason quoted. Relay it:
#                                the next run's gate will read a lagging ledger.
# With the ledger path already clean — a duplicate whose row was committed when
# it was written — --commit prints nothing further, and --push still pushes,
# because a committed row nobody can read is the defect either way. A failed
# commit ends the journey: nothing is pushed and only the one line is printed.
#
# Exits 1 with LEDGER-REFUSED, writing nothing and committing nothing, when the
# call is malformed — an unknown outcome, a non-numeric issue, a lane count
# outside {1, 2, 3}, a `stopped` or `died` row given a pr, a ledger whose marker
# is a version this script neither writes nor migrates. A bad field must never
# reach the file: every row is read later by script.
#
# Migration is this script's, not a PM's hands. A ledger opening with the
# previous marker and holding no rows whose outcome word changed meaning has its
# marker line rewritten in place, takes the append, and reports the rewrite:
#   LEDGER-MIGRATED:<path> …     printed before the append's own line, because a
#                                script that edits a PM's file says so
# One that holds such rows exits 1 with LEDGER-MIGRATION-BLOCKED and writes
# nothing — splitting them is a PM correction, not a rewrite a machine can make.
#
# **`lanes` is a field addition, not a meaning change, so the marker does not
# move** (STAGE-CONTRACT.md § 3's evolution rule, while the population is still
# small). What does move is the header: a ledger whose table header predates the
# column gets that header and its rule row rewritten in place, so the cell is
# visible where a human reads the file rather than dropped by the renderer.
#   LEDGER-COLUMN-ADDED:<path> … printed before the append's own line, for the
#                                same reason LEDGER-MIGRATED is. Rows written
#                                before the column read null — no cell, which is
#                                what every reader of this table already gets
#                                from a column that is not there.
#
# Ledger path: $LEDGER_FILE, else <repo root>/docs/agents/ledger.md.
set -u

# The canonical marker, and the one older version this script can migrate from.
# `scripts/check-markers.sh` reads the repo's canon from the first full-form
# marker in this file, so this stays the first one written here — and the older
# version is assembled, never spelled, so no stale literal ships in the string
# the check greps for.
MARKER='<!-- ledger v3 -->'
MIGRATE_FROM=2

refuse() { echo "LEDGER-REFUSED: $1"; exit 1; }

# The flags out of the argument list, wherever they sit, before anything reads a
# positional. Rotating the list rather than collecting an array keeps this on
# bash 3.2 and stays correct when every argument is a flag.
do_commit=0
do_push=0
argc=$#
argn=0
while [ "$argn" -lt "$argc" ]; do
  arg="$1"
  shift
  case "$arg" in
    --commit) do_commit=1 ;;
    --push)   do_push=1; do_commit=1 ;;
    *)        set -- "$@" "$arg" ;;
  esac
  argn=$((argn + 1))
done

[ $# -ge 3 ] || refuse "usage: ledger-append.sh [--commit] [--push] <issue> <pr|-> <outcome> [verdict|-] [tokens|-] [date|-] [lanes|-]"

issue="${1#\#}"
pr="${2#\#}"
outcome="$3"
verdict="${4:--}"
tokens="${5:--}"
day="${6:--}"
lanes="${7:--}"

case "$issue" in ''|*[!0-9]*) refuse "issue must be a number, got: $1" ;; esac
case "$pr" in
  '-') ;;
  ''|*[!0-9]*) refuse "pr must be a number or -, got: $2" ;;
esac
case "$outcome" in
  merged-clean|rework|reverted|bounced|stopped|died) ;;
  *) refuse "outcome must be merged-clean | rework | reverted | bounced | stopped | died, got: $3" ;;
esac
# Two words assert the absence of a PR, and each is refused one given a PR. A
# STOPPED recap stops *before* the PR — the worker opens one or it stops, never
# both. A `died` row is written on a `REAP-HELD-DEAD` finding, which is a branch
# with **no** PR and a hosting pid measured gone; a PR would have contradicted
# the finding that produced the row. So either shape is a malformed call, not a
# rare one.
# It has to be refused here rather than tolerated: `ledger-corroborate.sh` reads
# a row by its `pr` cell, so such a row answers for a merged PR, and a derived
# `merged-clean` against a recorded `stopped` matches none of its mismatch
# branches — the independent witness would report `LEDGER-OK` over the top of a
# flat contradiction. It also holds both words on the no-dedupe side of the
# `pr`-cell boundary below, where their reason puts them.
if [ "$pr" != "-" ]; then
  case "$outcome" in
    stopped) refuse "a stopped row carries no pr — a STOPPED recap opens none; got: $2" ;;
    died)    refuse "a died row carries no pr — the REAP-HELD-DEAD finding behind it is a branch with none; got: $2" ;;
  esac
fi
# The lane count in force, straight from resolve-lanes.sh, whose whole output
# vocabulary is {1, 2, 3}. Anything else is a caller passing something it did
# not measure, and the cell exists to separate two populations — a value nothing
# can classify puts a row in neither.
case "$lanes" in
  -|1|2|3) ;;
  *) refuse "lanes must be 1, 2, 3 or - — what resolve-lanes.sh printed; got: $lanes" ;;
esac
if [ "$day" = "-" ]; then
  day=$(date +%Y-%m-%d)
else
  case "$day" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) refuse "date must be YYYY-MM-DD, got: $6" ;;
  esac
fi

# Free-text cells cannot carry the column separator or a newline through.
verdict=$(printf '%s' "$verdict" | tr '|' '/' | tr '\n' ' ')
tokens=$(printf '%s' "$tokens" | tr '|' '/' | tr '\n' ' ')
[ -n "$verdict" ] || verdict="-"
[ -n "$tokens" ] || tokens="-"

. "$(dirname "$0")/repo-root-lib.sh"
ledger="${LEDGER_FILE:-}"
if [ -z "$ledger" ]; then
  root=$(repo_main_root) \
    || refuse "not a git repository, and \$LEDGER_FILE is unset"
  ledger="$root/docs/agents/ledger.md"
fi

# The outcome column of every data row, one per line — read only by the
# migration check below. Column 6 under the same split `ledger-corroborate.sh`
# uses, so "a `bounced` row" means the same thing to both scripts.
outcomes() { # <ledger>
  awk -F'|' '/^\|[ \t]*#[0-9]/ {
    o = $6; gsub(/^[ \t]+|[ \t]+$/, "", o); if (o != "") print o
  }' "$1"
}

# --- committing the row ------------------------------------------------------
# Called only past every refusal — `refuse` and LEDGER-MIGRATION-BLOCKED both
# exit before either call site — so a call this script turned down never
# commits.
#
# Four properties, each measured rather than assumed:
#
#   * **One path, never the tree.** The orchestrator's working tree carries the
#     run's other work, dirty and staged. `git commit --only -- <path>` commits
#     the working-tree version of that one path and leaves the rest of the index
#     alone; the `git add` is needed only for a ledger git has never seen.
#   * **The repository's own identity.** This commits on the maintainer's
#     behalf, in the maintainer's repository, so ordinary identity resolution
#     applies and nothing is forced here.
#   * **It cannot wait for a person.** Every git call goes through `gitq` below.
#   * **Failure is a finding, not an error.** The row is on disk either way.
oneline() { printf '%s' "$1" | tr '\n' ' ' | sed 's/  */ /g; s/ *$//'; }

# What to quote when git fails. Git is not required to say anything, and a
# reason of "" reads as a bug in this script rather than a fact about the
# repository, so a silent failure is reported as one.
reason() { # <captured output> <exit code>
  local t
  t=$(oneline "$1")
  [ -n "$t" ] || t="git exited $2 and said nothing"
  # Bounded, because a finding is one line somebody relays: git's own conflict
  # advice was measured at 470 characters of hints past the sentence that
  # matters, and it arrives with the newlines already flattened out of it.
  [ ${#t} -le 200 ] || t="$(printf '%s' "$t" | cut -c1-200)…"
  printf '%s' "$t"
}

# Every git call this script makes, so "it cannot block waiting for input" is
# one property in one place: stdin is /dev/null and no terminal prompt is
# allowed, so a repository whose credentials want a terminal reaches a finding
# rather than holding a headless run until its timeout kills the session. An
# existing $GIT_SSH_COMMAND is left alone; without one, ssh is put in batch
# mode for the same reason. A signing or credential helper that opens /dev/tty
# for itself is past what this script can close.
gitq() {
  GIT_TERMINAL_PROMPT=0 \
  GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" \
  git "$@" </dev/null
}

commit_failed() { # <ledger> <reason>
  echo "LEDGER-COMMIT-FAILED:$1 the row is written but not committed — $2"
}

commit_row() { # <ledger> → 0 committed or nothing to commit, 1 failed
  local ledger="$1" ldir lbase msg branch err rc
  ldir=$(dirname "$ledger")
  lbase=$(basename "$ledger")

  gitq -C "$ldir" rev-parse --show-toplevel >/dev/null 2>&1 \
    || { commit_failed "$ledger" "$ldir is not inside a git repository"; return 1; }

  # Nothing outstanding on the path: a duplicate whose row the run that wrote it
  # already committed. Say nothing further. Committing whenever the path *is*
  # dirty is what lets a re-run repair a row an earlier failed commit left
  # behind, duplicate or not.
  [ -n "$(gitq -C "$ldir" status --porcelain -uall -- "./$lbase" 2>/dev/null)" ] \
    || return 0

  # The message is the script's to compose, for the reason the row's format
  # already is: one a caller writes by hand drifts, and this log is read by a
  # human looking for one row. A `-` verdict is left out, not written as a dash.
  msg="docs(ledger): row for #$issue"
  if [ "$pr" = "-" ]; then msg="$msg, no PR"; else msg="$msg -> PR #$pr"; fi
  [ "$verdict" = "-" ] || msg="$msg, verdict $verdict"
  msg="$msg, $outcome"

  if ! gitq -C "$ldir" ls-files --error-unmatch -- "./$lbase" >/dev/null 2>&1; then
    err=$(gitq -C "$ldir" add -- "./$lbase" 2>&1); rc=$?
    [ "$rc" = 0 ] \
      || { commit_failed "$ledger" "git add: $(reason "$err" "$rc")"; return 1; }
  fi
  err=$(gitq -C "$ldir" commit --only -m "$msg" -- "./$lbase" 2>&1); rc=$?
  [ "$rc" = 0 ] \
    || { commit_failed "$ledger" "git commit: $(reason "$err" "$rc")"; return 1; }

  branch=$(gitq -C "$ldir" symbolic-ref --short HEAD 2>/dev/null) || branch=""
  [ -n "$branch" ] || branch="a detached HEAD"
  echo "LEDGER-COMMITTED:$ledger on $branch — $msg"
}

# --- pushing it ---------------------------------------------------------------
# Committing alone does not put the row where anything can read it. Both readers
# resolve the ledger by filesystem path — `runner-gate.sh` and
# `ledger-corroborate.sh` — so a row that never leaves this checkout is a
# blackboard of one.
#
# This is a script and not a line of doctrine because the sequence is
# deterministic and its failure is silent: measured against a bare origin, a
# plain `git push` after the iteration's own merge is rejected
# `! [rejected] main -> main (fetch first)`, and a plain `git rebase` then
# refuses too, `cannot rebase: You have unstaged changes`, because the run's
# tree is dirty. An orchestrator that follows written steps literally is exactly
# what this ticket is about.
#
# The bounds, each measured:
#
#   * **Push first, sync only when refused.** Nothing is rewritten on the common
#     path, and the sync is `git rebase --autostash`, which was measured to
#     restore the run's unrelated dirty files afterwards.
#   * **Never force, and never more than one retry.** A second rejection is a
#     finding, not a fight.
#   * **A commit touching anything but the ledger path stops the sync.** A
#     rebase rewrites every local commit it replays, and republishing work of
#     someone else's is not this script's authority. Read the limit exactly as
#     it is written: the test is the **paths**, not the author. Any commit that
#     touches only the ledger path — including a hand correction the maintainer
#     made and has not pushed — is rebased to a new sha and published with the
#     row. An author check would not close that: the script commits under the
#     repository's own identity, so its commits and the maintainer's carry the
#     same author, measured identical in one checkout.
#   * **A conflict leaves the checkout as it found it.** `git rebase --abort`
#     was measured to restore both HEAD and the autostashed dirty files.
push_failed() { # <reason>
  echo "LEDGER-PUSH-FAILED: the row is committed but not pushed — $1"
}

push_row() { # <ledger>
  local ledger="$1" ldir lbase b remote merge rbranch rel out rc other c synced=0
  ldir=$(dirname "$ledger")
  lbase=$(basename "$ledger")

  b=$(gitq -C "$ldir" symbolic-ref --short HEAD 2>/dev/null) || b=""
  [ -n "$b" ] || { push_failed "a detached HEAD has no branch to push"; return 0; }
  remote=$(gitq -C "$ldir" config "branch.$b.remote" 2>/dev/null) || remote=""
  merge=$(gitq -C "$ldir" config "branch.$b.merge" 2>/dev/null) || merge=""
  [ -n "$remote" ] && [ -n "$merge" ] || {
    push_failed "branch $b has no upstream — set one, or push it by hand"
    return 0
  }
  rbranch="${merge#refs/heads/}"

  out=$(gitq -C "$ldir" push "$remote" "HEAD:$merge" 2>&1); rc=$?
  if [ "$rc" != 0 ]; then
    # The measured case: the iteration's own merge advanced the remote while
    # this checkout stood still.
    out=$(gitq -C "$ldir" fetch "$remote" "$rbranch" 2>&1); rc=$?
    [ "$rc" = 0 ] || { push_failed "git fetch: $(reason "$out" "$rc")"; return 0; }

    rel=$(gitq -C "$ldir" ls-files --full-name -- "./$lbase" 2>/dev/null)
    [ -n "$rel" ] || { push_failed "$ledger is not tracked, so there is nothing to push"; return 0; }
    for c in $(gitq -C "$ldir" rev-list FETCH_HEAD..HEAD 2>/dev/null); do
      other=$(gitq -C "$ldir" show --format= --name-only "$c" 2>/dev/null \
        | grep -v -x -F "$rel" | head -n 1)
      # A merge commit lists no file under --name-only, so it is caught by its
      # parent count instead. Either way it is not a row this script wrote.
      case "$(gitq -C "$ldir" show -s --format=%P "$c" 2>/dev/null)" in
        *' '*) other="more than one parent" ;;
      esac
      if [ -n "$other" ]; then
        push_failed "$b is ahead of $remote/$rbranch by a commit that touches more than the ledger path ($(gitq -C "$ldir" rev-parse --short "$c") touches $other) — syncing would rebase and republish it, so push by hand"
        return 0
      fi
    done

    out=$(gitq -C "$ldir" rebase --autostash FETCH_HEAD 2>&1); rc=$?
    if [ "$rc" != 0 ]; then
      gitq -C "$ldir" rebase --abort >/dev/null 2>&1
      push_failed "git rebase onto $remote/$rbranch: $(reason "$out" "$rc") — the rebase was aborted and the checkout left as it was"
      return 0
    fi
    synced=1

    out=$(gitq -C "$ldir" push "$remote" "HEAD:$merge" 2>&1); rc=$?
    [ "$rc" = 0 ] || { push_failed "git push after syncing: $(reason "$out" "$rc")"; return 0; }
  fi

  if [ "$synced" = 1 ]; then
    echo "LEDGER-PUSHED:$remote/$rbranch — the push was refused, so $b was rebased onto the fetched tip and pushed"
  else
    echo "LEDGER-PUSHED:$remote/$rbranch — $b pushed, no sync needed"
  fi
}

# The row's journey, in the order it travels, from wherever the script leaves
# off. A commit that failed ends it: there is nothing to push, and a second
# finding about the same fact would only bury the first.
land_row() {
  [ "$do_commit" = 1 ] || return 0
  commit_row "$ledger" || return 0
  [ "$do_push" = 1 ] && push_row "$ledger"
  return 0
}

if [ ! -f "$ledger" ]; then
  mkdir -p "$(dirname "$ledger")" || refuse "cannot create $(dirname "$ledger")"
  printf '%s\n' "$MARKER" > "$ledger" || refuse "cannot write $ledger"
  cat >> "$ledger" <<'EOF' || refuse "cannot write $ledger"

# Outcome ledger

One row per drained ticket, appended by `drain-ready-queue` at the end of the iteration that
produced it. Written by `ledger-append.sh`; checked against `gh` and `git` by
`ledger-corroborate.sh`. Editing a row by hand is a correction, and a correction is the PM's call.

| issue | pr | dispatched | verdict | outcome | tokens | lanes |
|---|---|---|---|---|---|---|
EOF
else
  first=$(head -n 1 "$ledger")
  if [ "$first" != "$MARKER" ]; then
    # The version on the file, read rather than matched against a literal, so
    # the only marker string this file spells is the one it writes.
    have=$(printf '%s' "$first" \
      | sed -n 's|^<!-- ledger v\([0-9][0-9]*\) -->$|\1|p')
    [ "$have" = "$MIGRATE_FROM" ] \
      || refuse "$ledger does not open with $MARKER — a different version writes different rows"

    # `bounced` used to cover the effort bounce **and** the dead run. Those rows
    # cannot be split by machine — no `bounced` row says whether a worker was
    # ever spawned — so the script migrates the marker only when there are none,
    # and hands the rest back as a correction.
    stale=$(outcomes "$ledger" | grep -c '^bounced$')
    if [ "$stale" -gt 0 ]; then
      echo "LEDGER-MIGRATION-BLOCKED:$ledger $stale \`bounced\` row(s) predate $MARKER, where \`bounced\` no longer covers a dead run. PM correction: reclassify each row as \`bounced\` (the effort bounce, nothing attempted) or \`died\` (a dispatch that died before its PR), rewrite line 1 to $MARKER, then re-run this append."
      exit 1
    fi

    tmp="$ledger.migrate.$$"
    { printf '%s\n' "$MARKER" && tail -n +2 "$ledger"; } > "$tmp" \
      || { rm -f "$tmp"; refuse "cannot write $tmp while migrating $ledger"; }
    mv "$tmp" "$ledger" || { rm -f "$tmp"; refuse "cannot migrate $ledger"; }
    echo "LEDGER-MIGRATED:$ledger marker rewritten to $MARKER, no \`bounced\` rows to reclassify"
  fi
fi

# --- the lanes column, added in place ------------------------------------------
# A field addition under the same marker (STAGE-CONTRACT.md § 3), so the rows
# already written stay exactly as they are and read null in the new column. Only
# the header moves, and it has to: a markdown renderer drops the cells a body row
# carries past its header, so without this the value would be written and
# invisible to the one reader the ledger is shaped for.
HEADER='| issue | pr | dispatched | verdict | outcome | tokens | lanes |'
RULE='|---|---|---|---|---|---|---|'
if grep -q '^|[ \t]*issue[ \t]*|' "$ledger" && ! grep -qxF "$HEADER" "$ledger"; then
  tmp="$ledger.column.$$"
  awk -v hdr="$HEADER" -v rul="$RULE" '
    seen == 0 && $0 ~ /^\|[ \t]*issue[ \t]*\|/ { print hdr; seen = 1; next }
    seen == 1 { seen = 2; if ($0 ~ /^\|[ \t]*-/) { print rul; next } }
    { print }' "$ledger" > "$tmp" \
    || { rm -f "$tmp"; refuse "cannot write $tmp while adding the lanes column to $ledger"; }
  mv "$tmp" "$ledger" || { rm -f "$tmp"; refuse "cannot add the lanes column to $ledger"; }
  echo "LEDGER-COLUMN-ADDED:$ledger the \`lanes\` column was added to the table header in place; rows written before it read null"
fi

prcell="-"
[ "$pr" = "-" ] || prcell="#$pr"

# The `pr` cell draws the boundary. A row that carries a PR dedupes on issue+PR,
# so a re-run of one iteration cannot double-count a landing. A row whose cell is
# `-` never dedupes: nothing in it distinguishes two no-PR events for one ticket,
# and both of them are real — a ticket re-readied after a stop can honestly stop
# again, one re-scored after a bounce can honestly bounce again, and a
# re-dispatched ticket can honestly die again. Collapsing the second into the
# first hides the two streaks the brakes read and deflates the bounce rate the
# queue is judged on.
if [ "$prcell" != "-" ] && grep -q "^| #$issue | $prcell |" "$ledger"; then
  echo "LEDGER-DUPLICATE:#$issue $prcell already has a row"
  # Nothing was written, but an earlier run may have written a row whose commit
  # failed, or committed one whose push failed. The dirty check inside decides
  # the first; a clean path says nothing and the push still runs, because a
  # committed row that never left this checkout is the whole defect.
  land_row
  exit 0
fi

printf '| #%s | %s | %s | %s | %s | %s | %s |\n' \
  "$issue" "$prcell" "$day" "$verdict" "$outcome" "$tokens" "$lanes" >> "$ledger" \
  || refuse "cannot append to $ledger"

echo "LEDGER-APPENDED:#$issue $prcell $outcome -> $ledger"
land_row
exit 0
