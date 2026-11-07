#!/usr/bin/env bash
# fm-memory-write-check.sh - fork-only jjtylr/firstmate memory content check.
# Usage: fm-memory-write-check.sh [--json] [<memory-file>]
#        fm-memory-write-check.sh --claude < Stop-payload.json
# With no file checks the home's writable captain.md, captain-shared.md
# (primary only), learnings.md and charter.md. File paths must be one of those
# files in this home's data/. FM_HOME and FM_{DATA,STATE,CONFIG}_OVERRIDE apply.
# Uses per-file private state/memory-write-check/ snapshots: only added or
# changed lines are classified in one typed Jev call for ordinary writes.
# Large scans pack bounded parallel batches (3s network, shared 4s deadline).
# An unchanged turn makes no request and runs no budget command. Every new
# nonblank line, including headings and comments, is checked; pointers are
# judged with instructions not to mistake them for repeated rules.
# Each candidate gets a typed Choice: duplicate, quote, misplaced, finished,
# or fine. All non-fine choices are returned, including low confidence, so the
# writer can distinguish a tentative finding from a confident one.
# Prints nothing if fine; otherwise short flags with action and confidence.
# --json includes flags, skipped reason, budget report and call timing for proof.
# Never edits memory. Records the checked version even on Jev failure: unchanged
# lines are not retried/reflagged, including across moves within a file. A new
# edit permits a new check. Budget accounting delegates to its existing owner
# (charter remains outside that owner's three-file startup total).
# --claude scopes to primary/secondmate sessions, not child worktrees or foreign
# hosts. New flags go to stderr with exit 2 for one corrective continuation;
# diagnostics alone use systemMessage and exit 0. No stop_hook_active bypass:
# a subsequent genuinely changed line still needs checking. Existing hooks are
# independent. Other harnesses can use the CLI but have no automatic hook here.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}
FM_HOME=${FM_HOME:-$FM_ROOT}
export FM_HOME
if [ "${1:-}" = --claude ]; then
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$SCRIPT_DIR/fm-hook-host-lib.sh"
  PAYLOAD=$(cat 2>/dev/null) || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  printf '%s' "$PAYLOAD" | jq -e 'type=="object"' >/dev/null 2>&1 || exit 0
  fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
  # Scope the session root, not an inherited FM_HOME: a child worktree can
  # inherit its supervisor's home while loading these tracked hooks.
  fm_primary_scope_matches "${CLAUDE_PROJECT_DIR:-$FM_ROOT}" "${FM_STATE_OVERRIDE:-$FM_HOME/state}" || exit 0
fi
exec python3 "$SCRIPT_DIR/fm-memory-write-check.py" "$@"
