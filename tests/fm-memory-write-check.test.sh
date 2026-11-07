#!/usr/bin/env bash
# CLI regressions: changed-line detection, suppression, typed batch validation,
# outage/timeout and deterministic budget feedback, Claude scope and secondmates.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-memory-write-check)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
TOOL=$ROOT/bin/fm-memory-write-check.sh
export FM_HOME=$TMP_ROOT/home
export CLAUDE_PROJECT_DIR=$FM_HOME
export CALL_LOG=$TMP_ROOT/calls
unset FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DISPATCH_PROVIDER FM_DISPATCH_MODEL FM_DISPATCH_BASE_URL FM_DISPATCH_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY
export TYPESAFE_API_KEY=fixture-secret
mkdir -p "$FM_HOME"/{config,data,state,bin}
printf '50000\n' > "$FM_HOME/config/startup-memory-budget"
printf '## How we work\n- An existing rule.\n' > "$FM_HOME/AGENTS.md"
git -C "$FM_HOME" init -q
cat > "$FAKEBIN/curl" <<'PY'
#!/usr/bin/env python3
import json, os, sys, time
assert not any(k in os.environ for k in ('TYPESAFE_API_KEY','OPENROUTER_API_KEY','OPENAI_API_KEY','FM_DISPATCH_API_KEY','KEY_PRIVATE','TYPESAFE_API_KEY_PRIVATE'))
assert 'fixture-secret' not in ' '.join(sys.argv)
request = json.load(sys.stdin)
with open(os.environ['CALL_LOG'], 'a') as f:
    f.write(json.dumps(request['state']['candidates'])+'\n')
if os.environ.get('MODE') == 'slow':
    time.sleep(10)
if os.environ.get('MODE') == 'offline':
    sys.exit(7)
out = sys.argv[sys.argv.index('-o') + 1]
answers = {}
for key in request['questions']:
    line = request['state']['candidates'][key]['text']
    choice = 'duplicate' if 'DUP' in line else 'quote' if 'QUOTE' in line else 'fine'
    probabilities = {kind:0.025 for kind in ('duplicate','quote','misplaced','finished','fine')}
    probabilities[choice] = 0.9
    answers[key] = {'choice':choice,'confidence':0.9,'probabilities':probabilities}
if os.environ.get('MODE') == 'invalid':
    answers[next(iter(answers))]['confidence'] = 'not-a-number'
with open(out, 'w') as f:
    json.dump({'answers':answers}, f)
sys.stdout.write('200')
PY
chmod +x "$FAKEBIN/curl"
export PATH="$FAKEBIN:$PATH"
run() { bash "$TOOL" "$@"; }
calls() { if [ -f "$CALL_LOG" ]; then wc -l < "$CALL_LOG" | tr -d ' '; else echo 0; fi; }
assert_json() { python3 -c 'import json,sys; r=json.load(sys.stdin); assert eval(sys.argv[1]), r' "$1"; }

[ -z "$(run)" ] || fail 'absent memory should be silent'
[ "$(calls)" = 0 ] || fail 'absent memory made a call'
printf '# Notes\n- A useful home fact.\n- QUOTE quoted rule.\n' > "$FM_HOME/data/learnings.md"
run --json | assert_json 'len(r["flags"])==1 and r["flags"][0]["question"]=="quote" and len(r["latency_ms"])==1'
[ "$(calls)" = 1 ] || fail 'first scan should batch the lines'
[ -z "$(run)" ] || fail 'same flag should not repeat'
[ "$(calls)" = 1 ] || fail 'unchanged turn made a call'
# A line-number shift and move must not repeat an unchanged flag.
printf '# Notes\n- A new useful fact.\n- QUOTE quoted rule.\n- A useful home fact.\n' > "$FM_HOME/data/learnings.md"
[ -z "$(run)" ] || fail 'move repeated an unchanged flag'
[ "$(calls)" = 2 ] || fail 'new line not checked'
python3 - "$CALL_LOG" <<'PY'
import json,sys
rows=[json.loads(line) for line in open(sys.argv[1])]
assert [v['text'] for v in rows[-1].values()]==['- A new useful fact.']
PY
# Tool-independent replacement and new duplicate occurrence both get checked.
printf '# Notes\n- DUP changed rule.\n- A useful home fact.\n- A useful home fact.\n' > "$FM_HOME/data/learnings.md"
run --json | assert_json 'len(r["flags"])==1 and r["flags"][0]["question"]=="duplicate"'
python3 - "$CALL_LOG" <<'PY'
import json,sys
row=json.loads(open(sys.argv[1]).readlines()[-1])
assert len(row)==2, row
PY
pass 'changed-line detection, moves, duplicate occurrences and no repeated flags'

# Deletion-only changes advance the baseline without another model call.
n=$(calls)
printf '# Notes\n- A useful home fact.\n' > "$FM_HOME/data/learnings.md"
[ -z "$(run)" ] || fail 'deletion should be silent'
[ "$(calls)" = "$n" ] || fail 'deletion made a Jev call'
printf '\n- QUOTE new quote.\n' >> "$FM_HOME/data/learnings.md"
printf '10\n' > "$FM_HOME/config/startup-memory-budget"
export MODE=offline
run --json | assert_json 'r["skipped"] is not None and any(f["question"]=="budget" for f in r["flags"])'
[ -z "$(run)" ] || fail 'outage/budget repeated after same content'
printf -- '- A new over-budget line.\n' >> "$FM_HOME/data/learnings.md"
set +e
printf '{}' | run --claude > "$TMP_ROOT/outage.out" 2> "$TMP_ROOT/outage.err"
rc=$?
set -e
[ "$rc" = 2 ] || fail 'budget feedback must still reach Claude during an outage'
grep -q 'Jev check skipped' "$TMP_ROOT/outage.err" || fail 'outage must be disclosed alongside budget feedback'
unset MODE
printf '50000\n' > "$FM_HOME/config/startup-memory-budget"
for mode in invalid slow; do
  export MODE=$mode
  printf -- '- New line %s.\n' "$mode" >> "$FM_HOME/data/learnings.md"
  run --json | assert_json 'r["skipped"] is not None and not r["flags"]'
done
unset MODE
pass 'outage, invalid response and bounded timeout still account for size and do not loop'
# An opt-out list protects memory text just as it protects dispatch text.
printf 'secret-marker\n' > "$FM_HOME/config/dispatch-never-send"
printf -- '- secret-marker QUOTE withheld.\n' >> "$FM_HOME/data/learnings.md"
n=$(calls)
run --json | assert_json 'r["skipped"] is not None and not r["flags"]'
[ "$(calls)" = "$n" ] || fail 'never-send list allowed a request'
rm "$FM_HOME/config/dispatch-never-send"
pass 'never-send list withholds the whole request before network access'

# The inherited shared file is comparison context, never writable candidates.
printf 'mate\n' > "$FM_HOME/.fm-secondmate-home"
printf -- '- DUP inherited only.\n' > "$FM_HOME/data/captain-shared.md"
printf -- '- Useful charter routing fact.\n' > "$FM_HOME/data/charter.md"
run --json | assert_json 'not any(p.endswith("captain-shared.md") for p in r["changed_files"]) and any(p.endswith("charter.md") for p in r["changed_files"])'
# Hook flags force one continuation, then the unchanged Stop is silent.
printf -- '- QUOTE a new bad line.\n' >> "$FM_HOME/data/learnings.md"
set +e
printf '{"stop_hook_active":true}' | run --claude > "$TMP_ROOT/hook.out" 2> "$TMP_ROOT/hook.err"
rc=$?
set -e
[ "$rc" = 2 ] || fail 'Claude must receive new flags at turn end'
grep -q 'quote confidence=0.90' "$TMP_ROOT/hook.err" || fail 'missing Claude feedback'
[ -z "$(printf '{}' | run --claude 2>&1)" ] || fail 'Claude repeated same flag'
printf -- '- QUOTE another bad line.\n' >> "$FM_HOME/data/learnings.md"
n=$(calls)
[ -z "$(printf '{"cursor_version":"fixture"}' | run --claude)" ] || fail 'foreign hook should be inert'
[ -z "$(printf '{}' | CLAUDE_PROJECT_DIR="$TMP_ROOT/child-project" run --claude)" ] || fail 'child with inherited primary home must be inert'
# An isolated child copy is not a firstmate session.
export FM_HOME=$TMP_ROOT/child
export CLAUDE_PROJECT_DIR=$FM_HOME
mkdir -p "$FM_HOME"/{data,state,bin}
printf 'scope\n' > "$FM_HOME/AGENTS.md"
printf -- '- QUOTE child memory.\n' > "$FM_HOME/data/learnings.md"
[ -z "$(printf '{}' | run --claude)" ] || fail 'unrecognized child must be inert'
[ "$(calls)" = "$n" ] || fail 'out-of-scope hook made a request'
pass 'secondmate inherited copy is excluded; Stop feedback is bounded and scoped'
# A large initial scan is packed, bounded and still delivered through the CLI.
export FM_HOME=$TMP_ROOT/bulk
mkdir -p "$FM_HOME"/{data,config}
printf '50000\n' > "$FM_HOME/config/startup-memory-budget"
printf '## How we work\n- Existing rule.\n' > "$FM_HOME/AGENTS.md"
python3 - "$FM_HOME/data/learnings.md" <<'PY'
import sys
with open(sys.argv[1], 'w') as f:
    for i in range(150): f.write(f'- Useful home fact {i}: '+('ordinary operational context ' * 5)+'\n')
PY
run --json | assert_json 'not r["skipped"] and not r["flags"] and len(r["latency_ms"]) > 1'
[ -z "$(run)" ] || fail 'unchanged bulk scan should be silent'
pass 'large scans batch without losing lines or repeating feedback'
printf '# all memory-write-check tests passed\n'
