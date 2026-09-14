#!/bin/bash
# cleanup-stopped.sh <branch> — collect the briefed ticket branch after a run
# that ended without a PR. Scope is the one briefed branch, never a pattern
# sweep: agent/* is also how humans name branches they manage by hand.
#
#   branch absent                  -> silent no-op (safe on re-run)
#   still checked out in a worktree-> REAP-HELD (the run edited files; that is
#                                     the inspect-before-re-dispatch case)
#   contained in the base branch   -> deleted
#   holds commits base lacks       -> REAP-ORPHAN (a dead run's evidence; the
#                                     PM decides, never this script)
# Always exits 0. Set BASE_BRANCH if the repo's default is not main.
set -u
br="${1:?usage: cleanup-stopped.sh <branch>}"
base="${BASE_BRANCH:-main}"
# Every git call below runs against the main checkout (repo-root-lib.sh). Refs
# and the worktree list are fleet-wide already, so the answer would be the same
# from a linked worktree today; pinning the root keeps that true by
# construction instead of by luck.
. "$(dirname "$0")/repo-root-lib.sh"
repo=$(repo_main_root) || exit 1
if git -C "$repo" show-ref --verify --quiet "refs/heads/$br"; then
  if git -C "$repo" worktree list | grep -q "\[$br\]"; then
    echo "REAP-HELD: $br is still checked out — the run changed files; inspect, don't delete"
  elif git -C "$repo" merge-base --is-ancestor "$br" "$base"; then
    git -C "$repo" branch -D "$br"
  else
    echo "REAP-ORPHAN: $br holds commits $base lacks and has no PR — the PM decides"
  fi
fi
exit 0
