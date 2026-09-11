#!/bin/bash
# runner.sh — the headless drain runner (spec #120). A bash loop that starts a
# fresh `claude -p` session per iteration, each running exactly one drain cycle
# and then exiting, so ticket twelve is reasoned about in a context window that
# never saw tickets one through eleven.
#
#   bash runner.sh                start a headless run
#   bash runner.sh lock-status    report whether a headless run holds this
#                                 repo's lock. The attended drain's step 0a check
#
#   exit 0   the run ended on a stop condition — the queue drained, a brake,
#            the iteration cap. RUNNER-STOP says which
#   exit 1   the run ended on the consecutive-failure cap: the environment is
#            broken, not the queue
#   exit 2   refused to start. RUNNER-REFUSED says why, and nothing ran
#   exit 3   the gate could not establish an answer before the first iteration
#
#   lock-status: exit 0 free, stale, or held by the caller's own run
#   (RUNNER-LOCK-FREE / RUNNER-LOCK-STALE / RUNNER-LOCK-SELF), exit 1 held by
#   another live runner, or unreadable (RUNNER-LOCK-HELD)
#
# ## The start command
#
# One command, run from the repository being drained:
#
#   bash "<plugin>/skills/drain-ready-queue/scripts/runner.sh"
#
# `<plugin>` is the installed snapshot — `~/.claude/plugins/cache/agent-toolkit/
# toolkit/<sha>`. That directory is stamped with the commit SHA and old
# snapshots are kept beside the current one, so a `*` there matches many
# directories: name the one you mean. In this repository, which *is* the plugin,
# the command is the relative path:
#
#   bash skills/drain-ready-queue/scripts/runner.sh
#
# Nothing else is required. Every bound below has a default, and the two things
# a headless session needs from the plugin have one too:
#
#  - the permission profile — `RUNNER_SETTINGS` unset resolves to
#    **`headless-profile.json` beside this script**;
#  - **Bash reads of the plugin tree** — `--add-dir <plugin root>` is passed on
#    every run, the root resolved three directories up from this script and
#    confirmed by the `.claude-plugin/plugin.json` it must hold. The probe
#    measured why it is not optional: an allow rule like `Bash(grep:*)` carries
#    an implicit workspace scope, so `grep` against a path inside the installed
#    plugin is denied without it while the same rule passes inside the working
#    directory. The `Read` tool is unaffected either way.
#
# Prefix `MILESTONE=…` to scope the run's queue, and `RUNNER_PLUGIN_DIR=<plugin>`
# to load the plugin from a named snapshot rather than from the operator's own
# settings — that directory then becomes the one `--add-dir` too.
#
# **The runner parses no model output.** Every continue/stop decision comes from
# runner-gate.sh's exit code, and the session's own stdout is passed through to
# whatever log the PM redirected into — read, never interpreted.
#
# The loop is fetch -> gate -> session -> sleep -> fetch -> gate. The gate runs
# `start` before the first iteration and `next <run-start>` between them — with
# the finished iteration's own start time as a third argument when its session
# exited 0, which is this runner vouching for a completed cycle and arms the
# gate's live-lock stop. A failed or killed session is not a full cycle, so no
# third argument is passed for one: the failure cap owns that path, and a crash
# read as a live-lock would end a run the cap meant to retry. Both phases and
# every condition they derive belong to that script, and this one only
# obeys the code. The fetch is `git fetch --prune origin`, run before **every**
# gate call because the gate's exclusion reads remote-tracking refs;
# RUNNER-FETCH-FAILED is a findings line, never a stop.
#
# ## Every session says how long it ran
#
# One iteration's session ends in exactly one of three findings lines, and each
# carries the elapsed wall clock of that session in whole seconds:
#
#   RUNNER-SESSION: iteration 3 exited 0 after 512s
#   RUNNER-SESSION-TIMEOUT: iteration 3 ran past 2700s and its process group
#     was killed after 2731s
#   RUNNER-SESSION-FAILED: iteration 3 exited 7 after 12s
#
# The measurement wraps the `claude -p` call itself, so the clean exit, the
# timeout kill and its grace, and every other non-zero exit are all covered; the
# gate, the fetch and the sleep that follow are not. That is the whole point of
# it: RUNNER_ITERATION_TIMEOUT and RUNNER_MAX_FAILURES are then re-derivable
# from a posted run log, instead of held at the one-off floor a single probe
# measured.
#
# ## The lock is a lockfile with a pid in it
#
# The obvious mechanism — the advisory file-locking utility every Linux box
# carries — is not available here: macOS ships no such binary, so a runner built
# on it would work nowhere it is meant to run. The lock is instead a
# **PID-stamped lockfile**: claimed with
# `set -C` (O_EXCL, so two runners racing cannot both win), carrying the
# runner's pid, and a lockfile whose recorded pid is measurably gone is stale and
# claimable — `ps -p`, the same liveness test reap.sh already makes about a
# worktree's hosting session. A lockfile this script cannot read a pid out of is
# never stolen: an unreadable lock is a held lock.
#
# It lives in the repository's **common git directory**, not the working tree.
# Repo-local either way, but from there it is invisible to `git status` in every
# repo the plugin travels to, and shared by every worktree of one repository —
# which is the scope that matters, since the attended drain may run from one.
#
# ## A session can tell its own run's lock from a stranger's
#
# This runner claims the lock before it opens the run issue and before it starts
# any session, so **every** headless session runs the attended step 0a check
# against a lock its own runner holds. Answer that with RUNNER-LOCK-HELD and the
# session stops for a second orchestrator that does not exist. The run then ends
# having done no work, and reports a live-lock (#212).
#
# So the runner names itself to the session it starts. RUNNER_PID carries the
# same pid the claim wrote, and `lock-status` compares it with the lockfile. A
# match against a **live** holder is RUNNER-LOCK-SELF at exit 0, so the cycle
# runs. An attended run passes no identity, so every answer it can get is the
# answer it got before.
#
# Measured for #212 on Claude Code 2.1.247, under headless-profile.json: a
# variable the runner exports does reach a Bash tool call inside the `claude -p`
# session it starts. So the comparison is two numbers in a script, and no model
# judgment sits on the path. Any value that is not the live holder's pid falls
# through to the answer it would have had without it. A stranger's pid, a stale
# one, a typo: each fails toward held, never toward mine.
#
# ## `timeout` is Homebrew coreutils, not a system tool
#
# So the preflight refuses when it is absent instead of discovering it at the
# end of the first iteration, and `gtimeout` is accepted as the name Homebrew
# installs without `gnubin` on PATH.
#
# The kill reaches the session's **whole process group**. GNU timeout puts the
# command in its own group and signals the group; `--foreground` disables that,
# so it is deliberately not passed (measured: with `--foreground` a grandchild
# `sleep` outlives the kill, without it, it does not). A hung `git push` or a
# wedged gate under a dead session would otherwise hold the lock until the
# machine was rebooted, and no cap can fire while a session never returns.
#
# ## Environment — defaults live here, not in loop.md
#
# Deliberately not loop-config keys until a shakedown shows repos needing to
# differ (spec #120).
#
#   RUNNER_SLEEP=15               seconds between iterations, and the backoff
#                                 before a gate retry (lowered from 60 on the
#                                 2026-08-25 shakedown review: the iteration is
#                                 the pacing, and 60s idled ~10% of a run)
#   RUNNER_MAX_ITERATIONS=15      belt cap on iterations
#   RUNNER_MAX_FAILURES=2         consecutive session failures that end the run
#   RUNNER_ITERATION_TIMEOUT=2700 per-iteration wall clock, seconds. The probe
#                                 measured a full iteration at ~9 minutes
#                                 (docs/research/2026-08-25-headless-permission-profile.md)
#   RUNNER_KILL_AFTER=30          grace between the group's TERM and its KILL
#   RUNNER_LOCK                   the lockfile path
#   RUNNER_CLAUDE=claude          the session binary
#   RUNNER_DRAIN_COMMAND=/toolkit:drain-ready-queue
#   RUNNER_SETTINGS              the permission profile passed as `--settings`.
#                                Unset or empty resolves to headless-profile.json
#                                beside this script — the measured allowlist
#                                from docs/research/2026-08-25-headless-permission-profile.md,
#                                `dontAsk` and no `deny`. No resolvable profile
#                                is a refusal, not a fallback: a session with no
#                                allowlist runs under the operator's own default
#                                mode, which the probe measured as `auto`.
#                                Whichever profile resolves is validated first:
#                                `claude -p` **silently ignores** a settings file
#                                that fails validation, so an unchecked
#                                malformed profile runs the whole night under
#                                that same default mode
#   RUNNER_PLUGIN_DIR            when set, `--plugin-dir` + `--setting-sources
#                                project`, and it is also the `--add-dir`. Unset
#                                is the probe's Form C, which resolved the plugin
#                                from user settings and is the measured default;
#                                `--add-dir` is then this script's own plugin
#                                root. Either way exactly one `--add-dir` is
#                                passed. A runner whose plugin root does not
#                                resolve says `RUNNER-NO-PLUGIN-ROOT` and runs
#                                on without the flag — degraded, not refused,
#                                because `Read` still reaches the plugin tree
#   MILESTONE                    passed through to the gate, which scopes the
#                                queue by it
#
# One more variable is read here, and it is **not** an operator knob. The runner
# sets RUNNER_PID on the session it starts, and `lock-status` reads it as the
# caller's run identity. Set it by hand and you claim to be a runner you are
# not. It changes an answer only when the value is the live holder's pid.
set -u

here="$(cd "$(dirname "$0")" && pwd)"

SLEEP_SECONDS="${RUNNER_SLEEP:-15}"
MAX_ITERATIONS="${RUNNER_MAX_ITERATIONS:-15}"
MAX_FAILURES="${RUNNER_MAX_FAILURES:-2}"
ITERATION_TIMEOUT="${RUNNER_ITERATION_TIMEOUT:-2700}"
KILL_AFTER="${RUNNER_KILL_AFTER:-30}"
CLAUDE_BIN="${RUNNER_CLAUDE:-claude}"
DRAIN_COMMAND="${RUNNER_DRAIN_COMMAND:-/toolkit:drain-ready-queue}"
SETTINGS="${RUNNER_SETTINGS:-}"
PLUGIN_DIR="${RUNNER_PLUGIN_DIR:-}"
PLUGIN_ROOT=""

STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RUN_ISSUE=""
LOCK=""
LOCK_HELD=0
WORK=""
LOGFILE=""
ITERATION=0
FAILURES=0
ENDING=0
SESSION_SECONDS=0

# --- saying things ------------------------------------------------------------
# Findings go to stderr as they happen *and* into the run log, which is the
# comment the run issue ends with. A headless run reports to nobody watching, so
# a line that only ever reached a terminal did not survive the run.
say() {
  printf '%s\n' "$1" >&2
  [ -n "$LOGFILE" ] && printf '%s\n' "$1" >> "$LOGFILE"
  return 0
}
# Never into the log: used when the log itself is what failed.
gripe()  { printf '%s\n' "$1" >&2; }
refuse() { say "RUNNER-REFUSED: $1"; end_run 2; }

# --- the lock -----------------------------------------------------------------
lock_path() {
  [ -n "${RUNNER_LOCK:-}" ] && { printf '%s\n' "$RUNNER_LOCK"; return 0; }
  local g
  g="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ -n "$g" ] || return 1
  case "$g" in
    /*) ;;
    *) g="$(cd "$g" 2>/dev/null && pwd)" || return 1 ;;
  esac
  printf '%s/drain-runner.lock\n' "$g"
}

lock_pid()     { sed -n 's/^pid \([0-9][0-9]*\)$/\1/p' "$LOCK" 2>/dev/null | head -n 1; }
lock_started() { sed -n 's/^started \(.*\)$/\1/p'      "$LOCK" 2>/dev/null | head -n 1; }
pid_alive()    { ps -p "$1" >/dev/null 2>&1; }

# O_EXCL through noclobber: the whole claim is one atomic create, so two runners
# starting together cannot both believe they won.
lock_claim() {
  ( set -C; printf 'pid %s\nstarted %s\nrepo %s\n' "$$" "$STARTED" "${ROOT:-?}" > "$LOCK" ) 2>/dev/null
}

lock_release() {
  [ "$LOCK_HELD" = 1 ] || return 0
  [ "$(lock_pid)" = "$$" ] || return 0
  rm -f "$LOCK"
  LOCK_HELD=0
  return 0
}

# --- ending -------------------------------------------------------------------
# One exit path. It posts the run log to the run issue and gives the lock back,
# whether the run ended on a stop condition, a cap, or a signal.
end_run() { # <exit-code>
  local code="$1"
  ENDING=1
  post_log
  lock_release
  [ -n "$WORK" ] && rm -rf "$WORK"
  exit "$code"
}

stop_run() { # <reason> — this runner's own stop, as opposed to the gate's
  say "RUNNER-STOP: $1"
  end_run 0
}

post_log() {
  [ -n "$RUN_ISSUE" ] || return 0
  [ -n "$LOGFILE" ] && [ -s "$LOGFILE" ] || return 0
  local body="$WORK/comment.md"
  {
    printf '## Runner stop\n\n'
    printf 'Started %s, ended %s (UTC). %s iteration(s).\n\n' \
      "$STARTED" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ITERATION"
    printf 'Every line this run produced, in order:\n\n```\n'
    cat "$LOGFILE"
    printf '```\n'
  } > "$body" 2>/dev/null || {
    gripe "RUNNER-POST-FAILED: the run log could not be assembled; #$RUN_ISSUE has no stop reason"
    return 0
  }
  bash "$here/run-issue-post.sh" "$RUN_ISSUE" "$body" >/dev/null || {
    gripe "RUNNER-POST-FAILED: the stop reason did not reach #$RUN_ISSUE — the lines above are the only record"
    return 0
  }
  return 0
}

on_signal() {
  [ "$ENDING" = 1 ] && exit 1
  say "RUNNER-STOP: interrupted by a signal after $ITERATION iteration(s)"
  end_run 1
}
on_exit() { lock_release; [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }

# **The honest limit of that trap.** Bash runs a trap only once the foreground
# command returns, so a TERM sent while a session is running is not acted on
# until that session ends — up to $RUNNER_ITERATION_TIMEOUT away. To stop a run
# sooner, signal the runner's process group (`kill -TERM -<pid>`), which reaches
# the session too. The lock is still released either way: the trap runs before
# the exit, and a runner killed outright leaves a lockfile whose pid is dead,
# which the next runner reads as stale and claims.

# --- lock-status --------------------------------------------------------------
# No tool preflight: reading a lock needs neither `timeout` nor `claude`, and the
# attended drain that asks this question may have neither installed.
lock_status() {
  LOCK="$(lock_path)" || {
    echo "RUNNER-UNKNOWN: not a git repository, so this repo's runner lock has no path" >&2
    exit 1
  }
  [ -f "$LOCK" ] || { echo "RUNNER-LOCK-FREE: no headless run holds $LOCK" >&2; exit 0; }
  local p
  p="$(lock_pid)"
  if [ -z "$p" ]; then
    echo "RUNNER-LOCK-HELD: $LOCK exists but names no pid — unreadable, so treated as held. The PM removes it" >&2
    exit 1
  fi
  if pid_alive "$p"; then
    # The caller's own run, or a stranger's. Only a live holder can be "mine":
    # a matching identity against a dead pid is still stale, and one against no
    # lockfile is still free, because both cases returned above.
    if [ "${RUNNER_PID:-}" = "$p" ]; then
      echo "RUNNER-LOCK-SELF: pid $p has held $LOCK since $(lock_started), and it is this session's own runner — not a second orchestrator, so the cycle runs" >&2
      exit 0
    fi
    echo "RUNNER-LOCK-HELD: pid $p has held $LOCK since $(lock_started) — a headless drain run is live in this repo" >&2
    exit 1
  fi
  echo "RUNNER-LOCK-STALE: $LOCK records pid $p, which is gone — a runner died holding it. The next runner claims it" >&2
  exit 0
}

case "${1:-run}" in
  run) [ $# -le 1 ] || { echo "RUNNER-REFUSED: usage: runner.sh [run|lock-status]" >&2; exit 2; } ;;
  lock-status) lock_status ;;
  *) echo "RUNNER-REFUSED: usage: runner.sh [run|lock-status]" >&2; exit 2 ;;
esac

# --- preflight ----------------------------------------------------------------
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || ROOT=""
[ -n "$ROOT" ] || { echo "RUNNER-REFUSED: not a git repository — a run is scoped to one repo and locked in its git directory" >&2; exit 2; }

# `timeout` first and alone in its own check, because it is the one tool here
# that a machine can plausibly lack: coreutils is a Homebrew install on macOS,
# and without it there is no per-iteration kill, which means a hung session
# holds the lock forever.
TIMEOUT_BIN=""
for t in timeout gtimeout; do
  command -v "$t" >/dev/null 2>&1 && { TIMEOUT_BIN="$t"; break; }
done
[ -n "$TIMEOUT_BIN" ] || {
  echo "RUNNER-REFUSED: timeout is not on PATH (nor gtimeout) — it is Homebrew coreutils on macOS, not a system tool, and without it a hung session holds the lock with no cap able to fire. brew install coreutils" >&2
  exit 2
}

missing=""
for c in "$CLAUDE_BIN" gh jq; do
  command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
done
[ -z "$missing" ] || {
  echo "RUNNER-REFUSED: not on PATH:$missing — a headless run cannot start a session or read the blackboard without them" >&2
  exit 2
}

for n in "$SLEEP_SECONDS" "$MAX_ITERATIONS" "$MAX_FAILURES" "$ITERATION_TIMEOUT" "$KILL_AFTER"; do
  case "$n" in
    ''|*[!0-9]*)
      echo "RUNNER-REFUSED: '$n' is not a whole number of seconds or iterations — one unreadable bound is one brake that cannot fire" >&2
      exit 2 ;;
  esac
done
[ "$MAX_ITERATIONS" -gt 0 ] || { echo "RUNNER-REFUSED: RUNNER_MAX_ITERATIONS is 0 — a run with no iterations in it" >&2; exit 2; }
[ "$MAX_FAILURES" -gt 0 ] || { echo "RUNNER-REFUSED: RUNNER_MAX_FAILURES is 0 — the failure cap would fire before the first session" >&2; exit 2; }

# No session starts without a permission profile. Empty RUNNER_SETTINGS resolves
# to the one shipped beside this script — the same directory this script already
# resolves runner-gate.sh from — and a profile that resolves to nothing is a
# refusal rather than a fallback, because the fallback is the operator's own
# interactive default mode and the allowlist would be decorative.
#
# Then, whichever profile resolved: a settings file that fails validation is
# silently ignored by `claude -p`, and the run goes all night under that same
# default mode. Parsing it here is the whole guard against that.
#
# Both checks are ahead of the lock and the working directory, so a refusal
# leaves no lockfile behind and starts nothing.
DEFAULT_SETTINGS="$here/headless-profile.json"
[ -n "$SETTINGS" ] || SETTINGS="$DEFAULT_SETTINGS"
if [ ! -f "$SETTINGS" ]; then
  if [ "$SETTINGS" = "$DEFAULT_SETTINGS" ]; then
    echo "RUNNER-REFUSED: no permission profile — RUNNER_SETTINGS is unset and the shipped default $SETTINGS is missing. An unattended session with no profile runs under the operator's own default permission mode, so the run is refused instead. Restore the shipped profile, or point RUNNER_SETTINGS at one" >&2
  else
    echo "RUNNER-REFUSED: no such settings profile: $SETTINGS" >&2
  fi
  exit 2
fi
jq empty "$SETTINGS" >/dev/null 2>&1 || {
  echo "RUNNER-REFUSED: $SETTINGS is not valid JSON — \`claude -p\` ignores an invalid profile silently, so the run would go unattended under the user's own permission mode" >&2
  exit 2
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/drain-runner.XXXXXX")" || {
  echo "RUNNER-REFUSED: cannot create a working directory for the run log" >&2
  exit 2
}
LOGFILE="$WORK/run-log.txt"
: > "$LOGFILE"

trap on_signal INT TERM
trap on_exit EXIT

# --- the plugin tree, in scope for Bash -----------------------------------------
# `--add-dir` is not a `RUNNER_PLUGIN_DIR` accessory: without it, a session's
# `Bash(grep:*)`-shaped rules are denied against paths inside the installed
# plugin, because a prefix rule carries an implicit workspace scope (measured,
# docs/research/2026-08-25-headless-permission-profile.md). So the flag is
# resolved on every run, and the bare start command in the header gets it too.
#
# The root is three directories up from this script — <root>/skills/<skill>/
# scripts/runner.sh — and the manifest is the witness that the answer is a
# plugin and not whatever happened to be three levels above a loose copy.
# Not resolving is a findings line rather than a refusal: the `Read` tool still
# reaches the tree, so the run is degraded and not impossible. Said after the
# log exists, so the reason reaches the run issue instead of only a terminal.
if [ -n "$PLUGIN_DIR" ]; then
  PLUGIN_ROOT="$PLUGIN_DIR"
else
  PLUGIN_ROOT="$(cd "$here/../../.." 2>/dev/null && pwd)" || PLUGIN_ROOT=""
  [ -n "$PLUGIN_ROOT" ] && [ -f "$PLUGIN_ROOT/.claude-plugin/plugin.json" ] || PLUGIN_ROOT=""
fi
[ -n "$PLUGIN_ROOT" ] || say "RUNNER-NO-PLUGIN-ROOT: no plugin root three directories above $here carries .claude-plugin/plugin.json, so no --add-dir is passed and Bash reads of the plugin tree will be denied. The Read tool still reaches it. Set RUNNER_PLUGIN_DIR to name the snapshot"

# --- the lock -----------------------------------------------------------------
LOCK="$(lock_path)" || refuse "this repo's git directory could not be resolved, so the run lock has no home"

if lock_claim; then
  LOCK_HELD=1
else
  holder="$(lock_pid)"
  if [ -z "$holder" ]; then
    refuse "the run lock $LOCK is held and names no pid — an unreadable lock is never stolen. The PM removes it"
  elif pid_alive "$holder"; then
    refuse "the run lock $LOCK is held by live pid $holder (since $(lock_started)) — a headless run is already draining this repo"
  fi
  say "RUNNER-LOCK-STALE: $LOCK recorded pid $holder, which is gone — claiming it"
  rm -f "$LOCK"
  lock_claim || refuse "the run lock $LOCK was taken by another runner while this one cleared the stale claim"
  LOCK_HELD=1
fi
say "RUNNER-LOCK: pid $$ holds $LOCK for this run"

# --- the gate, before anything is opened --------------------------------------
GATE_ERR=""
# The gate's stdout is the dispatchable candidate list, which this runner has no
# use for: the session picks its own ticket through the same pick.sh. Discarded
# rather than passed through, so a headless run's log holds report lines and not
# a JSON array per iteration. The exit code is the whole signal, and the gate's
# stderr — RUNNER-CONTINUE, RUNNER-STOP, every finding — is relayed verbatim.

# The gate's candidate exclusion reads remote-tracking refs, and those are only
# as fresh as the last fetch — so every gate call gets one first. `--prune` is
# load-bearing: without it a branch deleted on the host stays in `refs/remotes`
# forever and the exclusion reads a trace that is not there. A failed fetch is a
# findings line and the run carries on: the gate's own `gh` reads fail closed
# into RUNNER-UNKNOWN when the network is really gone, so stopping here would
# only duplicate that with less information.
fetch_refs() {
  local code msg
  git fetch --prune origin >/dev/null 2>"$WORK/fetch.err"
  code=$?
  [ "$code" = 0 ] && return 0
  msg="$(head -n 1 "$WORK/fetch.err" 2>/dev/null)"
  say "RUNNER-FETCH-FAILED: git fetch --prune origin exited $code${msg:+ — $msg}. Remote-tracking refs are as stale as the last fetch, so the gate may read a branch that is gone or miss one that is new"
  return 0
}

run_gate() { # start | next <since>
  local code
  fetch_refs
  bash "$here/runner-gate.sh" "$@" >/dev/null 2>"$WORK/gate.err"
  code=$?
  GATE_ERR="$(cat "$WORK/gate.err" 2>/dev/null)"
  [ -n "$GATE_ERR" ] && say "$GATE_ERR"
  return $code
}

run_gate start
gate_code=$?
case $gate_code in
  0) ;;
  1) end_run 0 ;;   # the gate's own RUNNER-STOP is already said and logged
  2) end_run 2 ;;
  *) end_run 3 ;;
esac

# --- the run issue ------------------------------------------------------------
# Opened only once the gate has agreed there is a run to have. An issue opened
# ahead of a refusal would be a run issue for a run that never happened, and the
# next runner would refuse until the PM closed it.
RUN_ISSUE="$(bash "$here/run-issue-open.sh" 2>"$WORK/open.err")"
open_code=$?
open_err="$(cat "$WORK/open.err" 2>/dev/null)"
[ -n "$open_err" ] && say "$open_err"
if [ "$open_code" != 0 ] || [ -z "$RUN_ISSUE" ]; then
  RUN_ISSUE=""
  refuse "no run issue was opened, so this run has nowhere to report — a headless run with no log is not a run"
fi
say "RUNNER-RUN: #$RUN_ISSUE, started $STARTED, sleep ${SLEEP_SECONDS}s, cap $MAX_ITERATIONS, timeout ${ITERATION_TIMEOUT}s, failures $MAX_FAILURES"

# --- one iteration ------------------------------------------------------------
# The brief adds exactly two facts to the attended form: one iteration then
# exit, and the run issue's number. Everything else — the rails, the briefs, the
# verdict, the merge decision — is the doctrine the skill already carries, and a
# fact restated here would be a second copy of it, free to drift.
#
# It also times itself. The clock is read either side of the session call and
# nowhere else, so SESSION_SECONDS is the session's own wall clock and carries
# none of the gate, the fetch or the sleep around it — including on the timeout
# path, where `timeout` returns only once the killed group is gone and the
# elapsed time therefore covers the TERM-to-KILL grace as well. Whole seconds
# from `date +%s`: a run log is read to size a 2700-second bound, and no finer
# unit changes that answer. A clock that steps backwards mid-session would give
# a negative, which is not a duration and would break the `after <n>s` shape the
# three lines promise, so it floors at 0.
run_session() {
  local prompt started code
  prompt="$DRAIN_COMMAND

Run exactly one iteration, then exit.

This is a headless run. Its run issue is #$RUN_ISSUE."

  set -- "$TIMEOUT_BIN" --kill-after="$KILL_AFTER" "$ITERATION_TIMEOUT" "$CLAUDE_BIN" -p
  if [ -n "$PLUGIN_DIR" ]; then
    set -- "$@" --plugin-dir "$PLUGIN_DIR" --setting-sources project
  fi
  # Exactly one --add-dir, whichever way the root resolved above — a second copy
  # of the same path would be the drift the resolution exists to prevent.
  if [ -n "$PLUGIN_ROOT" ]; then
    set -- "$@" --add-dir "$PLUGIN_ROOT"
  fi
  # Unconditional: the preflight refused already if no profile resolved, so
  # there is no run in which this flag is absent.
  set -- "$@" --settings "$SETTINGS"
  set -- "$@" "$prompt"
  started="$(date +%s)"
  # The one fact the session gets outside its brief, and it stays out of the
  # brief on purpose. `lock-status` compares it with the lockfile itself, so no
  # session ever reads two pids and decides which one is its own. Scoped to this
  # command, so nothing else the runner shells out to carries an identity it has
  # no use for.
  RUNNER_PID=$$ "$@" < /dev/null
  code=$?
  SESSION_SECONDS=$(( $(date +%s) - started ))
  [ "$SESSION_SECONDS" -ge 0 ] || SESSION_SECONDS=0
  return $code
}

count_failure() { # <line>
  FAILURES=$((FAILURES + 1))
  say "$1 ($FAILURES consecutive failure(s), cap $MAX_FAILURES)"
  if [ "$FAILURES" -ge "$MAX_FAILURES" ]; then
    say "RUNNER-STOP: $FAILURES consecutive failure(s), at the cap of $MAX_FAILURES — that is a broken environment, not a drained queue"
    end_run 1
  fi
  return 0
}

# --- the loop -----------------------------------------------------------------
while :; do
  ITERATION=$((ITERATION + 1))
  say "RUNNER-ITERATION: $ITERATION of at most $MAX_ITERATIONS"

  # Stamped before the session, in the gate's own timestamp shape: every trace
  # the session leaves on the blackboard is then dated after it.
  CYCLE_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  CYCLE_ARG=""
  run_session
  session_code=$?
  case $session_code in
    0)
      FAILURES=0
      CYCLE_ARG="$CYCLE_START"
      say "RUNNER-SESSION: iteration $ITERATION exited 0 after ${SESSION_SECONDS}s" ;;
    124|137)
      count_failure "RUNNER-SESSION-TIMEOUT: iteration $ITERATION ran past ${ITERATION_TIMEOUT}s and its process group was killed after ${SESSION_SECONDS}s" ;;
    *)
      count_failure "RUNNER-SESSION-FAILED: iteration $ITERATION exited $session_code after ${SESSION_SECONDS}s" ;;
  esac

  if [ "$ITERATION" -ge "$MAX_ITERATIONS" ]; then
    stop_run "the iteration cap of $MAX_ITERATIONS is reached — a belt, and no statement about the queue"
  fi

  # The gate between iterations, retried while it can only say "unknown": a
  # read that failed is a failure and counts as one, never a drained queue.
  while :; do
    [ "$SLEEP_SECONDS" -gt 0 ] && sleep "$SLEEP_SECONDS"
    run_gate next "$STARTED" ${CYCLE_ARG:+"$CYCLE_ARG"}
    gate_code=$?
    case $gate_code in
      0) break ;;
      1) end_run 0 ;;
      2) end_run 2 ;;
      *) count_failure "RUNNER-GATE-UNKNOWN: the gate could not establish whether another iteration may run" ;;
    esac
  done
done
