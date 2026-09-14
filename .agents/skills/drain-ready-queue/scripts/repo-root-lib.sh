#!/bin/bash
# repo-root-lib.sh — the main checkout, from anywhere in the fleet. Sourced,
# never run:
#
#   . "$(dirname "$0")/repo-root-lib.sh"
#   root=$(repo_main_root) || root=""
#
# Every file the loop shares — docs/agents/ledger.md, docs/agents/loop.md, the
# .claude/worktrees/ sweep — lives in the MAIN checkout, and every script that
# reads or writes one has to find that checkout whichever checkout it is
# standing in. `git rev-parse --show-toplevel` does not: from inside a linked
# worktree it names the worktree, and the ledger row lands on the ticket branch
# (pushed there, reported as a success) while the claim it was meant to release
# reads as open from a ledger that never received it (#256 and the worktree
# audit of 2026-09-05, T1). The common git dir's parent is the main checkout
# from anywhere, which is what this answers with.
#
# Needs git 2.31 (March 2021) for --path-format.
#
#   stdout   the main checkout's absolute path
#   exit 0   answered
#   exit 1   not inside a git repository, nothing printed

repo_main_root() {
  local common
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  (cd "$common/.." 2>/dev/null && pwd) || return 1
}
