#!/usr/bin/env bash
# Configure the current repository for the project-local Codex parts that
# `npx skills` cannot create: named agent roles and project hooks. Codex trusts
# each project and each hook separately; this script does not make either choice.
#
# Usage: configure-codex-project.sh [project-directory]
#
# Findings contract:
#   CODEX-PROJECT-OK: project-local agents and hooks were written
#   CODEX-PROJECT-FAIL: project configuration stopped; the reason follows
#
# The script preserves config outside one marked TOML block. It merges the two
# toolkit handlers into hooks.json and leaves all other handlers in place.
# It never changes Codex's project-trust or hook-trust records.
set -uo pipefail

fail() {
  printf 'CODEX-PROJECT-FAIL: %s\n' "$1" >&2
  exit 1
}

command -v git >/dev/null 2>&1 || fail 'git is required'
command -v node >/dev/null 2>&1 || fail 'node is required because npx skills and the JSON merge use it'
command -v codex >/dev/null 2>&1 || fail 'codex is required to validate the generated project configuration'

requested="${1:-.}"
project="$(cd "$requested" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" ||
  fail "not a git repository: $requested"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" ||
  fail 'cannot resolve the installed setup-engineering-skills directory'
bundle_root="$(cd "$script_dir/.." 2>/dev/null && pwd)" ||
  fail 'cannot resolve the installed setup-engineering-skills directory'
manifest="$bundle_root/codex/skill-manifest.txt"
role_source="$bundle_root/codex/agents"

[ -f "$manifest" ] || fail "missing installer manifest: $manifest"
[ -d "$role_source" ] || fail "missing Codex agent templates: $role_source"

missing=""
skill_count=0
while IFS= read -r skill; do
  [ -n "$skill" ] || continue
  skill_count=$((skill_count + 1))
  if [ ! -f "$project/.agents/skills/$skill/SKILL.md" ]; then
    missing="${missing}${missing:+, }$skill"
  fi
done < "$manifest"
[ -z "$missing" ] || fail "all toolkit skills must be installed first; missing: $missing"

codex_dir="$project/.codex"
agent_dir="$codex_dir/agents"
mkdir -p "$agent_dir" || fail "cannot create $agent_dir"

config_tmp="$codex_dir/.toolkit-config.$$"
hooks_tmp="$codex_dir/.toolkit-hooks.$$"
roles_tmp="$codex_dir/.toolkit-agents.$$"
validation_dir="$codex_dir/.toolkit-validation.$$"
cleanup() {
  rm -f "$config_tmp" "$hooks_tmp"
  rm -rf "$roles_tmp"
  [ -n "$validation_dir" ] && rm -rf "$validation_dir"
}
trap cleanup EXIT HUP INT TERM

PROJECT_CONFIG="$codex_dir/config.toml" OUTPUT_CONFIG="$config_tmp" node <<'NODE'
const fs = require('fs');
const input = process.env.PROJECT_CONFIG;
const output = process.env.OUTPUT_CONFIG;
const begin = '# >>> agent-toolkit Codex agents >>>';
const end = '# <<< agent-toolkit Codex agents <<<';
const block = `${begin}
[agents.operative]
config_file = "agents/toolkit-operative.toml"

[agents.verifier]
config_file = "agents/toolkit-verifier.toml"

[agents.scorer]
config_file = "agents/toolkit-scorer.toml"

[agents.score-calibrator]
config_file = "agents/toolkit-score-calibrator.toml"
${end}`;
let text = fs.existsSync(input) ? fs.readFileSync(input, 'utf8') : '';
const beginCount = text.split(begin).length - 1;
const endCount = text.split(end).length - 1;
if (beginCount !== endCount || beginCount > 1) {
  throw new Error('config.toml has incomplete or duplicate agent-toolkit markers');
}
let outside = text;
if (beginCount === 1) {
  const start = text.indexOf(begin);
  const finish = text.indexOf(end, start) + end.length;
  outside = text.slice(0, start) + text.slice(finish);
}
for (const role of ['operative', 'verifier', 'scorer', 'score-calibrator']) {
  const escaped = role.replace('-', '\\-');
  const header = new RegExp(`^\\s*\\[agents\\.(?:"${escaped}"|'${escaped}'|${escaped})\\]\\s*(?:#.*)?$`, 'm');
  if (header.test(outside)) {
    throw new Error(`config.toml already defines agents.${role} outside the agent-toolkit block`);
  }
}
outside = outside.replace(/\s+$/, '');
const merged = outside ? `${outside}\n\n${block}\n` : `${block}\n`;
fs.writeFileSync(output, merged, { mode: 0o600 });
NODE
config_code=$?
[ "$config_code" = 0 ] || fail 'could not merge the agent role block into .codex/config.toml'

PROJECT_HOOKS="$codex_dir/hooks.json" OUTPUT_HOOKS="$hooks_tmp" node <<'NODE'
const fs = require('fs');
const input = process.env.PROJECT_HOOKS;
const output = process.env.OUTPUT_HOOKS;
let doc = fs.existsSync(input)
  ? JSON.parse(fs.readFileSync(input, 'utf8'))
  : { hooks: {} };
if (!doc || Array.isArray(doc) || typeof doc !== 'object') throw new Error('hooks.json must contain an object');
if (doc.hooks === undefined) doc.hooks = {};
if (!doc.hooks || Array.isArray(doc.hooks) || typeof doc.hooks !== 'object') {
  throw new Error('hooks.json hooks must contain an object');
}
const sessionCommand = '/bin/bash "$(git rev-parse --show-toplevel)/.agents/skills/unslop/scripts/reminder.sh" codex-session';
const promptCommand = '/bin/bash "$(git rev-parse --show-toplevel)/.agents/skills/unslop/scripts/reminder.sh" codex-prompt';
function isManagedHandler(handler, command) {
  return handler && !Array.isArray(handler) && typeof handler === 'object' &&
    Object.keys(handler).length === 2 && handler.type === 'command' && handler.command === command;
}
function withoutToolkit(groups, command) {
  if (groups === undefined) return [];
  if (!Array.isArray(groups)) throw new Error('hook event must contain an array');
  return groups.flatMap(group => {
    if (!group || Array.isArray(group) || typeof group !== 'object' || !Array.isArray(group.hooks)) {
      throw new Error('hook matcher group must contain a hooks array');
    }
    const hooks = group.hooks.filter(handler => !isManagedHandler(handler, command));
    return hooks.length ? [{ ...group, hooks }] : [];
  });
}
doc.hooks.SessionStart = withoutToolkit(doc.hooks.SessionStart, sessionCommand);
doc.hooks.UserPromptSubmit = withoutToolkit(doc.hooks.UserPromptSubmit, promptCommand);
doc.hooks.SessionStart.push({
  matcher: 'startup|resume',
  hooks: [{
    type: 'command',
    command: sessionCommand
  }]
});
doc.hooks.UserPromptSubmit.push({
  hooks: [{
    type: 'command',
    command: promptCommand
  }]
});
fs.writeFileSync(output, `${JSON.stringify(doc, null, 2)}\n`, { mode: 0o600 });
NODE
hooks_code=$?
[ "$hooks_code" = 0 ] || fail 'could not merge toolkit handlers into .codex/hooks.json'

mkdir "$roles_tmp" || fail 'cannot stage Codex agent role files'
for role in operative verifier scorer score-calibrator; do
  source_file="$role_source/toolkit-$role.toml"
  [ -f "$source_file" ] || fail "missing Codex agent template: $source_file"
  cp "$source_file" "$roles_tmp/toolkit-$role.toml" || fail "cannot stage toolkit-$role.toml"
done

mkdir -p "$validation_dir/agents" || fail 'cannot stage Codex configuration validation'
cp "$config_tmp" "$validation_dir/config.toml" || fail 'cannot stage Codex config validation'
cp "$hooks_tmp" "$validation_dir/hooks.json" || fail 'cannot stage Codex hooks validation'
for role in operative verifier scorer score-calibrator; do
  cp "$roles_tmp/toolkit-$role.toml" "$validation_dir/agents/toolkit-$role.toml" ||
    fail "cannot stage toolkit-$role.toml validation"
done
(
  cd "$validation_dir" || exit 1
  CODEX_HOME="$validation_dir" codex -c 'project_root_markers=[]' features list >/dev/null 2>&1
) || fail 'Codex rejected the generated project configuration'

for role in operative verifier scorer score-calibrator; do
  mv "$roles_tmp/toolkit-$role.toml" "$agent_dir/toolkit-$role.toml" ||
    fail "cannot install toolkit-$role.toml"
done
rmdir "$roles_tmp" 2>/dev/null || true
mv "$config_tmp" "$codex_dir/config.toml" || fail 'cannot install .codex/config.toml'
mv "$hooks_tmp" "$codex_dir/hooks.json" || fail 'cannot install .codex/hooks.json'
chmod +x "$project/.agents/skills/unslop/scripts/reminder.sh" 2>/dev/null || true

printf 'CODEX-PROJECT-OK: installed %s skills, 4 agent roles, and 2 codex-exec hook handlers in %s\n' "$skill_count" "$project"
printf '%s\n' 'Toolkit project hooks support codex exec only. Interactive Codex is unsupported.'
printf '%s\n' 'Approve project trust, then review and trust the project hooks before using codex exec.'
exit 0
