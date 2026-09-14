#!/usr/bin/env bash
# Firstmate adaptation of the upstream Codex operative runner.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 2
root="${FM_ROOT:-$(cd "$here/../../../../" 2>/dev/null && pwd -P)}"
[ -x "$root/bin/fm-codex-toolkit-dispatch.sh" ] || {
  printf 'CODEX-OPERATIVE-REFUSED: Firstmate dispatch adapter is missing\n' >&2
  exit 2
}
FM_ROOT="$root" exec "$root/bin/fm-codex-toolkit-dispatch.sh" "$@"
