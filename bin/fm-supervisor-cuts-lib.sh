#!/usr/bin/env bash
# fm-supervisor-cuts-lib.sh - the one declared list of what a Claude supervisor
# (the main firstmate and every Claude secondmate) starts without, sourced by
# bin/fm-claude-main.sh and bin/fm-spawn.sh.
#
# A supervisor resends its whole start on every request until the next clear,
# so tools, skills, and connectors it never uses are a fixed cost on every
# turn. Each cut below removes one such group from the model's context.
# docs/configuration.md "Supervisor start cuts" owns the operator contract:
# what each cut removes, what stops working, and how to switch one back.
#
# Cuts, each switched back by naming it in the home's own
# config/supervisor-claude-keep (one name per line, # comments allowed):
#   delegation      --disallowedTools Agent,Workflow,ScheduleWakeup,ListAgents.
#                   bin/fm-subagent-pretool-check.sh already refuses all four;
#                   hiding them also drops Claude Code's agent-type list.
#                   bin/fm-claude-main.sh keeps them when FM_ALLOW_SUBAGENT=1.
#   report-findings --disallowedTools ReportFindings.
#   artifacts       --disallowedTools for the claude.ai artifacts tool server
#                   and the built-in artifact tools Claude Code adds when that
#                   server is hidden.
#   chrome          --no-chrome (Claude in Chrome).
#   connectors      settings "disableClaudeAiConnectors": true.
#   skills          settings "skillOverrides": every listed non-firstmate
#                   skill set to "user-invocable-only", so the captain can
#                   still type it but the model's skill list no longer
#                   carries it. Plugin skills are not covered by
#                   skillOverrides; the plugins cut handles those.
#   plugins         settings "enabledPlugins": the listed plugins false.
#
# Feedback drafts are not a cut here: every firstmate-launched Claude already
# runs with CLAUDE_CODE_SEND_FEEDBACK=0 and "feedbackDrafts": "off"
# (bin/fm-spawn.sh launch_template), and bin/fm-claude-main.sh does the same.
#
# The skill and plugin names are this fleet's installed non-firstmate skills;
# `claude plugin list` prints each plugin's id (a claude.ai plugin is <name>@synced).
# A name that matches nothing in a session has no effect, so a host without
# one of them is unaffected. Skills a user setting already turns "off" are left
# out so this list never loosens them.

FM_SUPERVISOR_CUTS='delegation report-findings artifacts chrome connectors skills plugins'

FM_SUPERVISOR_DELEGATION_TOOLS='Agent,Workflow,ScheduleWakeup,ListAgents'
FM_SUPERVISOR_REPORT_TOOLS='ReportFindings'
FM_SUPERVISOR_ARTIFACT_TOOLS='mcp__claude-artifacts,Artifact,ArtifactComments,ArtifactData,ArtifactCheck'

FM_SUPERVISOR_USER_ONLY_SKILLS='update-config keybindings-help code-review simplify ship ship-local steward fewer-permission-prompts claude-approvals loop schedule claude-api workflow-authoring claude-in-chrome run plugin-authoring init security-review dataviz no-mistakes nucleo-icons nucleo-customize anthropic-skills:built-in-browser anthropic-skills:chrome-browser anthropic-skills:computer-use anthropic-skills:deep-research anthropic-skills:docs anthropic-skills:docx anthropic-skills:human-writer anthropic-skills:instruction-audit anthropic-skills:pdf anthropic-skills:pptx anthropic-skills:xlsx'

FM_SUPERVISOR_OFF_PLUGINS='codex@openai-codex cowork-plugin-management@synced'

# fm_supervisor_cuts_kept <config-dir>: print the space-joined cut names the
# home's config/supervisor-claude-keep switches back, empty when the file is
# absent. Non-zero with the reason on stderr for an unreadable file or an
# unknown name, so a typo never silently keeps a cut the operator meant to undo.
fm_supervisor_cuts_kept() {
  local config=$1 file line kept=''
  file=$config/supervisor-claude-keep
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    return 0
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: config/supervisor-claude-keep must be a readable regular file" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in
    '' | '#'*) continue ;;
    esac
    case " $FM_SUPERVISOR_CUTS " in
    *" $line "*) kept="${kept:+$kept }$line" ;;
    *)
      echo "error: config/supervisor-claude-keep names '$line', which is not a supervisor cut; expected one of: $FM_SUPERVISOR_CUTS" >&2
      return 1
      ;;
    esac
  done <"$file" || {
    echo "error: cannot read config/supervisor-claude-keep" >&2
    return 1
  }
  printf '%s' "$kept"
}

# _fm_supervisor_cut_on <kept> <cut>: succeed when <cut> is not kept.
_fm_supervisor_cut_on() {
  case " $1 " in
  *" $2 "*) return 1 ;;
  esac
  return 0
}

# fm_supervisor_claude_flags <kept> [keep-delegation 0|1]: print the Claude
# command-line flags for the active cuts, each followed by one space, or
# nothing. The caller must place another flag after this output, because
# --disallowedTools is variadic and would otherwise swallow a positional prompt.
fm_supervisor_claude_flags() {
  local kept=$1 keep_delegation=${2:-0} tools=''
  if [ "$keep_delegation" != 1 ] && _fm_supervisor_cut_on "$kept" delegation; then
    tools=$FM_SUPERVISOR_DELEGATION_TOOLS
  fi
  if _fm_supervisor_cut_on "$kept" report-findings; then
    tools="${tools:+$tools,}$FM_SUPERVISOR_REPORT_TOOLS"
  fi
  if _fm_supervisor_cut_on "$kept" artifacts; then
    tools="${tools:+$tools,}$FM_SUPERVISOR_ARTIFACT_TOOLS"
  fi
  [ -z "$tools" ] || printf "%s '%s' " --disallowedTools "$tools"
  if _fm_supervisor_cut_on "$kept" chrome; then
    printf '%s ' --no-chrome
  fi
}

# fm_supervisor_claude_settings_keys <kept>: print the Claude settings keys for
# the active cuts as JSON object members, each followed by a comma, or nothing,
# for the caller to splice into its own settings object.
fm_supervisor_claude_settings_keys() {
  local kept=$1 name members
  if _fm_supervisor_cut_on "$kept" connectors; then
    printf '%s' '"disableClaudeAiConnectors":true,'
  fi
  if _fm_supervisor_cut_on "$kept" skills; then
    members=''
    for name in $FM_SUPERVISOR_USER_ONLY_SKILLS; do
      members="${members:+$members,}\"$name\":\"user-invocable-only\""
    done
    printf '"skillOverrides":{%s},' "$members"
  fi
  if _fm_supervisor_cut_on "$kept" plugins; then
    members=''
    for name in $FM_SUPERVISOR_OFF_PLUGINS; do
      members="${members:+$members,}\"$name\":false"
    done
    printf '"enabledPlugins":{%s},' "$members"
  fi
}
