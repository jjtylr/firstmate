#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CODEX_TOOLKIT_HOOKS_LIVE_E2E codex node

TMP_ROOT=$(fm_test_tmproot fm-codex-toolkit-hooks-live-e2e)
lab="$TMP_ROOT/project"
record="$TMP_ROOT/hooks.log"
mkdir -p "$lab/.codex" "$lab/.agents/skills/unslop/scripts"
git -C "$lab" init -q
printf '# Codex toolkit hook lab\n' > "$lab/AGENTS.md"

INPUT_HOOKS="$ROOT/.codex/hooks.json" OUTPUT_HOOKS="$lab/.codex/hooks.json" node <<'NODE' \
  || fail "could not isolate the tracked toolkit hook groups"
const fs = require('fs');
const doc = JSON.parse(fs.readFileSync(process.env.INPUT_HOOKS, 'utf8'));
const signature = '.agents/skills/unslop/scripts/reminder.sh';
const selected = {};
for (const event of ['SessionStart', 'UserPromptSubmit']) {
  selected[event] = (doc.hooks[event] || []).filter(group =>
    (group.hooks || []).some(handler =>
      typeof handler.command === 'string' && handler.command.includes(signature)
    )
  );
  if (selected[event].length !== 1) throw new Error(`expected one toolkit ${event} group`);
}
fs.writeFileSync(process.env.OUTPUT_HOOKS, `${JSON.stringify({ hooks: selected }, null, 2)}\n`);
NODE

cat > "$lab/.agents/skills/unslop/scripts/reminder.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${FM_CODEX_TOOLKIT_HOOK_RECORD:?}"
printf '[toolkit] hook %s delivered\n' "$1"
exit 0
SH
chmod +x "$lab/.agents/skills/unslop/scripts/reminder.sh"

version=$(codex --version 2>/dev/null | head -n 1)
out=$(cd "$lab" && FM_CODEX_TOOLKIT_HOOK_RECORD="$record" codex exec --ephemeral \
  --dangerously-bypass-hook-trust \
  --dangerously-bypass-approvals-and-sandbox 'Reply with exactly OK.' 2>&1)
status=$?
[ "$status" -eq 0 ] || {
  printf '%s\n' "$out" >&2
  fail "$version failed the toolkit hook probe"
}
session_count=$(grep -Fxc codex-session "$record" 2>/dev/null || true)
prompt_count=$(grep -Fxc codex-prompt "$record" 2>/dev/null || true)
session_count=${session_count:-0}
prompt_count=${prompt_count:-0}
printf 'CODEX_TOOLKIT_HOOKS session=%s prompt=%s\n' "$session_count" "$prompt_count"
[ "$session_count" -eq 1 ] || fail "$version did not deliver one toolkit SessionStart hook"
[ "$prompt_count" -eq 1 ] || fail "$version did not deliver one toolkit UserPromptSubmit hook"
pass "$version delivered both toolkit hooks under codex exec"
