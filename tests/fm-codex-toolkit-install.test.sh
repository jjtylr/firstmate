#!/usr/bin/env bash
# Behavioral coverage for the pinned Codex toolkit installer and adaptations.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALLER="$ROOT/bin/fm-install-codex-toolkit.sh"
MANIFEST="$ROOT/.agents/skills/setup-engineering-skills/codex/skill-manifest.txt"
UPSTREAM_FIXTURE="$ROOT/tests/fixtures/codex-toolkit-upstream"
TMP_ROOT=$(fm_test_tmproot fm-codex-toolkit-install)

if [ "${FM_CODEX_TOOLKIT_INSTALL_LIVE_E2E:-0}" = 1 ]; then
  fm_live_gate opt-in FM_CODEX_TOOLKIT_INSTALL_LIVE_E2E git node npx codex
  live_project="$TMP_ROOT/live-project"
  mkdir -p "$live_project/bin" "$live_project/.agents/skills/preexisting"
  cp "$INSTALLER" "$ROOT/bin/fm-codex-toolkit-dispatch.sh" \
    "$ROOT/bin/fm-codex-toolkit-merge.sh" "$live_project/bin/"
  cp "$ROOT/skills-lock.json" "$live_project/"
  chmod +x "$live_project/bin/"*.sh
  printf '%s\n' '# Existing Firstmate contract' > "$live_project/AGENTS.md"
  printf '%s\n' 'preexisting internal skill' \
    > "$live_project/.agents/skills/preexisting/SKILL.md"
  git -C "$live_project" init -q

  live_out=$(env -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_NOSYSTEM \
    "$live_project/bin/fm-install-codex-toolkit.sh") \
    || fail "live pinned toolkit install failed"
  assert_contains "$live_out" \
    "FM-TOOLKIT-INSTALL-OK: agent-toolkit 26bc6befdcfbd335a8f99cc466e664e994f647d2" \
    "live installer did not install the pinned release"
  [ "$(cat "$live_project/.agents/skills/preexisting/SKILL.md")" = \
    "preexisting internal skill" ] \
    || fail "live installer changed a preexisting internal skill"
  [ "$(cat "$live_project/AGENTS.md")" = "# Existing Firstmate contract" ] \
    || fail "live installer changed the existing AGENTS contract"

  cmp "$ROOT/skills-lock.json" "$live_project/skills-lock.json" >/dev/null \
    || fail "live installer changed the canonical skills lock"
  for adapted_path in \
    .agents/skills/setup-engineering-skills/scripts/configure-codex-project.sh \
    .agents/skills/drain-ready-queue/CODEX-OPERATIVE.md \
    .agents/skills/drain-ready-queue/ORCHESTRATION.md \
    .agents/skills/drain-ready-queue/MERGE-PIPELINE.md \
    .agents/skills/drain-ready-queue/MERGE-POLICY.md \
    .agents/skills/drain-ready-queue/SKILL.md \
    .agents/skills/drain-ready-queue/scripts/runner.sh; do
    cmp "$ROOT/$adapted_path" "$live_project/$adapted_path" >/dev/null \
      || fail "live installer output differs from the tracked $adapted_path contract"
  done
  live_tree_digest() {
    (
      cd "$live_project"
      find .agents .codex -type f -print0
      printf 'AGENTS.md\0skills-lock.json\0'
    ) | LC_ALL=C sort -z | while IFS= read -r -d '' file; do
      printf '%s  ' "$file"
      shasum -a 256 "$live_project/$file"
    done | shasum -a 256 | cut -d' ' -f1
  }
  first_live_digest=$(live_tree_digest)
  env -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_NOSYSTEM \
    "$live_project/bin/fm-install-codex-toolkit.sh" >/dev/null \
    || fail "live pinned toolkit reinstall failed"
  second_live_digest=$(live_tree_digest)
  [ "$first_live_digest" = "$second_live_digest" ] \
    || fail "live reinstall changed the installed file inventory"
  pass "live pinned install and reinstall complete from GitHub"
  exit 0
fi

fixture="$TMP_ROOT/upstream"
project="$TMP_ROOT/project"
fakebin="$TMP_ROOT/fakebin"
mkdir -p "$fixture/.agents/skills" "$project/bin" "$fakebin"
REAL_GIT=$(command -v git)

while IFS= read -r skill; do
  [ -n "$skill" ] || continue
  cp -R "$ROOT/.agents/skills/$skill" "$fixture/.agents/skills/$skill"
  if [ "$skill" != drain-ready-queue ]; then
    printf '%s\n' '---' "name: $skill" "description: Upstream fixture for $skill." '---' \
      > "$fixture/.agents/skills/$skill/SKILL.md"
  fi
done < "$MANIFEST"
cp "$ROOT/skills-lock.json" "$fixture/skills-lock.json"
upstream_drain="$UPSTREAM_FIXTURE/.agents/skills/drain-ready-queue"
fixture_drain="$fixture/.agents/skills/drain-ready-queue"
cp "$upstream_drain/CODEX-OPERATIVE.md.fixture" "$fixture_drain/CODEX-OPERATIVE.md"
cp "$upstream_drain/SKILL.md.fixture" "$fixture_drain/SKILL.md"
for upstream_script in merge-pinned.sh run-codex-operative.sh runner.sh; do
  cp "$upstream_drain/scripts/$upstream_script" "$fixture_drain/scripts/$upstream_script"
done
cp "$UPSTREAM_FIXTURE/.agents/skills/setup-engineering-skills/scripts/configure-codex-project.sh.fixture" \
  "$fixture/.agents/skills/setup-engineering-skills/scripts/configure-codex-project.sh"

cp "$INSTALLER" "$project/bin/fm-install-codex-toolkit.sh"
cp "$ROOT/bin/fm-codex-toolkit-dispatch.sh" "$project/bin/"
cp "$ROOT/bin/fm-codex-toolkit-merge.sh" "$project/bin/"
cp "$ROOT/skills-lock.json" "$project/"
chmod +x "$project/bin/fm-install-codex-toolkit.sh" "$project/bin/fm-codex-toolkit-"*.sh
git -C "$project" init -q
git -C "$project" add bin
git -C "$project" -c user.name=test -c user.email=test@example.invalid commit -qm baseline

cat > "$fakebin/npx" <<'SH'
#!/usr/bin/env bash
set -eu
source=${4:-}
[ "$1 $2 $3" = "--yes skills@1.5.1 add" ] \
  || { printf 'unexpected npx command: %s\n' "$*" >&2; exit 1; }
[ "$5 $6 $7 $8 $9 ${10}" = "--skill * --agent codex --copy --yes" ] \
  || { printf 'unexpected npx options: %s\n' "$*" >&2; exit 1; }
[ -f "$source/.agents/skills/setup-engineering-skills/codex/skill-manifest.txt" ] \
  || { printf 'npx source is not the fetched toolkit checkout: %s\n' "$source" >&2; exit 1; }
mkdir -p "$PWD/.agents/skills"
while IFS= read -r skill; do
  [ -n "$skill" ] || continue
  rm -rf "$PWD/.agents/skills/$skill"
  cp -R "$source/.agents/skills/$skill" "$PWD/.agents/skills/$skill"
done < "$source/.agents/skills/setup-engineering-skills/codex/skill-manifest.txt"
printf '%s\n' '{"source":"temporary-local-checkout"}' > "$PWD/skills-lock.json"
SH
cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = -C ] && [ "${3:-}" = fetch ]; then
  [ "$4 $5 $6 $7" = "--depth 1 https://github.com/jjtylr/agent-toolkit.git 26bc6befdcfbd335a8f99cc466e664e994f647d2" ] \
    || { printf 'unexpected git fetch: %s\n' "$*" >&2; exit 1; }
  cp -R "$FAKE_TOOLKIT/." "$2/"
  exit 0
fi
if [ "${1:-}" = -C ] && [ "${3:-}" = checkout ]; then
  [ "$4 $5 $6" = "-q --detach FETCH_HEAD" ] \
    || { printf 'unexpected git checkout: %s\n' "$*" >&2; exit 1; }
  exit 0
fi
if [ "${1:-}" = -C ] && [ "${3:-}" = rev-parse ] && [ "${4:-}" = HEAD ]; then
  printf '%s\n' 26bc6befdcfbd335a8f99cc466e664e994f647d2
  exit 0
fi
exec "$REAL_GIT" "$@"
SH
cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$fakebin/npx" "$fakebin/git" "$fakebin/codex"

install_fixture() {
  PATH="$fakebin:$PATH" FAKE_TOOLKIT="$fixture" REAL_GIT="$REAL_GIT" \
    "$project/bin/fm-install-codex-toolkit.sh"
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
assert_contains "$out" "Toolkit project hooks support codex exec only" \
  "installer did not state the supported toolkit hook path"

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
assert hooks["SessionStart"][0]["matcher"] == "startup|resume"
PY

for adapted_path in \
  .agents/skills/setup-engineering-skills/scripts/configure-codex-project.sh \
  .agents/skills/drain-ready-queue/SKILL.md \
  .agents/skills/drain-ready-queue/CODEX-OPERATIVE.md \
  .agents/skills/drain-ready-queue/ORCHESTRATION.md \
  .agents/skills/drain-ready-queue/MERGE-PIPELINE.md \
  .agents/skills/drain-ready-queue/MERGE-POLICY.md \
  .agents/skills/drain-ready-queue/scripts/merge-pinned.sh \
  .agents/skills/drain-ready-queue/scripts/run-codex-operative.sh \
  .agents/skills/drain-ready-queue/scripts/runner.sh; do
  cmp "$ROOT/$adapted_path" "$project/$adapted_path" >/dev/null \
    || fail "installer output differs from the tracked $adapted_path contract"
done

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
[ -z "${GH_LOG:-}" ] || printf '%s\n' "$*" >> "$GH_LOG"
case "${1:-} ${2:-}" in
  "repo view")
    case " $* " in
      *" nameWithOwner "*) printf 'example/project\n' ;;
      *) printf 'https://github.com/example/project\n' ;;
    esac
    ;;
  "pr view")
    case " $* " in
      *" --json commits "*) printf 'build: keep examined behavior\n' ;;
      *" --json state,headRefOid "*)
        printf '{"state":"%s","headRefOid":"%s"}\n' \
          "${GH_PR_STATE:-MERGED}" \
          "${GH_PR_HEAD:-0123456789012345678901234567890123456789}"
        ;;
      *) exit 1 ;;
    esac
    ;;
  "pr merge") exit 0 ;;
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
gh_log="$TMP_ROOT/gh.log"
rm -f "$merge_log" "$gh_log"
GH_LOG="$gh_log" MERGE_LOG="$merge_log" FM_ROOT="$project" \
  PATH="$fakebin:$PATH" \
  "$project/.agents/skills/drain-ready-queue/scripts/merge-pinned.sh" \
  7 0123456789012345678901234567890123456789 squash auto-on-verdict \
  > "$TMP_ROOT/claude-merge.out" 2> "$TMP_ROOT/claude-merge.err" \
  || fail "Claude toolkit merge runner did not preserve its four-argument path"
assert_absent "$merge_log" "Claude toolkit merge reached Firstmate's Codex merge owner"
assert_contains "$(cat "$TMP_ROOT/claude-merge.out")" "MERGE-PINNED:#7 merged" \
  "Claude toolkit merge runner did not report its pinned merge"
assert_contains "$(cat "$gh_log")" \
  "pr merge 7 --squash --subject build: keep examined behavior (#7) --delete-branch --repo example/project --match-head-commit 0123456789012345678901234567890123456789" \
  "Claude toolkit merge runner did not preserve its pinned forge command"
printf 'yolo=on\n' > "$TMP_ROOT/home/state/task-42.meta"
for rejected_policy in pm-merge unknown-policy; do
  rm -f "$merge_log" "$hold_log"
  if HOLD_LOG="$hold_log" RELEASED_APPROVAL=1 MERGE_LOG="$merge_log" FM_ROOT="$project" \
    FM_HOME="$TMP_ROOT/home" PATH="$fakebin:$PATH" \
    "$project/.agents/skills/drain-ready-queue/scripts/merge-pinned.sh" \
    7 0123456789012345678901234567890123456789 squash "$rejected_policy" task-42 \
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
  FM_HOME="$TMP_ROOT/home" PATH="$fakebin:$PATH" \
  "$project/.agents/skills/drain-ready-queue/scripts/merge-pinned.sh" \
  7 0123456789012345678901234567890123456789 squash auto-on-verdict task-42 \
  > "$TMP_ROOT/unauthorized.out" 2> "$TMP_ROOT/unauthorized.err"; then
  fail "Codex toolkit merge runner accepted yolo=off without a captain release"
fi
assert_absent "$merge_log" "unauthorized Codex toolkit merge reached Firstmate's merge owner"
assert_contains "$(cat "$TMP_ROOT/unauthorized.out")" "no durable captain release" \
  "unauthorized Codex toolkit merge did not name its missing authority"

HOLD_LOG="$hold_log" RELEASED_APPROVAL=1 MERGE_LOG="$merge_log" FM_ROOT="$project" \
  FM_HOME="$TMP_ROOT/home" PATH="$fakebin:$PATH" \
  "$project/.agents/skills/drain-ready-queue/scripts/merge-pinned.sh" \
  7 0123456789012345678901234567890123456789 squash auto-on-verdict task-42 >/dev/null \
  || fail "Codex toolkit merge runner did not delegate through Firstmate merge authority"
assert_contains "$(cat "$hold_log")" "released task-42" \
  "Codex toolkit merge runner did not verify the captain release"
assert_contains "$(cat "$merge_log")" \
  "task-42 https://github.com/example/project/pull/7 --expected-head 0123456789012345678901234567890123456789 -- --squash --subject build: keep examined behavior (#7)" \
  "Codex toolkit merge runner dropped its commit pin or squash subject"

if HOLD_LOG="$hold_log" RELEASED_APPROVAL=1 MERGE_LOG="$merge_log" FM_ROOT="$project" \
  FM_HOME="$TMP_ROOT/home" GH_PR_STATE=OPEN PATH="$fakebin:$PATH" \
  "$project/.agents/skills/drain-ready-queue/scripts/merge-pinned.sh" \
  7 0123456789012345678901234567890123456789 squash auto-on-verdict task-42 \
  > "$TMP_ROOT/queued.out" 2> "$TMP_ROOT/queued.err"; then
  fail "Codex toolkit merge runner reported a queued PR as landed"
fi
assert_not_contains "$(cat "$TMP_ROOT/queued.out")" "MERGE-PINNED" \
  "Codex toolkit merge runner emitted landed success for a queued PR"
assert_contains "$(cat "$TMP_ROOT/queued.out")" "has not landed" \
  "Codex toolkit merge runner did not explain the queued PR outcome"
pass "Codex dispatch and merge routes preserve Firstmate authority and examined inputs"

runner_dir="$project/.agents/skills/drain-ready-queue/scripts"
captured="$TMP_ROOT/comment.md"
mkdir -p "$project/private"
cat > "$runner_dir/runner-gate.sh" <<'SH'
#!/usr/bin/env bash
printf "RUNNER-CONTINUE: RUNNER_LOCK=/srv/private/Client,Alpha/run.lock, spaced %s/Private Project/missing.git, quoted '%s/hidden/file', URL https://github.com/example/project/pull/7\n" \
  "$PROJECT_SECRET" \
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

PATH="$fakebin:$PATH" REAL_GIT="$REAL_GIT" FAKE_TOOLKIT="$fixture" \
  CAPTURED_BODY="$captured" PROJECT_SECRET="$project" \
  RUNNER_LOCK="$project/private/run.lock" \
  RUNNER_MAX_ITERATIONS=1 RUNNER_SLEEP=0 \
  bash "$runner_dir/runner.sh" >/dev/null 2>&1 \
  || fail "adapted headless runner did not finish its bounded public-log fixture"
assert_present "$captured" "adapted headless runner did not post its stop log"
body=$(cat "$captured")
assert_not_contains "$body" "$project" "public run log disclosed its absolute project path"
assert_not_contains "$body" "Client,Alpha/run.lock" \
  "public run log disclosed punctuation from an absolute path"
assert_not_contains "$body" "Private Project/missing.git" \
  "public run log disclosed a suffix from an absolute path containing spaces"
assert_contains "$body" "<host-path>" \
  "public run log did not replace its path-bearing diagnostic"
assert_contains "$body" "holds the run lock for this run" \
  "public run log did not use its path-free lock description"
pass "public headless-run logs omit absolute host paths"
