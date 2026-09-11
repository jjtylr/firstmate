#!/bin/bash
# runner-gate.sh start | next <run-start> — "may another iteration run?",
# answered from the blackboard alone. The headless runner (spec #120) calls this
# before every iteration and does what the exit code says; it parses no model
# prose, because a control signal read out of a model's output is not a rail.
#
#   runner-gate.sh start                    before the first iteration
#   runner-gate.sh next 2026-08-25T17:50:33Z   between iterations, given the
#                                           run's own recorded start time (UTC,
#                                           seconds, `Z` — the shape
#                                           `date -u +%Y-%m-%dT%H:%M:%SZ` and
#                                           gh's `mergedAt` both use)
#   runner-gate.sh next <run-start> <cycle-start>   the same, plus the moment
#                                           the just-finished iteration's
#                                           session started, same shape. The
#                                           runner passes it only for a session
#                                           that exited 0 — its word that a full
#                                           cycle ran — and that word arms the
#                                           live-lock stop below. A failed or
#                                           killed session is not a full cycle;
#                                           the runner's failure cap owns those
#
#   stdout   the dispatchable candidates, pick.sh's JSON array minus every
#            ticket carrying a trace of a prior dispatch. Empty on any non-zero
#            exit, so `c=$(runner-gate.sh …)` yields nothing when the answer is
#            no. Findings go to stderr, because stdout is parsed as JSON.
#   exit 0   run another iteration. RUNNER-CONTINUE names the top candidate
#   exit 1   stop this run. RUNNER-STOP says which condition fired
#   exit 2   refuse to run at all. RUNNER-REFUSED says why
#   exit 3   the gate could not establish the answer. RUNNER-UNKNOWN says what
#            it could not read
#
# **Exit 3 is not exit 1**, and that is the whole reason the exit vocabulary is
# four-valued. "The queue is empty" and "the queue could not be read" arrive as
# the same silence, and a runner that treats the second as the first reports a
# finished job over a broken environment — the PICK-UNKNOWN defect class, one
# level up. Every read here fails closed into exit 3.
#
# **What exit 3 costs, because one flaky read can end a run.** Six reads, each a
# separate `gh` call, and any one of them failing is exit 3 for the whole gate:
#
#   - the `run-log` issue query, delegated to run-issue-find.sh. `start` only
#   - the ready-queue listing, delegated to pick.sh. Both phases
#   - the open PR list. Both phases
#   - the merged PR list. `next` only
#   - one `gh pr list --head` per *distinct* loop branch among the candidates,
#     so this one is not a fixed cost — it grows with the queue
#   - the repo-wide comment listing behind the live-lock stop. `next` only,
#     only when a <cycle-start> was passed, and only on a cycle that merged
#     nothing — a merge already proves progress without it
#
# The first two are another script's read, and they fail closed here just the
# same: their own findings are relayed and then this gate adds its RUNNER-UNKNOWN
# on top, so those two paths print two findings lines, not one.
#
# runner.sh then does two different things with exit 3, and neither is a retry of
# this script's own reads (measured, runner.test.sh):
#
#   - at `start` — `end_run 3`. The run is over, having dispatched nothing and
#     opened no run issue.
#   - between iterations — a counted failure (RUNNER-GATE-UNKNOWN), and the
#     runner calls the gate again. $RUNNER_MAX_FAILURES *consecutive* unreadable
#     gates end the run with exit 1; one that clears on the next call does not.
#
# So a repo whose queue routinely carries many loop branches makes the `start`
# gate a wider target: more calls, and any single failure ends the run before it
# begins. That is the fail-closed direction and it is deliberate — never a
# drained queue reported over a broken network — but it is a property to know
# before an overnight run, not a surprise to find in the morning.
#
# The refusals answer "should a headless run exist right now":
#   - `merge_policy` is not an auto policy. A runner under `pm-merge` would
#     stack PRs against a PM who is not there; the attended `/loop` is that
#     repo's runner. The catalog of auto policies is MERGE-POLICY.md and it is
#     executed by merge-decision.sh, so this asks that script rather than
#     keeping a second copy of the list. It reads that script's **policy
#     findings line**, not its exit code: the button refuses for several
#     reasons at once — a stale verdict marker among them — and only one of
#     them answers the question asked here. An exit code conflates them, and
#     conflating them reads every auto policy as `pm-merge`.
#     This read fails closed like every other one: only a recognized answer
#     (`MERGE-ALLOWED`, or a `MERGE-REFUSED:` for some other reason) clears the
#     policy gate. Silence — a missing, unreadable, or crashing decision
#     script — is exit 3, never a pass. Matching one arm and falling through
#     otherwise would let a `pm-merge` repo start a headless run the moment
#     that script stopped answering.
#   - a `run-log` issue is already open. Closing it is the PM's ack of the last
#     run, so the interlock is the same one run-issue-open.sh holds, read
#     through the same run-issue-find.sh. Checked at `start` only: from the
#     first iteration onward the open run issue is this run's own.
#
# The stops answer "may this run take one more ticket", and spec #120 files all
# three brakes as stops **between iterations**. `start` does not evaluate them,
# and that is a correctness property rather than an economy: each one measures
# what this run has done so far, and at `start` this run has done nothing, so
# what they would actually measure is the previous run — whose review is already
# interlocked by the run issue above. The wedge is concrete. A `stopped`/
# `stopped` pair left in the ledger by a run in July would refuse every `start`
# after it, forever, because the row that clears the streak can only come from a
# dispatch the refusal prevents. A brake only a hand-edit can release is not a
# brake.
#
#   - parked-PR bound — open unmerged loop PRs at $RUNNER_PARKED_BOUND
#     (default 3, mirroring the attended ~4-unreviewed brake). `next` only.
#   - check-in bound — merged loop PRs since <run-start>, counted **from the
#     code host**, against the config's `auto_merge_checkin`. Host-counted
#     because a session that dies between its merge and its ledger append would
#     otherwise undercount the one brake that pauses an unattended run; the
#     ledger corroborates and is never the counter. `next` only — nothing can
#     have merged in a run that has not dispatched anything.
#   - STOPPED streak — the last two ledger rows whose outcome is neither
#     `bounced` nor `died` both read `stopped`. An effort bounce is not a
#     dispatch, so it neither makes nor resets the streak; a death is a dispatch
#     the *other* streak below owns, and reading it here would let one dead
#     worker buy a mislabeled queue another iteration. `next` only, and read
#     **only over rows dated on or after <run-start>'s day** — the same "since
#     the run's recorded start time" window the check-in bound uses. Both brakes
#     reconstruct state the
#     attended orchestrator held in its own context for the length of one run
#     (spec #120, Problem Statement), so neither may reach back into a previous
#     one. The ledger dates a row by its dispatch day and nothing finer, so a
#     row from earlier on the run's own start day counts: the window errs toward
#     stopping early, which is the safe direction for a brake.
#   - death streak — the last two ledger rows whose outcome is neither `bounced`
#     nor `stopped` both read `died`. Same window, same phase, and the mirror
#     image of the streak above: each reads past the other's word, so neither
#     can mask the other, and a run that alternates between them stops as soon
#     as either pair completes. Both complete at once only on a ledger holding
#     both pairs, and the STOPPED streak is evaluated first, so that is the line
#     such a run reports. This one says a different thing. The harness is
#     breaking workers, not the queue mislabeling tickets, which is why it is a
#     second stop with its own line rather than a third word in the first. A
#     `merged-clean` or a `rework` breaks both, because a success says the run
#     is working.
#   - live-lock — candidates present, nothing dispatched and nothing merged
#     across the last completed cycle (SCHEDULER.md). The one failure whose
#     output looks healthy: held candidates reported once per cycle is exactly
#     what a correctly-starving queue produces. `next` only, and only when the
#     runner passed <cycle-start>: this gate is stateless, so "the last cycle"
#     is the runner's word, and both halves are then read off the blackboard
#     with real timestamps — a merge is `mergedAt` after <cycle-start>, a
#     dispatch is a lane-claim comment *created* after it. The claim is the
#     instrument because CLAIM.md writes it before any worker spawns, so a
#     dispatch with no claim does not exist; the ledger is deliberately not,
#     because its rows carry a day and a cycle lasts minutes. A bounce never
#     ends a cycle — SKILL.md bounces and takes the next candidate — so a
#     completed cycle with neither trace while candidates stand is a stuck
#     scheduler, not a slow one. Clock skew against the host's timestamps errs
#     toward stopping, the safe direction for a brake.
#   - nothing left to dispatch — four different findings, never one word. A
#     queue held by open blockers, a queue held by open lane claims, and a queue
#     whose every candidate is already dispatched, are each reported as
#     themselves; only a genuinely empty pick is reported as drained. "Blocked"
#     or "claimed" read as "drained" ends a run that had work in it, and reports
#     a finished job over a queue the PM has to release by hand. This one is
#     evaluated in **both** phases, alone among the
#     stops: the gate's stdout is the dispatchable candidate, so `start` has to
#     read the queue to answer at all, and a queue that is empty before the
#     first iteration cannot wedge anything — the next `start` re-reads it.
#
# Candidate exclusion, applied to pick.sh's array: a ticket is excluded when its
# `agent/*-<N>` loop branch carries an **unfinished** dispatch, which is two
# shapes and only two:
#
#   - the parked PR — an **open** PR holds the branch. A second operative on
#     that branch would overwrite the first one's work.
#   - the dead run — the branch exists (local ref or remote-tracking ref) and
#     **no PR was ever opened from it**. The runner's per-iteration timeout kills
#     sessions, and a killed session dies before its operative opens a PR,
#     leaving a ticket that still carries every ready label.
#
# A branch whose newest PR is **merged or closed** is a *finished* dispatch, and
# it does not exclude: the work landed, or the PM already adjudicated it. Nothing
# in the loop deleted a loop branch before this ticket, so "the branch exists at
# all" would read every finished dispatch as a trace and make any ticket ever
# dispatched permanently undispatchable headless — which contradicts ledger v3's
# own story, where a ticket the PM re-readies after a `stopped` can honestly stop
# again (LEDGER-REFERENCE.md). Measured on this repo 2026-08-25: 49 `agent/*`
# branches on origin, 47 of them the head of a merged PR.
#
# The finished branch still stands on the remote, so a re-dispatch reusing the
# slug collides on push. That is reported — RUNNER-PRIOR-DISPATCH — never turned
# back into an exclusion; SKILL.md step 6 deletes the branch it merges, so the
# population stops growing.
#
# Which PRs a branch ever carried is asked per branch (`gh pr list --head`), not
# read out of a bounded list of the repo's newest PRs: a branch whose PR fell off
# the end of such a list would read as "no PR ever" and be excluded as a dead
# run. One call per distinct loop branch among the candidates, so a candidate
# with no branch costs nothing and a local ref and its tracking ref cost one
# between them.
#
# Remote-tracking refs are only as fresh as the last fetch, so the runner runs
# `git fetch --prune origin` before every call to this gate — `--prune` because
# a remote branch deleted on the host otherwise stays in `refs/remotes` forever
# and is read here as a trace that is not there.
#
# Findings, beyond the four exit lines above. This list is the whole of what the
# gate can put on stderr, and it is enumerated from the code rather than grown one
# defect at a time: every `note` call here, plus everything the two delegated
# scripts can print through the two relay points.
#
# Raised here:
#   RUNNER-EXCLUDED       one per candidate held out, naming which case fired
#   RUNNER-PRIOR-DISPATCH one per candidate that passes through carrying a
#                         finished dispatch's branch
#   RUNNER-LEDGER-LAG     the host counted more merged loop PRs than the ledger
#                         holds rows for
#
# Relayed, not raised — another script's line, passed through verbatim:
#   RUNNER-MULTIPLE       run-issue-find.sh, when several `run-log` issues are
#                         open. Rides out with the `start` refusal
#   RUNNER-UNKNOWN        run-issue-find.sh's own, when its query failed —
#                         *beside* this gate's, so that path prints two
#   PICK-BLOCKED          pick.sh's held tickets. The PM's findings whatever this
#                         gate decides, so relayed before every exit below it.
#                         Read a second time for the empty-queue ending
#   PICK-CLAIMED          pick.sh again, for a ticket an open lane claim holds
#                         out — already excluded from the array this gate reads,
#                         so the exclusion is relayed and never re-derived here.
#                         Read a second time for the ending, exactly as
#                         PICK-BLOCKED is: this line is the only trace a claimed
#                         ticket leaves, and a queue whose whole pick was claimed
#                         would otherwise stop as drained
#   PICK-UNKNOWN          pick.sh, when the queue listing failed — again beside
#                         this gate's own RUNNER-UNKNOWN, two lines on that path
#
# run-issue-find.sh's RUNNER-NO-RUN-ISSUE is deliberately *not* here: it is that
# script's answer on its exit 1, which this gate reads as "none is open" and does
# not relay.
#
# Environment: $MILESTONE scopes the queue (read by pick.sh, honored here by
# passing it through), $LOOP_CONFIG and $LEDGER_FILE relocate the two files,
# $RUNNER_PARKED_BOUND overrides the parked bound. $PICK_SLIM is set rather than
# read — see the queue section.
set -u

here="$(cd "$(dirname "$0")" && pwd)"

PARKED_BOUND="${RUNNER_PARKED_BOUND:-3}"

stop()    { echo "RUNNER-STOP: $1" >&2; exit 1; }
refuse()  { echo "RUNNER-REFUSED: $1" >&2; exit 2; }
unknown() { echo "RUNNER-UNKNOWN: $1" >&2; exit 3; }
note()    { printf '%s\n' "$1" >&2; }

phase="${1-}"
since="${2-}"
cycle="${3-}"

case "$phase" in
  start)
    [ -z "$since" ] || unknown "usage: runner-gate.sh start (no run-start; nothing can have merged yet)"
    ;;
  next)
    # A malformed timestamp compares lexicographically against `mergedAt` just
    # as happily as a good one, and every comparison would be wrong in the
    # direction that disables the check-in brake. Refuse to guess.
    case "$since" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
      '') unknown "usage: runner-gate.sh next <run-start>, e.g. 2026-08-25T17:50:33Z" ;;
      *)  unknown "run-start '$since' is not YYYY-MM-DDThh:mm:ssZ — the check-in count cannot be derived from it" ;;
    esac
    case "$cycle" in
      ''|[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
      *)  unknown "cycle-start '$cycle' is not YYYY-MM-DDThh:mm:ssZ — whether the last cycle produced anything cannot be derived from it" ;;
    esac
    ;;
  *)
    unknown "usage: runner-gate.sh start | next <run-start>"
    ;;
esac

command -v gh >/dev/null 2>&1 || unknown "gh is not installed — nothing on the blackboard can be read"
command -v jq >/dev/null 2>&1 || unknown "jq is not installed — nothing on the blackboard can be read"

. "$here/repo-root-lib.sh"
root="$(repo_main_root)" || root=""

# --- the config ---------------------------------------------------------------
# One value out of one `## key` section of docs/agents/loop.md: the first
# backtick-opened line of its own paragraph. That is the shape the setup skill
# writes and the shape every section in the template has — and the blank line
# before it is what tells a value apart from a prose line that happens to wrap
# onto a backticked policy name.
config="${LOOP_CONFIG:-}"
if [ -z "$config" ] && [ -n "$root" ]; then
  config="$root/docs/agents/loop.md"
fi

config_value() { # <key>
  [ -n "$config" ] && [ -f "$config" ] || return 0
  awk -v key="$1" '
    /^## / {
      if (sect) exit
      h = substr($0, 4); sub(/[ \t\r]+$/, "", h)
      if (h == key) { sect = 1; blank = 1 }
      next
    }
    sect {
      if ($0 ~ /^[ \t\r]*$/) { blank = 1; next }
      if (blank && substr($0, 1, 1) == "`") {
        v = substr($0, 2); i = index(v, "`")
        if (i > 1) { print substr(v, 1, i - 1); exit }
      }
      blank = 0
    }' "$config"
}

policy="$(config_value merge_policy)"
[ -n "$policy" ] || refuse "no merge_policy in ${config:-docs/agents/loop.md}, which reads as pm-merge — a headless run needs an auto policy, so the attended /loop is this repo's runner"
case "$(bash "$here/merge-decision.sh" pass CHECKS-PASS "$policy" 2>/dev/null)" in
  *'is not an auto policy the catalog carries'*)
    refuse "merge_policy is '$policy', not an auto policy the catalog carries — under it the PM merges, and a headless run would stack PRs against nobody" ;;
  MERGE-ALLOWED*|MERGE-REFUSED:*)
    : ;;  # the button answered, and the name was not the thing it objected to
  *)
    unknown "the merge decision script did not answer whether '$policy' is an auto policy: $here/merge-decision.sh printed nothing this gate recognizes. An unread policy is never an auto one" ;;
esac

# --- the previous run's issue -------------------------------------------------
if [ "$phase" = start ]; then
  finderr="$(mktemp "${TMPDIR:-/tmp}/runner-gate.XXXXXX")" \
    || unknown "cannot create a temporary file to read the run-issue findings"
  open="$(bash "$here/run-issue-find.sh" 2>"$finderr")"
  found=$?
  findings="$(cat "$finderr" 2>/dev/null)"
  rm -f "$finderr"
  case $found in
    0)
      # RUNNER-MULTIPLE is a real finding and rides out with the refusal;
      # RUNNER-NO-RUN-ISSUE is the answer on the other branch, not a finding.
      [ -n "$findings" ] && note "$findings"
      refuse "run issue #$open is still open — closing it is the ack that starts the next run"
      ;;
    1) ;;
    *)
      if [ -n "$findings" ]; then note "$findings"; fi
      unknown "cannot establish whether a run issue is open"
      ;;
  esac
fi

# --- open loop PRs: the parked bound, and half of the exclusion ----------------
openprs="$(gh pr list --state open --limit 100 --json number,headRefName 2>/dev/null)" \
  || unknown "gh pr list --state open failed — parked PRs cannot be counted"
# gh prints `[]` for a match-nothing query, so nothing at all is a gh that said
# nothing, never a repo with no open PRs.
[ -n "$openprs" ] || unknown "gh answered nothing for the open PR list, not even an empty list"

parked="$(printf '%s\n' "$openprs" \
  | jq -r '[.[] | select(.headRefName | startswith("agent/"))
           | "#\(.number) \(.headRefName)"] | join(", ")')" \
  || unknown "the open PR list is not JSON this gate can read"

parked_n=0
[ -z "$parked" ] || parked_n="$(printf '%s\n' "$parked" | tr ',' '\n' | grep -c '#')"

# The list itself is read in both phases — the exclusion below needs it — but
# the bound is a between-iterations stop. At `start` these PRs are the previous
# run's, and the interlock that governs those is the run issue.
if [ "$phase" = next ] && [ "$parked_n" -ge "$PARKED_BOUND" ]; then
  stop "$parked_n open loop PR(s) are parked, at the bound of $PARKED_BOUND ($parked) — a run that stacks unreviewed PRs against an absent reviewer stops instead"
fi

# --- the ledger's path, read by the two checks below --------------------------
ledger="${LEDGER_FILE:-}"
if [ -z "$ledger" ] && [ -n "$root" ]; then
  ledger="$root/docs/agents/ledger.md"
fi
[ -n "$ledger" ] && [ -f "$ledger" ] || ledger=""

# --- the check-in bound, counted from the host --------------------------------
if [ "$phase" = next ]; then
  merged="$(gh pr list --state merged --limit 200 --json number,headRefName,mergedAt 2>/dev/null)" \
    || unknown "gh pr list --state merged failed — merges since $since cannot be counted"
  [ -n "$merged" ] || unknown "gh answered nothing for the merged PR list, not even an empty list"

  # Filtered here, against the timestamp the runner passed. Never by a search
  # qualifier on the merge date: `gh search` reads GitHub's index, the index
  # lags behind the merge, and this counter is the brake that pauses an
  # unattended run — an undercount here is a run that keeps going. ISO-8601 in
  # one fixed shape compares lexicographically, so `>` is the whole comparison.
  merged_n="$(printf '%s\n' "$merged" \
    | jq -r --arg s "$since" '[.[] | select(.headRefName | startswith("agent/"))
             | select((.mergedAt // "") > $s)] | length')" \
    || unknown "the merged PR list is not JSON this gate can read"

  checkin="$(config_value auto_merge_checkin)"
  case "$checkin" in
    ''|*[!0-9]*)
      refuse "auto_merge_checkin in ${config:-docs/agents/loop.md} is '${checkin}', not a number — under an auto policy that key is required, and an unreadable brake is no brake"
      ;;
  esac

  # Corroboration, reported before the decision and never part of it: a ledger
  # row records the *dispatch* date, so it is the weaker instrument, and the
  # gap it reveals is a ledger to repair — a session that died between its
  # merge and its append. Printed whether or not the bound fires, because a
  # lagging ledger below the bound is the same defect one iteration earlier.
  if [ -n "$ledger" ] && [ "$merged_n" -gt 0 ]; then
    rows="$(awk -F'|' -v day="${since%%T*}" '
      /^\|[ \t]*#[0-9]/ {
        pr = $3; gsub(/^[ \t]+|[ \t]+$/, "", pr)
        d = $4; gsub(/^[ \t]+|[ \t]+$/, "", d)
        if (pr != "-" && pr != "" && d >= day) n++
      }
      END { print n + 0 }' "$ledger")"
    if [ "$rows" -lt "$merged_n" ]; then
      note "RUNNER-LEDGER-LAG: the host counted $merged_n merged loop PR(s) since $since, the ledger holds $rows row(s) with a PR from that day on — the host is the counter; a missing row is a ledger to repair, not a lower count"
    fi
  fi

  if [ "$merged_n" -ge "$checkin" ]; then
    stop "$merged_n loop PR(s) merged since $since, at the auto_merge_checkin bound of $checkin — the PM reviews this batch before the run takes more"
  fi
fi

# --- the two streaks, inside this run's window ---------------------------------
# `next` only, and only over rows this run put there. A streak is a statement
# about the queue this run is draining; read unbounded it is a statement about
# history, and a historical pair can never be cleared, because the row that
# clears it can only come from a dispatch the streak itself refuses.
#
# Two of them, and each is blind to the other's word. What varies between the
# pair is the two words, so those are the arguments; the window and the file are
# the same for both reads, so `streak_of` takes them off the enclosing scope. On
# top of them it always reads past `bounced`, which is never a dispatch and so
# neither makes nor breaks either streak. Reading a death as an interruption of
# the STOPPED streak would let one dead worker buy a mislabeled queue another
# iteration, and reading a refusal as an interruption of the death streak would
# do the same for a harness that is killing its workers.
streak_of() { # <word the pair reads> <the other streak's word, skipped>
  awk -F'|' -v day="${since%%T*}" -v want="$1" -v skip="$2" '
    /^\|[ \t]*#[0-9]/ {
      d = $4; gsub(/^[ \t]+|[ \t]+$/, "", d)
      if (d < day) next
      o = $6; gsub(/^[ \t]+|[ \t]+$/, "", o)
      i = $2; gsub(/^[ \t]+|[ \t]+$/, "", i)
      if (o == "" || o == "bounced" || o == skip) next
      prev_o = last_o; prev_i = last_i; last_o = o; last_i = i
    }
    END { if (prev_o == want && last_o == want) print prev_i " " last_i }
  ' "$ledger"
}

if [ "$phase" = next ] && [ -n "$ledger" ]; then
  streak="$(streak_of stopped died)"
  if [ -n "$streak" ]; then
    stop "the last two ledger rows this run dispatched both read \`stopped\` ($streak) — two STOPPED recaps in a row is a mislabeled queue, not a run to continue"
  fi

  deaths="$(streak_of died stopped)"
  if [ -n "$deaths" ]; then
    stop "the last two ledger rows this run dispatched both read \`died\` ($deaths) — two dispatches killed before their first PR is a broken harness, not a run to continue"
  fi
fi

# --- the queue ----------------------------------------------------------------
pickerr="$(mktemp "${TMPDIR:-/tmp}/runner-gate.XXXXXX")" \
  || unknown "cannot create a temporary file to read the pick's findings"
# `PICK_SLIM=1`: this call's array is composed, printed, and thrown away —
# `runner.sh`'s `run_gate()` sends this gate's stdout to /dev/null and keeps the
# exit code and the stderr findings. What survives that is the candidate
# numbers, the labels, the open blockers and pick.sh's own findings lines, none
# of which come from the issue body, so the body is fetched here for nothing.
# Measured 2026-08-27 on a 12-candidate queue: the full field list is 137450 B,
# the same list without `body` is 106049 B, and without `comments` too it is
# 5793 B. The seam drops `body` alone — a quarter of what is on offer. The rest
# is `comments`, which still arrives, and which is what keeps the ranking, the
# PICK-CLAIMED lines and the claim-held stop below working exactly as they do
# without the seam. #207 carries why the rest cannot follow yet.
candidates="$(PICK_SLIM=1 bash "$here/pick.sh" 2>"$pickerr")"
pickcode=$?
pickfindings="$(cat "$pickerr" 2>/dev/null)"
rm -f "$pickerr"
# Held tickets are the PM's findings whatever this gate decides, so they are
# relayed before any exit below.
[ -n "$pickfindings" ] && note "$pickfindings"

if [ "$pickcode" != 0 ]; then
  unknown "the candidate listing failed — pick.sh exited $pickcode. A queue that cannot be read is never an empty queue"
fi

numbers="$(printf '%s\n' "$candidates" | jq -r '.[].n' 2>/dev/null)" \
  || unknown "pick.sh did not answer with a candidate array"

# --- exclusion: an unfinished dispatch ----------------------------------------
heads="$(printf '%s\n' "$openprs" \
  | jq -r '.[] | select(.headRefName | startswith("agent/"))
           | "\(.number) \(.headRefName)"')"
refs="$(git for-each-ref --format='%(refname:short)' refs/heads refs/remotes 2>/dev/null \
        | grep -e '^agent/' -e '/agent/')"

# `agent/foo-11` from a local ref, `origin/agent/foo-11` from a tracking one:
# the branch name is what `gh pr list --head` wants, so the remote is stripped.
branch_of() { # <short ref>
  case "$1" in
    agent/*) printf '%s\n' "$1" ;;
    *)       printf 'agent/%s\n' "${1#*/agent/}" ;;
  esac
}

# The newest PR ever opened from a branch, as `<STATE> <number>`, or `none`.
# Highest PR number is newest — numbers are monotonic and never reused, which no
# ordering flag on `gh pr list` has to be trusted for.
newest_pr_for() { # <branch> -> stdout, or non-zero
  local out
  out="$(gh pr list --head "$1" --state all --limit 50 --json number,state 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" \
    | jq -r 'sort_by(.number) | last | if . == null then "none" else "\(.state) \(.number)" end' \
    || return 1
}

keep=""
excluded=0
for n in $numbers; do
  why=""
  finished=""
  while read -r pr branch; do
    [ -n "${branch:-}" ] || continue
    case "$branch" in
      agent/*-"$n") why="open PR #$pr holds $branch — a parked PR is never re-dispatched"; break ;;
    esac
  done <<EOF
$heads
EOF

  if [ -z "$why" ]; then
    # Every distinct loop branch for this ticket, not just the first: a local
    # ref and its tracking ref are one branch, but a ticket may also carry a
    # dead run's branch beside a finished one, and the dead run must still win.
    seen=""
    for r in $refs; do
      case "$r" in
        agent/*-"$n"|*/agent/*-"$n") ;;
        *) continue ;;
      esac
      b="$(branch_of "$r")"
      case " $seen " in *" $b "*) continue ;; esac
      seen="$seen $b"

      state="$(newest_pr_for "$b")" \
        || unknown "gh pr list --head $b failed — whether #$n's loop branch holds a finished dispatch or a dead run cannot be read, and an unread branch is never a dispatchable one"
      case "$state" in
        none)
          why="branch $b exists and no PR was ever opened from it — a prior dispatch died before it opened one"
          break ;;
        OPEN\ *)
          why="open PR #${state#OPEN } holds $b — a parked PR is never re-dispatched"
          break ;;
        *)
          finished="$finished${finished:+; }$b is the head of ${state%% *} PR #${state#* }" ;;
      esac
    done
  fi

  if [ -n "$why" ]; then
    note "RUNNER-EXCLUDED: #$n $why"
    excluded=$((excluded + 1))
  else
    [ -z "$finished" ] || note "RUNNER-PRIOR-DISPATCH: #$n $finished — a finished dispatch, so it does not block re-dispatch; the branch still stands, so a re-dispatch reusing the slug collides on push"
    keep="$keep $n"
  fi
done

# The parenthesized ticket list a held ending names, from the relayed findings of
# one kind: one `#<n>` per line, joined with a single space. `tr` turns the
# newline *after* the last item into a separator too, so that one is trimmed —
# without it every list ends `(#174 )`, in every ending that renders one. One
# home for the join, because more than one ending renders a list.
held_list() { # <findings prefix> — reads $pickfindings
  printf '%s\n' "$pickfindings" \
    | sed -n "s/^$1: \(#[0-9]*\) .*/\1/p" \
    | tr '\n' ' ' | sed 's/ $//'
}

if [ -z "$keep" ]; then
  # Four endings, four findings. Only the last one is drained.
  if [ "$excluded" -gt 0 ]; then
    stop "every candidate in the queue ($excluded) already carries an unfinished dispatch — a parked PR, or a branch a dead run left behind. That is a queue to reap and re-label, not a finished one"
  fi
  if printf '%s\n' "$pickfindings" | grep -q '^PICK-BLOCKED'; then
    held="$(held_list PICK-BLOCKED)"
    stop "no dispatchable candidate; the queue is held by open blockers ($held) — held work is not finished work"
  fi
  # pick.sh drops a claimed ticket from its array and records the exclusion on
  # its stderr alone, so this line is the only trace of it that reaches here.
  # Read it, or a queue parked behind claims arrives indistinguishable from an
  # empty one and is reported as drained.
  if printf '%s\n' "$pickfindings" | grep -q '^PICK-CLAIMED'; then
    claimed="$(held_list PICK-CLAIMED)"
    stop "no dispatchable candidate; the queue is held by open lane claims ($claimed) — a claim nobody releases starves its ticket, so this is a queue to release, not a finished one"
  fi
  stop "the ready queue is drained${MILESTONE:+ for milestone \"$MILESTONE\"} — pick.sh returned no candidate and none is held"
fi

# --- the live-lock stop: a completed cycle that produced nothing ---------------
# All three of SCHEDULER.md's conditions, measured: candidates present is the
# non-empty $keep above — the three empty endings already stopped — and the
# other two are timestamp reads against <cycle-start>. Only claims *created* in
# the window count: the API's `since=` filters on update time, and a PARKED or
# RELEASED annotation on an old claim is not a dispatch. The comment listing is
# paid only on a cycle that merged nothing.
if [ "$phase" = next ] && [ -n "$cycle" ]; then
  cycle_merged="$(printf '%s\n' "$merged" \
    | jq -r --arg s "$cycle" '[.[] | select(.headRefName | startswith("agent/"))
             | select((.mergedAt // "") > $s)] | length')" \
    || unknown "the merged PR list is not JSON this gate can read"
  if [ "$cycle_merged" = 0 ]; then
    comments="$(gh api -X GET "repos/{owner}/{repo}/issues/comments" \
                  -f since="$cycle" -f per_page=100 --paginate 2>/dev/null)" \
      || unknown "the comment listing since $cycle failed — whether the last cycle dispatched anything cannot be read, and an unread cycle never clears a brake"
    [ -n "$comments" ] || unknown "gh answered nothing for the comment listing, not even an empty list"
    new_claims="$(printf '%s\n' "$comments" \
      | jq -s -r --arg s "$cycle" '[(add // [])[] | select((.created_at // "") > $s)
               | select((.body // "") | any(split("\n")[]; test("^<!-- lane-claim v1 -->[ \t\r]*$")))] | length')" \
      || unknown "the comment listing is not JSON this gate can read"
    if [ "$new_claims" = 0 ]; then
      stop "candidates are waiting and the cycle since $cycle dispatched nothing and merged nothing — a live-locked scheduler reports held candidates forever, so the PM clears what every slot is waiting on before the run takes more"
    fi
  fi
fi

printf '%s\n' "$candidates" \
  | jq --argjson keep "[$(printf '%s' "$keep" | sed 's/^ //; s/ /,/g')]" \
       'map(select(.n as $n | $keep | index($n)))' \
  || unknown "the dispatchable candidates could not be composed"

top="$(printf '%s' "$keep" | awk '{print $1}')"
also=""
[ "$excluded" = 0 ] || also=", $excluded candidate(s) excluded"
note "RUNNER-CONTINUE: #$top is next$also"
exit 0
