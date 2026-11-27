#!/usr/bin/env bash
# fm-warm-compact-lib.sh - warm-cache compaction for a Claude primary, the
# supervision host's engine conversation, and idle Claude workers (one owner of
# all three, and of the one pane-typing path they share, fm_warm_compact_type).
#
# Sourced, never executed. The supervision host (bin/fm-supervision-host.sh)
# calls the primary and engine parts while it is parked, so that trigger lives
# on the Claude adapter path; docs/configuration.md "Warm-cache compaction"
# owns their home gate and tunables. bin/fm-idle-worker-compact.sh calls the
# worker part; see "Idle worker compaction" below.
#
# WHY. A session that sits idle past its prompt-cache lifetime re-writes its
# whole context at the cache-write price on the next turn. Compacting while the
# cache is still warm reads the old context at the read price, so the next turn
# writes only the summary.
#
# THE GATE (config/warm-compact). Absent means off. A present file enables it;
# its optional lines are
#   idle-seconds=<n>          idle time before a session is due (default 2700)
#   min-context-tokens=<n>    context size below which no session is due (80000)
# Blank lines and lines starting with # are ignored; an unusable value keeps
# its default.
#
# A DUE SESSION is idle for at least idle-seconds, holds at least
# min-context-tokens of context (the last request's input + cache_read +
# cache_creation usage in its transcript), and has not been compacted in this
# idle episode. fm_warm_compact_verdict names the first guard that holds a
# session back; the actions below act only on "due".
#
# THE PRIMARY. fm_warm_compact_primary types /compact through
# fm_warm_compact_type, which uses the backend's verified submit primitive
# (fm_backend_send_text_submit, the one the away-mode daemon injects through),
# only when the backend reports the agent not busy and the composer provably
# empty. It never uses raw pane send-text or send-keys.
#
# THE ENGINE. fm_warm_compact_engine resumes the engine conversation with
# /compact as a bounded headless turn (fm_supervision_engine_turn).
#
# A compaction is internal housekeeping: these functions print one verdict word
# and write nothing the captain sees.

FM_WARM_COMPACT_IDLE_DEFAULT=2700
FM_WARM_COMPACT_MIN_DEFAULT=80000
FM_WARM_COMPACT_ENGINE_TIMEOUT_DEFAULT=300

# fm_warm_compact_config <config-dir>: succeed and set FM_WARM_COMPACT_IDLE and
# FM_WARM_COMPACT_MIN when the home opted in; fail when it did not.
fm_warm_compact_config() {
  local file=$1/warm-compact line key value
  [ -f "$file" ] || return 1
  FM_WARM_COMPACT_IDLE=$FM_WARM_COMPACT_IDLE_DEFAULT
  FM_WARM_COMPACT_MIN=$FM_WARM_COMPACT_MIN_DEFAULT
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    case "$value" in '' | 0* | *[!0-9]*) continue ;; esac
    case "$key" in
      idle-seconds) FM_WARM_COMPACT_IDLE=$value ;;
      min-context-tokens) FM_WARM_COMPACT_MIN=$value ;;
    esac
  done < "$file"
  return 0
}

# fm_warm_compact_context_tokens <transcript>: print the context size of the
# transcript's last request, or nothing when it cannot be read.
fm_warm_compact_context_tokens() {
  local transcript=$1
  [ -r "$transcript" ] || return 1
  tail -n 400 "$transcript" 2>/dev/null | jq -R -r '
      fromjson? | select(.type == "assistant") | .message.usage // empty
      | select(type == "object")
      | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)
    ' 2>/dev/null | tail -n 1
}

# fm_warm_compact_verdict <config-dir> <idle-seconds> <context-tokens> <compacted 0|1>
# prints off|episode|young|small|due.
fm_warm_compact_verdict() {
  local config=$1 idle=$2 tokens=$3 compacted=$4
  fm_warm_compact_config "$config" || { printf 'off\n'; return 0; }
  if [ "$compacted" = 1 ]; then printf 'episode\n'; return 0; fi
  case "$idle" in '' | *[!0-9]*) printf 'young\n'; return 0 ;; esac
  if [ "$idle" -lt "$FM_WARM_COMPACT_IDLE" ]; then printf 'young\n'; return 0; fi
  case "$tokens" in '' | *[!0-9]*) printf 'small\n'; return 0 ;; esac
  if [ "$tokens" -lt "$FM_WARM_COMPACT_MIN" ]; then printf 'small\n'; return 0; fi
  printf 'due\n'
}

# fm_warm_compact_primary <config-dir> <backend> <target> <idle-seconds> <transcript> <compacted 0|1>
# prints off|episode|young|small|busy|composer|sent|failed. "sent" and "failed"
# both mean a /compact was attempted, so the caller marks the episode.
fm_warm_compact_primary() {
  local config=$1 backend=$2 target=$3 idle=$4 transcript=$5 compacted=$6
  local tokens verdict
  tokens=$(fm_warm_compact_context_tokens "$transcript")
  verdict=$(fm_warm_compact_verdict "$config" "$idle" "$tokens" "$compacted")
  if [ "$verdict" != due ]; then printf '%s\n' "$verdict"; return 0; fi
  fm_warm_compact_type "$backend" "$target" /compact idle
}

# fm_warm_compact_type <backend> <target> <text> <idle|not-busy> prints
# busy|composer|sent|failed: the one pane-typing path for a compaction. The
# backend's native busy verdict must read idle (policy idle), or merely not
# busy when the caller has already proved the turn over (policy not-busy), and
# the composer must read provably empty; otherwise nothing is typed.
fm_warm_compact_type() {
  local backend=$1 target=$2 text=$3 policy=$4 native
  native=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null)
  case "$policy:$native" in
    idle:idle | not-busy:idle | not-busy:unknown) ;;
    *) printf 'busy\n'; return 0 ;;
  esac
  if [ "$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)" != empty ]; then
    printf 'composer\n'
    return 0
  fi
  if [ "$(fm_backend_send_text_submit "$backend" "$target" "$text" 3 0.4 0.4 2>/dev/null)" = empty ]; then
    printf 'sent\n'
  else
    printf 'failed\n'
  fi
}

# fm_warm_compact_engine_transcript <session-id>: print the engine
# conversation's transcript path, or fail when none exists.
fm_warm_compact_engine_transcript() {
  local session=$1 root=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects dir
  case "$session" in '' | */* | *..*) return 1 ;; esac
  for dir in "$root"/*/; do
    [ -f "$dir$session.jsonl" ] || continue
    printf '%s\n' "$dir$session.jsonl"
    return 0
  done
  return 1
}

# fm_warm_compact_engine <config-dir> <idle-seconds> <session> <engine> <model> <prompt-file> <compacted 0|1> [pid-file]
# prints off|episode|young|small|compacted|failed. Needs
# fm-supervision-engine-lib.sh sourced and STATE set.
fm_warm_compact_engine() {
  local config=$1 idle=$2 session=$3 engine=$4 model=$5 prompt=$6 compacted=$7 pid_file=${8:-}
  local transcript tokens verdict msg result errors rc
  transcript=$(fm_warm_compact_engine_transcript "$session") || transcript=
  tokens=$(fm_warm_compact_context_tokens "$transcript")
  verdict=$(fm_warm_compact_verdict "$config" "$idle" "$tokens" "$compacted")
  if [ "$verdict" != due ]; then printf '%s\n' "$verdict"; return 0; fi
  # shellcheck disable=SC2153 # STATE is the sourcing host's state directory.
  msg=$(mktemp "$STATE/.supervision-host-warm.msg.XXXXXX") || { printf 'failed\n'; return 0; }
  result=$(mktemp "$STATE/.supervision-host-warm.result.XXXXXX") || { rm -f "$msg"; printf 'failed\n'; return 0; }
  errors=$(mktemp "$STATE/.supervision-host-warm.err.XXXXXX") || { rm -f "$msg" "$result"; printf 'failed\n'; return 0; }
  printf '/compact' > "$msg"
  rc=0
  fm_supervision_engine_turn "$engine" "$model" "$prompt" "$msg" "$session" resume \
    "${FM_WARM_COMPACT_ENGINE_TIMEOUT:-$FM_WARM_COMPACT_ENGINE_TIMEOUT_DEFAULT}" "$result" "$errors" "$pid_file" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(fm_supervision_engine_result "$engine" "$result" | sed -n 's/^error=\([01]\).*/\1/p')" = 0 ]; then
    printf 'compacted\n'
  else
    printf 'failed\n'
  fi
  rm -f "$msg" "$result" "$errors"
}

# --- Idle worker compaction ---------------------------------------------------
#
# A Claude ship or scout worker waiting on a review, an approval, or a merge
# often sits idle past the one-hour cache. fm_idle_compact_tick, run by
# bin/fm-idle-worker-compact.sh from the watcher's regular tick, types one
# /compact into such a worker shortly before the hour. docs/configuration.md
# "Idle worker compaction" owns the switch and the threshold.
#
# THE GATE (config/idle-worker-compact). On by default; absent means on with
# the defaults. Its optional lines are
#   enabled=0|1               0 turns it off
#   min-context-tokens=<n>    context size below which no worker is due (150000)
# Blank lines and lines starting with # are ignored; an unusable value keeps
# its default.
#
# A DUE WORKER (fm_idle_compact_verdict names the first guard that holds one
# back) is a local kind=ship|scout harness=claude task whose busy record
# (bin/fm-busy-lib.sh) reads idle, that
#   - ended its turn between FM_IDLE_COMPACT_DUE and FM_IDLE_COMPACT_LATE
#     seconds ago, and whose last request is not older than the late bound: a
#     missed window does nothing, because compacting a cold conversation costs
#     more than leaving it;
#   - has not been acted on in this idle spell (one busy-record idle event);
#   - has no compaction marker after its last request (after a compaction the
#     last usage record still shows the old size, so size alone would compact
#     twice, for example after Claude Code's own idle compaction);
#   - holds at least min-context-tokens (bin/fm-context-size.sh --compaction);
#   - has no declared pause that ends before FM_IDLE_COMPACT_HORIZON seconds
#     after the turn ended.
# Before typing, the semantic classifier must still read idle, the
# fm_warm_compact_type guards must pass (native state not busy, composer
# provably empty), and the busy record and the transcript must be unchanged
# since the idle time was read.
#
# RECORDS. state/<id>.idle-compact holds the spell acted on and, until it is
# settled, the pending confirmation. A later tick confirms the compaction by a
# marker newer than the /compact, or gives up after FM_IDLE_COMPACT_CONFIRM_SECS.
# Each outcome appends one line to state/idle-worker-compact.log:
#   at=<epoch of the /compact> task=<id> tokens=<size before> result=compacted|failed [reason=<why>]
# A failure is never retried. Nothing reaches the captain or wakes firstmate.

FM_IDLE_COMPACT_DUE=3300
FM_IDLE_COMPACT_LATE=3480
FM_IDLE_COMPACT_HORIZON=3600
FM_IDLE_COMPACT_MIN_DEFAULT=150000
FM_IDLE_COMPACT_CONFIRM_SECS=300

# fm_idle_compact_config <config-dir>: succeed and set FM_IDLE_COMPACT_MIN when
# the feature is on; fail when the home turned it off.
fm_idle_compact_config() {
  local file=$1/idle-worker-compact line key value
  FM_IDLE_COMPACT_MIN=$FM_IDLE_COMPACT_MIN_DEFAULT
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    case "$key:$value" in
      enabled:0) return 1 ;;
      min-context-tokens:'' | min-context-tokens:0* | min-context-tokens:*[!0-9]*) ;;
      min-context-tokens:*) FM_IDLE_COMPACT_MIN=$value ;;
    esac
  done < "$file"
  return 0
}

# fm_idle_compact_window <idle-seconds> prints young|late|due.
fm_idle_compact_window() {
  case "$1" in '' | *[!0-9]*) printf 'late\n'; return 0 ;; esac
  if [ "$1" -lt "$FM_IDLE_COMPACT_DUE" ]; then printf 'young\n'
  elif [ "$1" -ge "$FM_IDLE_COMPACT_LATE" ]; then printf 'late\n'
  else printf 'due\n'
  fi
}

# fm_idle_compact_verdict <config-dir> <idle-seconds> <request-age> <tokens>
#   <compacted-after 0|1> <spell-done 0|1> <turn-end-epoch> [pause-until-epoch]
# prints off|spell|young|late|compacted|small|paused|due.
fm_idle_compact_verdict() {
  local config=$1 idle=$2 age=$3 tokens=$4 compacted=$5 spell=$6 ended=$7 until=${8:-} window
  fm_idle_compact_config "$config" || { printf 'off\n'; return 0; }
  if [ "$spell" = 1 ]; then printf 'spell\n'; return 0; fi
  window=$(fm_idle_compact_window "$idle")
  if [ "$window" != due ]; then printf '%s\n' "$window"; return 0; fi
  if [ "$(fm_idle_compact_window "$age")" = late ]; then printf 'late\n'; return 0; fi
  if [ "$compacted" != 0 ]; then printf 'compacted\n'; return 0; fi
  case "$tokens" in '' | *[!0-9]*) printf 'small\n'; return 0 ;; esac
  if [ "$tokens" -lt "$FM_IDLE_COMPACT_MIN" ]; then printf 'small\n'; return 0; fi
  case "$until:$ended" in
    *[!0-9:]* | :* | *:) ;;
    *) if [ "$until" -lt $((ended + FM_IDLE_COMPACT_HORIZON)) ]; then printf 'paused\n'; return 0; fi ;;
  esac
  printf 'due\n'
}

# fm_idle_compact_text <data-dir> <state-dir> <id> <branch> prints the /compact
# line, which names what the worker must keep.
fm_idle_compact_text() {
  printf '/compact Keep exactly: the launch brief path %s, the steering inbox %s, the status file %s, the branch %s, every decision made so far, and the remaining steps.' \
    "$1/$3/launch-brief.md" "$2/$3.inbox" "$2/$3.status" "${4:-recorded in the launch brief}"
}

# fm_idle_compact_observe <meta>: print "<tokens> <request-age> <compacted-after 0|1>
# <compaction-age|-> <signature>" from one bin/fm-context-size.sh --compaction
# read, or fail when the conversation could not be read.
fm_idle_compact_observe() {
  "${FM_IDLE_COMPACT_CONTEXT_SIZE:-${FM_WARM_COMPACT_BIN:-$(dirname "${BASH_SOURCE[0]}")}/fm-context-size.sh}" --compaction "$1" 2>/dev/null \
    | jq -r 'select(.status == "read" and (.tokens | type) == "number" and (.age_seconds | type) == "number"
        and (.compacted_after_usage | type) == "boolean" and (.log_signature | type) == "string")
      | "\(.tokens) \(.age_seconds) \(if .compacted_after_usage then 1 else 0 end) \(.compaction_age_seconds // "-") \(.log_signature)"' 2>/dev/null \
    | grep .
}

# fm_idle_compact_busy_line <state-dir> <id>: print the busy record line when
# it is valid for the task's current generation and reads idle.
fm_idle_compact_busy_line() {
  local verdict
  verdict=$(fm_busy_record_read "$1" "$2" 2>/dev/null) || return 1
  case "$verdict" in idle\ *) ;; *) return 1 ;; esac
  head -n 1 "$(fm_busy_record_path "$1" "$2")" 2>/dev/null
}

fm_idle_compact_log() {  # <state-dir> <sent-epoch> <id> <tokens> <result> [reason]
  printf 'at=%s task=%s tokens=%s result=%s%s\n' "$2" "$3" "$4" "$5" "${6:+ reason=$6}" >> "$1/idle-worker-compact.log"
}

fm_idle_compact_record_write() {  # <state-dir> <id> <spell> <sent> <tokens> <result>
  local rec=$1/$2.idle-compact tmp
  tmp=$(mktemp "$rec.tmp.XXXXXX") || return 1
  if printf 'spell=%s\nsent=%s\ntokens=%s\nresult=%s\n' "$3" "$4" "$5" "$6" > "$tmp" && mv -f "$tmp" "$rec"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

fm_idle_compact_record_get() {  # <state-dir> <id> <key>
  sed -n "s/^$3=//p" "$1/$2.idle-compact" 2>/dev/null | head -n 1
}

# fm_idle_compact_worker <config-dir> <state-dir> <data-dir> <meta> <id> <now>
# prints skip|off|spell|young|late|compacted|small|paused|busy|composer|changed|sent|failed.
fm_idle_compact_worker() {
  local config=$1 state=$2 data=$3 meta=$4 id=$5 now=$6
  local busy ts spell spell_done=0 idle obs tokens age compacted _cage sig until line
  local backend target verdict typed
  case "$(fm_meta_get "$meta" kind)" in ship | scout) ;; *) printf 'skip\n'; return 0 ;; esac
  [ "$(fm_meta_get "$meta" harness)" = claude ] || { printf 'skip\n'; return 0; }
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || { printf 'skip\n'; return 0; }
  busy=$(fm_idle_compact_busy_line "$state" "$id") || { printf 'busy\n'; return 0; }
  ts=$(printf '%s\n' "$busy" | sed -n 's/.* ts=\([0-9][0-9]*\).*/\1/p')
  spell=$(printf '%s\n' "$busy" | sed -n 's/.* gen=\([^ ]*\) seq=\([0-9]*\) .*/\1:\2/p')
  [ -n "$ts" ] && [ -n "$spell" ] || { printf 'busy\n'; return 0; }
  [ "$(fm_idle_compact_record_get "$state" "$id" spell)" != "$spell" ] || spell_done=1
  idle=$((now - ts))
  # The cheap timing guards run before the conversation is read.
  verdict=$(fm_idle_compact_verdict "$config" "$idle" 0 "$FM_IDLE_COMPACT_MIN_DEFAULT" 0 "$spell_done" "$ts")
  case "$verdict" in off | spell | young | late) printf '%s\n' "$verdict"; return 0 ;; esac
  obs=$(fm_idle_compact_observe "$meta") || { printf 'small\n'; return 0; }
  read -r tokens age compacted _cage sig <<< "$obs"
  line=$(status_declared_wait_line "$state/$id.status" 2>/dev/null) || line=
  until=$(status_paused_until "$line" 2>/dev/null) || until=
  verdict=$(fm_idle_compact_verdict "$config" "$idle" "$age" "$tokens" "$compacted" "$spell_done" "$ts" "$until")
  [ "$verdict" = due ] || { printf '%s\n' "$verdict"; return 0; }
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  case "$(fm_busy_classify_live "$backend" "$target" claude "$id" "$state" 2>/dev/null)" in
    idle\ *) ;;
    *) printf 'busy\n'; return 0 ;;
  esac
  # The transcript and the turn must be the ones the idle time was read from.
  if [ "$(fm_idle_compact_busy_line "$state" "$id" 2>/dev/null)" != "$busy" ] \
    || [ "$(fm_idle_compact_observe "$meta" | awk '{ print $5 }')" != "$sig" ]; then
    printf 'changed\n'
    return 0
  fi
  typed=$(fm_warm_compact_type "$backend" "$target" \
    "$(fm_idle_compact_text "$data" "$state" "$id" "$(fm_meta_get "$meta" branch)")" not-busy)
  case "$typed" in
    sent) fm_idle_compact_record_write "$state" "$id" "$spell" "$now" "$tokens" pending ;;
    failed)
      fm_idle_compact_record_write "$state" "$id" "$spell" "$now" "$tokens" failed
      fm_idle_compact_log "$state" "$now" "$id" "$tokens" failed submit-unconfirmed
      ;;
  esac
  printf '%s\n' "$typed"
}

# fm_idle_compact_confirm <state-dir> <meta> <id> <now> settles a pending
# record: prints pending|compacted|failed, or nothing when none is pending.
fm_idle_compact_confirm() {
  local state=$1 meta=$2 id=$3 now=$4 sent tokens spell obs cage
  [ "$(fm_idle_compact_record_get "$state" "$id" result)" = pending ] || return 0
  sent=$(fm_idle_compact_record_get "$state" "$id" sent)
  tokens=$(fm_idle_compact_record_get "$state" "$id" tokens)
  spell=$(fm_idle_compact_record_get "$state" "$id" spell)
  case "$sent" in '' | *[!0-9]*) sent=0 ;; esac
  cage=-
  if [ -f "$meta" ] && obs=$(fm_idle_compact_observe "$meta"); then
    cage=$(printf '%s\n' "$obs" | awk '{ print $4 }')
  fi
  case "$cage" in
    '' | *[!0-9]*) ;;
    *)
      # A marker written after the /compact; the slack covers clock rounding.
      if [ "$cage" -le $((now - sent + 5)) ]; then
        fm_idle_compact_record_write "$state" "$id" "$spell" "$sent" "$tokens" compacted
        fm_idle_compact_log "$state" "$sent" "$id" "$tokens" compacted
        printf 'compacted\n'
        return 0
      fi
      ;;
  esac
  if [ ! -f "$meta" ] || [ $((now - sent)) -ge "$FM_IDLE_COMPACT_CONFIRM_SECS" ]; then
    fm_idle_compact_record_write "$state" "$id" "$spell" "$sent" "$tokens" failed
    fm_idle_compact_log "$state" "$sent" "$id" "$tokens" failed no-marker
    printf 'failed\n'
    return 0
  fi
  printf 'pending\n'
}

# fm_idle_compact_tick <config-dir> <state-dir> <data-dir> [now]: one pass over
# the home's recorded tasks. Needs fm-backend.sh, fm-busy-lib.sh, and
# fm-classify-lib.sh sourced.
fm_idle_compact_tick() {
  local config=$1 state=$2 data=$3 now=${4:-$(date +%s)} meta id rec
  for rec in "$state"/*.idle-compact; do
    [ -f "$rec" ] || continue
    id=$(basename "$rec" .idle-compact)
    fm_idle_compact_confirm "$state" "$state/$id.meta" "$id" "$now" >/dev/null
    # A settled record of a task that is gone has nothing left to guard.
    [ -f "$state/$id.meta" ] || [ "$(fm_idle_compact_record_get "$state" "$id" result)" = pending ] || rm -f "$rec"
  done
  fm_idle_compact_config "$config" || return 0
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    [ "$(fm_idle_compact_record_get "$state" "$id" result)" != pending ] || continue
    fm_idle_compact_worker "$config" "$state" "$data" "$meta" "$id" "$now" >/dev/null
  done
}
