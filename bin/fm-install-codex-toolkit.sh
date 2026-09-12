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
  if (!runner.includes(upstream)) throw new Error(`runner adaptation source is missing: ${upstream}`);
  runner = runner.replace(upstream, adapted);
}
const oldSay = `# Findings go to stderr as they happen *and* into the run log, which is the
# comment the run issue ends with. A headless run reports to nobody watching, so
# a line that only ever reached a terminal did not survive the run.
say() {
  printf '%s\\n' "$1" >&2
  [ -n "$LOGFILE" ] && printf '%s\\n' "$1" >> "$LOGFILE"
  return 0
}
`;
const newSay = `# Findings go to stderr as they happen *and* into the run log, which is the
# comment the run issue ends with. A headless run reports to nobody watching, so
# a line that only ever reached a terminal did not survive the run.
# Public comments must not disclose the host that ran the loop. Keep the
# terminal diagnostic useful while replacing absolute paths in the persisted log.
sanitize_log_line() {
  printf '%s\\n' "$1" | sed -E \\
    's#(^|[^[:alnum:]:/])(/[-A-Za-z0-9._~@%+,=:]+)+#\\1<host-path>#g'
}
say() {
  local public
  printf '%s\\n' "$1" >&2
  if [ -n "$LOGFILE" ]; then
    public="$(sanitize_log_line "$1")"
    printf '%s\\n' "$public" >> "$LOGFILE"
  fi
  return 0
}
`;
if (!runner.includes(oldSay)) throw new Error('runner say block is missing');
runner = runner.replace(oldSay, newSay);
fs.writeFileSync(runnerPath, runner, 'utf8');

function installFirstmateWrapper(relative, helper) {
  const target = path.join(root, relative);
  const text = `#!/usr/bin/env bash
# Firstmate adaptation of the upstream Codex toolkit entrypoint.
set -u
here="$(cd "$(dirname "\${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 2
root="\${FM_ROOT:-$(cd "$here/../../../../" 2>/dev/null && pwd -P)}"
[ -x "$root/bin/${helper}" ] || {
  printf 'Firstmate adapter is missing: %s\\n' "$root/bin/${helper}" >&2
  exit 2
}
FM_ROOT="$root" exec "$root/bin/${helper}" "$@"
`;
  fs.writeFileSync(target, text, 'utf8');
}
installFirstmateWrapper('.agents/skills/drain-ready-queue/scripts/run-codex-operative.sh', 'fm-codex-toolkit-dispatch.sh');
installFirstmateWrapper('.agents/skills/drain-ready-queue/scripts/merge-pinned.sh', 'fm-codex-toolkit-merge.sh');

const codexDoc = path.join(root, '.agents/skills/drain-ready-queue/CODEX-OPERATIVE.md');
const codexDocText = [
  '# Codex operative runner (Firstmate adaptation)',
  '',
  'Firstmate owns worker dispatch, isolation, harness selection, trust handling, and merge authority.',
  'The upstream toolkit runner path is not used after installation here.',
  '',
  'Create the task brief with `bin/fm-brief.sh`, then spawn it with `bin/fm-spawn.sh` using',
  'explicit mode, yolo posture, and `--harness codex`. The adapted three-argument runner verifies',
  '`FM_HOME`, `FM_TASK_ID`, and the recorded brief before delegating to that owner.',
  'It never falls back to a direct Codex process or to the parent checkout.',
  ''
].join('\n');
fs.writeFileSync(codexDoc, codexDocText, 'utf8');
const skillDoc = path.join(root, '.agents/skills/drain-ready-queue/SKILL.md');
let skill = fs.readFileSync(skillDoc, 'utf8');
const upstreamCodex = `**Codex:** follow [CODEX-OPERATIVE.md](./CODEX-OPERATIVE.md). Run \`bash
"$SKILL/scripts/run-codex-operative.sh" <N> <SLUG> <absolute-brief-file>\` from the repo root, one
parallel call per lane. Never use \`spawn_agent\` or replace a refusal with direct \`codex exec\`.
`;
const firstmateCodex = `**Codex:** Firstmate owns Codex dispatch. Create and record the task brief with Firstmate's
\`bin/fm-brief.sh\`, then invoke \`bin/fm-spawn.sh\` with explicit mode, yolo posture, and \`--harness
codex\`. The adapted \`run-codex-operative.sh\` accepts the legacy arguments only to verify the
recorded brief and delegates through that Firstmate owner; it never launches Codex directly.
Never use \`spawn_agent\` or bypass Firstmate dispatch after a refusal.
`;
if (!skill.includes(upstreamCodex)) throw new Error('Codex dispatch instructions are missing');
skill = skill.replace(upstreamCodex, firstmateCodex);
const upstreamMerge = '`gh pr merge` never runs bare, and never unpinned. Carry in what this cycle\n';
const firstmateMerge = 'The toolkit never invokes a forge merge command directly; carry the Firstmate\nmerge owner\'s verified result into this cycle. Carry in what this cycle\n';
if (!skill.includes(upstreamMerge)) throw new Error('merge instructions are missing');
skill = skill.replace(upstreamMerge, firstmateMerge);
fs.writeFileSync(skillDoc, skill, 'utf8');
NODE

configurer="$ROOT/.agents/skills/setup-engineering-skills/scripts/configure-codex-project.sh"
[ -x "$configurer" ] || fail "missing executable Codex configurer: $configurer"
"$configurer" "$ROOT" || fail 'the Codex roles and hooks could not be configured'

printf 'FM-TOOLKIT-INSTALL-OK: agent-toolkit %s installed with Firstmate adaptations\n' "$TOOLKIT_COMMIT"
