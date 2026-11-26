#!/usr/bin/env bash
# fm-alert-wake.sh - wake the mate that has not written under an alert.
#
# The ripplez Bridge runs this by path (its RIPPLEZ_PLANE_ALERT_WAKE_COMMAND
# setting) for an alert the project's mate has left unanswered, and again each
# 15 minutes while it stays unanswered.
#
# Usage: fm-alert-wake.sh <mate-id> <board-slug> <alert-id> <title> <minutes>
#   <mate-id>     `main`, or a second mate id from data/secondmates.md
#   <board-slug>  the alerts board, for example alerts-darkpoolz
#   <alert-id>    the alert's message id (A-Za-z0-9._:-)
#   <title>       the alert's title
#   <minutes>     whole minutes the alert has gone unanswered, counted from when
#                 it was sent, not from the previous wake
#
# First it writes a note naming the board, the alert and "not written under for
# <minutes> minutes" into that mate's own home inbox (on its host for a remote
# mate) with `bin/fm-inbox.sh note`, which brings the mate's wake. The request id
# is alert-wake-<alert-id>-<count>, where <count> is <minutes> divided by 15,
# rounded down, and at least 1. So each 15-minute wake writes a fresh note, while
# a repeat inside the same count replays that note instead of adding one.
#
# The Bridge kills this command after 10 seconds, less than a relaunch takes, so
# once the note is written the command hands a second mate to a detached
# background process in its own process group and returns.
#
# That process starts the second mate if it is proven not running, as classified
# by bin/fm-secondmate-liveness-lib.sh: a local one through
# `bin/fm-control.sh <id> relaunch`, a remote one through
# bin/fm-remote-secondmate-relaunch.sh with the harness, model, and effort in
# this home's state/<id>.meta. A relaunch discards the mate's conversation, so a
# mate that is running or whose state is unclear gets the note only, as does
# `main`, which nothing in firstmate restarts.
#
# Output is one line for the note and one saying `main` gets nothing more, or
# where the second mate's outcome will be recorded: the timestamped lines the
# background process appends to this home's state/.alert-wake-<mate-id>.log,
# including why a relaunch failed.
#
# Exit status: 0 once the note is written, whatever happens after it, including a
# saved note whose wake could not be queued and a background check that could not
# be logged and so was not started (both reported on stderr); 1 when the note
# could not be written or confirmed, with nothing relaunched; 2 on a usage error.
#
# Home resolution matches bin/fm-roster.sh: FM_HOME when set, otherwise the code
# root's own home.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

WAKE_INTERVAL_MINUTES=15

say() { printf 'fm-alert-wake: %s\n' "$1"; }
warn() { printf 'fm-alert-wake: %s\n' "$1" >&2; }
log() { say "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1"; }
die() { warn "$1"; exit 1; }
usage() { sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,1\}//'; }
bad_args() { warn "$1"; usage >&2; exit 2; }

note_only() { OUTCOME="note only: $1"; }

relaunch_mate() {  # <meta>
  local meta=$1 harness model effort out rc=0
  if [ "$REMOTE" -eq 1 ]; then
    harness=$(fm_meta_get "$meta" harness)
    model=$(fm_meta_get "$meta" model)
    effort=$(fm_meta_get "$meta" effort)
    if [ -z "$harness" ]; then
      OUTCOME="relaunch of $ID not attempted: $meta records no harness"
      return
    fi
  fi
  log "relaunching $ID: $FM_SM_LIVE_CAUSE"
  if [ "$REMOTE" -eq 1 ]; then
    out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-remote-secondmate-relaunch.sh" \
      "$ID" "$harness" "${model:-default}" "${effort:-default}" </dev/null 2>&1) || rc=$?
  else
    out=$(FM_HOME="$FM_HOME" FM_SPAWN_NO_GUARD=1 "$SCRIPT_DIR/fm-control.sh" \
      "$ID" relaunch </dev/null 2>&1) || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    OUTCOME="relaunched $ID"
  else
    OUTCOME="relaunch of $ID failed (exit $rc): $out"
  fi
}

wake_second_mate() {
  local meta="$STATE/$ID.meta" meta_remote=0
  if [ ! -f "$meta" ] || [ -L "$meta" ] || [ "$(fm_meta_get "$meta" kind)" != secondmate ]; then
    note_only "this home has no second mate record for $ID, so its state is unclear"
    return
  fi
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || meta_remote=1
  if [ "$meta_remote" -ne "$REMOTE" ]; then
    note_only "the registry and $meta disagree on where $ID runs, so its state is unclear"
    return
  fi
  # Held across probe and relaunch, so the watcher and session start cannot act
  # on this mate at the same time.
  if ! fm_secondmate_liveness_lock "$ID"; then
    note_only "another liveness check or relaunch of $ID is in progress"
    return
  fi
  fm_secondmate_liveness_probe "$meta" "$ID" poll
  case "$FM_SM_LIVE_STATUS" in
    relaunchable) relaunch_mate "$meta" ;;
    alive) note_only "$ID is running" ;;
    silent) note_only "$meta records no endpoint, so $ID's state is unclear" ;;
    *) note_only "$ID's state is unclear: $FM_SM_LIVE_REASON" ;;
  esac
  fm_secondmate_liveness_unlock "$ID"
}

# Internal: the detached process, run as `--check-mate <mate-id> <remote 0|1>`.
if [ "$#" -eq 3 ] && [ "$1" = --check-mate ]; then
  ID=$2
  REMOTE=$3
  case "$ID" in ''|*[!A-Za-z0-9._-]*) bad_args "invalid mate id: $ID" ;; esac
  # shellcheck source=bin/fm-secondmate-liveness-lib.sh
  . "$SCRIPT_DIR/fm-secondmate-liveness-lib.sh"
  OUTCOME=
  wake_second_mate
  log "$OUTCOME"
  exit 0
fi

case "$#:${1:-}" in 1:-h|1:--help) usage; exit 0 ;; esac
[ "$#" -eq 5 ] || bad_args "expected 5 arguments, got $#"
ID=$1
BOARD=$2
ALERT=$3
TITLE=$(printf '%s' "$4" | tr '\n\r\t' '   ')
MINUTES=$5
case "$ID" in ''|*[!A-Za-z0-9._-]*) bad_args "invalid mate id: $ID" ;; esac
case "$BOARD" in ''|*[!A-Za-z0-9._-]*) bad_args "invalid board slug: $BOARD" ;; esac
case "$ALERT" in ''|*[!A-Za-z0-9._:-]*) bad_args "invalid alert id: $ALERT" ;; esac
case "$MINUTES" in ''|*[!0-9]*) bad_args "minutes must be a whole number: $MINUTES" ;; esac

COUNT=$((10#$MINUTES / WAKE_INTERVAL_MINUTES))
[ "$COUNT" -ge 1 ] || COUNT=1
REQUEST_ID="alert-wake-$ALERT-$COUNT"
BODY="Alert $ALERT on board $BOARD not written under for $MINUTES minutes: $TITLE"

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

REMOTE=0
MATE_HOME=
if [ "$ID" != main ]; then
  secondmate_registry_line_for_id "$DATA/secondmates.md" "$ID" \
    || die "no single readable second mate '$ID' in $DATA/secondmates.md; no note written"
  REMOTE=$SECONDMATE_REGISTRY_REMOTE
  MATE_HOME=$SECONDMATE_REGISTRY_HOME
  if [ "$REMOTE" -eq 0 ]; then
    [ "$(cat "$MATE_HOME/.fm-secondmate-home" 2>/dev/null)" = "$ID" ] \
      || die "$MATE_HOME is not second mate $ID's seeded home; no note written"
  fi
fi

write_note() {
  if [ "$ID" = main ]; then
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-inbox.sh" note --request-id "$REQUEST_ID" -
  elif [ "$REMOTE" -eq 1 ]; then
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-on.sh" --stdin "$ID" \
      fm-inbox.sh note --request-id "$REQUEST_ID" -
  else
    # This home's path overrides must not redirect another home's inbox.
    (
      unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE \
        STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
      FM_HOME="$MATE_HOME" "$SCRIPT_DIR/fm-inbox.sh" note --request-id "$REQUEST_ID" -
    )
  fi
}

NOTE_RC=0
NOTE_OUT=$(printf '%s' "$BODY" | write_note 2>&1) || NOTE_RC=$?
case "$NOTE_RC" in
  0) say "note $REQUEST_ID written for $ID" ;;
  # fm-inbox.sh's status for a note that is saved but whose wake was not queued.
  3) warn "note $REQUEST_ID is saved for $ID but its wake was not queued: $NOTE_OUT" ;;
  *) die "note $REQUEST_ID for $ID was not confirmed written (exit $NOTE_RC): $NOTE_OUT" ;;
esac

if [ "$ID" = main ]; then
  say "note only: nothing in firstmate restarts main"
  exit 0
fi

# Its own process group, so a bound on the caller's group cannot reach it, and no
# stdio of the caller's, so a caller reading this command's output is not held.
LOG="$STATE/.alert-wake-$ID.log"
if ! { mkdir -p "$STATE" && : >> "$LOG"; } 2>/dev/null; then
  warn "$ID was not checked: cannot write $LOG"
  exit 0
fi
( set -m 2>/dev/null || true
  FM_HOME="$FM_HOME" nohup "$SCRIPT_DIR/fm-alert-wake.sh" --check-mate "$ID" "$REMOTE" \
    </dev/null >> "$LOG" 2>&1 & )
say "checking $ID in the background; outcome in $LOG"
exit 0
