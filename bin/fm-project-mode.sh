#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md section 7).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh (refuse local-only seeding, run no-mistakes init), and
# bin/fm-spawn.sh's advisory registry-deviation notice.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (default)
#   direct-PR              push + PR via gh-axi, no pipeline
#   local-only             local branch, no remote/PR, guarded local merge
#   no-mistakes-prod-only  a conditional policy, not a task mode: firstmate
#                          classifies each task's surface at intake (the
#                          project-management skill owns that classification).
#                          Mechanical output maps it to its most rigorous leg,
#                          no-mistakes, so sync, seeding, and init treat such a
#                          project as the remote-backed pipeline project it is.
# yolo (orthogonal) = merge authority only: when on, firstmate merges green,
#   in-scope work itself (AGENTS.md section 7).
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
# --strict requires a safe registry and exactly one valid matching entry instead
# of applying the advisory fallback behavior.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr, so a typo never silently drops the gate.
# Usage: fm-project-mode.sh [--raw] [--strict] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
STRICT=0
while [ "$#" -gt 0 ]; do
  case "$1" in
  --raw) RAW=1; shift ;;
  --strict) STRICT=1; shift ;;
  --*) echo "error: unknown option: $1" >&2; exit 2 ;;
  *) break ;;
  esac
done
NAME=${1:?usage: fm-project-mode.sh [--raw] [--strict] <project-name>}
[ "$#" -eq 1 ] || {
  echo "error: usage: fm-project-mode.sh [--raw] [--strict] <project-name>" >&2
  exit 2
}

if [ "$STRICT" -eq 1 ]; then
  # shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
  if ! fm_backlog_record_present "$REG" "project registry" "$DATA"; then
    echo "error: $FM_BACKLOG_TRANSITION_ERROR" >&2
    exit 1
  fi
elif [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

# awk emits "<count> <valid> <mode> <yolo>" or nothing if the project is absent.
# The mode and yolo fields always come from the first match, preserving the
# established advisory behavior when strict validation is not requested.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    count++;
    if (count == 1) {
      mode="no-mistakes"; yolo="off"; valid=0;
      if ($3 ~ /^\[/) {
        s=""; close_at=0;
        for (i=3; i<=NF; i++) {
          s = s (s==""?"":" ") $i;
          if ($i ~ /\]$/) { close_at=i; break }
        }
        if (s ~ /^\[(no-mistakes|direct-PR|local-only|no-mistakes-prod-only)( \+yolo)?\]$/ &&
            close_at > 0 && close_at + 1 < NF && $(close_at + 1) == "-") valid=1;
        gsub(/^\[|\]$/, "", s);
        k = split(s, a, " ");
        if (a[1] != "" && a[1] != "+yolo") mode = a[1];
        for (j=1; j<=k; j++) if (a[j]=="+yolo") yolo="on";
      } else if ($3 == "-" && NF > 3) valid=1;
    }
  }
  END { if (count > 0) print count, valid, mode, yolo }
' "$REG")

if [ -z "$parsed" ]; then
  if [ "$STRICT" -eq 1 ]; then
    echo "error: project \"$NAME\" is not registered in $REG" >&2
    exit 1
  fi
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

count=${parsed%% *}
parsed=${parsed#* }
valid=${parsed%% *}
parsed=${parsed#* }
mode=${parsed%% *}
yolo=${parsed##* }
if [ "$STRICT" -eq 1 ] && [ "$count" -ne 1 ]; then
  echo "error: project \"$NAME\" has $count registry entries in $REG; expected exactly one" >&2
  exit 1
fi
if [ "$STRICT" -eq 1 ] && [ "$valid" -ne 1 ]; then
  echo "error: project \"$NAME\" has a malformed registry entry in $REG; expected one valid mode with optional +yolo" >&2
  exit 1
fi
case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *)
    if [ "$STRICT" -eq 1 ]; then
      echo "error: unknown mode \"$mode\" for $NAME in $REG" >&2
      exit 1
    fi
    echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2
    mode=no-mistakes
    yolo=off
    ;;
esac
case "$yolo" in
on|off) ;;
*)
  if [ "$STRICT" -eq 1 ]; then
    echo "error: unknown yolo posture \"$yolo\" for $NAME in $REG" >&2
    exit 1
  fi
  yolo=off
  ;;
esac
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
echo "$mode $yolo"
