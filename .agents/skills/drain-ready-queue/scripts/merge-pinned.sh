#!/bin/bash
# merge-pinned.sh <pr-number> <examined-commit> <merge-method> <merge-policy> —
# the last step of the serialized merge pipeline (MERGE-PIPELINE.md): the merge
# itself, pinned server-side to the commit the verifier examined. Prints
# exactly one finding line on stdout. **Three exit codes, because the caller's
# next move differs between them:**
#
#   exit 0   MERGE-PINNED:<line>       it merged. Count it toward auto_merge_checkin.
#   exit 2   MERGE-PIN-REFUSED:<line>  the branch moved; the host refused the pin.
#                                      The PR re-enters the pipeline **once**, then parks.
#   exit 1   MERGE-FAILED:<line>       anything else. The PR parks to the PM, never retried.
#
# The pin is `--match-head-commit <examined-commit>`, measured present in
# gh 2.98.0 (`gh pr merge --help`). It is what makes the merge refuse itself
# when the head moved between the verifier's reading and this call: without it
# every guard in the pipeline is a check the host does not share, and the race
# between a push and a merge is won by whoever is later.
#
# **The refusal is classified by re-reading the host, never by matching gh's
# message.** A merge that exits non-zero fits several mechanisms at once —
# a moved head, branch protection, a conflict that appeared underneath — and a
# message string is the host's to reword. So on any failure this script asks
# the host what happened: a PR that is now MERGED merged (the branch delete can
# fail after the merge lands); a head that no longer matches the examined commit
# is the pin firing; anything else, including a re-read that itself fails, parks.
# An unread outcome parks rather than re-entering: re-entry is for a cause that
# was measured.
#
# **Under a non-auto merge policy nothing is attempted.** The catalog's
# `pm-merge` gives the merge point no loop-side machinery at all
# (MERGE-POLICY.md), so this script refuses before its first host call rather
# than trusting a caller to have read the doctrine. Whether a name is an auto
# policy is asked of merge-decision.sh — the catalog's executor — and read from
# its **policy findings line**, never its exit code, exactly as resolve-lanes.sh
# asks it: the button refuses for several reasons at once and only one of them
# answers this question.
#
# `--delete-branch --repo <owner/repo>` are carried for the reason RATIONALE § 6
# measured: `--repo` is what lets the remote branch delete be reached at all
# while the operative's worktree still holds the local branch.
#
# **Under `squash` the subject is deliberate, never the title.** Without
# `--subject`, gh composes main's permanent commit subject from the PR title —
# prose no verdict covers: a title is not part of the examined tree, so a
# verifier that flags one must tag it `[adjacent]`, which never lowers the
# verdict (#235, measured on PR #196 where a wrong title nearly landed). So the
# squash subject is the branch's **first commit subject** — written by the
# operative under the repo's commit conventions — plus ` (#<pr>)`, read from
# the host before the merge is attempted. A subject the host will not give
# refuses rather than falling back to the title. `merge` and `rebase` send no
# `--subject`: neither composes its commit subject from the title.
#
# The findings lines, all of them:
#
#   MERGE-PINNED:#<pr> merged at <commit>
#   MERGE-PINNED:#<pr> merged at <commit>, and the command reported an error afterwards — <message>
#   MERGE-PIN-REFUSED:#<pr> head is now <head>, not the examined <commit> — the branch moved and the host refused the pinned merge
#   MERGE-FAILED:usage: merge-pinned.sh <pr-number> <examined-commit> <merge-method> <merge-policy>
#   MERGE-FAILED:'<commit>' is not a full 40-character commit id — a pin must name the examined commit exactly; nothing was attempted
#   MERGE-FAILED:merge_policy '<name>' is not an auto policy the catalog carries — under it the loop never merges; nothing was attempted
#   MERGE-FAILED:the merge decision script did not answer whether '<name>' is an auto policy — an unread policy is never an auto one; nothing was attempted
#   MERGE-FAILED:merge_method '<name>' is none of squash, merge, rebase — nothing was attempted
#   MERGE-FAILED:cannot read this repository's owner/name from the host — <message>; nothing was attempted
#   MERGE-FAILED:cannot read PR #<pr>'s first commit subject from the host — <message>; nothing was attempted
#   MERGE-FAILED:#<pr> did not merge and its head is still <commit> — <message>
#   MERGE-FAILED:#<pr> did not merge and the host could not be re-read to say why — <message>; an unread outcome parks
set -u

here="$(cd "$(dirname "$0")" && pwd)"

if [ "$#" -eq 5 ]; then
  root="${FM_ROOT:-$(cd "$here/../../../../" 2>/dev/null && pwd -P)}"
  [ -x "$root/bin/fm-codex-toolkit-merge.sh" ] || {
    printf 'MERGE-FAILED:Firstmate merge adapter is missing; nothing was attempted\n'
    exit 1
  }
  FM_ROOT="$root" exec "$root/bin/fm-codex-toolkit-merge.sh" "$@"
fi

pr="${1-}"
commit="${2-}"
method="${3-}"
policy="${4-}"

failed() { echo "MERGE-FAILED:$1"; exit 1; }

case "$pr" in
  ''|*[!0-9]* ) failed 'usage: merge-pinned.sh <pr-number> <examined-commit> <merge-method> <merge-policy>' ;;
esac
{ [ -n "$commit" ] && [ -n "$method" ] && [ -n "$policy" ]; } \
  || failed 'usage: merge-pinned.sh <pr-number> <examined-commit> <merge-method> <merge-policy>'

# A short or abbreviated sha would still pin, but to a commit nobody named in a
# verdict. The pin's whole value is that it and EXAMINED-COMMIT are the same
# string.
case "$commit" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) failed "'$commit' is not a full 40-character commit id — a pin must name the examined commit exactly; nothing was attempted" ;;
esac

case "$method" in
  squash|merge|rebase) ;;
  *) failed "merge_method '$method' is none of squash, merge, rebase — nothing was attempted" ;;
esac

case "$(bash "$here/merge-decision.sh" pass CHECKS-PASS "$policy" 2>/dev/null)" in
  *'is not an auto policy the catalog carries'*)
    failed "merge_policy '$policy' is not an auto policy the catalog carries — under it the loop never merges; nothing was attempted" ;;
  MERGE-ALLOWED*|MERGE-REFUSED:*)
    : ;;
  *)
    failed "the merge decision script did not answer whether '$policy' is an auto policy — an unread policy is never an auto one; nothing was attempted" ;;
esac

repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>&1)"
[ $? -eq 0 ] && [ -n "$repo" ] \
  || failed "cannot read this repository's owner/name from the host — $repo; nothing was attempted"

if [ "$method" = "squash" ]; then
  subject="$(gh pr view "$pr" --repo "$repo" --json commits \
             --jq '.commits[0].messageHeadline // empty' 2>&1)"
  subj_code=$?
  { [ "$subj_code" -eq 0 ] && [ -n "$subject" ]; } \
    || failed "cannot read PR #$pr's first commit subject from the host — $subject; nothing was attempted"
  out="$(gh pr merge "$pr" --squash --subject "$subject (#$pr)" --delete-branch \
          --repo "$repo" --match-head-commit "$commit" 2>&1)"
else
  out="$(gh pr merge "$pr" --"$method" --delete-branch --repo "$repo" \
          --match-head-commit "$commit" 2>&1)"
fi
code=$?

if [ "$code" -eq 0 ]; then
  echo "MERGE-PINNED:#$pr merged at $commit"
  exit 0
fi

# The failure's cause, measured rather than read off the message.
after="$(gh pr view "$pr" --repo "$repo" --json state,headRefOid 2>&1)"
if [ $? -ne 0 ]; then
  failed "#$pr did not merge and the host could not be re-read to say why — $after; an unread outcome parks"
fi
state="$(printf '%s' "$after" | jq -r '.state // empty' 2>/dev/null)"
head="$(printf '%s' "$after" | jq -r '.headRefOid // empty' 2>/dev/null)"

if [ -z "$state" ] || [ -z "$head" ]; then
  failed "#$pr did not merge and the host could not be re-read to say why — $after; an unread outcome parks"
fi

if [ "$state" = "MERGED" ]; then
  echo "MERGE-PINNED:#$pr merged at $commit, and the command reported an error afterwards — $out"
  exit 0
fi

if [ "$head" != "$commit" ]; then
  echo "MERGE-PIN-REFUSED:#$pr head is now $head, not the examined $commit — the branch moved and the host refused the pinned merge"
  exit 2
fi

failed "#$pr did not merge and its head is still $commit — $out"
