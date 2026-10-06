#!/usr/bin/env bash
# Behavior tests for bin/fm-roster.sh - the read-only fleet roster.
#   (a) a local and a remote second mate report their computer and placement
#   (b) the first mate holds every registered project no second mate lists
#   (c) a project listed by two mates appears under each and is flagged shared
#   (d) a GitHub repo comes from a local clone's origin, null without one
#   (e) an absent data/secondmates.md yields the first mate alone
#   (f) it runs from outside the repo, with FM_HOME and with no environment
#   (g) it writes nothing into the home it reads
#   (h) a malformed secondmate entry is an error, not a dropped mate
#   (i) fm-project-mode.sh --list enumerates registry names
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip - jq not installed"; exit 0; }

T=$(fm_test_tmproot fm-roster)
HOST=$(hostname -s 2>/dev/null || uname -n)
HOST=${HOST%%.*}

home=$T/home
mkdir -p "$home/data" "$T/elsewhere/alpha"
cat > "$home/data/projects.md" <<'EOF'
# Projects

- alpha [no-mistakes] - owner/alpha (added 2026-01-01)
- beta [direct-PR +yolo] - beta app (added 2026-01-01)
- gamma - legacy entry (added 2026-01-01)
- delta [local-only] - plain folder (added 2026-01-01)
- my project [local-only] - spaced name (added 2026-01-01)
- * [local-only] - wildcard name (added 2026-01-01)
EOF
cat > "$home/data/secondmates.md" <<EOF
# Second mates

- near - Own beta; and (some) prose. (home: $T/near-home; scope: All beta work; with semicolons; projects: beta, shared, my project,*; added 2026-01-02)
- far - Own gamma remotely. (host: box-2; root: /srv/firstmate; home: /srv/homes/far; scope: All gamma work; projects: gamma, shared; added 2026-01-03)
EOF
fm_git_init_commit "$home/projects/alpha" >/dev/null
git -C "$home/projects/alpha" remote add origin git@github.com:owner/alpha.git
fm_git_init_commit "$home/projects/delta" >/dev/null
git -C "$home/projects/delta" remote add origin https://gitlab.example/owner/delta.git

roster() { (cd "$T/elsewhere" && FM_HOME=$home "$ROOT/bin/fm-roster.sh" "$@"); }

home_digest() { (cd "$home" && find . -print | LC_ALL=C sort && find . -type f -exec cksum {} + | LC_ALL=C sort); }
before=$(home_digest)
out=$(roster --json) || fail "roster --json exited non-zero"
after=$(home_digest)
assert_contains "$before" "./data/projects.md" "(g) digest covers the home"
assert_equals "$before" "$after" "(g) roster changed the home it read"
pass "(g) roster leaves the home unchanged"

q() { printf '%s' "$out" | jq -c "$1"; }

assert_equals '"fm-roster.v1"' "$(q .schema)" "schema id"
assert_equals '["main","near","far"]' "$(q '[.mates[].id]')" "mate order"

assert_equals "{\"role\":\"secondmate\",\"computer\":\"$HOST\",\"placement\":\"local\",\"home\":\"$T/near-home\",\"summary\":\"Own beta; and (some) prose.\",\"scope\":\"All beta work; with semicolons\"}" \
  "$(q '.mates[1] | {role,computer,placement,home,summary,scope}')" "(a) local second mate"
assert_equals '{"role":"secondmate","computer":"box-2","placement":"remote","home":"/srv/homes/far","scope":"All gamma work"}' \
  "$(q '.mates[2] | {role,computer,placement,home,scope}')" "(a) remote second mate"
pass "(a) local and remote second mates report computer and placement"

assert_equals "{\"role\":\"firstmate\",\"computer\":\"$HOST\",\"placement\":\"local\",\"home\":\"$home\",\"summary\":null,\"scope\":null}" \
  "$(q '.mates[0] | {role,computer,placement,home,summary,scope}')" "(b) first mate fields"
assert_equals '["alpha","delta"]' "$(q '[.mates[0].projects[].name]')" "(b) first mate keeps unlisted projects"
assert_equals '"my project"' "$(q '.mates[1].projects[] | select(.name=="my project") | .name')" "project names with spaces stay assigned"
assert_equals '"*"' "$(q '.mates[1].projects[] | select(.name=="*") | .name')" "glob characters stay literal"
pass "(b) first mate holds the rest of the main registry"

assert_equals '{"name":"shared","repo":null,"shared":true,"mates":["near","far"]}' \
  "$(q '.mates[1].projects[] | select(.name=="shared")')" "(c) shared under near"
assert_equals '{"name":"shared","repo":null,"shared":true,"mates":["near","far"]}' \
  "$(q '.mates[2].projects[] | select(.name=="shared")')" "(c) shared under far"
assert_equals 'false' "$(q '.mates[1].projects[] | select(.name=="beta") | .shared')" "(c) unshared project not flagged"
pass "(c) a project held by two mates is listed under each and flagged"

assert_equals '"owner/alpha"' "$(q '.mates[0].projects[] | select(.name=="alpha") | .repo')" "(d) github origin"
assert_equals 'null' "$(q '.mates[0].projects[] | select(.name=="delta") | .repo')" "(d) non-github origin"
pass "(d) repo comes from a GitHub clone origin only"

table=$(roster) || fail "plain roster exited non-zero"
assert_contains "$table" "far" "(a) table lists remote mate"
assert_contains "$table" "box-2" "(a) table shows host alias"
assert_contains "$table" "shared*" "(c) table marks shared project"
pass "plain table lists every mate"

cp "$home/data/secondmates.md" "$T/secondmates.saved"
printf '%s\n' '- main - Owns alpha. (home: /tmp/main-home; scope: Main route; projects: alpha; added 2026-01-04)' >> "$home/data/secondmates.md"
rc=0
err=$(roster --json 2>&1 >/dev/null) || rc=$?
expect_code 1 "$rc" "secondmate ID colliding with firstmate"
assert_contains "$err" "ID conflicts with firstmate" "collision is rejected"
pass "firstmate and secondmate IDs remain distinct"
cp "$T/secondmates.saved" "$home/data/secondmates.md"
printf '%s\n' '- near - Duplicate route. (home: $T/duplicate-home; scope: Duplicate route; projects: alpha; added 2026-01-04)' >> "$home/data/secondmates.md"
rc=0
err=$(roster --json 2>&1 >/dev/null) || rc=$?
expect_code 1 "$rc" "duplicate secondmate ID"
assert_contains "$err" "duplicate secondmate ID: near" "duplicate ID is rejected"
pass "duplicate secondmate IDs are rejected"
cp "$T/secondmates.saved" "$home/data/secondmates.md"
mv "$home/data/secondmates.md" "$T/secondmates.saved"
out=$(roster --json) || fail "(e) roster without secondmates.md exited non-zero"
assert_equals '["main"]' "$(q '[.mates[].id]')" "(e) only the first mate"
assert_equals '["alpha","beta","gamma","delta","my project","*"]' "$(q '[.mates[0].projects[].name]')" "(e) first mate holds every project"
pass "(e) absent secondmate registry yields the first mate alone"
ln -s "$T/missing-registry-target" "$home/data/secondmates.md"
rc=0
err=$(roster --json 2>&1 >/dev/null) || rc=$?
expect_code 1 "$rc" "dangling secondmate registry symlink"
assert_contains "$err" "secondmate registry is unsafe" "dangling symlink is rejected"
pass "dangling secondmate registry symlink is not treated as absent"
rm "$home/data/secondmates.md"
mv "$T/secondmates.saved" "$home/data/secondmates.md"

code=$T/code
mkdir -p "$code"
cp -R "$ROOT/bin" "$code/bin"
cp -R "$home/data" "$code/data"
out=$(cd "$T/elsewhere" && env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE "$code/bin/fm-roster.sh" --json) ||
  fail "(f) roster without FM_HOME exited non-zero"
assert_equals "\"$code\"" "$(q '.mates[0].home')" "(f) defaults to the code root's home"
assert_equals '["main","near","far"]' "$(q '[.mates[].id]')" "(f) reads the code root's registries"
pass "(f) runs from outside the repo with and without FM_HOME"

printf '%s\n' '- broken - no structured suffix' >> "$home/data/secondmates.md"
rc=0
err=$(roster --json 2>&1 >/dev/null) || rc=$?
expect_code 1 "$rc" "(h) malformed entry"
assert_contains "$err" "malformed secondmate registry entry" "(h) names the malformed entry"
pass "(h) a malformed secondmate entry is an error"

names=$(FM_HOME=$home "$ROOT/bin/fm-project-mode.sh" --list)
assert_equals $'alpha\nbeta\ngamma\ndelta\nmy project\n*' "$names" "(i) --list names"
assert_equals "" "$(FM_HOME=$T/elsewhere "$ROOT/bin/fm-project-mode.sh" --list)" "(i) --list with no registry"
pass "(i) fm-project-mode.sh --list enumerates registry names"
