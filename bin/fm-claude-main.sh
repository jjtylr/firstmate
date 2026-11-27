#!/usr/bin/env bash
# fm-claude-main.sh - start the main firstmate on Claude Code with the
# supervisor start cuts.
#
# Usage: bin/fm-claude-main.sh [claude arguments...]
#
# Run it where you would run `claude` for the main firstmate (the home's
# checkout). It execs the `claude` on PATH with:
#   - CLAUDE_CODE_SEND_FEEDBACK=0 and "feedbackDrafts": "off", as every
#     firstmate-launched Claude already runs;
#   - the cuts declared in bin/fm-supervisor-cuts-lib.sh: hidden tools and
#     --no-chrome on the command line, connector, skill, and plugin keys in
#     one inline --settings JSON object;
#   - any arguments given here, after those, so `--resume <id>`, `--continue`,
#     `--model <m>`, or a prompt pass straight through.
#
# A cut named in this home's config/supervisor-claude-keep is left out.
# FM_ALLOW_SUBAGENT=1 also leaves the delegation tools in, so the
# bin/fm-subagent-pretool-check.sh exception still has a tool to allow.
# docs/configuration.md "Supervisor start cuts" owns the operator contract.
#
# The cuts are process flags and session settings, so they hold for the life
# of this process: a /clear keeps them, while a fresh start must use this
# command again. Nothing is written to any settings file; in particular the
# home's .claude/settings.local.json is left alone, because worker copies of
# this repository read that file too.
set -euo pipefail

case "${1:-}" in
-h | --help)
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
  ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-supervisor-cuts-lib.sh
. "$SCRIPT_DIR/fm-supervisor-cuts-lib.sh"

kept=$(fm_supervisor_cuts_kept "$CONFIG")
keep_delegation=0
[ "${FM_ALLOW_SUBAGENT:-}" != 1 ] || keep_delegation=1

# The lib prints shell-quoted flags built only from its own fixed names.
flags=$(fm_supervisor_claude_flags "$kept" "$keep_delegation")
eval "cut_args=($flags)"
settings="{$(fm_supervisor_claude_settings_keys "$kept")\"feedbackDrafts\":\"off\"}"

# --settings follows the variadic --disallowedTools, so a passed-through
# prompt is never read as another tool name.
exec env CLAUDE_CODE_SEND_FEEDBACK=0 claude ${cut_args[@]+"${cut_args[@]}"} --settings "$settings" "$@"
