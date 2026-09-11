#!/usr/bin/env bash
# Regenerate every derived region of docs/fleet-atlas/index.md from the shared
# area files. The shared area files are the single home of truth
# (skills/atlas/FLEET.md); this script is the only writer of the index's
# shared-area table and dependency graph, and neither is ever hand-edited.
# Idempotent: a second run changes nothing.
#
#   render-fleet-index.sh [fleet-root]     default: current directory
#
# Two regions, each between the same marker pair the repo index uses:
#
#   atlas-table   one row per shared area: the current title linked to the key
#                 file, the kind, the Owner of an implementation or the
#                 Revision of a contract, and the understood axis, each copied
#                 from that file. The row order already in the index is kept,
#                 a shared area missing from it is appended in key order, and
#                 a row whose file is gone goes.
#   atlas-graph   the Mermaid graph, drawn by the same function the repo index
#                 uses: one `key["Current title"]` node per shared area, then
#                 one solid `blocker --> blocked` edge per Blocked-by entry,
#                 then one dotted `decider -.-> waiting` edge per Pending-on
#                 entry. Each group is sorted, and the solid group comes first.
#
# An index drawn by hand has no table pair. This script inserts one around
# the rows under `## Shared areas`, so adopting the generated table is one
# command. A graph pair it never inserts, and a marker line already present is
# never rewritten; what the checker compares is FLEET.md's to say.
#
# Exit 0 on success, whether or not the file changed. Exit 1 with one stderr
# line when the root has no fleet atlas index, when the index has no
# `## Shared areas` heading to anchor the table to, or when it carries no
# atlas-graph marker pair.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/atlas-lib.sh"

ROOT="${1:-.}"
FLEET="$ROOT/docs/fleet-atlas"
INDEX="$FLEET/index.md"

[ -f "$INDEX" ] || { echo "no fleet atlas index at $INDEX" >&2; exit 1; }
grep -q '^## Shared areas' "$INDEX" \
  || { echo "no '## Shared areas' heading in $INDEX; add it from FLEET.md first" >&2; exit 1; }
atlas_has_markers "$INDEX" "$ATLAS_GRAPH_OPEN" "$ATLAS_GRAPH_SHUT" \
  || { echo "no atlas-graph markers in $INDEX; add the marker pair from FLEET.md first" >&2; exit 1; }

WORK="$(mktemp)" || exit 1
trap 'rm -f "$WORK"' EXIT

# --- 1. give the table its marker pair ---------------------------------------
# The pair replaces the contiguous run of table rows under `## Shared areas`.
# Everything else in the section, including a `## Graph block` heading and the
# graph markers, is left where it is.

if atlas_has_markers "$INDEX" "$ATLAS_TABLE_OPEN" "$ATLAS_TABLE_SHUT"; then
  cp "$INDEX" "$WORK"
else
  awk -v tb="$ATLAS_TABLE_BEGIN" -v te="$ATLAS_TABLE_END" -v go="$ATLAS_GRAPH_OPEN" '
    function ins() { if (!done) { print tb; print te; done = 1 } }
    /^## Shared areas/          { print; intable = 1; next }
    intable && /^\|/            { ins(); next }
    intable && /^## /           { ins(); intable = 0; print; next }
    intable && index($0, go)==1 { ins(); intable = 0; print; next }
                                { print }
    END                         { ins() }
  ' "$INDEX" > "$WORK"
fi

# --- 2. fill each region from the shared area files --------------------------
# The row order is read from the index as it stands on disk, before this run
# blanked anything, so a hand-ordered table survives its first regeneration.

fill() { # fill <begin-prefix> <end-prefix> <body>
  ATLAS_REGION_BODY="$3"
  export ATLAS_REGION_BODY
  awk -v b="$1" -v e="$2" '
    index($0, b) == 1 { print; print ENVIRON["ATLAS_REGION_BODY"]; skip = 1; next }
    index($0, e) == 1 { skip = 0 }
    !skip             { print }
  ' "$WORK"
}

OUT="$(fill "$ATLAS_TABLE_OPEN" "$ATLAS_TABLE_SHUT" \
  "$(atlas_table_body "$FLEET" "$INDEX" "$ATLAS_FLEET_TABLE_HEAD" atlas_fleet_cells)")"
printf '%s\n' "$OUT" > "$WORK"

OUT="$(fill "$ATLAS_GRAPH_OPEN" "$ATLAS_GRAPH_SHUT" "$(atlas_graph_body "$FLEET")")"
printf '%s\n' "$OUT" > "$WORK"

# --- 3. write only on a real change ------------------------------------------
cmp -s "$WORK" "$INDEX" || cp "$WORK" "$INDEX"
