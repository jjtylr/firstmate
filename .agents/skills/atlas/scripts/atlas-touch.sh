#!/usr/bin/env bash
# The atlas touch as one command: render the index, then check the atlas.
#
#   atlas-touch.sh [repo-root]      default: current directory
#
# Every flow that edits docs/atlas/ ends the same way, and the order is not a
# preference. The area files are the single home of truth (SCHEMA.md), so the
# index has to be regenerated from them before anything compares the two.
# Checking first reports a staleness the same session is about to remove, and
# rendering never reports the area file that is actually wrong. Running the
# pair from here is what lets SKILL.md, SITTING.md and TOUCH.md name one
# command instead of restating an order that only prose was holding.
#
# Silent with exit 0 when the atlas is clean after rendering. Exit 1 with the
# failing arm's own output: render-index.sh's one stderr line when it cannot
# write the index, or check-atlas.sh's DRIFT lines when the map still
# disagrees with the repo. This script prints nothing of its own, so what
# reaches the caller is exactly what the arm printed.
#
# It writes, so it belongs to the flow that just edited the map. A verifier
# checking work it did not do runs check-atlas.sh alone: a verifier that
# renders would repair the very drift it was asked to report.
set -uo pipefail

HERE="$(dirname "${BASH_SOURCE[0]}")"
ROOT="${1:-.}"

"$HERE/render-index.sh" "$ROOT" || exit 1
exec "$HERE/check-atlas.sh" "$ROOT"
