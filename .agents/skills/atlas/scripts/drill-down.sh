#!/usr/bin/env bash
# Drill down from an area of the map to the code it claims. Reads only.
#
#   drill-down.sh <area-key> [repo-root]      default root: current directory
#
# Prints the tracked files the area's `Owns:` patterns match, one per line, in
# git's order, relative to the root given. Nothing else goes to stdout, and a
# path outside ASCII is printed as itself, so the output pipes into a command
# that opens the files.
#
# A claim is written against that same root, the directory holding `docs/atlas/`.
# An atlas nested inside a larger repository therefore claims `src/scrape`, not
# the path from git's top level down, and moving the package it maps rewrites no
# claim.
#
# The patterns are git pathspecs and git evaluates them (skills/atlas/SCHEMA.md).
# So a bare directory claims its whole subtree, the exclude syntax works, and a
# file that two of the area's own patterns both match is printed once. Only
# tracked files are seen, because `git ls-files` reads the index: untracked
# scratch is never an area's code, and `git add` is what makes a new file appear
# here.
#
# Nothing is derived on disk. There is no cache and no regeneration step. The
# script reads the repository as it stands at run time.
#
# Four ways it refuses to answer. Each writes to stderr and nothing to stdout:
#
#   exit 2   no area key was given
#   exit 1   the repo has no docs/atlas/
#   exit 1   the key names no area of that atlas
#   git's    a claim git refuses as a pathspec, or a root that is not a git
#            repository — git's own message and git's own exit code, unchanged
#
# An area with no `Owns:` line prints nothing and exits 0. So does one whose
# claims match nothing, because a claim in a repo the code has not reached yet is
# an intention. Neither is a defect, and neither is this script's to judge. The
# gate never compares the map to the code.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/atlas-lib.sh"

KEY="${1:-}"
ROOT="${2:-.}"
ATLAS="$ROOT/docs/atlas"

[ -n "$KEY" ] || { echo "usage: drill-down.sh <area-key> [repo-root]" >&2; exit 2; }
[ -d "$ATLAS" ] || { echo "no atlas at $ATLAS" >&2; exit 1; }

# The index is a file of the atlas, not an area of it, and a key is lowercase
# letters, digits and hyphens. One message covers all three refusals, because
# they say the same thing to whoever asked: this atlas has no such area.
if [ "$KEY" = "index" ] || ! atlas_is_key "$KEY" || [ ! -f "$ATLAS/$KEY.md" ]; then
  echo "no area '$KEY' in $ATLAS" >&2
  exit 1
fi

atlas_claimed_files "$ROOT" "$ATLAS/$KEY.md"
