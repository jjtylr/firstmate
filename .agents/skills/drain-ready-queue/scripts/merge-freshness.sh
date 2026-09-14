#!/bin/bash
# merge-freshness.sh <pr-number> <examined-commit|-> — the serialized merge
# pipeline's read of the host (MERGE-PIPELINE.md). It answers one question:
# does the host still hold the tree a witness examined, in a state the host
# says it can merge? Prints exactly one finding line on stdout.
#
#   exit 0   FRESH-OK:<head>       the 40-character head the host reports
#   exit 2   FRESH-REFUSED:<why>   the one refusal that means "not yet": a
#                                  mergeability the host has not finished
#                                  computing. The PR re-enters the pipeline
#                                  once. MERGE-PIPELINE.md § *The park
#                                  conditions* owns that budget, which every
#                                  re-entering detection shares.
#   exit 1   FRESH-REFUSED:<why>   anything else — an unread PR never merges
#
# **The caller reads the code, not the message.** Exit 2 is what separates the
# uncomputed mergeability from every other refusal, so no step decides a
# re-entry by matching prose the host is free to reword. It is the same code
# merge-pinned.sh reserves for the same purpose.
#
# **Every field comes from the host's API; this script runs no `git` at all.**
# The hole it exists to close is the stale local ref: a checkout whose
# `refs/remotes/origin/<branch>` still names the examined commit while the
# remote has moved on reads as fresh to `git rev-parse` and is not. So the
# comparison is made against what the host says, and a read that fails refuses
# rather than falling back to anything local.
#
# **Two calls, one contract.** With a commit as the second argument the script
# compares: the pipeline's pre-merge freshness gate, chained between
# merge-decision.sh and merge-pinned.sh. With `-` it only reports: the
# pipeline's post-update read, whose FRESH-OK line carries the commit the
# verifier is then briefed to examine. `-` skips the comparison and nothing
# else — every other refusal below still applies, which is what makes the
# post-update read a park decision as well as a commit source. The uncomputed
# mergeability fires at both calls, so exit 2 is reachable from both.
#
# The findings lines, all of them. `FRESH-OK` is exit 0, every refusal
# below it is exit 1, and the last one is exit 2:
#
#   FRESH-OK:<head>
#   FRESH-REFUSED:usage: merge-freshness.sh <pr-number> <examined-commit|->
#   FRESH-REFUSED:the host did not answer for PR #<pr> — <message>; an unread PR is never a fresh one
#   FRESH-REFUSED:the host's answer for PR #<pr> carries no head commit — refusing rather than guessing it
#   FRESH-REFUSED:PR #<pr> is <STATE>, not OPEN — there is nothing here to merge
#   FRESH-REFUSED:PR #<pr> head is <head>, not the examined <examined> — the branch moved after it was verified
#   FRESH-REFUSED:PR #<pr> conflicts with its base (mergeable <m>, merge state <s>) — the branch update did not land clean
#   FRESH-REFUSED:PR #<pr> is BEHIND its base — the base moved after the branch update; update and re-verify before this can merge
#   FRESH-REFUSED:PR #<pr> merge state is <s> — the host will not merge it as it stands
#   FRESH-REFUSED:PR #<pr> mergeability is still UNKNOWN after <n> read(s) — the host had not finished computing it, and an uncomputed state is never a fresh one   (exit 2)
#
# **The order of those checks is part of the contract**, because a closed PR
# reports no merge state at all: measured with gh 2.98.0 against this repo's
# merged PR #165, `mergeStateStatus` and `mergeable` both read `UNKNOWN` while
# `state` reads `MERGED`. State is therefore read before either of them, or an
# already-merged PR would be reported as a PR whose mergeability is uncomputed.
#
# **Why UNKNOWN is re-read rather than refused outright.** The host computes
# mergeability lazily, and a read does not compute it inline: the read queues a
# background job and answers UNKNOWN, and a later read collects the result. So
# UNKNOWN — in either field — is the one reading that resolves on its own, where
# a moved head and a conflict are answers. It is re-read up to $FRESHNESS_READS
# times, $FRESHNESS_READ_SECONDS apart, and refuses when it is still UNKNOWN at
# the end. No other refusal is ever retried.
#
# **The computation can start cold, so the window is sized for a cold one.** A
# branch update that finds the branch already current asks the host to recompute
# nothing, and a newly opened PR has never had a mergeability computed at all —
# in both cases the first read of the pipeline is the read that starts the work.
# Measured on this repo's PR #196: three reads across ten seconds refused, and
# the same PR read MERGEABLE/CLEAN six consecutive times twenty minutes later.
# The defaults below give it fifty seconds.
#
# **What this script does not decide.** CI is `pr-checks.sh`'s witness and the
# verdict is `merge-decision.sh`'s, so a merge state of UNSTABLE — the host's
# word for a non-required check that is not green — is fresh here. One fact,
# one home; a second CI opinion in this script could only disagree with the
# first.
#
# Environment: $FRESHNESS_READS (default 6) is the total number of reads an
# UNKNOWN mergeability gets; $FRESHNESS_READ_SECONDS (default 10) is the wait
# between them. Both exist so the tests can drive the retry path without
# sleeping.
set -u

pr="${1-}"
examined="${2-}"

# One printer, two codes. The second argument is the exit code, and only the
# uncomputed mergeability passes one: 2 there is what lets the caller re-enter
# on that refusal without reading the message.
refuse() { echo "FRESH-REFUSED:$1"; exit "${2:-1}"; }

case "$pr" in
  '' ) refuse 'usage: merge-freshness.sh <pr-number> <examined-commit|->' ;;
  *[!0-9]* ) refuse 'usage: merge-freshness.sh <pr-number> <examined-commit|->' ;;
esac
[ -n "$examined" ] || refuse 'usage: merge-freshness.sh <pr-number> <examined-commit|->'

reads="${FRESHNESS_READS:-6}"
case "$reads" in ''|*[!0-9]*) reads=6 ;; esac
[ "$reads" -ge 1 ] || reads=1
wait_s="${FRESHNESS_READ_SECONDS:-10}"
case "$wait_s" in ''|*[!0-9]*) wait_s=10 ;; esac

attempt=0
while :; do
  attempt=$((attempt + 1))

  # stderr is folded into the capture so a failed read can say what the host
  # said; on success the capture is the JSON document and nothing else.
  answer="$(gh pr view "$pr" --json state,headRefOid,mergeable,mergeStateStatus 2>&1)"
  code=$?
  [ "$code" -eq 0 ] \
    || refuse "the host did not answer for PR #$pr — $answer; an unread PR is never a fresh one"

  field() { printf '%s' "$answer" | jq -r "$1 // empty" 2>/dev/null; }
  state="$(field .state)"
  head="$(field .headRefOid)"
  mergeable="$(field .mergeable)"
  mstate="$(field .mergeStateStatus)"

  [ -n "$head" ] \
    || refuse "the host's answer for PR #$pr carries no head commit — refusing rather than guessing it"

  [ "$state" = "OPEN" ] \
    || refuse "PR #$pr is ${state:-unreported}, not OPEN — there is nothing here to merge"

  if [ "$examined" != "-" ] && [ "$head" != "$examined" ]; then
    refuse "PR #$pr head is $head, not the examined $examined — the branch moved after it was verified"
  fi

  case "$mergeable:$mstate" in
    CONFLICTING:*|*:DIRTY)
      refuse "PR #$pr conflicts with its base (mergeable ${mergeable:-unreported}, merge state ${mstate:-unreported}) — the branch update did not land clean" ;;
    *:BEHIND)
      refuse "PR #$pr is BEHIND its base — the base moved after the branch update; update and re-verify before this can merge" ;;
  esac

  if [ "$mergeable" = "UNKNOWN" ] || [ "$mstate" = "UNKNOWN" ] || [ -z "$mergeable" ] || [ -z "$mstate" ]; then
    if [ "$attempt" -lt "$reads" ]; then
      [ "$wait_s" -eq 0 ] || sleep "$wait_s"
      continue
    fi
    refuse "PR #$pr mergeability is still UNKNOWN after $attempt read(s) — the host had not finished computing it, and an uncomputed state is never a fresh one" 2
  fi

  case "$mstate" in
    CLEAN|HAS_HOOKS|UNSTABLE) ;;
    *) refuse "PR #$pr merge state is $mstate — the host will not merge it as it stands" ;;
  esac

  echo "FRESH-OK:$head"
  exit 0
done
