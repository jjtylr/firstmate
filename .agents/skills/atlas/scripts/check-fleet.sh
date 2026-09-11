#!/usr/bin/env bash
# Fleet atlas drift check. Reports; never edits (verifiers-do-not-edit).
#
# Checks docs/fleet-atlas/ at the fleet root against itself and against the
# repo atlases of the attached checkouts. Six drift classes, each one DRIFT
# line per finding:
#
#   bad-vocabulary      a shared area header is malformed, the Kind line is
#                       missing or outside `contract` and `implementation`,
#                       the line that goes with the kind is wrong (a contract
#                       needs Revision and no Owner, an implementation needs
#                       Owner and no Revision, Revision is a positive integer,
#                       Owner is a repo in Repos), the axis uses a value
#                       outside ❌, 🔶 and ✅, a pointer is spelled in
#                       something other than key form, a header line carries
#                       a key the schema does not define, the index's Repos
#                       line is missing or names something that is not a
#                       repo key, or a Sides bullet breaks the grammar: an
#                       unknown repo, a malformed head, an indented
#                       bullet, a head naming `index`, a pin on an
#                       implementation side or on an uncharted side, a
#                       missing pin on a contract side, a pin above the
#                       contract's Revision, or an implementation side that
#                       names the owner
#   bad-edge            a Blocked-by or Pending-on entry is a well-formed key
#                       with no shared area file
#   axes-contradiction  Understood contradicts the shared area's own record
#                       (✅ with open decisions left, ❌ with resolved options
#                       recorded, ✅ with a Pending-on line)
#   pending-resolved    a Pending-on entry names a shared area that is ✅
#                       understood, so the edge is a fossil; remove it
#   stale-index         a generated region of index.md differs from what the
#                       shared area files produce; run render-fleet-index.sh
#   orphan-relation     a side head `<repo>:<key>` where the repo's checkout
#                       has docs/atlas/ and no <key>.md in it; keys are never
#                       renamed, so the area was deleted
#
# The header grammar lives in atlas-lib.sh and this script calls it with the
# fleet vocabulary: the title check, the Understood axis, the Blocked-by and
# Pending-on edge lines, the closed header vocabulary, the understood-axis
# contradictions, and the bad-edge and pending-resolved checks against
# docs/fleet-atlas/. What is the fleet's own is here: Kind and the line that
# goes with it, the Repos line, the Sides grammar, and orphan-relation.
#
# The fleet vocabulary is the shared area keys Kind, Revision, Owner,
# Understood, Blocked-by and Pending-on, and the index key Repos. The Repos
# line is the closed set a side may name. When the line is missing the set is
# empty and the side checks that need it are skipped, so one missing line is
# one finding.
#
#   check-fleet.sh <fleet-root> <repo>=<path> ...
#
# <fleet-root> is the directory holding docs/fleet-atlas/. Every repo the
# index's Repos line names takes one <repo>=<path> argument naming its
# checkout, so a partial check never reads as green. A checkout with no
# docs/atlas/ is legal: every side naming it is uncharted and there is nothing
# here to resolve against.
#
# Silent with exit 0 when clean; DRIFT lines and exit 1 when not. Exit 1 with
# one stderr line when the root has no docs/fleet-atlas/ or it has no
# index.md. Exit 2 with one stderr line and nothing on stdout on a usage
# error: a repo in Repos with no path, a path for a repo not in Repos, an
# argument without `=`, a path that is not a directory, or a repo given twice.
#
# There is one accepted form of every generated region and no fallback: the
# shared-area table and the graph are byte-compared against what
# render-fleet-index.sh would write. Because the table is a byte-exact mirror,
# a bad value in it is reported once, at the shared area file it came from.
#
# Nothing here compares the fleet atlas to code, and nothing depends on
# another repo's progress. A side pinned below a contract's revision is the
# queue's finding, not this gate's.
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

# --- the repo set and the checkouts ------------------------------------------
# The set is the well-formed, first-seen entries of the Repos line. The
# arguments are checked against it before anything is printed, so a usage
# error leaves stdout empty. A malformed entry is reported below, after the
# arguments pass, and the parsable entries are the set it is checked against.
REPOS=
REPOS_BAD=
REPOS_DUP=
while IFS= read -r ENTRY; do
  [ -n "$ENTRY" ] || continue
  if ! atlas_is_key "$ENTRY"; then
    REPOS_BAD="$REPOS_BAD$ENTRY
"
  elif [ -n "$REPOS" ] && [ "${REPOS#* $ENTRY }" != "$REPOS" ]; then
    REPOS_DUP="$REPOS_DUP$ENTRY
"
  else
    REPOS="${REPOS:- }$ENTRY "
  fi
done < <(atlas_fleet_repos "$INDEX")
REPOS_N="$(atlas_header_block "$INDEX" | grep -c '^Repos:' || true)"

atlas_fleet_checkouts "$ME" "$REPOS" "$@" || exit $?

in_repos() { case "$REPOS" in *" $1 "*) return 0 ;; esac; return 1; }

# --- the index header --------------------------------------------------------
atlas_check_index_header "$INDEX" Repos
[ "$REPOS_N" -ge 1 ] || atlas_drift bad-vocabulary "index.md: malformed Repos header"
while IFS= read -r ENTRY; do
  [ -n "$ENTRY" ] || continue
  atlas_drift bad-vocabulary "index.md: Repos entry '$ENTRY' is not a repo key"
done < <(printf '%s' "$REPOS_BAD")
while IFS= read -r ENTRY; do
  [ -n "$ENTRY" ] || continue
  atlas_drift bad-vocabulary "index.md: Repos entry '$ENTRY' is listed twice"
done < <(printf '%s' "$REPOS_DUP")

# --- per-area checks ---------------------------------------------------------

# One fleet header line by prefix, the way atlas_check_axis reads an axis. The
# count of lines opening with the field lands in FIELD_N, and FIELD_VALUE is
# the trimmed value when there is exactly one line and it carries its colon.
# A single line without the colon is left to atlas_check_vocabulary, which
# names it as an undefined key, so the same line is not named twice here.
field() { # field <shared-area-file> <Field>
  local lines
  lines="$(atlas_header_block "$1" | grep "^$2" || true)"
  FIELD_N="$(printf '%s\n' "$lines" | grep -c . || true)"
  FIELD_VALUE=
  if [ "$FIELD_N" -gt 1 ]; then
    atlas_drift bad-vocabulary "$KEY.md: malformed $2 header (more than one line)"
  elif [ "$FIELD_N" -eq 1 ]; then
    case "$lines" in
      "$2:"*) FIELD_VALUE="$(atlas_trim "${lines#"$2:"}")"
              [ -n "$FIELD_VALUE" ] || atlas_drift bad-vocabulary "$KEY.md: malformed $2 header" ;;
    esac
  fi
}

for F in "$FLEET"/*.md; do
  [ -f "$F" ] || continue
  KEY="$(basename "$F" .md)"
  [ "$KEY" = "index" ] && continue

  atlas_check_title "$F"

  atlas_check_axis "$F" Understood
  U="$ATLAS_AXIS_VALUE"

  atlas_check_edge_line "$F" Blocked-by
  EDGES_OK="$ATLAS_EDGE_OK"
  atlas_check_edge_line "$F" Pending-on
  PENDING_OK="$ATLAS_EDGE_OK"
  PENDING_N="$ATLAS_EDGE_N"

  # bad-vocabulary: exactly one Kind line, one of two values.
  field "$F" Kind
  KIND=
  if [ "$FIELD_N" -eq 0 ]; then
    atlas_drift bad-vocabulary "$KEY.md: malformed Kind header"
  elif [ -n "$FIELD_VALUE" ]; then
    case "$FIELD_VALUE" in
      contract|implementation) KIND="$FIELD_VALUE" ;;
      *) atlas_drift bad-vocabulary "$KEY.md: Kind has invalid value '$FIELD_VALUE'; it is contract or implementation" ;;
    esac
  fi

  # bad-vocabulary: the line that goes with the kind. A contract carries
  # Revision, an implementation carries Owner, and no file carries both or
  # neither. Each value has its own form: Revision is a positive integer and
  # Owner is a repo in Repos.
  field "$F" Revision
  REV_N="$FIELD_N"; REV_VALUE="$FIELD_VALUE"
  field "$F" Owner
  OWN_N="$FIELD_N"; OWN_VALUE="$FIELD_VALUE"
  REVISION=
  OWNER=
  if [ "$REV_N" -gt 0 ] && [ "$OWN_N" -gt 0 ]; then
    atlas_drift bad-vocabulary "$KEY.md: carries both Revision and Owner; a contract carries Revision and an implementation carries Owner"
  elif [ "$REV_N" -eq 0 ] && [ "$OWN_N" -eq 0 ]; then
    atlas_drift bad-vocabulary "$KEY.md: carries neither Revision nor Owner; a contract carries Revision and an implementation carries Owner"
  elif [ "$KIND" = "contract" ] && [ "$OWN_N" -gt 0 ]; then
    atlas_drift bad-vocabulary "$KEY.md: Kind contract carries Owner but needs Revision"
  elif [ "$KIND" = "implementation" ] && [ "$REV_N" -gt 0 ]; then
    atlas_drift bad-vocabulary "$KEY.md: Kind implementation carries Revision but needs Owner"
  elif [ -n "$REV_VALUE" ]; then
    if printf '%s' "$REV_VALUE" | grep -qE '^[1-9][0-9]*$'; then
      REVISION="$REV_VALUE"
    else
      atlas_drift bad-vocabulary "$KEY.md: Revision has invalid value '$REV_VALUE'; it is a positive integer"
    fi
  elif [ -n "$OWN_VALUE" ]; then
    if [ "$REPOS_N" -eq 0 ] || in_repos "$OWN_VALUE"; then
      OWNER="$OWN_VALUE"
    else
      atlas_drift bad-vocabulary "$KEY.md: Owner '$OWN_VALUE' is not a repo in Repos"
    fi
  fi

  # The axis and both edge lines have their own form check above, so they are
  # prefix keys. Kind, Revision and Owner must carry the colon.
  atlas_check_vocabulary "$F" 'Understood Blocked-by Pending-on' 'Kind Revision Owner'

  atlas_check_understood "$F" "$U" "$PENDING_OK" "$PENDING_N"

  # bad-edge and pending-resolved, for each edge line that parsed.
  [ "$EDGES_OK" -eq 1 ] && atlas_check_edge_targets "$F" "$FLEET" docs/fleet-atlas Blocked-by
  [ "$PENDING_OK" -eq 1 ] && atlas_check_edge_targets "$F" "$FLEET" docs/fleet-atlas Pending-on

  # bad-vocabulary and orphan-relation: every side, against the grammar, the
  # kind, and the repo's own atlas. A side whose repo is unknown stops at that
  # one finding. The pin rules and the orphan check are independent facts
  # about one side, so a side can draw one of each.
  while IFS= read -r SPEC; do
    [ -n "$SPEC" ] || continue
    case "$SPEC" in
      "- "*)
        atlas_drift bad-vocabulary "$KEY.md: side '$SPEC' is indented; a side is one top-level bullet under Sides"
        continue ;;
    esac
    if ! atlas_parse_side "$SPEC"; then
      atlas_drift bad-vocabulary "$KEY.md: side '$SPEC' is malformed; a side is <repo>, <repo>:<key> or <repo>:uncharted, with @<n> on a contract"
      continue
    fi
    REPO="$ATLAS_SIDE_REPO"; SKEY="$ATLAS_SIDE_KEY"; PIN="$ATLAS_SIDE_PIN"; HEAD="$ATLAS_SIDE_HEAD"
    if [ "$REPOS_N" -ge 1 ] && ! in_repos "$REPO"; then
      atlas_drift bad-vocabulary "$KEY.md: side '$HEAD' names repo '$REPO', which is not in Repos"
      continue
    fi
    if [ "$SKEY" = "index" ]; then
      atlas_drift bad-vocabulary "$KEY.md: side '$HEAD' names 'index', which is not an area key"
      continue
    fi
    case "$KIND" in
      contract)
        if [ "$SKEY" = "uncharted" ]; then
          [ -z "$PIN" ] || atlas_drift bad-vocabulary "$KEY.md: side '$HEAD' is uncharted and carries a pin @$PIN"
        elif [ -z "$PIN" ]; then
          atlas_drift bad-vocabulary "$KEY.md: side '$HEAD' carries no pin"
        elif [ -n "$REVISION" ] && [ "$PIN" -gt "$REVISION" ]; then
          atlas_drift bad-vocabulary "$KEY.md: side '$HEAD' is pinned at @$PIN above Revision $REVISION"
        fi
        ;;
      implementation)
        [ -z "$PIN" ] || atlas_drift bad-vocabulary "$KEY.md: side '$HEAD' carries a pin @$PIN on an implementation"
        [ -z "$OWNER" ] || [ "$REPO" != "$OWNER" ] \
          || atlas_drift bad-vocabulary "$KEY.md: side '$HEAD' names the owner; the owner is never a side"
        ;;
    esac
    if [ -n "$SKEY" ] && [ "$SKEY" != "uncharted" ]; then
      CHECKOUT="$(atlas_checkout_of "$REPO")"
      if [ -n "$CHECKOUT" ] && [ -d "$CHECKOUT/docs/atlas" ] && [ ! -f "$CHECKOUT/docs/atlas/$SKEY.md" ]; then
        atlas_drift orphan-relation "$KEY.md: side '$HEAD' names an area but $REPO has no docs/atlas/$SKEY.md"
      fi
    fi
  done < <(atlas_sides_of "$F")
done

# --- stale-index -------------------------------------------------------------
# Each generated region byte-compared against what render-fleet-index.sh writes.
if atlas_has_markers "$INDEX" "$ATLAS_TABLE_OPEN" "$ATLAS_TABLE_SHUT"; then
  [ "$(atlas_region_of "$INDEX" "$ATLAS_TABLE_OPEN" "$ATLAS_TABLE_SHUT")" \
    = "$(atlas_table_body "$FLEET" "$INDEX" "$ATLAS_FLEET_TABLE_HEAD" atlas_fleet_cells)" ] \
    || atlas_drift stale-index "index.md shared-area table does not match the shared area files; run render-fleet-index.sh"
else
  atlas_drift stale-index "index.md has no atlas-table marker pair; run render-fleet-index.sh"
fi

if atlas_has_markers "$INDEX" "$ATLAS_GRAPH_OPEN" "$ATLAS_GRAPH_SHUT"; then
  [ "$(atlas_region_of "$INDEX" "$ATLAS_GRAPH_OPEN" "$ATLAS_GRAPH_SHUT")" \
    = "$(atlas_graph_body "$FLEET")" ] \
    || atlas_drift stale-index "index.md graph block does not match the shared area files; run render-fleet-index.sh"
else
  atlas_drift stale-index "index.md has no atlas-graph marker pair"
fi

exit $ATLAS_FAIL
