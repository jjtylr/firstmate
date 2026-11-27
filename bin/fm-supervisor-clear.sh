#!/usr/bin/env bash
# fm-supervisor-clear.sh - the supervisor clear policy: a supervisor whose
# conversation has grown past a set size gets a FRESH conversation after it
# writes down its open work. Never a compaction: a compacted conversation keeps
# re-reading a summary of everything before it, while a fresh one starts from
# the durable records, which is what session start already restores.
#
# Usage:
#   fm-supervisor-clear.sh tick          one policy pass (bin/fm-watch.sh runs it)
#   fm-supervisor-clear.sh saved         main: its open work is written down
#   fm-supervisor-clear.sh record-main   session start: record main's own endpoint
#   fm-supervisor-clear.sh status        thresholds, main's record, recent log
#   fm-supervisor-clear.sh clear-main    internal: the detached /clear helper
#   fm-supervisor-clear.sh restart-mate <id> <tokens>
#                                        internal: the detached mate restart
#
# WHO. Main (the home's own primary) and every second mate this home records,
# local or remote. Ship and scout workers are out of scope. A secondmate home's
# own conversation is its parent's business, so a home carrying
# .fm-secondmate-home never clears itself and only handles its own mates.
#
# THRESHOLDS. Once a supervisor's conversation reaches SOFT tokens (default
# 150000) it is cleared at its next idle moment, and it must be cleared before
# HARD tokens (default 200000). config/supervisor-clear overrides both
# (docs/configuration.md "Supervisor clear policy" owns the format); `off` there
# turns the policy off, and an invalid file is reported once and acts on nothing.
# Size is the conversation's latest model call as bin/fm-context-size.sh reads
# it (local and remote alike); a reading whose call predates this supervisor's
# last clear or restart belongs to the conversation already dropped and is
# ignored, as is any unknown reading.
#
# SECOND MATES. Over SOFT and idle (an exact idle busy verdict: the semantic
# contract for a local mate, the host's own observation for a remote one), the
# mate is restarted by bin/fm-secondmate-restart.sh --keep-profile --reason
# context, which first asks it to write down its open work (the /stow skill's
# open-record persistence only) and restarts it only once it confirms, on the
# harness, model, and effort its record already names. A busy mate under HARD
# is left alone and retried on a later pass, which is its next idle moment. At
# HARD a busy mate is sent the same restart: the request queues behind the turn
# it is in, asks it to finish that step first, and the restart waits for its
# answer at that turn end. One attempt per mate per RETRY_SECS (1800), and a
# mate whose runtime cannot prove a restart is logged, not nudged.
#
# MAIN. Over SOFT, main is told once through its ordinary notification path (a
# `check: supervisor-clear:` wake this pass prints) to write down its open work
# and then run `fm-supervisor-clear.sh saved`; at HARD it is told once more.
# After `saved`, the next pass starts the /clear helper OUTSIDE main's
# conversation (its own process group, so a /clear that ends main's hooks
# cannot take it down). The helper types into main's pane only when every one
# of these holds, and otherwise skips and is retried on the next pass:
#   - main's endpoint was recorded by its own session start (record-main), on a
#     backend this helper can type into (tmux, herdr) and on Claude, whose
#     /clear is the verified fresh-conversation command;
#   - no model call in the last SETTLE seconds (10);
#   - the pane is not busy, read twice QUIET seconds (3) apart: the backend's
#     native state is idle where it has one (herdr) and not busy otherwise,
#     and the Claude busy footer is absent;
#   - the composer is proven empty both times (bin/fm-composer-lib.sh's strict
#     rule: anything typed, half-typed, or unrecognized is not empty);
#   - the pane did not change at all between the two reads, so neither main
#     nor the captain was doing anything in it.
# It then types /clear and Enter once (retrying only Enter, never the text),
# and confirms the clear by main's session start re-recording its endpoint
# after the typing. At HARD, if main has saved but the helper could not
# confirm a safe moment, or the runtime cannot be cleared here at all, main is
# told once to tell the captain in one line that main needs a /clear.
#
# LOG. Every ask, save, clear, skip, and restart is one line in
# state/supervisor-clear/clear.log: ISO time, epoch, who, tokens before, event,
# detail. The same directory holds the per-supervisor markers this policy
# keeps (main.endpoint, main.asked, main.saved, main.cleared, main.told,
# main.skipped, <id>.attempt, <id>.restarted) and the pass stamp .last-tick.
#
# OUTPUT of `tick`: nothing, or exactly one `check: supervisor-clear: ...` line
# for main to act on. Exit 0 unless the pass itself could not run.
#
# Environment knobs (tests and operators):
#   FM_SUPERVISOR_CLEAR_SETTLE   seconds with no model call before typing (10)
#   FM_SUPERVISOR_CLEAR_QUIET    seconds between the two pane reads (3)
#   FM_SUPERVISOR_CLEAR_CONFIRM  seconds to wait for session start after /clear (30)
#   FM_SUPERVISOR_CLEAR_RETRY    seconds between attempts on one mate (1800)
#   FM_SUPERVISOR_CLEAR_RESTART  restart command (bin/fm-secondmate-restart.sh)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DIR="$STATE/supervisor-clear"
LOG="$DIR/clear.log"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-secondmate-restart-lib.sh
. "$SCRIPT_DIR/fm-secondmate-restart-lib.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"

SOFT=150000
HARD=200000
SETTLE=${FM_SUPERVISOR_CLEAR_SETTLE:-10}
QUIET=${FM_SUPERVISOR_CLEAR_QUIET:-3}
CONFIRM=${FM_SUPERVISOR_CLEAR_CONFIRM:-30}
RETRY_SECS=${FM_SUPERVISOR_CLEAR_RETRY:-1800}
RESTART_CMD=${FM_SUPERVISOR_CLEAR_RESTART:-$SCRIPT_DIR/fm-secondmate-restart.sh}
for knob in "$SETTLE" "$QUIET" "$CONFIRM" "$RETRY_SECS"; do
  case "$knob" in ''|*[!0-9]*) echo "error: supervisor-clear timing knobs must be non-negative integers" >&2; exit 2 ;; esac
done

usage() {
  sed -n '2,/^set -u$/{/^#/{s/^# \{0,1\}//;p;};}' "$0"
}

now() { date +%s; }

# One log line: who, tokens before, event, detail.
log_event() {  # <who> <tokens> <event> [detail]
  local detail=${4:-}
  mkdir -p "$DIR" 2>/dev/null || return 0
  detail=$(printf '%s' "$detail" | tr '\t\n' '  ')
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(now)" \
    "$1" "${2:--}" "$3" "$detail" >> "$LOG" 2>/dev/null || true
}

marker_read() {  # <name> -> first field of the marker's first line
  local line
  [ -f "$DIR/$1" ] || return 1
  IFS= read -r line < "$DIR/$1" || [ -n "$line" ] || return 1
  printf '%s' "${line%% *}"
}

marker_write() {  # <name> <value...>
  local name=$1 tmp
  shift
  mkdir -p "$DIR" || return 1
  tmp=$(mktemp "$DIR/.marker.XXXXXX") || return 1
  printf '%s\n' "$*" > "$tmp" && mv -f -- "$tmp" "$DIR/$name"
}

# Thresholds from config/supervisor-clear. Prints nothing on success; on an
# invalid file prints the reason and returns 1; `off` returns 2.
POLICY_ERROR=
load_policy() {
  local file="$CONFIG/supervisor-clear" line key value n=0 seen=
  POLICY_ERROR=
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%%#*}
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -n "$line" ] || continue
    key=${line%%[[:space:]]*}
    value=${line#"$key"}
    value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//')
    case " $seen " in *" $key "*) POLICY_ERROR="line $n repeats '$key'"; return 1 ;; esac
    seen="$seen $key"
    case "$key" in
      off) [ -z "$value" ] || { POLICY_ERROR="line $n: 'off' takes no value"; return 1; }; return 2 ;;
      soft|hard)
        case "$value" in ''|*[!0-9]*) POLICY_ERROR="line $n: '$key' needs a whole number of tokens"; return 1 ;; esac
        [ "$key" = soft ] && SOFT=$value || HARD=$value ;;
      *) POLICY_ERROR="line $n: unknown key '$key'"; return 1 ;;
    esac
  done < "$file"
  [ "$SOFT" -ge 1000 ] || { POLICY_ERROR="soft must be at least 1000 tokens"; return 1; }
  [ "$SOFT" -lt "$HARD" ] || { POLICY_ERROR="soft must be below hard"; return 1; }
  return 0
}

# Measure one conversation from a key=value record bin/fm-context-size.sh reads.
# Sets OBS_TOKENS (digits or empty) and OBS_CALL_EPOCH (when its latest model
# call ran, or empty when unknown).
OBS_TOKENS=
OBS_CALL_EPOCH=
measure() {  # <record>
  local json parsed
  OBS_TOKENS=
  OBS_CALL_EPOCH=
  json=$("$SCRIPT_DIR/fm-context-size.sh" "$1" 2>/dev/null) || return 1
  parsed=$(printf '%s' "$json" | python3 -I -c '
import json, sys, time
try:
    row = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
tokens, age = row.get("tokens"), row.get("age_seconds")
if row.get("status") != "read" or not isinstance(tokens, int) or isinstance(tokens, bool):
    sys.exit(1)
call = int(time.time()) - age if isinstance(age, int) and not isinstance(age, bool) else ""
print(tokens, call)
') || return 1
  OBS_TOKENS=${parsed%% *}
  OBS_CALL_EPOCH=${parsed#* }
  [ "$OBS_CALL_EPOCH" != "$parsed" ] || OBS_CALL_EPOCH=
  return 0
}

# A reading is stale when its model call is not newer than <since>, the epoch
# this supervisor was last cleared or restarted, or when its age is unknown.
reading_predates() {  # <since-epoch>
  [ -n "$1" ] || return 1
  [ -n "$OBS_CALL_EPOCH" ] || return 0
  [ "$OBS_CALL_EPOCH" -le "$1" ]
}

fmt_tokens() {  # <n> -> 163,000
  local n=$1 out=
  while [ "${#n}" -gt 3 ]; do
    out=",${n: -3}$out"
    n=${n:0:${#n}-3}
  done
  printf '%s%s' "$n" "$out"
}

start_detached() {  # <args...>: run this script in its own process group
  ( set -m 2>/dev/null || true
    nohup "$0" "$@" </dev/null >/dev/null 2>&1 & )
}

# --- second mates ------------------------------------------------------------

# 0 iff the mate is proven idle right now.
mate_idle() {  # <meta> <id>
  local meta=$1 id=$2 verdict
  if [ -n "$(fm_meta_get "$meta" remote_host)" ]; then
    verdict=$(fm_run_timed 10 "$SCRIPT_DIR/fm-on.sh" "$id" \
      fm-remote-secondmate-control.sh observe "$id" </dev/null 2>/dev/null) || return 1
    [ "$verdict" = idle ]
    return
  fi
  verdict=$(fm_busy_classify_meta "$meta" "$id" "$STATE" 2>/dev/null) || return 1
  [ "${verdict%% *}" = idle ]
}

mates_tick() {
  local meta id t attempt restarted level lock
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    [ "$(fm_meta_get "$meta" kind)" = secondmate ] || continue
    [ -n "$(fm_meta_get "$meta" window)" ] || continue
    id=$(basename "$meta" .meta)
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    lock="$DIR/$id.restarting"
    if [ -e "$lock" ]; then
      fm_lock_try_acquire "$lock" || continue
      fm_lock_release "$lock" || true
    fi
    t=$(now)
    attempt=$(marker_read "$id.attempt" 2>/dev/null || true)
    if [ -n "$attempt" ] && [ $((t - attempt)) -lt "$RETRY_SECS" ]; then
      continue
    fi
    measure "$meta" || continue
    restarted=$(marker_read "$id.restarted" 2>/dev/null || true)
    ! reading_predates "$restarted" || continue
    [ "$OBS_TOKENS" -ge "$SOFT" ] || continue
    if ! fm_secondmate_restart_capable "$meta"; then
      marker_write "$id.attempt" "$t" || true
      log_event "$id" "$OBS_TOKENS" cannot-restart "$FM_SECONDMATE_RESTART_REASON"
      continue
    fi
    level=soft
    [ "$OBS_TOKENS" -lt "$HARD" ] || level=hard
    if [ "$level" = soft ] && ! mate_idle "$meta" "$id"; then
      continue
    fi
    marker_write "$id.attempt" "$t" || continue
    log_event "$id" "$OBS_TOKENS" restart-requested "$level"
    start_detached restart-mate "$id" "$OBS_TOKENS"
  done
}

cmd_restart_mate() {  # <id> <tokens>
  local id=$1 tokens=$2 lock out rc line
  case "$id" in ''|*[!A-Za-z0-9._-]*) echo "error: invalid second mate id: $id" >&2; exit 2 ;; esac
  mkdir -p "$DIR" || exit 1
  lock="$DIR/$id.restarting"
  fm_lock_try_acquire "$lock" || exit 0
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$RESTART_CMD" --keep-profile --reason context "$id" 2>&1); rc=$?
  while IFS= read -r line; do
    case "$line" in
      restarted:*) log_event "$id" "$tokens" restarted "${line#restarted: }" ;;
      nudged:*|unreached:*) log_event "$id" "$tokens" restart-failed "$line" ;;
    esac
  done <<EOF
$out
EOF
  if [ "$rc" -eq 0 ]; then
    marker_write "$id.restarted" "$(now)" || true
  elif ! printf '%s\n' "$out" | grep -Eq '^(nudged|unreached):'; then
    log_event "$id" "$tokens" restart-failed "$(printf '%s\n' "$out" | sed -n '/./{p;q;}')"
  fi
  fm_lock_release "$lock" || true
}

# --- main --------------------------------------------------------------------

main_record() { printf '%s' "$DIR/main.endpoint"; }

# Prints one wake line for main, or nothing.
main_tick() {
  local rec t cleared harness backend asked asked_level saved skipped told level clear_lock
  [ ! -e "$FM_HOME/.fm-secondmate-home" ] || return 0
  rec=$(main_record)
  [ -f "$rec" ] || return 0
  measure "$rec" || return 0
  t=$(now)
  cleared=$(marker_read main.cleared 2>/dev/null || true)
  ! reading_predates "$cleared" || return 0
  if [ "$OBS_TOKENS" -lt "$SOFT" ]; then
    rm -f "$DIR/main.asked" "$DIR/main.saved" "$DIR/main.told" "$DIR/main.skipped"
    return 0
  fi
  told=$(marker_read main.told 2>/dev/null || true)
  harness=$(fm_meta_get "$rec" harness)
  backend=$(fm_meta_get "$rec" backend)
  if [ "$harness" != claude ] || { [ "$backend" != tmux ] && [ "$backend" != herdr ]; }; then
    if [ "$OBS_TOKENS" -ge "$HARD" ] && [ -z "$told" ]; then
      marker_write main.told "$t" || return 0
      log_event main "$OBS_TOKENS" captain-told "cannot type /clear on ${harness:-unknown} in ${backend:-unknown}"
      printf 'check: supervisor-clear: main'"'"'s conversation is at %s tokens, past the %s limit, and this runtime (%s in %s) cannot be cleared automatically. Tell the captain in one line that main needs a fresh conversation (/clear).\n' \
        "$(fmt_tokens "$OBS_TOKENS")" "$(fmt_tokens "$HARD")" "${harness:-unknown}" "${backend:-unknown}"
    fi
    return 0
  fi
  saved=$(marker_read main.saved 2>/dev/null || true)
  if [ -n "$saved" ]; then
    skipped=$(marker_read main.skipped 2>/dev/null || true)
    if [ "$OBS_TOKENS" -ge "$HARD" ] && [ -n "$skipped" ] && [ "$skipped" -ge "$saved" ] && [ -z "$told" ]; then
      marker_write main.told "$t" || return 0
      log_event main "$OBS_TOKENS" captain-told "$(sed -n '1s/^[0-9]* //p' "$DIR/main.skipped")"
      printf 'check: supervisor-clear: main'"'"'s conversation is at %s tokens, past the %s limit, and /clear could not be typed safely (%s). Tell the captain in one line that main needs a /clear.\n' \
        "$(fmt_tokens "$OBS_TOKENS")" "$(fmt_tokens "$HARD")" "$(sed -n '1s/^[0-9]* //p' "$DIR/main.skipped")"
    fi
    clear_lock="$DIR/main.clearing"
    if [ -e "$clear_lock" ]; then
      fm_lock_try_acquire "$clear_lock" || return 0
      fm_lock_release "$clear_lock" || true
    fi
    start_detached clear-main
    return 0
  fi
  level=soft
  [ "$OBS_TOKENS" -lt "$HARD" ] || level=hard
  asked_level=$(sed -n '1s/^[0-9]* //p' "$DIR/main.asked" 2>/dev/null || true)
  if [ "$asked_level" = hard ]; then
    asked=$(marker_read main.asked 2>/dev/null || true)
    if [ -z "$told" ] && [ -n "$asked" ] && [ $((t - asked)) -ge "$RETRY_SECS" ]; then
      marker_write main.told "$t" || return 0
      log_event main "$OBS_TOKENS" captain-told "main did not record a save"
      printf 'check: supervisor-clear: main'"'"'s conversation is at %s tokens, past the %s limit, and main has not recorded that its open work is saved, so /clear has not been typed. Tell the captain in one line that main needs a /clear.\n' \
        "$(fmt_tokens "$OBS_TOKENS")" "$(fmt_tokens "$HARD")"
    fi
    return 0
  fi
  if [ -f "$DIR/main.asked" ] && [ "$level" = soft ]; then
    return 0
  fi
  marker_write main.asked "$t $level" || return 0
  log_event main "$OBS_TOKENS" asked "$level"
  if [ "$level" = hard ]; then
    printf 'check: supervisor-clear: main'"'"'s conversation is at %s tokens, past the %s limit. Finish the step you are on, write down the open work held only in this conversation (the /stow skill'"'"'s Open-record persistence section only), run bin/fm-supervisor-clear.sh saved, and end the turn; /clear is then typed into this pane at its next idle moment.\n' \
      "$(fmt_tokens "$OBS_TOKENS")" "$(fmt_tokens "$HARD")"
  else
    printf 'check: supervisor-clear: main'"'"'s conversation is at %s tokens (cleared from %s, always before %s). Write down the open work held only in this conversation (the /stow skill'"'"'s Open-record persistence section only), run bin/fm-supervisor-clear.sh saved, and end the turn; /clear is then typed into this pane at its next idle moment.\n' \
      "$(fmt_tokens "$OBS_TOKENS")" "$(fmt_tokens "$SOFT")" "$(fmt_tokens "$HARD")"
  fi
}

# Pane reads for the /clear guard. PANE_WHY names the first failed condition.
PANE_WHY=
PANE_SCREEN=
pane_quiet_once() {  # <backend> <target>
  local backend=$1 target=$2 native composer
  PANE_SCREEN=
  native=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null || printf 'unknown')
  if [ "$native" = busy ]; then
    PANE_WHY="main's pane reports a turn in progress"
    return 1
  fi
  # Herdr reports the agent's own state, so there it must be exactly idle;
  # tmux has no native state, and the rendered checks below carry the proof.
  if [ "$backend" = herdr ] && [ "$native" != idle ]; then
    PANE_WHY="main's pane could not be proven idle"
    return 1
  fi
  if ! PANE_SCREEN=$(fm_backend_capture "$backend" "$target" 40 2>/dev/null); then
    PANE_WHY="main's pane could not be read"
    return 1
  fi
  if printf '%s' "$PANE_SCREEN" | grep -v '^[[:space:]]*$' | tail -12 | fm_busy_lines_match claude; then
    PANE_WHY="main's pane shows a turn in progress"
    return 1
  fi
  composer=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null || printf 'unknown')
  if [ "$composer" != empty ]; then
    case "$composer" in
      pending|pending-unproven) PANE_WHY="text is waiting in main's input box" ;;
      *) PANE_WHY="main's input box could not be proven empty" ;;
    esac
    return 1
  fi
  return 0
}

pane_quiet() {  # <backend> <target>
  local first
  PANE_WHY=
  pane_quiet_once "$1" "$2" || return 1
  first=$PANE_SCREEN
  sleep "$QUIET"
  pane_quiet_once "$1" "$2" || return 1
  if [ "$first" != "$PANE_SCREEN" ]; then
    PANE_WHY="main's pane changed while it was being watched"
    return 1
  fi
}

send_literal() {  # <backend> <target> <text>
  fm_backend_source "$1" || return 1
  case "$1" in
    tmux) fm_backend_tmux_send_literal "$2" "$3" ;;
    herdr) fm_backend_herdr_send_literal "$2" "$3" ;;
    *) return 1 ;;
  esac
}

cmd_clear_main() {
  local lock rec backend target recorded_at typed_at deadline saved t confirmed=0 enters=0 composer
  [ ! -e "$FM_HOME/.fm-secondmate-home" ] || exit 0
  mkdir -p "$DIR" || exit 1
  lock="$DIR/main.clearing"
  fm_lock_try_acquire "$lock" || exit 0
  # shellcheck disable=SC2064
  trap "fm_lock_release '$lock' >/dev/null 2>&1 || true" EXIT
  rec=$(main_record)
  saved=$(marker_read main.saved 2>/dev/null || true)
  [ -n "$saved" ] && [ -f "$rec" ] || exit 0
  sleep "$SETTLE"
  skip() {
    marker_write main.skipped "$(now) $1" || true
    log_event main "${OBS_TOKENS:-}" skipped "$1"
    exit 0
  }
  measure "$rec" || skip "main's conversation size could not be read"
  t=$(now)
  [ -n "$OBS_CALL_EPOCH" ] || skip "the time of main's last model call is unknown"
  [ $((t - OBS_CALL_EPOCH)) -ge "$SETTLE" ] || skip "main made a model call in the last ${SETTLE}s"
  backend=$(fm_meta_get "$rec" backend)
  target=$(fm_meta_get "$rec" target)
  recorded_at=$(fm_meta_get "$rec" recorded_at)
  [ "$(fm_meta_get "$rec" harness)" = claude ] || skip "main does not run on Claude"
  case "$backend" in tmux|herdr) ;; *) skip "main's pane is on ${backend:-an unknown backend}, which this helper cannot type into" ;; esac
  [ -n "$target" ] || skip "main's pane was never recorded"
  fm_backend_target_exists "$backend" "$target" || skip "main's recorded pane was not found"
  pane_quiet "$backend" "$target" || skip "$PANE_WHY"
  # Re-check the save is still the one this pass acted on: a save cancelled or a
  # record replaced while the pane was watched is not this helper's to act on.
  [ "$(marker_read main.saved 2>/dev/null || true)" = "$saved" ] || exit 0
  [ "$(fm_meta_get "$rec" target)" = "$target" ] || exit 0
  typed_at=$(now)
  send_literal "$backend" "$target" /clear || skip "typing into main's pane failed"
  log_event main "$OBS_TOKENS" typed "/clear into $backend $target"
  while [ "$enters" -lt 3 ]; do
    sleep 1
    fm_backend_send_key "$backend" "$target" Enter >/dev/null 2>&1 || true
    enters=$((enters + 1))
    deadline=$(( $(now) + CONFIRM / 3 + 1 ))
    while [ "$(now)" -lt "$deadline" ]; do
      recorded_at=$(fm_meta_get "$rec" recorded_at)
      case "$recorded_at" in ''|*[!0-9]*) recorded_at=0 ;; esac
      if [ "$recorded_at" -ge "$typed_at" ]; then
        confirmed=1
        break 2
      fi
      sleep 1
    done
    composer=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null || printf 'unknown')
    case "$composer" in pending|pending-unproven) ;; *) break ;; esac
  done
  marker_write main.cleared "$typed_at" || true
  rm -f "$DIR/main.asked" "$DIR/main.saved" "$DIR/main.told" "$DIR/main.skipped"
  if [ "$confirmed" = 1 ]; then
    log_event main "$OBS_TOKENS" cleared "session start re-ran after /clear"
  else
    log_event main "$OBS_TOKENS" cleared-unconfirmed "session start did not re-record main within ${CONFIRM}s"
  fi
}

cmd_saved() {
  local t
  [ ! -e "$FM_HOME/.fm-secondmate-home" ] || {
    echo "error: a secondmate home is restarted by its parent; there is no /clear to schedule here" >&2
    exit 1
  }
  t=$(now)
  marker_write main.saved "$t" || { echo "error: could not record the save under $DIR" >&2; exit 1; }
  rm -f "$DIR/main.skipped" "$DIR/.last-tick"
  log_event main - saved ""
  echo "saved: /clear will be typed into main's pane at its next idle moment"
}

cmd_record_main() {
  local target backend harness cwd account tmp
  [ ! -e "$FM_HOME/.fm-secondmate-home" ] || return 0
  target=$(discover_supervisor_target) || return 0
  backend=$(discover_supervisor_backend) || return 0
  harness=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || true)
  cwd=${CLAUDE_PROJECT_DIR:-$PWD}
  account=ordinary
  [ "$harness" != claude ] || [ -z "${CLAUDE_CONFIG_DIR:-}" ] || account=$CLAUDE_CONFIG_DIR
  mkdir -p "$DIR" || return 1
  tmp=$(mktemp "$DIR/.endpoint.XXXXXX") || return 1
  {
    printf 'backend=%s\n' "$backend"
    printf 'target=%s\n' "$target"
    printf 'harness=%s\n' "$harness"
    printf 'worktree=%s\n' "$cwd"
    printf 'account=%s\n' "$account"
    printf 'recorded_at=%s\n' "$(now)"
  } > "$tmp" && mv -f -- "$tmp" "$(main_record)"
}

cmd_tick() {
  local rc=0 line
  mkdir -p "$DIR" || exit 1
  : > "$DIR/.last-tick"
  load_policy || rc=$?
  if [ "$rc" -eq 2 ]; then
    return 0
  elif [ "$rc" -ne 0 ]; then
    line="config/supervisor-clear is invalid ($POLICY_ERROR)"
    if [ "$(cat "$DIR/.policy-error" 2>/dev/null || true)" != "$line" ]; then
      printf '%s\n' "$line" > "$DIR/.policy-error"
      log_event policy - invalid "$POLICY_ERROR"
      printf 'check: supervisor-clear: %s, so no supervisor is being cleared; fix or remove the file (docs/configuration.md "Supervisor clear policy").\n' "$line"
    fi
    return 0
  fi
  rm -f "$DIR/.policy-error"
  mates_tick
  main_tick
}

cmd_status() {
  local rc=0
  load_policy || rc=$?
  case "$rc" in
    0) printf 'policy: clear from %s tokens, always before %s\n' "$SOFT" "$HARD" ;;
    2) printf 'policy: off (config/supervisor-clear)\n' ;;
    *) printf 'policy: invalid config/supervisor-clear (%s)\n' "$POLICY_ERROR" ;;
  esac
  if [ -f "$(main_record)" ]; then
    printf 'main: %s %s on %s\n' "$(fm_meta_get "$(main_record)" backend)" \
      "$(fm_meta_get "$(main_record)" target)" "$(fm_meta_get "$(main_record)" harness)"
  else
    printf 'main: endpoint not recorded yet (session start records it)\n'
  fi
  [ ! -f "$LOG" ] || tail -10 "$LOG"
}

case "${1:-}" in
  tick) cmd_tick ;;
  saved) cmd_saved ;;
  record-main) cmd_record_main ;;
  status) cmd_status ;;
  clear-main) cmd_clear_main ;;
  restart-mate) [ "$#" -eq 3 ] || { usage >&2; exit 2; }; cmd_restart_mate "$2" "$3" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
