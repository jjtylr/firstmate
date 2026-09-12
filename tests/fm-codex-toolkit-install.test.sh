#!/usr/bin/env bash
# Behavioral coverage for the pinned Codex toolkit installer and adaptations.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALLER="$ROOT/bin/fm-install-codex-toolkit.sh"
MANIFEST="$ROOT/.agents/skills/setup-engineering-skills/codex/skill-manifest.txt"
TMP_ROOT=$(fm_test_tmproot fm-codex-toolkit-install)

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
    if "metadata:" in frontmatter:
        metadata = frontmatter.index("metadata:")
        internal = next(i for i, line in enumerate(frontmatter[metadata + 1:], metadata + 1)
                        if line.strip().startswith("internal:"))
        del lines[internal + 1]
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
adapted_say = """# Findings go to stderr as they happen *and* into the run log, which is the
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
"""
upstream_say = """# Findings go to stderr as they happen *and* into the run log, which is the
# comment the run issue ends with. A headless run reports to nobody watching, so
# a line that only ever reached a terminal did not survive the run.
say() {
  printf '%s\\n' "$1" >&2
  [ -n "$LOGFILE" ] && printf '%s\\n' "$1" >> "$LOGFILE"
  return 0
}
"""
if adapted_say not in text:
    raise SystemExit("checked-out runner is missing its Firstmate log adaptation")
runner.write_text(text.replace(adapted_say, upstream_say), encoding="utf-8")

skill = root / ".agents/skills/drain-ready-queue/SKILL.md"
text = skill.read_text(encoding="utf-8")
adapted_dispatch = """**Codex:** Firstmate owns Codex dispatch. Create and record the task brief with Firstmate's
`bin/fm-brief.sh`, then invoke `bin/fm-spawn.sh` with explicit mode, yolo posture, and `--harness
codex`. The adapted `run-codex-operative.sh` accepts the legacy arguments only to verify the
recorded brief and delegates through that Firstmate owner; it never launches Codex directly.
Never use `spawn_agent` or bypass Firstmate dispatch after a refusal.
"""
upstream_dispatch = """**Codex:** follow [CODEX-OPERATIVE.md](./CODEX-OPERATIVE.md). Run `bash
"$SKILL/scripts/run-codex-operative.sh" <N> <SLUG> <absolute-brief-file>` from the repo root, one
parallel call per lane. Never use `spawn_agent` or replace a refusal with direct `codex exec`.
"""
adapted_merge = """The toolkit never invokes a forge merge command directly; carry the Firstmate
merge owner's verified result into this cycle. Carry in what this cycle established: the verdict word your own step-5 dispatch returned, the `pr-checks.sh` line, the
"""
upstream_merge = """`gh pr merge` never runs bare, and never unpinned. Carry in what this cycle
established: the verdict word your own step-5 dispatch returned, the `pr-checks.sh` line, the
"""
if adapted_dispatch not in text or adapted_merge not in text:
    raise SystemExit("checked-out skill is missing its Firstmate toolkit adaptations")
text = text.replace(adapted_dispatch, upstream_dispatch)
skill.write_text(text.replace(adapted_merge, upstream_merge), encoding="utf-8")
PY

cp "$INSTALLER" "$project/bin/fm-install-codex-toolkit.sh"
cp "$ROOT/bin/fm-codex-toolkit-dispatch.sh" "$project/bin/"
cp "$ROOT/bin/fm-codex-toolkit-merge.sh" "$project/bin/"
chmod +x "$project/bin/fm-install-codex-toolkit.sh" "$project/bin/fm-codex-toolkit-"*.sh
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

spawn_log="$TMP_ROOT/spawn.log"
cat > "$project/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$SPAWN_LOG"
SH
cat > "$project/bin/fm-pr-merge.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$MERGE_LOG"
SH
cat > "$project/bin/fm-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOLD_LOG"
[ "${RELEASED_APPROVAL:-0}" = 1 ]
SH
cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "repo view") printf 'https://github.com/example/project\n' ;;
  "pr view") printf 'build: keep examined behavior\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$project/bin/fm-spawn.sh" "$project/bin/fm-pr-merge.sh" \
  "$project/bin/fm-captain-hold.sh" "$fakebin/gh"
mkdir -p "$TMP_ROOT/home/data/task-42" "$TMP_ROOT/home/state"
printf 'dispatch brief\n' > "$TMP_ROOT/brief.md"
cp "$TMP_ROOT/brief.md" "$TMP_ROOT/home/data/task-42/brief.md"
SPAWN_LOG="$spawn_log" FM_ROOT="$project" FM_HOME="$TMP_ROOT/home" FM_TASK_ID=task-42 \
  "$project/.agents/skills/drain-ready-queue/scripts/run-codex-operative.sh" \
  42 example "$TMP_ROOT/brief.md" >/dev/null \
  || fail "Codex toolkit runner did not delegate through Firstmate spawn"
assert_contains "$(cat "$spawn_log")" "task-42 $project --mode direct-PR --yolo off --harness codex" \
  "Codex toolkit runner did not pass explicit Firstmate spawn policy"
merge_log="$TMP_ROOT/merge.log"
hold_log="$TMP_ROOT/hold.log"
printf 'yolo=on\n' > "$TMP_ROOT/home/state/task-42.meta"
for rejected_policy in pm-merge unknown-policy; do
  rm -f "$merge_log" "$hold_log"
  if HOLD_LOG="$hold_log" RELEASED_APPROVAL=1 MERGE_LOG="$merge_log" FM_ROOT="$project" \
    FM_HOME="$TMP_ROOT/home" FM_TASK_ID=task-42 PATH="$fakebin:$PATH" \
    "$project/.agents/skills/drain-ready-queue/scripts/merge-pinned.sh" \
    7 0123456789012345678901234567890123456789 squash "$rejected_policy" \
    > "$TMP_ROOT/policy.out" 2> "$TMP_ROOT/policy.err"; then
    fail "Codex toolkit merge runner accepted non-auto policy $rejected_policy"
  fi
  assert_absent "$merge_log" "non-auto policy $rejected_policy reached Firstmate's merge owner"
  assert_absent "$hold_log" "non-auto policy $rejected_policy reached captain-release authority"
  assert_contains "$(cat "$TMP_ROOT/policy.out")" "is not an auto policy" \
    "non-auto policy $rejected_policy did not explain its refusal"
done

printf 'yolo=off\n' > "$TMP_ROOT/home/state/task-42.meta"
if HOLD_LOG="$hold_log" RELEASED_APPROVAL=0 MERGE_LOG="$merge_log" FM_ROOT="$project" \
  FM_HOME="$TMP_ROOT/home" FM_TASK_ID=task-42 PATH="$fakebin:$PATH" \
  "$project/.agents/skills/drain-ready-queue/scripts/merge-pinned.sh" \
  7 0123456789012345678901234567890123456789 squash auto-on-verdict \
  > "$TMP_ROOT/unauthorized.out" 2> "$TMP_ROOT/unauthorized.err"; then
  fail "Codex toolkit merge runner accepted yolo=off without a captain release"
fi
assert_absent "$merge_log" "unauthorized Codex toolkit merge reached Firstmate's merge owner"
assert_contains "$(cat "$TMP_ROOT/unauthorized.out")" "no durable captain release" \
  "unauthorized Codex toolkit merge did not name its missing authority"

HOLD_LOG="$hold_log" RELEASED_APPROVAL=1 MERGE_LOG="$merge_log" FM_ROOT="$project" \
  FM_HOME="$TMP_ROOT/home" FM_TASK_ID=task-42 PATH="$fakebin:$PATH" \
  "$project/.agents/skills/drain-ready-queue/scripts/merge-pinned.sh" \
  7 0123456789012345678901234567890123456789 squash auto-on-verdict >/dev/null \
  || fail "Codex toolkit merge runner did not delegate through Firstmate merge authority"
assert_contains "$(cat "$hold_log")" "released task-42" \
  "Codex toolkit merge runner did not verify the captain release"
assert_contains "$(cat "$merge_log")" \
  "task-42 https://github.com/example/project/pull/7 --expected-head 0123456789012345678901234567890123456789 -- --squash --subject build: keep examined behavior (#7)" \
  "Codex toolkit merge runner dropped its commit pin or squash subject"
pass "Codex dispatch and merge routes preserve Firstmate authority and examined inputs"

runner_dir="$project/.agents/skills/drain-ready-queue/scripts"
captured="$TMP_ROOT/comment.md"
mkdir -p "$project/private"
cat > "$runner_dir/runner-gate.sh" <<'SH'
#!/usr/bin/env bash
printf "RUNNER-CONTINUE: RUNNER_LOCK=/srv/private/run.lock, quoted '%s/hidden/file', URL https://github.com/example/project/pull/7\n" \
  "$PROJECT_SECRET" >&2
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

PATH="$fakebin:$PATH" CAPTURED_BODY="$captured" PROJECT_SECRET="$project" \
  RUNNER_LOCK="$project/private/run.lock" \
  RUNNER_MAX_ITERATIONS=1 RUNNER_SLEEP=0 \
  bash "$runner_dir/runner.sh" >/dev/null 2>&1 \
  || fail "adapted headless runner did not finish its bounded public-log fixture"
assert_present "$captured" "adapted headless runner did not post its stop log"
body=$(cat "$captured")
assert_not_contains "$body" "$project" "public run log disclosed its absolute project path"
assert_not_contains "$body" "/srv/private/run.lock" \
  "public run log disclosed an absolute path outside its known host roots"
assert_contains "$body" "URL https://github.com/example/project/pull/7" \
  "public run log path redaction damaged a host URL"
assert_contains "$body" "three directories above this runner" \
  "public run log did not use its path-free runner description"
assert_contains "$body" "holds the run lock for this run" \
  "public run log did not use its path-free lock description"
pass "public headless-run logs omit absolute host paths"
