#!/bin/bash
# reap.sh — collect the worktrees this loop's dispatches own, and the harness's
# bookkeeping branches, at the top of a drain iteration. Prints REAP-* findings;
# always exits 0 (a held worktree is a finding for the PM, not an error).
#
# OWNERSHIP IS MEASURED, NEVER ASSUMED. The sweep path is shared, so a branch
# name proves nothing: only what the harness itself wrote does. A worktree is
# owned when its lock reason names the agent class (`claude agent <id> (pid <n>
# start <t>)` or `agent-toolkit codex operative #<n> branch <b> pid <n> start
# <t>`), or when it is unlocked and sits in an `agent-*` directory the
# harness made. Everything else is foreign — a `claude session` lock is another
# session's and stays silent, anything unrecognizable gets REAP-FOREIGN — and a
# foreign worktree is never interrogated, removed, or branch-deleted.
#
# LIVENESS IS MEASURED HERE, not deferred to a judgment step each cycle: the
# lock reason carries the hosting session's pid, and `ps -p` answers it. Alive
# asserts "hands off", which is the right assertion whether the dispatch is
# still working or the session merely outlived it. Only a pid measured gone
# makes a run established dead.
#
# Owned worktree, by the checked-out branch's PR:
#   detached HEAD -> REAP-SKIPPED (unmatchable to a PR, so never collected)
#   OPEN          -> silent (review in flight)
#   MERGED, unlocked  -> remove worktree, delete branch (-D: squash merges leave
#                        no ancestry for -d; the tracker's verdict is authority)
#   MERGED, remove refused by dirt -> REAP-BLOCKED naming the dirt
#   MERGED, lock pid alive -> REAP-HELD-LIVE   (never force a live session out)
#   MERGED, lock pid gone  -> REAP-BLOCKED naming the stale lock (never force)
#   CLOSED        -> REAP-HELD (PM discarded the PR; discarding the branch is
#                    theirs)
#   no PR, pid alive -> REAP-HELD-LIVE (still working toward its PR)
#   no PR, pid gone  -> REAP-HELD-DEAD (established dead). **This line changed
#                       in #213: it now names the branch, and its advice is the
#                       act rather than a hand-over.** It has to name the
#                       branch. The cycle acts on this finding by clearing the
#                       dead dispatch's lane, and the ticket to clear is the
#                       branch's numeric suffix; the worktree directory is named
#                       after a harness id and carries no link to a ticket at
#                       all.
#   no PR, unlocked  -> REAP-HELD (asserts neither reading)
#
# Branch sweep, for branches whose worktree is gone:
#   worktree-agent-*, no unique commits -> deleted (harness bookkeeping)
#   worktree-agent-*, unique commits    -> REAP-ORPHAN (never deleted)
#   agent/*, no unique commits          -> REAP-RESIDUE: an early death's only
#                                          marker, since the harness auto-removes
#                                          the worktree it never changed. Report
#                                          it, never delete it — agent/* is also
#                                          how humans name branches by hand.
#   agent/*, unique commits             -> silent (most likely a parked branch)
#
# Sweep root:
#   $repo/.claude/worktrees/ missing -> REAP-NONE naming the path it looked for.
#                                       Either there are no harness worktrees,
#                                       or the root resolved wrongly; the line
#                                       makes an empty sweep visible instead of
#                                       indistinguishable from a clean one.
#
# Set BASE_BRANCH if the repo's default branch is not main.
set -u
# The harness puts every dispatched worktree under the MAIN checkout, whichever
# checkout the orchestrator is standing in; repo-root-lib.sh says why
# --show-toplevel is the wrong question.
. "$(dirname "$0")/repo-root-lib.sh"
repo=$(repo_main_root) || exit 1
base="${BASE_BRANCH:-main}"
common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 1
codex_owners="$common/agent-toolkit-codex-operatives/owners"
sweep="$repo/.claude/worktrees/"
[ -d "$sweep" ] || echo "REAP-NONE: $sweep does not exist. No harness worktrees to collect, or the sweep root resolved wrongly"

pid_alive() { ps -p "$1" >/dev/null 2>&1; }

remove_codex_owner() {
  rco_wt=$1; rco_br=$2
  case "${rco_wt##*/}" in
    agent-codex-*) rco_ticket=${rco_wt##*/agent-codex-} ;;
    *) return 0 ;;
  esac
  case "$rco_ticket" in ''|*[!0-9]*) return 0 ;; esac
  rco_owner="$codex_owners/$rco_ticket"
  [ -f "$rco_owner" ] || return 0
  rco_owner_ticket=$(sed -n 's/^ticket \(.*\)$/\1/p' "$rco_owner")
  rco_owner_branch=$(sed -n 's/^branch \(.*\)$/\1/p' "$rco_owner")
  rco_owner_path=$(sed -n 's/^path \(.*\)$/\1/p' "$rco_owner")
  rco_owner_common=$(sed -n 's/^common \(.*\)$/\1/p' "$rco_owner")
  [ "$rco_owner_ticket" = "$rco_ticket" ] && [ "$rco_owner_branch" = "$rco_br" ] &&
    [ "$rco_owner_path" = "$rco_wt" ] && [ "$rco_owner_common" = "$common" ] || return 0
  rm -f "$rco_owner"
}

# $1 worktree, $2 branch, $3 hosting pid ("" when unlocked)
reap_owned() {
  ro_wt=$1; ro_br=$2; ro_pid=$3
  # Detached HEAD gives an empty name, and `gh pr list --head ""` ignores the
  # filter and answers about whatever PR is newest. Never let it through.
  [ -n "$ro_br" ] || { echo "REAP-SKIPPED: $ro_wt is on a detached HEAD"; return; }
  ro_state=$(gh pr list --head "$ro_br" --state all --limit 1 --json state --jq '.[0].state // "NONE"')
  case "$ro_state" in
    MERGED)
      if [ -n "$ro_pid" ] && pid_alive "$ro_pid"; then
        echo "REAP-HELD-LIVE: $ro_wt — PR merged, but pid $ro_pid still holds the lock: a session is live in there. Leave it; the next cycle collects it"
      elif [ -n "$ro_pid" ]; then
        echo "REAP-BLOCKED: $ro_wt — PR merged, but a stale lock holds it (pid $ro_pid is gone). Removal is refused and never forced here: the PM unlocks or removes"
      elif git worktree remove "$ro_wt"; then
        if git branch -D "$ro_br" >/dev/null && ! remove_codex_owner "$ro_wt" "$ro_br"; then
          echo "REAP-BLOCKED: $ro_wt was removed, but its Codex ownership record could not be removed"
        fi
      else
        echo "REAP-BLOCKED: $ro_wt still holds modified or untracked files"
      fi ;;
    CLOSED) echo "REAP-HELD: $ro_wt — PR closed unmerged; the PM decides whether to discard" ;;
    NONE)
      if [ -z "$ro_pid" ]; then
        echo "REAP-HELD: $ro_wt — branch has no PR and nothing holds the worktree: the run may still be working toward its PR, or it may have died; neither is established here"
      elif pid_alive "$ro_pid"; then
        echo "REAP-HELD-LIVE: $ro_wt — branch has no PR, and pid $ro_pid is alive: the run is still working toward it. Do not treat it as dead"
      else
        echo "REAP-HELD-DEAD: $ro_wt on branch $ro_br — branch has no PR, and pid $ro_pid is gone: the run is established dead. Clear its lane: move the ticket the branch names out of the queue, write its \`died\` ledger row, take the \`claimed\` mirror down (SKILL.md step 1). The worktree and the branch stand, and salvage or discard is the PM's (RATIONALE § 4)"
      fi ;;
  esac
}

# $1 worktree, $2 branch, $3 1 if locked, $4 lock reason
triage_worktree() {
  tw_wt=$1; tw_br=$2; tw_locked=$3; tw_lock=$4
  case "$tw_wt" in "$sweep"*) ;; *) return ;; esac
  tw_pid=""
  if [ "$tw_locked" = 1 ]; then
    case "$tw_lock" in
      "claude session "*) return ;;
      "claude agent "*)
        tw_pid=$(printf '%s' "$tw_lock" | sed -n 's/.*(pid \([0-9][0-9]*\)[^0-9].*/\1/p') ;;
      "agent-toolkit codex operative #"*)
        tw_pid=$(printf '%s' "$tw_lock" | sed -n 's/.* pid \([0-9][0-9]*\) start .*/\1/p') ;;
    esac
    if [ -z "$tw_pid" ]; then
      echo "REAP-FOREIGN: $tw_wt — its lock is not one this harness wrote (\"$tw_lock\"); not this loop's to touch"
      return
    fi
  else
    case "${tw_wt##*/}" in
      agent-*) ;;
      *) echo "REAP-FOREIGN: $tw_wt — unlocked and not a harness agent-* worktree; not this loop's to touch"; return ;;
    esac
  fi
  reap_owned "$tw_wt" "$tw_br" "$tw_pid"
}

# One pass over what git itself reports: a directory nobody registered as a
# worktree is not one, and the porcelain stream is where the lock reason lives.
wt=""; br=""; locked=0; lock=""
while IFS= read -r line; do
  case "$line" in
    "worktree "*) wt=${line#worktree }; br=""; locked=0; lock="" ;;
    "branch refs/heads/"*) br=${line#branch refs/heads/} ;;
    "locked") locked=1 ;;
    "locked "*) locked=1; lock=${line#locked } ;;
    "")
      [ -n "$wt" ] && triage_worktree "$wt" "$br" "$locked" "$lock"
      wt=""; br=""; locked=0; lock="" ;;
  esac
done < <(git worktree list --porcelain; echo)

# The branch sweep, after the removals above so the checked-out set is current.
checked_out=$(git worktree list --porcelain | sed -n 's|^branch refs/heads/||p')
while IFS= read -r b; do
  [ -n "$b" ] || continue
  printf '%s\n' "$checked_out" | grep -Fqx "$b" && continue
  if git merge-base --is-ancestor "$b" "$base" 2>/dev/null; then
    case "$b" in
      agent/*) echo "REAP-RESIDUE: $b has no worktree and no commits $base lacks — the marker of a dispatch that died before its first edit. Never deleted here" ;;
      *)       git branch -D "$b" >/dev/null ;;
    esac
  else
    case "$b" in
      agent/*) ;;
      *)       echo "REAP-ORPHAN: $b has no worktree but holds commits $base lacks — the PM decides, never this script" ;;
    esac
  fi
done <<EOF
$(git for-each-ref --format='%(refname:short)' 'refs/heads/worktree-agent-*' 'refs/heads/agent/*')
EOF
exit 0
