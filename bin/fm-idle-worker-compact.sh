#!/usr/bin/env bash
# fm-idle-worker-compact.sh - one idle worker compaction pass for this home.
#
# Usage: fm-idle-worker-compact.sh tick
#
# The watcher (bin/fm-watch.sh) starts one detached pass at most every
# FM_IDLE_COMPACT_TICK_SECS (default 60) seconds; it is not a daemon, and a pass
# that finds another still running exits at once. Each pass types one /compact
# into any Claude ship or scout worker due under bin/fm-warm-compact-lib.sh's
# "Idle worker compaction" guards, and settles earlier compactions. That lib
# owns the guards, the records, and the log; docs/configuration.md "Idle worker
# compaction" owns the switch and the threshold.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, and
# FM_DATA_OVERRIDE resolve the home as the other bin/ scripts do. Prints
# nothing and exits 0 on every pass, including a skipped one; 2 on a usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

[ "${1:-}" = tick ] && [ "$#" -eq 1 ] || { echo "usage: fm-idle-worker-compact.sh tick" >&2; exit 2; }
[ -d "$STATE" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=/dev/null # Analyzed separately as a canonical lint root.
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-warm-compact-lib.sh
. "$SCRIPT_DIR/fm-warm-compact-lib.sh"

LOCK="$STATE/.idle-worker-compact.lock"
fm_lock_try_acquire "$LOCK" || exit 0
trap 'fm_lock_release "$LOCK" >/dev/null 2>&1 || true' EXIT
fm_idle_compact_tick "$CONFIG" "$STATE" "$DATA" || true
exit 0
