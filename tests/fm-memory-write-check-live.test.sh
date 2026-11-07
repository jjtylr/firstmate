#!/usr/bin/env bash
# Credentialed real-Claude Stop feedback proof; Jev itself is stubbed.
# FM_MEMORY_WRITE_LIVE=1 opts in. Isolated temporary home, no live fleet state.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_MEMORY_WRITE_LIVE claude jq python3 git
TMP_ROOT=$(fm_test_tmproot fm-memory-write-live)
LAB=$TMP_ROOT/home
mkdir -p "$LAB"/{data,state,config,.claude}
ln -s "$ROOT/bin" "$LAB/bin"
printf '# Fixture\nThis is an isolated hook test.\n' > "$LAB/AGENTS.md"
printf '50000\n' > "$LAB/config/startup-memory-budget"
printf -- '- QUOTE bad memory rule.\n' > "$LAB/data/learnings.md"
git -C "$LAB" init -q
# Exercise the actual registration, isolating it from unrelated fleet hooks.
jq '{hooks:{Stop:[{hooks:[.hooks.Stop[].hooks[] | select(.command|contains("fm-memory-write-check.sh"))]}]}}' \
  "$ROOT/.claude/settings.json" > "$LAB/.claude/settings.json"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/curl" <<'PY'
#!/usr/bin/env python3
import json,os,sys
r=json.load(sys.stdin)
a={}
for key in r['questions']:
    bad='QUOTE' in r['state']['candidates'][key]['text']
    choice='quote' if bad else 'fine'
    p={kind:0.0 for kind in ('duplicate','quote','misplaced','finished','fine')}
    p[choice]=1.0
    a[key]={'choice':choice,'confidence':1.0,'probabilities':p}
with open(sys.argv[sys.argv.index('-o')+1],'w') as f: json.dump({'answers':a},f)
print('200',end='')
PY
chmod +x "$FAKEBIN/curl"
VERSION=$(claude --version)
export LAB FAKEBIN
# Bound and reap this exact test process group, never touch a shared runtime.
python3 - <<'PY'
import os,signal,subprocess,sys
lab=os.environ['LAB']
env=os.environ.copy()
for k in ('FM_DATA_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DISPATCH_PROVIDER','FM_DISPATCH_MODEL','FM_DISPATCH_BASE_URL','CLAUDECODE'):
    env.pop(k,None)
env.update(FM_HOME=lab,PATH=os.environ['FAKEBIN']+':'+env['PATH'],TYPESAFE_API_KEY='fixture-secret',
           CLAUDE_CODE_SEND_FEEDBACK='0',CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false')
prompt='This is a bounded Stop-hook integration test. First reply exactly INITIAL and stop, without using any tool. If Stop hook feedback asks you to fix memory, use Bash once to replace data/learnings.md with exactly "- Useful home fact." followed by a newline, then reply exactly REPAIRED and stop. Do not delegate or touch any other file.'
with open(lab+'/transcript.jsonl','w') as log:
    p=subprocess.Popen(['claude','-p',prompt,'--model','haiku','--effort','low','--max-turns','5',
        '--dangerously-skip-permissions','--setting-sources','project','--settings','{"feedbackDrafts":"off","autoMemoryEnabled":false}',
        '--output-format','stream-json','--verbose'],cwd=lab,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    try: rc=p.wait(timeout=90)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid,signal.SIGKILL);p.wait();rc=124
    if rc: sys.exit(rc)
PY
if ! grep -q 'Useful home fact' "$LAB/data/learnings.md"; then
  tail -25 "$LAB/transcript.jsonl" >&2
  fail "real $VERSION did not repair after feedback"
fi
python3 - "$LAB/transcript.jsonl" <<'PY'
import json,sys
rows=[json.loads(line) for line in open(sys.argv[1]) if line.startswith('{')]
feedback=[row for row in rows if row.get('type')=='user' and 'Memory write feedback' in json.dumps(row)]
assert len(feedback)==1, ('expected exactly one corrective continuation',feedback)
PY
pass "$VERSION: real Stop delivered one memory correction and next Stop ended without a loop"
