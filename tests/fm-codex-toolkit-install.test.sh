#!/usr/bin/env bash
# Behavioral coverage for the pinned Codex toolkit installer and adaptations.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALLER="$ROOT/bin/fm-install-codex-toolkit.sh"
MANIFEST="$ROOT/.agents/skills/setup-engineering-skills/codex/skill-manifest.txt"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-toolkit.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fixture="$TMP_ROOT/upstream"
project="$TMP_ROOT/project"
fakebin="$TMP_ROOT/fakebin"
mkdir -p "$fixture/.agents/skills" "$project/bin" "$fakebin"

while IFS= read -r skill; do
  [ -n "$skill" ] || continue
  cp -R "$ROOT/.agents/skills/$skill" "$fixture/.agents/skills/$skill"
done < "$MANIFEST"
cp "$ROOT/skills-lock.json" "$fixture/skills-lock.json"

python3 - "$fixture" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for skill_file in root.glob(".agents/skills/*/SKILL.md"):
    lines = skill_file.read_text(encoding="utf-8").splitlines(keepends=True)
    close = next(i for i, line in enumerate(lines[1:], 1) if line.rstrip("\r\n") == "---")
    frontmatter = [line.rstrip("\r\n") for line in lines[1:close]]
    metadata = frontmatter.index("metadata:")
    assert frontmatter[metadata + 1] == "  internal: true"
    del lines[metadata + 1]
    del lines[metadata]
    skill_file.write_text("".join(lines), encoding="utf-8")

runner = root / ".agents/skills/drain-ready-queue/scripts/runner.sh"
text = runner.read_text(encoding="utf-8")
text = text.replace(
    "no plugin root three directories above this runner carries .claude-plugin/plugin.json",
    "no plugin root three directories above $here carries .claude-plugin/plugin.json",
)
text = text.replace(
    "RUNNER-LOCK-STALE: the run lock recorded pid $holder, which is gone — claiming it",
    "RUNNER-LOCK-STALE: $LOCK recorded pid $holder, which is gone — claiming it",
)
text = text.replace(
    "RUNNER-LOCK: pid $$ holds the run lock for this run",
    "RUNNER-LOCK: pid $$ holds $LOCK for this run",
)
runner.write_text(text, encoding="utf-8")
PY

cp "$INSTALLER" "$project/bin/fm-install-codex-toolkit.sh"
chmod +x "$project/bin/fm-install-codex-toolkit.sh"
git -C "$project" init -q
git -C "$project" add bin
git -C "$project" -c user.name=test -c user.email=test@example.invalid commit -qm baseline

cat > "$fakebin/npx" <<'SH'
#!/usr/bin/env bash
set -eu
expected="--yes skills@1.5.1 add https://github.com/jjtylr/agent-toolkit/tree/26bc6befdcfbd335a8f99cc466e664e994f647d2 --skill * --agent codex --copy --yes"
[ "$*" = "$expected" ] || { printf 'unexpected npx arguments: %s\n' "$*" >&2; exit 1; }
mkdir -p "$PWD/.agents/skills"
while IFS= read -r skill; do
  [ -n "$skill" ] || continue
  rm -rf "$PWD/.agents/skills/$skill"
  cp -R "$FAKE_TOOLKIT/.agents/skills/$skill" "$PWD/.agents/skills/$skill"
done < "$FAKE_TOOLKIT/.agents/skills/setup-engineering-skills/codex/skill-manifest.txt"
cp "$FAKE_TOOLKIT/skills-lock.json" "$PWD/skills-lock.json"
SH
cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$fakebin/npx" "$fakebin/codex"

install_fixture() {
  PATH="$fakebin:$PATH" FAKE_TOOLKIT="$fixture" "$project/bin/fm-install-codex-toolkit.sh"
}

tree_digest() {
  (
    cd "$project"
    find .agents .codex -type f -print0
    printf 'skills-lock.json\0'
  ) | LC_ALL=C sort -z | while IFS= read -r -d '' file; do
    printf '%s  ' "$file"
    shasum -a 256 "$project/$file"
  done | shasum -a 256 | cut -d' ' -f1
}

out=$(install_fixture) || fail "pinned toolkit installer failed on a released snapshot"
assert_contains "$out" "FM-TOOLKIT-INSTALL-OK: agent-toolkit 26bc6befdcfbd335a8f99cc466e664e994f647d2" \
  "installer did not report the pinned release"

python3 - "$project" <<'PY'
import json
import pathlib
import sys
import tomllib

root = pathlib.Path(sys.argv[1])
manifest = root / ".agents/skills/setup-engineering-skills/codex/skill-manifest.txt"
skills = [line for line in manifest.read_text(encoding="utf-8").splitlines() if line]
assert len(skills) == 30
for skill in skills:
    lines = (root / ".agents/skills" / skill / "SKILL.md").read_text(encoding="utf-8").splitlines()
    close = lines.index("---", 1)
    frontmatter = lines[1:close]
    metadata = frontmatter.index("metadata:")
    block = frontmatter[metadata + 1:]
    block = block[:next((i for i, line in enumerate(block) if line and not line[0].isspace()), len(block))]
    values = dict(line.strip().split(":", 1) for line in block if ":" in line)
    assert values.get("internal", "").strip() == "true", skill

config = tomllib.loads((root / ".codex/config.toml").read_text(encoding="utf-8"))
assert set(config["agents"]) == {"operative", "verifier", "scorer", "score-calibrator"}
for role, entry in config["agents"].items():
    role_file = root / ".codex" / entry["config_file"]
    bundled = root / ".agents/skills/setup-engineering-skills/codex/agents" / role_file.name
    assert role_file.read_bytes() == bundled.read_bytes(), role

hooks = json.loads((root / ".codex/hooks.json").read_text(encoding="utf-8"))["hooks"]
assert len(hooks["SessionStart"]) == 1
assert len(hooks["UserPromptSubmit"]) == 1
PY

first=$(tree_digest)
install_fixture >/dev/null || fail "pinned toolkit reinstall failed"
second=$(tree_digest)
[ "$first" = "$second" ] || fail "reinstall changed the adapted toolkit bytes"
pass "pinned reinstall is byte-stable and retains 30 internal skills and four Codex roles"

runner_dir="$project/.agents/skills/drain-ready-queue/scripts"
captured="$TMP_ROOT/comment.md"
mkdir -p "$project/private"
cat > "$runner_dir/runner-gate.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$runner_dir/run-issue-open.sh" <<'SH'
#!/usr/bin/env bash
printf '42\n'
SH
cat > "$runner_dir/run-issue-post.sh" <<'SH'
#!/usr/bin/env bash
cp "$2" "$CAPTURED_BODY"
printf '100\n'
SH
cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
shift
exec "$@"
SH
cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$runner_dir/runner-gate.sh" "$runner_dir/run-issue-open.sh" \
  "$runner_dir/run-issue-post.sh" "$fakebin/timeout" "$fakebin/claude" "$fakebin/gh" "$fakebin/jq"

PATH="$fakebin:$PATH" CAPTURED_BODY="$captured" RUNNER_LOCK="$project/private/run.lock" \
  RUNNER_MAX_ITERATIONS=1 RUNNER_SLEEP=0 \
  bash "$runner_dir/runner.sh" >/dev/null 2>&1 \
  || fail "adapted headless runner did not finish its bounded public-log fixture"
assert_present "$captured" "adapted headless runner did not post its stop log"
body=$(cat "$captured")
assert_not_contains "$body" "$project" "public run log disclosed its absolute project path"
assert_contains "$body" "three directories above this runner" \
  "public run log did not use its path-free runner description"
assert_contains "$body" "holds the run lock for this run" \
  "public run log did not use its path-free lock description"
pass "public headless-run logs omit absolute host paths"
