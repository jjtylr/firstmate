#!/usr/bin/env bash
# Atlas drift check. Reports; never edits (verifiers-do-not-edit).
#
# Diffs docs/atlas/ against the repo it maps. Six drift classes, each one
# DRIFT line per finding:
#
#   unlinked-work       a repo file carries an `Area: <key>` line but that
#                       area's Links section does not reference the file back
#   axes-contradiction  a status axis contradicts the area file's own record
#                       (Understood ✅ with open decisions left, Understood ❌
#                       with resolved options recorded, Understood ✅ with a
#                       Pending-on line, Built ❌ with landed work linked)
#   bad-vocabulary      an area header is malformed, an axis uses a value
#                       outside ❌, 🔶 and ✅, a pointer is spelled in
#                       something other than key form, an `Imports:` line
#                       carries a value other than `any` or appears twice,
#                       or a header line carries a key the schema does not
#                       define
#   bad-edge            a Blocked-by or Pending-on entry is a well-formed key
#                       with no file
#   pending-resolved    a Pending-on entry names an area that is ✅ understood,
#                       so the edge is a fossil and the fix is to remove it
#   stale-index         a generated region of index.md differs from what the
#                       area files produce — run render-index.sh
#
# The header grammar lives in atlas-lib.sh, and this script calls it with the
# repo vocabulary: the title check, the Understood and Built axes, the
# Blocked-by and Pending-on edge lines, the closed header vocabulary, the
# understood-axis contradictions, and the bad-edge and pending-resolved checks
# against docs/atlas/. A fleet checker calls the same functions with its own
# vocabulary, so the grammar is written once. What stays here is repo-only:
# unlinked-work, the Built-axis Links check, the Imports ruling, and the
# stale-index comparison of each generated region.
#
# The repo vocabulary is the area keys Understood, Built, Blocked-by,
# Pending-on, Owns and Imports, and the index key Ignore. The prefix and colon
# rules for them are the library's, stated on atlas_check_vocabulary and
# atlas_check_index_header.
#
# The unlinked-work scan reads the repo's own files, and inside a skill bundle
# it skips an `Area:` value spelled as a `<placeholder>` — that is a skill
# documenting the convention, not work naming an area. The reasoning is at the
# scan itself.
#
#   check-atlas.sh [repo-root]      default: current directory
#
# Silent with exit 0 when clean; DRIFT lines and exit 1 when not.
#
# There is one accepted form of every generated region and no fallback: the
# area table and the graph are byte-compared against what render-index.sh
# would write, so neither can disagree with the area files and still pass.
# Because the table is a byte-exact mirror, a bad symbol in it is reported
# once, at the area file it was copied from.
#
# Merge state is read off the atlas's own record (the Links bullets), never
# the network, so the check is deterministic and runs anywhere — the
# update-on-write flows are what keep that record current.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/atlas-lib.sh"

ROOT="${1:-.}"
[ "$ROOT" = "/" ] || ROOT="${ROOT%/}"   # so the REL strip below always fires
ATLAS="$ROOT/docs/atlas"
INDEX="$ATLAS/index.md"

[ -d "$ATLAS" ] || { echo "no atlas at $ATLAS" >&2; exit 1; }

# --- unlinked-work -----------------------------------------------------------
# Landed work names its area by key; the area's Links section must reference
# the file back. Scanned from the repo's own files.
#
# Leading whitespace on the line is tolerated, which is what
# drain-ready-queue's decl-lib.sh has always done: an indented `Area:` is work
# here too, so no template can go quiet by moving off column zero.
#
# A skill bundle documents the `Area:` line in a template, and `npx skills add`
# vendors that bundle into the repo — so inside a bundle an entry carrying an
# angle bracket is documentation and is skipped, while every other entry on the
# same line is still checked. Nothing outside a bundle is skipped at all.
# `atlas_is_key` accepts only lowercase letters, digits and hyphens, so no area
# key can carry a bracket and nothing real is silenced. The test reads no
# install layout, which is why it holds whichever tree the installer wrote into
# and whether it copied or linked.
#
# A file at or below a bundle loses only its unfilled-placeholder check — a real
# value is still caught, so no genuine drift can hide there.

# A skill bundle is a directory holding a SKILL.md. Walk up from the file,
# stopping BEFORE the scanned root so a SKILL.md at the repo root cannot make
# the whole repository a bundle.
in_skill_bundle() { # in_skill_bundle <file> <root>
  D="${1%/*}"
  while [ -n "$D" ] && [ "$D" != "$2" ] && [ "$D" != "." ] && [ "$D" != "/" ]; do
    [ -f "$D/SKILL.md" ] && return 0
    [ "$D" = "${D%/*}" ] && break
    D="${D%/*}"
  done
  return 1
}

while read -r HIT; do
  [ -n "$HIT" ] || continue
  FILE="${HIT%%:*}"
  case "$FILE" in "$ATLAS"/*) continue ;; esac
  NAMES="${HIT#*:}"; NAMES="${NAMES#*Area:}"
  REL="${FILE#"$ROOT"/}"
  BUNDLE=0; in_skill_bundle "$FILE" "$ROOT" && BUNDLE=1
  while read -r NAME; do
    NAME="$(atlas_trim "$NAME")"
    [ -n "$NAME" ] || continue
    case "$NAME" in
      *'<'*|*'>'*) [ "$BUNDLE" = 1 ] && continue ;;
    esac
    if ! atlas_is_key "$NAME"; then
      atlas_drift bad-vocabulary "$REL: Area entry '$NAME' is not an area key"
    elif [ ! -f "$ATLAS/$NAME.md" ]; then
      atlas_drift unlinked-work "$REL names area '$NAME' but docs/atlas/$NAME.md does not exist"
    elif ! atlas_section "$ATLAS/$NAME.md" Links | grep -qF "$(basename "$FILE")"; then
      atlas_drift unlinked-work "$REL names area '$NAME' but docs/atlas/$NAME.md Links does not reference it"
    fi
  done < <(printf '%s\n' "$NAMES" | tr ',' '\n')
done < <(grep -r --include='*.md' --exclude-dir=.git '^[[:space:]]*Area:' "$ROOT" 2>/dev/null)

# --- per-area checks ---------------------------------------------------------
# The header grammar, called with the repo vocabulary. Each library call
# reports its own findings; the values a later check needs come back in the
# library variables atlas-lib.sh documents.
for F in "$ATLAS"/*.md; do
  [ -f "$F" ] || continue
  KEY="$(basename "$F" .md)"
  [ "$KEY" = "index" ] && continue

  atlas_check_title "$F"

  atlas_check_axis "$F" Understood
  U="$ATLAS_AXIS_VALUE"
  atlas_check_axis "$F" Built
  B="$ATLAS_AXIS_VALUE"

  atlas_check_edge_line "$F" Blocked-by
  EDGES_OK="$ATLAS_EDGE_OK"
  atlas_check_edge_line "$F" Pending-on
  PENDING_OK="$ATLAS_EDGE_OK"
  PENDING_N="$ATLAS_EDGE_N"

  # bad-vocabulary: at most one Imports line, and a present one carries the
  # literal `any` and nothing else. It records that the area imports from
  # anywhere by design (SCHEMA.md), so the gap queue skips its importing side;
  # a misspelled value would otherwise be silently ignored and the question
  # would keep returning.
  LINES="$(atlas_header_block "$F" | grep '^Imports:' || true)"
  COUNT="$(printf '%s\n' "$LINES" | grep -c . || true)"
  if [ "$COUNT" -gt 1 ]; then
    atlas_drift bad-vocabulary "$KEY.md: malformed Imports header (more than one line)"
  elif [ "$COUNT" -eq 1 ]; then
    VALUE="$(atlas_trim "${LINES#Imports:}")"
    [ "$VALUE" = "any" ] \
      || atlas_drift bad-vocabulary "$KEY.md: Imports has invalid value '$VALUE'; the only value is 'any'"
  fi

  # The axes and both edge lines have their own form check above, so they are
  # prefix keys. Owns and Imports must carry the colon.
  atlas_check_vocabulary "$F" 'Understood Built Blocked-by Pending-on' 'Owns Imports'

  atlas_check_understood "$F" "$U" "$PENDING_OK" "$PENDING_N"

  # axes-contradiction: Built ❌ means nothing carved from the area has merged.
  # Landed work is read off the *head* of a Links bullet's title. TOUCH.md
  # step 1 is the single home of that convention and it is not restated here;
  # the regex below matches only the two heads that step names as landed — a
  # pull request in the pointer or the title, and a bare issue number, the form
  # a drained ticket's operative writes because its PR has no number while the
  # touch is being made. Every other head is a label, so filed work stays
  # silent: filing does not move Built.
  if [ "$B" = "❌" ] \
    && atlas_section "$F" Links | grep -qE '/pull/[0-9]+|PR #[0-9]+|^-[[:space:]]+\[?#[0-9]+'; then
    atlas_drift axes-contradiction "$KEY.md: Built ❌ but Links records landed work"
  fi

  # bad-edge and pending-resolved, for each edge line that parsed.
  [ "$EDGES_OK" -eq 1 ] && atlas_check_edge_targets "$F" "$ATLAS" docs/atlas Blocked-by
  [ "$PENDING_OK" -eq 1 ] && atlas_check_edge_targets "$F" "$ATLAS" docs/atlas Pending-on
done

# --- stale-index -------------------------------------------------------------
# Each generated region byte-compared against what render-index.sh writes.
if [ ! -f "$INDEX" ]; then
  atlas_drift stale-index "docs/atlas/index.md does not exist"
else
  atlas_check_index_header "$INDEX" Ignore

  if atlas_has_markers "$INDEX" "$ATLAS_TABLE_OPEN" "$ATLAS_TABLE_SHUT"; then
    [ "$(atlas_region_of "$INDEX" "$ATLAS_TABLE_OPEN" "$ATLAS_TABLE_SHUT")" \
      = "$(atlas_table_body "$ATLAS" "$INDEX" "$ATLAS_REPO_TABLE_HEAD" atlas_repo_cells)" ] \
      || atlas_drift stale-index "index.md area table does not match the area files — run render-index.sh"
  else
    atlas_drift stale-index "index.md has no atlas-table marker pair — run render-index.sh"
  fi

  if atlas_has_markers "$INDEX" "$ATLAS_GRAPH_OPEN" "$ATLAS_GRAPH_SHUT"; then
    [ "$(atlas_region_of "$INDEX" "$ATLAS_GRAPH_OPEN" "$ATLAS_GRAPH_SHUT")" \
      = "$(atlas_graph_body "$ATLAS")" ] \
      || atlas_drift stale-index "index.md graph block does not match the area files — run render-index.sh"
  else
    atlas_drift stale-index "index.md has no atlas-graph marker pair"
  fi
fi

exit $ATLAS_FAIL
