#!/usr/bin/env bash
# Firstmate adaptation of the upstream merge-pinned runner.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 1
root="${FM_ROOT:-$(cd "$here/../../../../" 2>/dev/null && pwd -P)}"
[ -x "$root/bin/fm-codex-toolkit-merge.sh" ] || {
  printf 'MERGE-FAILED:Firstmate merge adapter is missing; nothing was attempted\n'
  exit 1
}
FM_ROOT="$root" exec "$root/bin/fm-codex-toolkit-merge.sh" "$@"
