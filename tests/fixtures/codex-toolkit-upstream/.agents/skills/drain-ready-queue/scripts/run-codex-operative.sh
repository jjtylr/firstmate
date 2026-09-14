#!/usr/bin/env bash
# run-codex-operative.sh <ticket> <slug> <brief-file>
#
# Run one Codex operative in one owned Git worktree. This is a bounded process,
# not a daemon: one invocation owns one ticket until `codex exec` returns, is
# interrupted, or reaches its timeout. Parallel lanes start separate invocations.
#
# The lane claim is the ticket and branch binding. The runner refuses an absent,
# unreadable, released, parked, or mismatched claim. It never falls back to the
# parent checkout. An owned stopped worktree can be acquired by a later run.
#
# Outcomes, exactly one per invocation:
#   CODEX-OPERATIVE-PR: an open PR points at the clean local branch head (exit 0)
#   CODEX-OPERATIVE-STOPPED: Codex returned with no PR and no work (exit 0)
#   CODEX-OPERATIVE-UNLANDED: work has no matching open PR; it was preserved (exit 1)
#   CODEX-OPERATIVE-FAILED-STARTUP: Codex failed before producing work (exit 1)
#   CODEX-OPERATIVE-TIMEOUT: the bounded run timed out; any work was preserved (exit 1)
#   CODEX-OPERATIVE-INTERRUPTED: the run was interrupted; any work was preserved (exit 1)
#   CODEX-OPERATIVE-REFUSED: isolation or ownership was not proven; Codex did not run (exit 2)
#
# When Codex wrote a final message, it appears between CODEX-OPERATIVE-RECAP-BEGIN
# and CODEX-OPERATIVE-RECAP-END before the outcome line.
#
# Environment:
#   CODEX_OPERATIVE_CODEX=codex     executable to launch
#   CODEX_OPERATIVE_TIMEOUT=2700    whole seconds per operative
#   CODEX_OPERATIVE_KILL_AFTER=30   TERM-to-KILL grace for GNU timeout
#   CODEX_OPERATIVE_TIMEOUT_BIN     timeout or gtimeout executable
#   BASE_BRANCH=main                branch the ticket branch starts from
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || {
  echo 'CODEX-OPERATIVE-REFUSED: cannot resolve the runner directory' >&2
  exit 2
}
. "$here/repo-root-lib.sh"

refuse() {
  printf 'CODEX-OPERATIVE-REFUSED: %s\n' "$1" >&2
  exit 2
}

[ $# -eq 3 ] || refuse 'usage: run-codex-operative.sh <ticket> <slug> <brief-file>'
ticket="${1#\#}"
slug="$2"
brief="$3"
case "$ticket" in ''|*[!0-9]*) refuse "ticket must be a positive issue number, got: $1" ;; esac
[ "$ticket" -gt 0 ] 2>/dev/null || refuse "ticket must be a positive issue number, got: $1"
case "$slug" in
  ''|[!a-z0-9]*|*[^a-z0-9-]*|*--*|*-) refuse "slug must use lowercase letters, digits, and single interior hyphens, got: $slug" ;;
esac
[ -f "$brief" ] && [ -r "$brief" ] || refuse "brief is not a readable file: $brief"

root="$(repo_main_root)" || refuse 'not a Git repository'
current="$(git rev-parse --show-toplevel 2>/dev/null)" || refuse 'not a Git repository'
root="$(cd "$root" 2>/dev/null && pwd -P)" || refuse 'cannot resolve the main checkout'
current="$(cd "$current" 2>/dev/null && pwd -P)" || refuse 'cannot resolve the current checkout'
[ "$current" = "$root" ] || refuse "run from the main checkout, not $current"
[ "$(pwd -P)" = "$root" ] || refuse "run from the repository root: $root"

base="${BASE_BRANCH:-main}"
branch="agent/$slug-$ticket"
case "$base" in ''|*[!A-Za-z0-9._/-]*) refuse "invalid BASE_BRANCH: $base" ;; esac
git -C "$root" show-ref --verify --quiet "refs/heads/$base" || refuse "base branch does not exist: $base"

branch_lines="$(grep -cF "Branch: \`$branch\`." "$brief" 2>/dev/null || true)"
ticket_lines="$(grep -cF "The PR body carries \`Closes #$ticket\`." "$brief" 2>/dev/null || true)"
[ "$branch_lines" = 1 ] || refuse "brief must bind exactly once to branch $branch"
[ "$ticket_lines" = 1 ] || refuse "brief must bind exactly once to Closes #$ticket"

for tracked in \
  .agents/skills/drain-ready-queue/agent-roles/operative.md \
  .codex/config.toml \
  .codex/hooks.json; do
  git -C "$root" cat-file -e "$base:$tracked" 2>/dev/null ||
    refuse "$tracked is not committed on $base; commit the Codex project installation before dispatch"
done

command -v jq >/dev/null 2>&1 || refuse 'jq is required'
command -v gh >/dev/null 2>&1 || refuse 'gh is required'
codex_bin="${CODEX_OPERATIVE_CODEX:-codex}"
command -v "$codex_bin" >/dev/null 2>&1 || refuse "Codex executable is not on PATH: $codex_bin"

timeout_seconds="${CODEX_OPERATIVE_TIMEOUT:-2700}"
kill_after="${CODEX_OPERATIVE_KILL_AFTER:-30}"
for bound in "$timeout_seconds" "$kill_after"; do
  case "$bound" in ''|*[!0-9]*) refuse "timeout bounds must be whole seconds, got: $bound" ;; esac
done
[ "$timeout_seconds" -gt 0 ] || refuse 'CODEX_OPERATIVE_TIMEOUT must be greater than zero'

timeout_bin="${CODEX_OPERATIVE_TIMEOUT_BIN:-}"
if [ -z "$timeout_bin" ]; then
  for candidate in timeout gtimeout; do
    command -v "$candidate" >/dev/null 2>&1 && { timeout_bin="$candidate"; break; }
  done
fi
[ -n "$timeout_bin" ] && command -v "$timeout_bin" >/dev/null 2>&1 ||
  refuse 'GNU timeout is required (timeout or gtimeout; brew install coreutils on macOS)'

claim="$(bash "$here/claim-status.sh" "$ticket" 2>/dev/null)" ||
  refuse "the lane claim for #$ticket could not be read"
case "$claim" in CLAIM-OPEN:*) ;; *) refuse "#${ticket} has no open lane claim: $claim" ;; esac
claim_branch="$(printf '%s\n' "$claim" | sed -n 's/^CLAIM-OPEN: #[0-9][0-9]* claimed .* on branch \([^,]*\), locks .*/\1/p')"
[ "$claim_branch" = "$branch" ] ||
  refuse "lane claim branch is '${claim_branch:-unreadable}', expected $branch"

common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
  refuse 'cannot resolve the common Git directory'
state="$common/agent-toolkit-codex-operatives"
owners="$state/owners"
runs="$state/runs"
mkdir -p "$owners" "$runs" || refuse "cannot create runner state under $state"

run_lock="$runs/$ticket"
claim_run_lock() {
  mkdir "$run_lock" 2>/dev/null || return 1
  printf 'pid %s\nbranch %s\n' "$$" "$branch" > "$run_lock/owner" 2>/dev/null || return 1
  return 0
}
if ! claim_run_lock; then
  holder="$(sed -n 's/^pid \([0-9][0-9]*\)$/\1/p' "$run_lock/owner" 2>/dev/null | head -n 1)"
  if [ -z "$holder" ] || ps -p "$holder" >/dev/null 2>&1; then
    refuse "ticket #$ticket already has a live or unreadable runner lock at $run_lock"
  fi
  stale="$runs/.stale-$ticket-$$"
  mv "$run_lock" "$stale" 2>/dev/null || refuse "the stale runner lock for #$ticket changed while it was inspected"
  rm -rf "$stale"
  claim_run_lock || refuse "another runner claimed #$ticket while the stale lock was cleared"
fi
run_lock_held=1

worktree_parent="$root/.claude/worktrees"
worktree="$worktree_parent/agent-codex-$ticket"
owner="$owners/$ticket"
worktree_locked=0
child_pid=""
interrupted=0
run_tmp=""

lock_reason() {
  git -C "$root" worktree list --porcelain 2>/dev/null | awk -v want="$worktree" '
    $0 == "worktree " want { inside=1; next }
    inside && /^locked / { sub(/^locked /, ""); print; exit }
    inside && /^$/ { inside=0 }
  '
}
unlock_ours() {
  [ "$worktree_locked" = 1 ] || return 0
  reason="$(lock_reason)"
  case "$reason" in
    "agent-toolkit codex operative #$ticket branch $branch pid $$ start "*)
      git -C "$root" worktree unlock "$worktree" >/dev/null 2>&1 || return 1
      worktree_locked=0 ;;
    '') worktree_locked=0 ;;
    *) return 1 ;;
  esac
  return 0
}
release_run_lock() {
  [ "$run_lock_held" = 1 ] || return 0
  holder="$(sed -n 's/^pid \([0-9][0-9]*\)$/\1/p' "$run_lock/owner" 2>/dev/null | head -n 1)"
  [ "$holder" = "$$" ] && rm -rf "$run_lock"
  run_lock_held=0
  return 0
}
on_exit() {
  unlock_ours >/dev/null 2>&1 || true
  release_run_lock
  [ -n "$run_tmp" ] && rm -rf "$run_tmp"
}
on_signal() {
  interrupted=1
  [ -n "$child_pid" ] && kill -TERM "$child_pid" >/dev/null 2>&1 || true
}
trap on_signal INT TERM
trap on_exit EXIT

registered_branch() {
  [ -d "$worktree" ] || return 1
  listed="$(git -C "$root" worktree list --porcelain 2>/dev/null | grep -cF "worktree $worktree")"
  [ "$listed" = 1 ] || return 1
  got_root="$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null)" || return 1
  got_root="$(cd "$got_root" 2>/dev/null && pwd -P)" || return 1
  [ "$got_root" = "$worktree" ] || return 1
  [ "$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null)" = "$branch" ] || return 1
  [ "$(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" = "$common" ] || return 1
  return 0
}

mkdir -p "$worktree_parent" || refuse "cannot create the worktree parent: $worktree_parent"
if [ -f "$owner" ]; then
  owner_ticket="$(sed -n 's/^ticket \(.*\)$/\1/p' "$owner")"
  owner_branch="$(sed -n 's/^branch \(.*\)$/\1/p' "$owner")"
  owner_path="$(sed -n 's/^path \(.*\)$/\1/p' "$owner")"
  owner_common="$(sed -n 's/^common \(.*\)$/\1/p' "$owner")"
  [ "$owner_ticket" = "$ticket" ] && [ "$owner_branch" = "$branch" ] &&
    [ "$owner_path" = "$worktree" ] && [ "$owner_common" = "$common" ] ||
    refuse "the ownership record for #$ticket does not match this repo, branch, and worktree"
  registered_branch || refuse "owned worktree for #$ticket is absent, unregistered, or on the wrong branch"
else
  [ ! -e "$worktree" ] || refuse "$worktree exists without an agent-toolkit ownership record"
  git -C "$root" show-ref --verify --quiet "refs/heads/$branch" &&
    refuse "branch $branch exists without an agent-toolkit ownership record"
  git -C "$root" worktree add -q -b "$branch" "$worktree" "$base" ||
    refuse "Git could not create an isolated worktree for $branch"
  registered_branch || refuse "Git created a worktree whose root or branch binding cannot be proven"
  owner_tmp="$owners/.owner-$ticket-$$"
  printf 'version 1\nticket %s\nbranch %s\npath %s\ncommon %s\n' \
    "$ticket" "$branch" "$worktree" "$common" > "$owner_tmp" ||
    refuse "cannot write the ownership record for #$ticket"
  ( set -C; cat "$owner_tmp" > "$owner" ) 2>/dev/null ||
    refuse "another ownership record appeared for #$ticket"
  rm -f "$owner_tmp"
fi

existing_reason="$(lock_reason)"
if [ -n "$existing_reason" ]; then
  case "$existing_reason" in
    "agent-toolkit codex operative #$ticket branch $branch pid "*)
      old_pid="$(printf '%s\n' "$existing_reason" | sed -n 's/.* pid \([0-9][0-9]*\) start .*/\1/p')"
      [ -n "$old_pid" ] && ! ps -p "$old_pid" >/dev/null 2>&1 ||
        refuse "owned worktree is locked by live or unreadable pid ${old_pid:-?}"
      git -C "$root" worktree unlock "$worktree" >/dev/null 2>&1 ||
        refuse 'could not clear the proven stale Codex operative lock' ;;
    *) refuse "owned worktree has a foreign lock: $existing_reason" ;;
  esac
fi
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
reason="agent-toolkit codex operative #$ticket branch $branch pid $$ start $started"
git -C "$root" worktree lock --reason "$reason" "$worktree" >/dev/null 2>&1 ||
  refuse "could not lock the owned worktree for #$ticket"
worktree_locked=1

run_tmp="$(mktemp -d "${TMPDIR:-/tmp}/agent-toolkit-codex-operative.XXXXXX")" ||
  refuse 'cannot create the operative temporary directory'
prompt="$run_tmp/prompt.txt"
recap="$run_tmp/last-message.txt"
{
  printf 'You are the project-local Codex operative for ticket #%s.\n' "$ticket"
  printf 'Your only repository root is %s. Never edit or run a repo command in the parent checkout.\n' "$worktree"
  printf 'The PR base is %s. Use that base, not a hard-coded default.\n' "$base"
  printf 'Read .agents/skills/drain-ready-queue/agent-roles/operative.md completely and follow it.\n'
  printf 'The role forbids merging or deploying. Open the PR, return its required recap, and stop.\n\n'
  cat "$brief"
} > "$prompt" || refuse 'cannot assemble the operative prompt'

(
  cd "$worktree" || exit 125
  TOOLKIT_CODEX_OPERATIVE_TICKET="$ticket" TOOLKIT_CODEX_OPERATIVE_BRANCH="$branch" \
    TOOLKIT_CODEX_OPERATIVE_BASE="$base" \
    "$timeout_bin" --signal=TERM --kill-after="${kill_after}s" "${timeout_seconds}s" \
    "$codex_bin" exec --strict-config --approve-for-me --ephemeral \
      --color never -C "$worktree" --output-last-message "$recap" - \
      < "$prompt" >/dev/null 2>&1
) &
child_pid=$!
wait "$child_pid"
code=$?
if [ "$interrupted" = 1 ]; then
  wait "$child_pid" >/dev/null 2>&1 || true
fi
child_pid=""

emit_recap() {
  [ -s "$recap" ] || return 0
  printf 'CODEX-OPERATIVE-RECAP-BEGIN: #%s\n' "$ticket"
  cat "$recap"
  case "$(tail -c 1 "$recap" 2>/dev/null)" in '') ;; *) printf '\n' ;; esac
  printf 'CODEX-OPERATIVE-RECAP-END: #%s\n' "$ticket"
}

clean_owned() { # safe branch deletion mode: normal | merged
  mode="$1"
  unlock_ours || return 1
  git -C "$root" worktree remove "$worktree" >/dev/null 2>&1 || return 1
  if [ "$mode" = merged ]; then
    git -C "$root" branch -D "$branch" >/dev/null 2>&1 || return 1
  else
    git -C "$root" branch -d "$branch" >/dev/null 2>&1 || return 1
  fi
  rm -f "$owner"
  return 0
}

# Re-prove the root and binding after the model ran. A changed branch or a
# replaced directory is preserved and refused, never cleaned by path alone.
if ! registered_branch; then
  emit_recap
  printf 'CODEX-OPERATIVE-UNLANDED: #%s changed or lost its proven worktree binding; preserved at %s for the PM\n' "$ticket" "$worktree" >&2
  exit 1
fi

dirty="$(git -C "$worktree" status --porcelain -uall 2>/dev/null)" || dirty='status unreadable'
head="$(git -C "$worktree" rev-parse HEAD 2>/dev/null)" || head=""
ahead="$(git -C "$worktree" rev-list --count "$base..$branch" 2>/dev/null)" || ahead="unreadable"

prs="$(cd "$root" && gh pr list --head "$branch" --state all --limit 2 --json number,state,headRefName,headRefOid,baseRefName 2>/dev/null)"
pr_code=$?
if [ "$pr_code" != 0 ] || [ -z "$prs" ] || ! printf '%s\n' "$prs" | jq -e 'type == "array"' >/dev/null 2>&1; then
  emit_recap
  printf 'CODEX-OPERATIVE-UNLANDED: #%s PR state could not be read; worktree and branch preserved at %s\n' "$ticket" "$worktree" >&2
  exit 1
fi
pr_count="$(printf '%s\n' "$prs" | jq 'length')"
[ "$pr_count" -le 1 ] || {
  emit_recap
  printf 'CODEX-OPERATIVE-UNLANDED: #%s has more than one PR for %s; worktree preserved at %s\n' "$ticket" "$branch" "$worktree" >&2
  exit 1
}
pr_number="$(printf '%s\n' "$prs" | jq -r '.[0].number // ""')"
pr_state="$(printf '%s\n' "$prs" | jq -r '.[0].state // "NONE"')"
pr_branch="$(printf '%s\n' "$prs" | jq -r '.[0].headRefName // ""')"
pr_head="$(printf '%s\n' "$prs" | jq -r '.[0].headRefOid // ""')"
pr_base="$(printf '%s\n' "$prs" | jq -r '.[0].baseRefName // ""')"
[ -z "$pr_number" ] || [ "$pr_branch" = "$branch" ] || {
  emit_recap
  printf 'CODEX-OPERATIVE-UNLANDED: #%s PR #%s names branch %s, not %s; preserved at %s\n' "$ticket" "$pr_number" "$pr_branch" "$branch" "$worktree" >&2
  exit 1
}
[ -z "$pr_number" ] || [ "$pr_base" = "$base" ] || {
  emit_recap
  printf 'CODEX-OPERATIVE-UNLANDED: #%s PR #%s targets %s, not %s; preserved at %s\n' "$ticket" "$pr_number" "$pr_base" "$base" "$worktree" >&2
  exit 1
}

has_work=0
[ -n "$dirty" ] && has_work=1
if [ -z "$pr_number" ]; then
  case "$ahead" in ''|*[!0-9]*) has_work=1 ;; *) [ "$ahead" -gt 0 ] && has_work=1 ;; esac
elif [ "$head" != "$pr_head" ]; then
  has_work=1
fi

if [ "$interrupted" = 1 ]; then
  emit_recap
  if [ "$pr_state" = NONE ] && [ "$has_work" = 0 ] && clean_owned normal; then
    printf 'CODEX-OPERATIVE-INTERRUPTED: #%s was interrupted before it produced work; empty worktree cleaned\n' "$ticket" >&2
  else
    printf 'CODEX-OPERATIVE-INTERRUPTED: #%s was interrupted; unlanded work preserved at %s\n' "$ticket" "$worktree" >&2
  fi
  exit 1
fi

if [ "$code" = 124 ] || [ "$code" = 137 ]; then
  emit_recap
  if [ "$pr_state" = NONE ] && [ "$has_work" = 0 ] && clean_owned normal; then
    printf 'CODEX-OPERATIVE-TIMEOUT: #%s exceeded %ss before it produced work; empty worktree cleaned\n' "$ticket" "$timeout_seconds" >&2
  else
    printf 'CODEX-OPERATIVE-TIMEOUT: #%s exceeded %ss; unlanded work preserved at %s\n' "$ticket" "$timeout_seconds" "$worktree" >&2
  fi
  exit 1
fi

if [ "$code" != 0 ]; then
  emit_recap
  if [ "$pr_state" = NONE ] && [ "$has_work" = 0 ] && clean_owned normal; then
    printf 'CODEX-OPERATIVE-FAILED-STARTUP: #%s codex exec exited %s before it produced work; empty worktree cleaned\n' "$ticket" "$code" >&2
  else
    printf 'CODEX-OPERATIVE-UNLANDED: #%s codex exec exited %s; work preserved at %s\n' "$ticket" "$code" "$worktree" >&2
  fi
  exit 1
fi

emit_recap
case "$pr_state" in
  OPEN)
    if [ "$has_work" = 0 ]; then
      unlock_ours || {
        printf 'CODEX-OPERATIVE-UNLANDED: #%s PR #%s is open but the owned worktree could not be unlocked; preserved at %s\n' "$ticket" "$pr_number" "$worktree" >&2
        exit 1
      }
      printf 'CODEX-OPERATIVE-PR: #%s opened PR #%s at %s on %s; worktree remains for review\n' "$ticket" "$pr_number" "$head" "$worktree"
      exit 0
    fi
    printf 'CODEX-OPERATIVE-UNLANDED: #%s has PR #%s but local work is not at its clean remote head; preserved at %s\n' "$ticket" "$pr_number" "$worktree" >&2
    exit 1 ;;
  MERGED)
    if [ "$has_work" = 0 ] && clean_owned merged; then
      printf 'CODEX-OPERATIVE-STOPPED: #%s PR #%s was already merged; clean worktree and branch removed\n' "$ticket" "$pr_number"
      exit 0
    fi
    printf 'CODEX-OPERATIVE-UNLANDED: #%s PR #%s is merged but local work differs; preserved at %s\n' "$ticket" "$pr_number" "$worktree" >&2
    exit 1 ;;
  CLOSED)
    printf 'CODEX-OPERATIVE-UNLANDED: #%s PR #%s is closed without merge; branch and worktree preserved at %s\n' "$ticket" "$pr_number" "$worktree" >&2
    exit 1 ;;
  NONE)
    if [ "$has_work" = 0 ] && clean_owned normal; then
      printf 'CODEX-OPERATIVE-STOPPED: #%s returned with no PR and no work; clean worktree and branch removed\n' "$ticket"
      exit 0
    fi
    printf 'CODEX-OPERATIVE-UNLANDED: #%s returned with no PR; work preserved at %s\n' "$ticket" "$worktree" >&2
    exit 1 ;;
  *)
    printf 'CODEX-OPERATIVE-UNLANDED: #%s returned unreadable PR state %s; work preserved at %s\n' "$ticket" "$pr_state" "$worktree" >&2
    exit 1 ;;
esac
