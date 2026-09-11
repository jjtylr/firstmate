#!/usr/bin/env bash
# fm-install-codex-toolkit.sh - reinstall the pinned Codex toolkit snapshot.
#
# Usage: bin/fm-install-codex-toolkit.sh
#
# The upstream bytes come from agent-toolkit commit 26bc6be. Firstmate then
# marks the installed skills internal, removes host paths from the public
# headless-run log, and reconciles the four Codex roles and toolkit hooks.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLKIT_COMMIT=26bc6befdcfbd335a8f99cc466e664e994f647d2
TOOLKIT_URL="https://github.com/jjtylr/agent-toolkit/tree/$TOOLKIT_COMMIT"
SKILLS_PACKAGE=skills@1.5.1

fail() {
  printf 'FM-TOOLKIT-INSTALL-FAIL: %s\n' "$1" >&2
  exit 1
}

[ $# -eq 0 ] || fail 'usage: bin/fm-install-codex-toolkit.sh'
command -v git >/dev/null 2>&1 || fail 'git is required'
command -v node >/dev/null 2>&1 || fail 'node is required'
command -v npx >/dev/null 2>&1 || fail 'npx is required'

git -C "$ROOT" rev-parse --show-toplevel >/dev/null 2>&1 || fail "$ROOT is not a git repository"

(
  cd "$ROOT"
  npx --yes "$SKILLS_PACKAGE" add "$TOOLKIT_URL" --skill '*' --agent codex --copy --yes
) || fail 'the pinned toolkit snapshot could not be installed'

manifest="$ROOT/.agents/skills/setup-engineering-skills/codex/skill-manifest.txt"
runner="$ROOT/.agents/skills/drain-ready-queue/scripts/runner.sh"
[ -f "$manifest" ] || fail "missing installed skill manifest: $manifest"
[ -f "$runner" ] || fail "missing installed headless runner: $runner"

node - "$ROOT" "$manifest" "$runner" <<'NODE'
const fs = require('fs');
const path = require('path');

const [root, manifestPath, runnerPath] = process.argv.slice(2);
const skills = fs.readFileSync(manifestPath, 'utf8')
  .split(/\r?\n/)
  .filter(Boolean);

if (skills.length !== 30 || new Set(skills).size !== skills.length) {
  throw new Error(`expected 30 unique toolkit skills, found ${skills.length}`);
}

for (const skill of skills) {
  if (!/^[a-z0-9-]+$/.test(skill)) throw new Error(`invalid skill name: ${skill}`);
  const skillPath = path.join(root, '.agents', 'skills', skill, 'SKILL.md');
  let text = fs.readFileSync(skillPath, 'utf8');
  const newline = text.includes('\r\n') ? '\r\n' : '\n';
  const lines = text.split(/\r?\n/);
  if (lines[0] !== '---') throw new Error(`${skillPath} has no YAML frontmatter`);
  const close = lines.indexOf('---', 1);
  if (close < 0) throw new Error(`${skillPath} has unterminated YAML frontmatter`);
  const metadata = lines.slice(1, close).findIndex(line => line === 'metadata:');
  if (metadata < 0) {
    lines.splice(close, 0, 'metadata:', '  internal: true');
  } else {
    const metadataLine = metadata + 1;
    let end = metadataLine + 1;
    while (end < close && (/^\s/.test(lines[end]) || lines[end] === '')) end += 1;
    const internal = lines.slice(metadataLine + 1, end)
      .findIndex(line => /^\s+internal\s*:/.test(line));
    if (internal < 0) {
      lines.splice(metadataLine + 1, 0, '  internal: true');
    } else if (!/^\s+internal\s*:\s*true\s*$/.test(lines[metadataLine + 1 + internal])) {
      throw new Error(`${skillPath} has a conflicting metadata.internal value`);
    }
  }
  const adapted = lines.join(newline);
  if (adapted !== text) fs.writeFileSync(skillPath, adapted, 'utf8');
}

let runner = fs.readFileSync(runnerPath, 'utf8');
const runnerAdaptations = [
  [
    'no plugin root three directories above $here carries .claude-plugin/plugin.json',
    'no plugin root three directories above this runner carries .claude-plugin/plugin.json'
  ],
  [
    'RUNNER-LOCK-STALE: $LOCK recorded pid $holder, which is gone — claiming it',
    'RUNNER-LOCK-STALE: the run lock recorded pid $holder, which is gone — claiming it'
  ],
  [
    'RUNNER-LOCK: pid $$ holds $LOCK for this run',
    'RUNNER-LOCK: pid $$ holds the run lock for this run'
  ]
];
for (const [upstream, adapted] of runnerAdaptations) {
  if (runner.includes(upstream)) runner = runner.replace(upstream, adapted);
  else if (!runner.includes(adapted)) throw new Error(`runner adaptation source is missing: ${upstream}`);
}
fs.writeFileSync(runnerPath, runner, 'utf8');
NODE

configurer="$ROOT/.agents/skills/setup-engineering-skills/scripts/configure-codex-project.sh"
[ -x "$configurer" ] || fail "missing executable Codex configurer: $configurer"
"$configurer" "$ROOT" || fail 'the Codex roles and hooks could not be configured'

printf 'FM-TOOLKIT-INSTALL-OK: agent-toolkit %s installed with Firstmate adaptations\n' "$TOOLKIT_COMMIT"
