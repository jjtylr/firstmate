#!/usr/bin/env bash
# The fleet queue: the ordered question list a fleet sitting works. Reads only.
#
#   fleet-queue.sh <fleet-root> <repo>=<path> ...
#
# Reads docs/fleet-atlas/ at the fleet root and the attached checkouts, and
# prints one GAP line per finding. This is the advisory half of the gate/queue
# split: check-fleet.sh gates the facts the fleet atlas and the attached
# atlases settle together as documents, and everything that measures another
# repo's progress or asks for a judgment is here. **No finding here can ever
# fail a landing.**
#
# Four classes, printed in this order, biggest question first:
#
#   stale-contract     a contract side pinned below the contract's current
#                      Revision. One line per side, naming the shared area,
#                      the repo, the head, the pin and the current revision.
#                      The plane turns it into an issue on the lagging repo.
#                      An uncharted head pins nothing and is never stale; a
#                      pin above the revision is the gate's finding and is
#                      not stale here
#   cross-repo-cycle   a cycle in who consumes whom. Every implementation
#                      draws one edge from each side's repo to its Owner, and
#                      a contract draws nothing. One line per distinct cycle,
#                      its repos in byte order joined by `, `; two cycles over
#                      the same repos print once. Lines sorted. A cycle is a
#                      question for the sitting, not a defect
#   uncharted-side     a side whose head is `<repo>:uncharted`, or whose head
#                      is `<repo>:<key>` and the repo's checkout has no
#                      docs/atlas/. One line per side, naming the shared area
#                      and the head. A whole-repo head is never here: it
#                      carries a pin, so the repo implements it as it stands
#   fog                an index Fog bullet, one line each, unadorned. Last,
#                      and with no age on it
#
# The same arguments and the same usage errors as check-fleet.sh: every repo
# the index's Repos line names takes one <repo>=<path> argument. The queue
# does not re-run the gate. A line it cannot read, a side outside the
# grammar, a Revision that is not an integer, is skipped in silence; the gate
# names it.
#
# Exit codes:
#
#   exit 0   always, findings or none. It is a report, never a gate
#   exit 1   <fleet-root> has no docs/fleet-atlas/, or no index.md in it
#   exit 2   a usage error, one line on stderr and nothing on stdout: a repo
#            in Repos with no path, a path for a repo not in Repos, an
#            argument without `=`, a path that is not a directory, or a repo
#            given twice
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/atlas-lib.sh"

ME="$(basename "$0")"
[ "$#" -ge 1 ] || { echo "usage: $ME <fleet-root> <repo>=<path> ..." >&2; exit 2; }

ROOT="$1"
shift
FLEET="$ROOT/docs/fleet-atlas"
INDEX="$FLEET/index.md"

[ -d "$FLEET" ] || { echo "no fleet atlas at $FLEET" >&2; exit 1; }
[ -f "$INDEX" ] || { echo "no fleet atlas index at $INDEX" >&2; exit 1; }

SEP="$(printf '\037')"

gap() { printf 'GAP %s: %s\n' "$1" "$2"; }

# The repo set is the well-formed entries of the Repos line, as the gate reads
# it. The arguments are checked against it before anything is printed.
REPOS=
while IFS= read -r ENTRY; do
  [ -n "$ENTRY" ] || continue
  atlas_is_key "$ENTRY" || continue
  case "$REPOS" in *" $ENTRY "*) continue ;; esac
  REPOS="${REPOS:- }$ENTRY "
done < <(atlas_fleet_repos "$INDEX")

atlas_fleet_checkouts "$ME" "$REPOS" "$@" || exit $?

# --- the sides, read once ----------------------------------------------------
# One line per side that parses, in key order and then bullet order: the
# key, the kind, the contract's Revision or the implementation's Owner, the
# repo, the side key, the pin and the head, separated by a byte no field can
# hold (a tab would collapse an empty pin when read back). Every class below
# reads this stream, so the three cannot disagree about what a side is.
SIDES=
for KEY in $(atlas_keys "$FLEET"); do
  F="$FLEET/$KEY.md"
  KIND="$(atlas_header_value "$F" 'Kind')"
  case "$KIND" in
    contract)       WITH="$(atlas_header_value "$F" 'Revision')" ;;
    implementation) WITH="$(atlas_header_value "$F" 'Owner')" ;;
    *) continue ;;
  esac
  while IFS= read -r SPEC; do
    [ -n "$SPEC" ] || continue
    atlas_parse_side "$SPEC" || continue
    SIDES="$SIDES$KEY$SEP$KIND$SEP$WITH$SEP$ATLAS_SIDE_REPO$SEP$ATLAS_SIDE_KEY$SEP$ATLAS_SIDE_PIN$SEP$ATLAS_SIDE_HEAD
"
  done < <(atlas_sides_of "$F")
done

# --- stale-contract ----------------------------------------------------------
printf '%s' "$SIDES" | awk -F "$SEP" '
  $2 == "contract" && $3 ~ /^[1-9][0-9]*$/ && $5 != "uncharted" && $6 != "" && ($6 + 0) < ($3 + 0) {
    printf "GAP stale-contract: %s.md: side %s in %s is pinned at @%s below Revision %s\n", $1, "\047" $7 "\047", $4, $6, $3
  }
'

# --- cross-repo-cycle --------------------------------------------------------
# The repo graph: one edge per implementation side, from the side's repo to
# the owner, kept once. A depth-first walk from each repo in byte order over
# repos that sort after it finds every elementary cycle once, with the start
# repo as its smallest member; the cycle's repos are then sorted and the
# line deduplicated, so two cycles over one repo set print once.
printf '%s' "$SIDES" | awk -F "$SEP" '
  $2 == "implementation" && $3 ~ /^[a-z0-9][a-z0-9-]*$/ && $4 != $3 { print $4 "\t" $3 }
' | LC_ALL=C sort -u | awk -F'\t' '
  function walk(u,    i, v) {
    for (i = 1; i <= n; i++) {
      v = nodes[i]
      if (!((u SUBSEP v) in edge)) continue
      if (v == s) { emit(); continue }
      if (v < s || onpath[v]) continue
      onpath[v] = 1; path[++len] = v
      walk(v)
      onpath[v] = 0; len--
    }
  }
  function emit(    i, j, t, out) {
    for (i = 1; i <= len; i++) sorted[i] = path[i]
    for (i = 2; i <= len; i++) {
      t = sorted[i]
      for (j = i - 1; j >= 1 && sorted[j] > t; j--) sorted[j + 1] = sorted[j]
      sorted[j + 1] = t
    }
    out = sorted[1]
    for (i = 2; i <= len; i++) out = out ", " sorted[i]
    print out
  }
  {
    edge[$1, $2] = 1
    if (!($1 in seen)) { seen[$1] = 1; nodes[++n] = $1 }
    if (!($2 in seen)) { seen[$2] = 1; nodes[++n] = $2 }
  }
  END {
    for (i = 2; i <= n; i++) {
      t = nodes[i]
      for (j = i - 1; j >= 1 && nodes[j] > t; j--) nodes[j + 1] = nodes[j]
      nodes[j + 1] = t
    }
    for (i = 1; i <= n; i++) {
      s = nodes[i]
      len = 1; path[1] = s; onpath[s] = 1
      walk(s)
      onpath[s] = 0
    }
  }
' | LC_ALL=C sort -u | sed 's/^/GAP cross-repo-cycle: /'

# --- uncharted-side ----------------------------------------------------------
printf '%s' "$SIDES" | while IFS="$SEP" read -r KEY KIND WITH REPO SKEY PIN HEAD; do
  [ -n "$KEY" ] || continue
  if [ "$SKEY" = "uncharted" ]; then
    gap uncharted-side "$KEY.md: side '$HEAD' is uncharted"
  elif [ -n "$SKEY" ]; then
    CHECKOUT="$(atlas_checkout_of "$REPO")"
    [ -n "$CHECKOUT" ] && [ ! -d "$CHECKOUT/docs/atlas" ] \
      && gap uncharted-side "$KEY.md: side '$HEAD' names an area but $REPO has no docs/atlas/"
  fi
done

# --- fog ---------------------------------------------------------------------
while IFS= read -r BULLET; do
  [ -n "$BULLET" ] || continue
  gap fog "${BULLET#- }"
done < <(atlas_section "$INDEX" 'Fog' | grep '^- ' || true)

exit 0
