#!/bin/bash
# claim-authority.sh [<repo-root>] — which copy of a plugin file is
# authoritative for a claim about a path under skills/, agents/, hooks/ or
# scripts/? Default root is the current directory. The installed snapshot is
# read from $CLAUDE_PLUGIN_ROOT, which may be unset.
#
# The measurement is the manifest, never the directory name: a repo that
# carries .claude-plugin/plugin.json with a name is a plugin's source, and its
# working tree wins over any installed snapshot of the same paths. The verdict
# never depends on comparing names with the snapshot: a plugin source's own
# paths are its source no matter which plugin dispatched the reader.
#
# Exactly one line on stdout, exit 0:
#
#   CLAIM-AUTHORITY-WORKING-TREE: <root> is the source of plugin '<name>', read plugin paths from this working tree, never the installed snapshot
#   CLAIM-AUTHORITY-SNAPSHOT: <root> is not a plugin source, plugin paths exist only in the installed snapshot at <plugin-root>
#
#   exit 1   the answer cannot be measured: one CLAIM-AUTHORITY-UNKNOWN line on
#            stderr, nothing on stdout. The caller says so in its findings
#            lines instead of picking a copy silently.
set -u

fail_unknown() {
  echo "CLAIM-AUTHORITY-UNKNOWN: $1" >&2
  exit 1
}

[ $# -le 1 ] || fail_unknown "usage: claim-authority.sh [<repo-root>]"
root="${1:-.}"
[ -d "$root" ] || fail_unknown "$root is not a directory"
root="$(cd "$root" 2>/dev/null && pwd)" \
  || fail_unknown "$1 is a directory this check cannot enter"

manifest="$root/.claude-plugin/plugin.json"
if [ -f "$manifest" ]; then
  name="$(jq -r '.name // empty' "$manifest")" \
    || fail_unknown "$manifest is not JSON this check can read"
  [ -n "$name" ] || fail_unknown "$manifest has no name, so whether this repo is the plugin's source cannot be measured"
  printf "CLAIM-AUTHORITY-WORKING-TREE: %s is the source of plugin '%s', read plugin paths from this working tree, never the installed snapshot\n" "$root" "$name"
  exit 0
fi

snapshot="${CLAUDE_PLUGIN_ROOT:-}"
[ -n "$snapshot" ] || fail_unknown "$root has no plugin manifest and CLAUDE_PLUGIN_ROOT is not set, so there is nowhere measured to read plugin paths from"
[ -f "$snapshot/.claude-plugin/plugin.json" ] || fail_unknown "$root has no plugin manifest and $snapshot carries none either, so it is not an installed snapshot"
printf 'CLAIM-AUTHORITY-SNAPSHOT: %s is not a plugin source, plugin paths exist only in the installed snapshot at %s\n' "$root" "$snapshot"
exit 0
