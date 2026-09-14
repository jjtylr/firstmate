#!/usr/bin/env bash
# The fleet touch as one command: render the fleet index, then check the fleet.
#
#   fleet-touch.sh <fleet-root> <repo>=<path> ...
#
# The repo pair's reason holds here (atlas-touch.sh): the shared area files are
# the truth, the index is generated from them, and a check that runs first
# reports a staleness the sitting created two edits ago. The checkout
# arguments are the gate's and pass through untouched, because only the gate
# reads the repos a side names; the renderer never leaves the fleet root.
#
# Silent with exit 0 when the fleet atlas is clean after rendering. Exit 1 with
# the failing arm's own output. Exit 2 with one stderr line on a usage error,
# the code check-fleet.sh already gives, so a caller cannot read a forgotten
# argument as a clean fleet or as a finding.
set -uo pipefail

HERE="$(dirname "${BASH_SOURCE[0]}")"
ME="${0##*/}"

[ "$#" -ge 1 ] || { echo "usage: $ME <fleet-root> <repo>=<path> ..." >&2; exit 2; }
ROOT="$1"
shift

"$HERE/render-fleet-index.sh" "$ROOT" || exit 1
exec "$HERE/check-fleet.sh" "$ROOT" "$@"
