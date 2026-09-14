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
TOOLKIT_REPOSITORY=https://github.com/jjtylr/agent-toolkit.git
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

toolkit_tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-toolkit.XXXXXX") \
  || fail 'could not create a temporary toolkit checkout'
toolkit_source="$toolkit_tmp/source"
stage_root="$toolkit_tmp/stage"
lock_backup="$toolkit_tmp/skills-lock.json"
cleanup() {
  rm -rf "$toolkit_tmp"
}
trap cleanup EXIT HUP INT TERM

mkdir "$toolkit_source" || fail 'could not stage the pinned toolkit snapshot'
git -C "$toolkit_source" init -q \
  || fail 'could not initialize the pinned toolkit checkout'
git -C "$toolkit_source" fetch --depth 1 "$TOOLKIT_REPOSITORY" "$TOOLKIT_COMMIT" \
  || fail 'the pinned toolkit commit could not be fetched'
git -C "$toolkit_source" checkout -q --detach FETCH_HEAD \
  || fail 'the pinned toolkit commit could not be checked out'
[ "$(git -C "$toolkit_source" rev-parse HEAD 2>/dev/null)" = "$TOOLKIT_COMMIT" ] \
  || fail 'the fetched toolkit commit did not match the pin'
[ -f "$ROOT/skills-lock.json" ] \
  || fail 'the canonical Firstmate skills lock is missing'
cp "$ROOT/skills-lock.json" "$lock_backup" \
  || fail 'the canonical Firstmate skills lock could not be staged'
mkdir -p "$stage_root/.agents" \
  || fail 'could not create the staged Firstmate tree'
cp -R "$ROOT/.agents/skills" "$stage_root/.agents/skills" \
  || fail 'the existing Firstmate skills could not be staged'
if [ -d "$ROOT/.codex" ]; then
  cp -R "$ROOT/.codex" "$stage_root/.codex" \
    || fail 'the existing Codex project configuration could not be staged'
else
  mkdir "$stage_root/.codex" \
    || fail 'the staged Codex project configuration could not be created'
fi
cp "$lock_backup" "$stage_root/skills-lock.json" \
  || fail 'the canonical Firstmate skills lock could not be copied into staging'
git -C "$stage_root" init -q \
  || fail 'could not initialize the staged Firstmate tree'

(
  cd "$stage_root"
  npx --yes "$SKILLS_PACKAGE" add "$toolkit_source" --skill '*' --agent codex --copy --yes
) || fail 'the pinned toolkit snapshot could not be installed'
cp "$lock_backup" "$stage_root/skills-lock.json" \
  || fail 'the canonical Firstmate skills lock could not be restored'

manifest="$stage_root/.agents/skills/setup-engineering-skills/codex/skill-manifest.txt"
runner="$stage_root/.agents/skills/drain-ready-queue/scripts/runner.sh"
[ -f "$manifest" ] || fail "missing installed skill manifest: $manifest"
[ -f "$runner" ] || fail "missing installed headless runner: $runner"

node - "$stage_root" "$manifest" "$runner" <<'NODE'
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
    const name = lines.slice(1, close).findIndex(line => /^name\s*:/.test(line));
    if (name < 0) throw new Error(`${skillPath} has no frontmatter name`);
    lines.splice(name + 2, 0, 'metadata:', '  internal: true');
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
  runner = runner.replace(upstream, () => adapted);
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
# terminal diagnostic useful while suppressing path-bearing persisted lines.
sanitize_log_line() {
  case "$1" in
    */*) printf '%s\\n' '<host-path>' ;;
    *) printf '%s\\n' "$1" ;;
  esac
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
runner = runner.replace(oldSay, () => newSay);
fs.writeFileSync(runnerPath, runner, 'utf8');

const dispatchWrapper = `#!/usr/bin/env bash
# Firstmate adaptation of the upstream Codex operative runner.
set -u
here="$(cd "$(dirname "\${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 2
root="\${FM_ROOT:-$(cd "$here/../../../../" 2>/dev/null && pwd -P)}"
[ -x "$root/bin/fm-codex-toolkit-dispatch.sh" ] || {
  printf 'CODEX-OPERATIVE-REFUSED: Firstmate dispatch adapter is missing\\n' >&2
  exit 2
}
FM_ROOT="$root" exec "$root/bin/fm-codex-toolkit-dispatch.sh" "$@"
`;
fs.writeFileSync(
  path.join(root, '.agents/skills/drain-ready-queue/scripts/run-codex-operative.sh'),
  dispatchWrapper,
  'utf8'
);
const mergeScriptPath = path.join(
  root,
  '.agents/skills/drain-ready-queue/scripts/merge-pinned.sh'
);
let mergeScript = fs.readFileSync(mergeScriptPath, 'utf8');
const mergeAnchor = 'here="$(cd "$(dirname "$0")" && pwd)"\n';
const firstmateMergeRoute = `
if [ "$#" -eq 5 ]; then
  root="\${FM_ROOT:-$(cd "$here/../../../../" 2>/dev/null && pwd -P)}"
  [ -x "$root/bin/fm-codex-toolkit-merge.sh" ] || {
    printf 'MERGE-FAILED:Firstmate merge adapter is missing; nothing was attempted\\n'
    exit 1
  }
  FM_ROOT="$root" exec "$root/bin/fm-codex-toolkit-merge.sh" "$@"
fi
`;
if (!mergeScript.includes(mergeAnchor)) {
  throw new Error('merge-pinned entry point is missing');
}
mergeScript = mergeScript.replace(mergeAnchor, mergeAnchor + firstmateMergeRoute);
fs.writeFileSync(mergeScriptPath, mergeScript, 'utf8');
fs.chmodSync(
  path.join(root, '.agents/skills/drain-ready-queue/scripts/run-codex-operative.sh'),
  0o755
);
fs.chmodSync(
  mergeScriptPath,
  0o755
);

const codexDoc = path.join(root, '.agents/skills/drain-ready-queue/CODEX-OPERATIVE.md');
const codexDocText = [
  '# Codex operative runner (Firstmate adaptation)',
  '',
  'Firstmate owns worker dispatch, isolation, harness selection, trust handling, and merge authority.',
  "The upstream toolkit runner's private `codex exec` path is not used after installation here.",
  'Use one stable Firstmate task id for each ticket from dispatch through cleanup.',
  '',
  "1. Create the task brief with Firstmate's `bin/fm-brief.sh`.",
  '2. Run `FM_TASK_ID=<task-id> FM_TOOLKIT_PROJECT=<project> FM_TOOLKIT_MODE=<mode> FM_TOOLKIT_YOLO=<on|off> bash "$SKILL/scripts/run-codex-operative.sh" <N> <SLUG> <absolute-brief-file>` from the repo root.',
  "3. Supervise the task through Firstmate's durable records, and send requested fixes through `bin/fm-send.sh <task-id> <message>`.",
  '4. Pass the same `<task-id>` as the fifth argument to `merge-pinned.sh`.',
  '5. After the pull request lands, or after a terminal no-change result, run `bin/fm-teardown.sh <task-id>`.',
  '',
  'The adapted `run-codex-operative.sh` verifies `FM_HOME`, `FM_TASK_ID`, the explicit project, mode, and yolo inputs, and that the supplied brief matches `$FM_HOME/data/$FM_TASK_ID/brief.md`.',
  'It then delegates to `bin/fm-spawn.sh` and prints `CODEX-OPERATIVE-DISPATCHED` when that handoff succeeds and `CODEX-OPERATIVE-REFUSED` otherwise.',
  'It never falls back to a direct Codex process or to the parent checkout.',
  'The upstream `reap.sh` and `cleanup-stopped.sh` scripts own Claude worktrees only and must not run for a Firstmate-dispatched Codex task.',
  'If `fm-teardown.sh` refuses cleanup, leave the task record, worktree, branch, and lane claim intact and report the refusal.',
  ''
].join('\n');
fs.writeFileSync(codexDoc, codexDocText, 'utf8');
const skillDoc = path.join(root, '.agents/skills/drain-ready-queue/SKILL.md');
let skill = fs.readFileSync(skillDoc, 'utf8');
function adaptSkill(upstream, adapted, label) {
  if (!skill.includes(upstream)) throw new Error(`${label} instructions are missing`);
  skill = skill.replace(upstream, () => adapted);
}
adaptSkill(
  'flag it. It provisions no workspaces but reaps each subagent\'s worktree under\n' +
    '`<repo>/.claude/worktrees/` (RATIONALE § 0).',
  'flag it. It provisions no workspaces.',
  'workspace lifecycle'
);
adaptSkill(
  '### 1. Reap what merged while the PM was reviewing — `bash "$SKILL/scripts/reap.sh"`\n',
  '### 1. Reconcile finished work\n\n' +
    '**Codex:** follow [CODEX-OPERATIVE.md](./CODEX-OPERATIVE.md) and skip the Claude worktree reaper.\n\n' +
    '**Claude Code:** `bash "$SKILL/scripts/reap.sh"`\n',
  'reconciliation lifecycle'
);
const upstreamCodex = `**Codex:** follow [CODEX-OPERATIVE.md](./CODEX-OPERATIVE.md). Run \`bash
"$SKILL/scripts/run-codex-operative.sh" <N> <SLUG> <absolute-brief-file>\` from the repo root, one
parallel call per lane. Never use \`spawn_agent\` or replace a refusal with direct \`codex exec\`.
`;
const firstmateCodex = `**Codex:** follow [CODEX-OPERATIVE.md](./CODEX-OPERATIVE.md), including its stable Firstmate task id.
Never use \`spawn_agent\`, direct \`codex exec\`, or bypass Firstmate dispatch after a refusal.
`;
adaptSkill(upstreamCodex, firstmateCodex, 'Codex dispatch');
adaptSkill(
  '**If a subagent dies mid-ticket**, never silently re-dispatch — RATIONALE § 4 has the procedure.',
  '**If a subagent dies mid-ticket**, Codex follows Firstmate\'s task record in\n' +
    '[CODEX-OPERATIVE.md](./CODEX-OPERATIVE.md), while Claude Code follows RATIONALE § 4.\n' +
    'Never silently re-dispatch.',
  'dead worker lifecycle'
);
adaptSkill(
  '- **Merge** → nothing to do; the next iteration\'s reap (step 1) collects the worktree and branches.',
  '- **Merge** → Codex follows the guarded cleanup in [CODEX-OPERATIVE.md](./CODEX-OPERATIVE.md), while\n' +
    '  Claude Code\'s next iteration reaps its worktree and branches.',
  'merged worker lifecycle'
);
adaptSkill(
  '- **More fixes** → **`SendMessage` to that same agent** with the PM\'s notes (RATIONALE § 6).',
  '- **More fixes** → Codex sends the PM\'s notes through `bin/fm-send.sh <task-id> <message>`, while\n' +
    '  Claude Code uses **`SendMessage` to that same agent** (RATIONALE § 6).',
  'worker steering'
);
adaptSkill(
  '- **STOPPED recap** → move the ticket out of the queue, then collect the branch the no-PR run left:\n',
  '- **STOPPED recap** → move the ticket out of the queue, then collect the branch the no-PR run left:\n\n' +
    '  Codex follows the guarded cleanup in [CODEX-OPERATIVE.md](./CODEX-OPERATIVE.md).\n' +
    '  Claude Code runs:\n',
  'stopped worker lifecycle'
);
adaptSkill(
  '- `MERGE-PINNED:` (exit 0) → merged. Count it toward the `auto_merge_checkin` bound and name the\n' +
    '  policy and the reason in your report, so the PM can audit the run afterwards.',
  '- `MERGE-PINNED:` (exit 0) → merged. Codex first follows the guarded cleanup in\n' +
    '  [CODEX-OPERATIVE.md](./CODEX-OPERATIVE.md). Count it toward the `auto_merge_checkin` bound and\n' +
    '  name the policy and the reason in your report, so the PM can audit the run afterwards.',
  'auto-merge cleanup'
);
const upstreamMerge = 'the park conditions; `gh pr merge` never runs bare, and never unpinned. Carry in what this cycle\nestablished:';
const firstmateMerge = 'the park conditions. The toolkit never invokes a forge merge command directly; carry the Firstmate\nmerge owner\'s verified result into this cycle. Carry in what this cycle established:';
adaptSkill(upstreamMerge, firstmateMerge, 'merge');
fs.writeFileSync(skillDoc, skill, 'utf8');

const orchestrationPath = path.join(root, '.agents/skills/drain-ready-queue/ORCHESTRATION.md');
let orchestration = fs.readFileSync(orchestrationPath, 'utf8');
const upstreamDispatch = `Use the client's fresh-worker mechanism. Claude Code uses the \`Agent\` tool. Codex uses its named
project roles, except for the drain operative: Codex \`spawn_agent\` inherits the parent checkout and
cannot isolate a lane, so \`drain-ready-queue\` uses its bounded \`run-codex-operative.sh\` process.
That process starts a fresh \`codex exec\` in one proven owned worktree. Never replace it with a
Codex subagent in the parent checkout.`;
const firstmateDispatch = `Use the client's fresh-worker mechanism. Claude Code uses the \`Agent\` tool. Codex uses its named
project roles, except for the drain operative.
Firstmate dispatches that operative asynchronously through its durable task record.
Never replace it with a Codex subagent or direct process in the parent checkout.`;
const upstreamWait = `Harness workers already run in the background and notify you when one completes.
\`run_in_background\` is a **Bash** parameter, not an \`Agent\` one, and passing it to \`Agent\` is an
input error, not a no-op. For Codex operative lanes, start one blocking runner command per lane in
a parallel shell tool-call batch and take whichever call returns first.`;
const firstmateWait = `Harness workers already run in the background and notify you when one completes.
\`run_in_background\` is a **Bash** parameter, not an \`Agent\` one, and passing it to \`Agent\` is an
input error, not a no-op.
For Codex operative lanes, \`run-codex-operative.sh\` reports only dispatch acceptance.
Keep the lane occupied until Firstmate surfaces that task's terminal notification, then read the
durable task state before advancing the ticket.`;
for (const [upstream, adapted, label] of [
  [upstreamDispatch, firstmateDispatch, 'dispatch'],
  [upstreamWait, firstmateWait, 'completion']
]) {
  if (orchestration.includes(upstream)) {
    orchestration = orchestration.replace(upstream, adapted);
  } else if (!orchestration.includes(adapted)) {
    throw new Error(`orchestration ${label} adaptation source is missing`);
  }
}
fs.writeFileSync(orchestrationPath, orchestration, 'utf8');

const mergePipelinePath = path.join(root, '.agents/skills/drain-ready-queue/MERGE-PIPELINE.md');
let mergePipeline = fs.readFileSync(mergePipelinePath, 'utf8');
const upstreamPinnedCommand =
  '```bash\n' +
  'bash "$SKILL/scripts/merge-decision.sh" <verdict> "<checks-line>" <merge_policy> "<MARKER>" \\\n' +
  '  && bash "$SKILL/scripts/merge-freshness.sh" <pr> <commit from step 3> \\\n' +
  '  && bash "$SKILL/scripts/merge-pinned.sh" <pr> <commit from step 3> <merge_method> <merge_policy>\n```';
const firstmatePinnedCommand =
  'Use the four-argument merge entry point for a Claude Code lane.\n\n' +
  '```bash\n' +
  'bash "$SKILL/scripts/merge-decision.sh" <verdict> "<checks-line>" <merge_policy> "<MARKER>" \\\n' +
  '  && bash "$SKILL/scripts/merge-freshness.sh" <pr> <commit from step 3> \\\n' +
  '  && bash "$SKILL/scripts/merge-pinned.sh" <pr> <commit from step 3> <merge_method> <merge_policy>\n```\n\n' +
  'Use the five-argument entry point only for a Firstmate-dispatched Codex task, with the stable task id chosen at dispatch.\n\n' +
  '```bash\n' +
  'bash "$SKILL/scripts/merge-decision.sh" <verdict> "<checks-line>" <merge_policy> "<MARKER>" \\\n' +
  '  && bash "$SKILL/scripts/merge-freshness.sh" <pr> <commit from step 3> \\\n' +
  '  && bash "$SKILL/scripts/merge-pinned.sh" <pr> <commit from step 3> <merge_method> <merge_policy> <task-id>\n```';
if (mergePipeline.includes(upstreamPinnedCommand)) {
  mergePipeline = mergePipeline.replace(upstreamPinnedCommand, firstmatePinnedCommand);
} else if (!mergePipeline.includes(firstmatePinnedCommand)) {
  throw new Error('merge pipeline task-id adaptation source is missing');
}
fs.writeFileSync(mergePipelinePath, mergePipeline, 'utf8');

const mergePolicyPath = path.join(root, '.agents/skills/drain-ready-queue/MERGE-POLICY.md');
let mergePolicy = fs.readFileSync(mergePolicyPath, 'utf8');
const upstreamPolicyCommand =
  '- **Merge-step action:** the serialized merge pipeline, [MERGE-PIPELINE.md](./MERGE-PIPELINE.md) —\n' +
  '  one PR at a time: update the branch server-side, wait out the restarted checks, read the head\n' +
  '  from the host and verify at exactly that commit, then chain\n' +
  '  `merge-decision.sh <verdict> <checks-line> <merge_policy> <verdict-marker>` into\n' +
  '  `merge-freshness.sh <pr> <commit>` into `merge-pinned.sh <pr> <commit> <merge_method>\n' +
  '  <merge_policy>`. `gh pr merge`';
const firstmatePolicyCommand =
  '- **Merge-step action:** Run the serialized merge pipeline in [MERGE-PIPELINE.md](./MERGE-PIPELINE.md), one PR at a time.\n' +
  '  Update the branch server-side, wait out the restarted checks, read the head from the host, and verify at exactly that commit.\n' +
  '  Then run the harness-specific chain in [MERGE-PIPELINE.md](./MERGE-PIPELINE.md).\n' +
  '  Claude Code uses the upstream four-argument merge entry point.\n' +
  '  A Firstmate-dispatched Codex task adds its stable task id as the fifth argument.\n' +
  '  `gh pr merge`';
if (mergePolicy.includes(upstreamPolicyCommand)) {
  mergePolicy = mergePolicy.replace(upstreamPolicyCommand, firstmatePolicyCommand);
} else if (!mergePolicy.includes(firstmatePolicyCommand)) {
  throw new Error('merge policy task-id adaptation source is missing');
}
fs.writeFileSync(mergePolicyPath, mergePolicy, 'utf8');

const configurerPath = path.join(
  root,
  '.agents/skills/setup-engineering-skills/scripts/configure-codex-project.sh'
);
let configurer = fs.readFileSync(configurerPath, 'utf8');
const configurerAdaptations = [
  [
    "matcher: 'startup|resume|clear|compact'",
    "matcher: 'startup|resume'"
  ],
  [
    `const signature = '.agents/skills/unslop/scripts/reminder.sh';
function withoutToolkit(groups) {
  if (groups === undefined) return [];
  if (!Array.isArray(groups)) throw new Error('hook event must contain an array');
  return groups.flatMap(group => {
    if (!group || Array.isArray(group) || typeof group !== 'object' || !Array.isArray(group.hooks)) {
      throw new Error('hook matcher group must contain a hooks array');
    }
    const hooks = group.hooks.filter(handler =>
      !(handler && typeof handler.command === 'string' && handler.command.includes(signature))
    );
    return hooks.length ? [{ ...group, hooks }] : [];
  });
}
doc.hooks.SessionStart = withoutToolkit(doc.hooks.SessionStart);
doc.hooks.UserPromptSubmit = withoutToolkit(doc.hooks.UserPromptSubmit);
doc.hooks.SessionStart.push({
  matcher: 'startup|resume',
  hooks: [{
    type: 'command',
    command: '/bin/bash "$(git rev-parse --show-toplevel)/.agents/skills/unslop/scripts/reminder.sh" codex-session'
  }]
});
doc.hooks.UserPromptSubmit.push({
  hooks: [{
    type: 'command',
    command: '/bin/bash "$(git rev-parse --show-toplevel)/.agents/skills/unslop/scripts/reminder.sh" codex-prompt'
  }]
});`,
    `const sessionCommand = '/bin/bash "$(git rev-parse --show-toplevel)/.agents/skills/unslop/scripts/reminder.sh" codex-session';
const promptCommand = '/bin/bash "$(git rev-parse --show-toplevel)/.agents/skills/unslop/scripts/reminder.sh" codex-prompt';
function isManagedHandler(handler, command) {
  return handler && !Array.isArray(handler) && typeof handler === 'object' &&
    Object.keys(handler).length === 2 && handler.type === 'command' && handler.command === command;
}
function withoutToolkit(groups, matchers, command) {
  if (groups === undefined) return [];
  if (!Array.isArray(groups)) throw new Error('hook event must contain an array');
  return groups.flatMap(group => {
    if (!group || Array.isArray(group) || typeof group !== 'object' || !Array.isArray(group.hooks)) {
      throw new Error('hook matcher group must contain a hooks array');
    }
    const keys = Object.keys(group);
    const matcher = Object.hasOwn(group, 'matcher') ? group.matcher : undefined;
    const managedShape = keys.every(key => key === 'matcher' || key === 'hooks') &&
      matchers.includes(matcher);
    if (!managedShape) return [group];
    const hooks = group.hooks.filter(handler => !isManagedHandler(handler, command));
    return hooks.length ? [{ ...group, hooks }] : [];
  });
}
doc.hooks.SessionStart = withoutToolkit(
  doc.hooks.SessionStart,
  ['startup|resume', 'startup|resume|clear|compact'],
  sessionCommand
);
doc.hooks.UserPromptSubmit = withoutToolkit(
  doc.hooks.UserPromptSubmit,
  [undefined],
  promptCommand
);
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
});`
  ],
  [
    `printf 'CODEX-PROJECT-OK: installed %s skills, 4 agent roles, and 2 hook handlers in %s\\n' "$skill_count" "$project"
printf '%s\\n' 'Restart Codex in this repository. Approve project trust, then review and trust the project hooks.'`,
    `printf 'CODEX-PROJECT-OK: installed %s skills, 4 agent roles, and 2 codex-exec hook handlers in %s\\n' "$skill_count" "$project"
printf '%s\\n' 'Toolkit project hooks support codex exec only. Interactive Codex is unsupported.'
printf '%s\\n' 'Approve project trust, then review and trust the project hooks before using codex exec.'`
  ]
];
for (const [upstream, adapted] of configurerAdaptations) {
  if (!configurer.includes(upstream)) {
    throw new Error(`Codex configurer adaptation source is missing: ${upstream}`);
  }
  configurer = configurer.replace(upstream, () => adapted);
}
fs.writeFileSync(configurerPath, configurer, 'utf8');
NODE

configurer="$stage_root/.agents/skills/setup-engineering-skills/scripts/configure-codex-project.sh"
[ -x "$configurer" ] || fail "missing executable Codex configurer: $configurer"
"$configurer" "$stage_root" || fail 'the Codex roles and hooks could not be configured'

node - "$ROOT" "$stage_root" <<'NODE'
const fs = require('fs');
const path = require('path');

const [root, stage] = process.argv.slice(2);
const nonce = `${process.pid}-${Date.now()}`;
const entries = [
  {
    live: path.join(root, '.agents', 'skills'),
    staged: path.join(stage, '.agents', 'skills'),
    prepared: path.join(root, '.agents', `.fm-toolkit-skills-${nonce}`),
    backup: path.join(root, '.agents', `.fm-toolkit-skills-backup-${nonce}`)
  },
  {
    live: path.join(root, '.codex'),
    staged: path.join(stage, '.codex'),
    prepared: path.join(root, `.fm-toolkit-codex-${nonce}`),
    backup: path.join(root, `.fm-toolkit-codex-backup-${nonce}`)
  },
  {
    live: path.join(root, 'skills-lock.json'),
    staged: path.join(stage, 'skills-lock.json'),
    prepared: path.join(root, `.fm-toolkit-skills-lock-${nonce}`),
    backup: path.join(root, `.fm-toolkit-skills-lock-backup-${nonce}`)
  }
];

try {
  for (const entry of entries) {
    fs.cpSync(entry.staged, entry.prepared, { recursive: true });
  }
  for (const entry of entries) {
    if (fs.existsSync(entry.live)) {
      fs.renameSync(entry.live, entry.backup);
      entry.backedUp = true;
    }
    fs.renameSync(entry.prepared, entry.live);
    entry.published = true;
  }
} catch (error) {
  for (const entry of [...entries].reverse()) {
    if (entry.published && fs.existsSync(entry.live)) {
      fs.rmSync(entry.live, { recursive: true, force: true });
    }
    if (entry.backedUp && fs.existsSync(entry.backup)) {
      fs.renameSync(entry.backup, entry.live);
    }
    if (fs.existsSync(entry.prepared)) {
      fs.rmSync(entry.prepared, { recursive: true, force: true });
    }
  }
  throw error;
}

for (const entry of entries) {
  fs.rmSync(entry.backup, { recursive: true, force: true });
}
NODE

printf 'FM-TOOLKIT-INSTALL-OK: agent-toolkit %s installed with Firstmate adaptations\n' "$TOOLKIT_COMMIT"
