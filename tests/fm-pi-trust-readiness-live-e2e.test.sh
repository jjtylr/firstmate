#!/usr/bin/env bash
# Token-free CLI guard for Pi-family per-launch project trust.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_PI_TRUST_READINESS_LIVE node
TMP_ROOT=$(fm_test_tmproot fm-pi-trust-readiness-live)
CHECKED=0

for identity in pi pi-signed; do
  if ! binary=$(command -v "$identity" 2>/dev/null); then
    printf '# %s absent: not exercised by this run\n' "$identity"
    continue
  fi
  if ! PI_TEST_BINARY="$binary" PI_TEST_ROOT="$TMP_ROOT/$identity" node --input-type=module <<'JS'; then
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { execFileSync, spawnSync } from "node:child_process";
const binary = process.env.PI_TEST_BINARY;
const root = process.env.PI_TEST_ROOT;
const project = path.join(root, "project with a long folder name to exercise path independence");
const agentDir = path.join(root, "agent");
const marker = path.join(root, "project-loaded.json");
const externalMarker = path.join(root, "cli-loaded");
const external = path.join(root, "external.ts");
const version = execFileSync(binary, ["--version"], { encoding: "utf8", timeout: 10000 }).trim();
fs.mkdirSync(path.join(project, ".pi/extensions"), { recursive: true });
fs.mkdirSync(agentDir, { recursive: true });
execFileSync("git", ["init", "-q", project]);
fs.writeFileSync(path.join(project, ".pi/settings.json"), "{}\n");
fs.writeFileSync(path.join(project, ".pi/extensions/proof.ts"), `
import { writeFileSync } from "node:fs";
export default function (pi) {
  pi.on("session_start", (_event, ctx) => writeFileSync(${JSON.stringify(marker)}, JSON.stringify({cwd: ctx.cwd})));
}
`);
fs.writeFileSync(external, `
import { writeFileSync } from "node:fs";
export default function (pi) {
  pi.on("session_start", () => writeFileSync(${JSON.stringify(externalMarker)}, "started"));
}
`);
const trustFile = path.join(agentDir, "trust.json");
function launch(approve) {
  fs.rmSync(marker, { force: true });
  fs.rmSync(externalMarker, { force: true });
  const args = ["--print", "--no-session", "--no-context-files", "--no-skills", "-e", external];
  if (approve) args.push("--approve");
  const result = spawnSync(binary, args, {
    cwd: project,
    env: { ...process.env, HOME: root, PI_CODING_AGENT_DIR: agentDir, PI_OFFLINE: "1" },
    encoding: "utf8", input: "", timeout: 30000,
  });
  assert.equal(result.status, 0, `${binary} ${version}: ${result.error || result.stderr || result.stdout}`);
  assert.ok(fs.existsSync(externalMarker), `${binary} ${version}: CLI extension never reached session_start`);
}
for (const policy of ["fresh", "denied", "never"]) {
  const trust = policy === "denied" ? { [fs.realpathSync(project)]: false } : {};
  fs.writeFileSync(trustFile, JSON.stringify(trust));
  fs.writeFileSync(path.join(agentDir, "settings.json"), JSON.stringify({
    defaultProjectTrust: policy === "never" ? "never" : "ask",
  }));
  launch(false);
  assert.ok(!fs.existsSync(marker), `${binary} ${version}: ${policy} control loaded untrusted project code`);
  launch(true);
  assert.deepEqual(JSON.parse(fs.readFileSync(marker, "utf8")), { cwd: project });
  assert.deepEqual(JSON.parse(fs.readFileSync(trustFile, "utf8")), trust);
  launch(false);
  assert.ok(!fs.existsSync(marker), `${binary} ${version}: ${policy} approval persisted into the next launch`);
  console.log(`ok - ${path.basename(binary)} ${version}: ${policy} project trust is granted only by per-launch --approve`);
}
JS
    fail "$identity per-launch project trust guard failed"
  fi
  CHECKED=$((CHECKED + 1))
done

if [ "$CHECKED" -eq 0 ]; then
  if [ "${FM_PI_TRUST_READINESS_LIVE:-${FM_LIVE:-0}}" = 1 ]; then
    fail "no Pi-family executable was installed, so the live trust guard verified nothing"
  fi
  printf 'skip: no Pi-family executable installed\n'
  exit 0
fi
printf '# checked %s installed Pi-family executable(s)\n' "$CHECKED"
