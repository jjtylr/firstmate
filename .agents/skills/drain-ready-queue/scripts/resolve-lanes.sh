#!/bin/bash
# resolve-lanes.sh — the drain's concurrent capacity, resolved from the repo's
# `max_lanes` together with its `merge_policy`. No arguments.
#
#   stdout   the lane count in force: 1, 2 or 3, on a line of its own and
#            nothing else, so `lanes=$(resolve-lanes.sh)` is the whole call.
#   stderr   at most one LANES-FALLBACK line, when the count in force is not
#            what the config asked for.
#   exit 0   always. There is no unreadable case: every reading this script
#            cannot use resolves to 1, which is the loop's behaviour today, so
#            a caller never has to decide what an error means.
#
# **Legal vocabulary `{1, 2, 3}`, and everything else reads as 1.** Absent key,
# `0`, `4`, text, an unreadable config — each resolves to single-lane and names
# the raw value it saw. Same fail-safe pattern as an unknown `merge_policy`
# (MERGE-POLICY.md): a config typo degrades to today's serial drain, never to
# uncontrolled parallelism.
#
# **Above 1 requires an auto merge policy.** Under `pm-merge` the merge point
# has no loop-side machinery at all, so the serialized merge pipeline that makes
# parallel lanes safe cannot run there; `2` or `3` under it resolves to 1 with
# the policy-conflict line. Whether a name is an auto policy is asked of
# merge-decision.sh — the catalog's executor — rather than kept as a second copy
# of the list here, and it is read from that script's **policy findings line**,
# never its exit code: the button refuses for several reasons at once, and only
# one of them answers the question asked here. Silence from it resolves to 1.
#
# The vocabulary is checked **first**, so a value that is both illegal and under
# `pm-merge` prints one line, not two: at 1 lane there is no conflict left to
# report.
#
# The findings lines, all of them:
#
#   LANES-FALLBACK: no loop config at <path> — max_lanes cannot be read; reading as 1 (single-lane)
#   LANES-FALLBACK: no max_lanes in <path>; reading as 1 (single-lane)
#   LANES-FALLBACK: max_lanes is '<raw>', outside the legal {1, 2, 3}; reading as 1 (single-lane)
#   LANES-FALLBACK: max_lanes is <n> but no merge_policy in <path>, which reads as pm-merge — parallel lanes need an auto policy; reading as 1 (single-lane)
#   LANES-FALLBACK: max_lanes is <n> but merge_policy is '<name>', not an auto policy the catalog carries — parallel lanes need the serialized merge pipeline an auto policy runs; reading as 1 (single-lane)
#   LANES-FALLBACK: max_lanes is <n> but the merge decision script did not answer whether '<name>' is an auto policy — an unread policy is never an auto one; reading as 1 (single-lane)
#   LANES-FALLBACK: usage: resolve-lanes.sh takes no arguments — it reads max_lanes and merge_policy from the loop config; reading as 1 (single-lane)
#
# They go to **stderr** because stdout is the number a caller reads, the same
# split runner-gate.sh makes for its JSON.
#
# Environment: $LOOP_CONFIG relocates docs/agents/loop.md, as it does for
# runner-gate.sh.
set -u

here="$(cd "$(dirname "$0")" && pwd)"

# Resolve to single-lane, say why once, and leave. Every exit but the clean one
# comes through here, which is what holds "at most one findings line".
fallback() {
  echo "LANES-FALLBACK: $1; reading as 1 (single-lane)" >&2
  echo 1
  exit 0
}

[ $# -eq 0 ] || fallback "usage: resolve-lanes.sh takes no arguments — it reads max_lanes and merge_policy from the loop config"

# --- the config ---------------------------------------------------------------
# One value out of one `## key` section: the first backtick-opened line of its
# own paragraph. Same shape runner-gate.sh reads, because it is the shape the
# setup skill's LOOP-TEMPLATE.md writes — the blank line before the value is
# what tells it apart from a prose line that happens to wrap onto a backticked
# policy name.
. "$here/repo-root-lib.sh"
config="${LOOP_CONFIG:-}"
if [ -z "$config" ]; then
  root="$(repo_main_root)" || root=""
  [ -z "$root" ] || config="$root/docs/agents/loop.md"
fi

[ -n "$config" ] && [ -f "$config" ] \
  || fallback "no loop config at ${config:-docs/agents/loop.md} — max_lanes cannot be read"

config_value() { # <key>
  awk -v key="$1" '
    /^## / {
      if (sect) exit
      h = substr($0, 4); sub(/[ \t\r]+$/, "", h)
      if (h == key) { sect = 1; blank = 1 }
      next
    }
    sect {
      if ($0 ~ /^[ \t\r]*$/) { blank = 1; next }
      if (blank && substr($0, 1, 1) == "`") {
        v = substr($0, 2); i = index(v, "`")
        if (i > 1) { print substr(v, 1, i - 1); exit }
      }
      blank = 0
    }' "$config"
}

# --- the vocabulary -----------------------------------------------------------
raw="$(config_value max_lanes)"

[ -n "$raw" ] || fallback "no max_lanes in $config"

case "$raw" in
  1) echo 1; exit 0 ;;
  2|3) ;;
  *) fallback "max_lanes is '$raw', outside the legal {1, 2, 3}" ;;
esac

# --- the policy, for a value above 1 ------------------------------------------
policy="$(config_value merge_policy)"

[ -n "$policy" ] \
  || fallback "max_lanes is $raw but no merge_policy in $config, which reads as pm-merge — parallel lanes need an auto policy"

case "$(bash "$here/merge-decision.sh" pass CHECKS-PASS "$policy" 2>/dev/null)" in
  *'is not an auto policy the catalog carries'*)
    fallback "max_lanes is $raw but merge_policy is '$policy', not an auto policy the catalog carries — parallel lanes need the serialized merge pipeline an auto policy runs" ;;
  MERGE-ALLOWED*|MERGE-REFUSED:*)
    : ;;  # the button answered, and the name was not the thing it objected to
  *)
    fallback "max_lanes is $raw but the merge decision script did not answer whether '$policy' is an auto policy — an unread policy is never an auto one" ;;
esac

echo "$raw"
