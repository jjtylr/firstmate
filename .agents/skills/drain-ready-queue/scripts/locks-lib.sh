#!/bin/bash
# locks-lib.sh — the repo's `global_locks` table and the two resolutions its
# readers need. **Sourced, never run**: it has no arguments, prints nothing of
# its own, and exits nothing.
#
#   . "$(dirname "$0")/locks-lib.sh"
#   locks_load || <the caller's own unreadable-config finding>
#
# Two scripts ask the same question of the table — `check-holds.sh`, of the
# locks a candidate declares and the locks an open PR's files match; and
# `check-declared-locks.sh`, of the locks the merged file list matched against
# what the ticket declared. A second copy of the glob match would read fine and
# drift silently, and the two answers disagreeing is exactly the state that
# declared-versus-measured comparison exists to detect. So there is one copy,
# here.
#
# What it provides, and what each answers with:
#
#   locks_load [<config>]     reads the table. Sets $LOCKS_CONFIG to the path
#                             it used and $LOCKS_TABLE to one
#                             `<name><TAB><glob>` line per glob, in table order,
#                             lowercased whole. Returns 1 without setting
#                             anything when there is no readable config — the
#                             caller owns what an unreadable table means,
#                             because the two callers word it differently.
#   norm_list <declaration>   a comma-separated declaration in, one trimmed
#                             lowercase name per line out. `-`, `none` and `n/a`
#                             are the written forms of "declares none" and drop
#                             out here, so every reader downstream sees an empty
#                             list for all three.
#   path_locks <path>         every global lock whose glob matches that path, one
#                             per line. Lowercase the path first — `lower` is
#                             here for it.
#   lower <string>            lowercased.
#
# **Everything is lowercased** — names, globs, and the paths matched against
# them. The comparison this table is read for is case-insensitive, and
# `AGENTS.md` and `CLAUDE.md` would otherwise miss their shared row.
#
# The honest bound: a measured path containing a space is split on it by every
# caller, so such a path matches no glob. That is fail-safe in both callers — an
# unmatched path holds no lock it could have hidden — and no path in this fleet
# has one yet.
set -u

TAB="$(printf '\t')"

lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

LOCKS_CONFIG=""
LOCKS_TABLE=""

# One `<name>\t<glob>` line per glob, in table order. A row's cells are read
# from their backticks, which is what skips the header and the `|---|` rule
# without having to count rows. A row-less table prints nothing, and every name
# then fails to resolve — the no-locks-registered behaviour the config's own
# prose promises, reached through the normal path rather than a special case.
_read_table() { # <config> <section>
  awk -v key="$2" '
    /^## / { sect = (substr($0, 4) ~ ("^" key "[ \t\r]*$")) ? 1 : 0; next }
    sect && substr($0, 1, 1) == "|" {
      cells = split($0, f, "|")
      if (cells < 3) next
      if (match(f[2], /`[^`]+`/) == 0) next
      name = substr(f[2], RSTART + 1, RLENGTH - 2)
      rest = f[3]
      while (match(rest, /`[^`]+`/) > 0) {
        print name "\t" substr(rest, RSTART + 1, RLENGTH - 2)
        rest = substr(rest, RSTART + RLENGTH)
      }
    }' "$1"
}

. "$(dirname "${BASH_SOURCE[0]}")/repo-root-lib.sh"

# $LOOP_CONFIG relocates docs/agents/loop.md, the same seam resolve-lanes.sh
# reads. An explicit argument beats it, for a caller that already resolved one.
locks_load() { # [<config path>]
  local config="${1:-}" root
  if [ -z "$config" ]; then
    config="${LOOP_CONFIG:-}"
  fi
  if [ -z "$config" ]; then
    root="$(repo_main_root)" || root=""
    [ -z "$root" ] || config="$root/docs/agents/loop.md"
  fi
  [ -n "$config" ] && [ -f "$config" ] || { LOCKS_CONFIG="${config:-docs/agents/loop.md}"; return 1; }
  LOCKS_CONFIG="$config"
  LOCKS_TABLE="$(_read_table "$config" global_locks | tr 'A-Z' 'a-z')"
  return 0
}

norm_list() { # <declaration>
  printf '%s\n' "$1" \
    | tr 'A-Z' 'a-z' | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -v '^$' | grep -vx -e '-' -e 'none' -e 'n/a'
}

# The glob is deliberately unquoted in the case — it is a pattern, not a string.
path_locks() { # <lowercased-path>
  local path="$1" name glob
  printf '%s\n' "$LOCKS_TABLE" | while IFS="$TAB" read -r name glob; do
    [ -n "$name" ] && [ -n "$glob" ] || continue
    case "$path" in $glob) printf '%s\n' "$name" ;; esac
  done
}
