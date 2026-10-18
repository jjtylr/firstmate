"""Disposable local endpoint + real harness/session/snapshot verification.
No credentials, operator data, lifecycle commands, or fake harness executables.
Run from the gate worktree: python3 <this-file>.
"""
import datetime, hashlib, html, json, os, re, shutil, socket, subprocess, threading, time
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path.cwd()
EV = Path(__file__).parent
LAB = ROOT / '.test-local/live'
LAB.mkdir(parents=True, exist_ok=True)
HOME = LAB / 'login'
AGENT = HOME / '.pi/agent'
CLAUDE = HOME / '.claude'
FLEET = LAB / 'fleet'
for p in (AGENT, CLAUDE, FLEET / 'state', FLEET / 'data', FLEET / 'config', FLEET / 'projects', LAB / 'tmp'):
    p.mkdir(parents=True, exist_ok=True)
ENV = {'PATH': os.environ['PATH'], 'HOME': str(HOME), 'TMPDIR': str(LAB / 'tmp'),
       'FM_HOME': str(FLEET), 'FM_ROOT_OVERRIDE': str(ROOT), 'PI_CODING_AGENT_DIR': str(AGENT),
       'PI_OFFLINE': '1', 'PI_SKIP_VERSION_CHECK': '1', 'PI_TELEMETRY': '0', 'TERM': 'xterm-256color',
       'DISABLE_AUTOUPDATER': '1', 'CLAUDE_CONFIG_DIR': str(CLAUDE),
       'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1', 'NO_PROXY': '127.0.0.1,localhost'}
TRANSCRIPT = []

def run(args, cwd=ROOT, overrides=None, timeout=30, check=True):
    env = dict(ENV, **(overrides or {}))
    t = time.monotonic()
    p = subprocess.run(list(map(str, args)), cwd=cwd, env=env, text=True, capture_output=True, timeout=timeout)
    TRANSCRIPT.append({'argv': list(map(str, args)), 'cwd': str(cwd), 'exit': p.returncode,
                       'seconds': round(time.monotonic()-t, 3), 'stdout': p.stdout, 'stderr': p.stderr})
    (EV / 'live-transcript.json').write_text(json.dumps(TRANSCRIPT, indent=2))
    if check and p.returncode:
        raise RuntimeError(f'{args}: {p.returncode}: {p.stderr}\n{p.stdout}')
    return p

class Endpoint(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
        model = body.get('model', 'sandbox-model')
        if '/messages/count_tokens' in self.path:
            payload = {'input_tokens': 250100}
            data = json.dumps(payload).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers(); self.wfile.write(data); return
        if '/messages' in self.path:
            message = {'id': 'msg_sandbox', 'type': 'message', 'role': 'assistant', 'model': model,
                       'content': [{'type': 'text', 'text': 'Sandbox response.'}], 'stop_reason': 'end_turn',
                       'stop_sequence': None, 'usage': {'input_tokens': 50000, 'cache_read_input_tokens': 150000,
                       'cache_creation_input_tokens': 50100, 'output_tokens': 3}}
            if body.get('stream'):
                start = dict(message, content=[], stop_reason=None)
                events = [('message_start', {'type': 'message_start', 'message': start}),
                          ('content_block_start', {'type': 'content_block_start', 'index': 0, 'content_block': {'type':'text','text':''}}),
                          ('content_block_delta', {'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':'Sandbox response.'}}),
                          ('content_block_stop', {'type':'content_block_stop','index':0}),
                          ('message_delta', {'type':'message_delta','delta':{'stop_reason':'end_turn','stop_sequence':None},'usage':message['usage']}),
                          ('message_stop', {'type':'message_stop'})]
                data = ''.join('event: '+name+'\ndata: '+json.dumps(event)+'\n\n' for name,event in events).encode()
                content_type = 'text/event-stream'
            else:
                data = json.dumps(message).encode(); content_type = 'application/json'
        else:
            chunks = [ {'id':'sandbox','object':'chat.completion.chunk','created':int(time.time()),'model':model,
                        'choices':[{'index':0,'delta':{'role':'assistant','content':'Sandbox response.'},'finish_reason':None}]},
                       {'id':'sandbox','object':'chat.completion.chunk','created':int(time.time()),'model':model,
                        'choices':[{'index':0,'delta':{},'finish_reason':'stop'}],
                        'usage':{'prompt_tokens':130000,'completion_tokens':3,'total_tokens':130003,
                                 'prompt_tokens_details':{'cached_tokens':80000}}} ]
            data = (''.join('data: '+json.dumps(c)+'\n\n' for c in chunks)+'data: [DONE]\n\n').encode()
            content_type = 'text/event-stream'
        self.send_response(200); self.send_header('Content-Type', content_type); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)

server = ThreadingHTTPServer(('127.0.0.1',0), Endpoint)
threading.Thread(target=server.serve_forever, daemon=True).start()
url = f'http://127.0.0.1:{server.server_port}'
(AGENT / 'models.json').write_text(json.dumps({'providers': {'sandbox': {'baseUrl': url+'/v1', 'api': 'openai-completions', 'apiKey': 'sandbox-local-only', 'models': [{'id':'sandbox-model','contextWindow':500000,'maxTokens':1024,'reasoning':False,'input':['text'], 'cost':{'input':0,'output':0,'cacheRead':0,'cacheWrite':0}}]}}}))

def meta(name, harness='claude', **extra):
    cwd = FLEET / 'projects' / name
    cwd.mkdir(exist_ok=True)
    values = dict(kind='ship', harness=harness, worktree=cwd, project='sandbox', **extra)
    path = FLEET / 'state' / (name+'.meta')
    path.write_text(''.join(f'{key}={value}\n' for key,value in values.items()))
    return cwd, path

def observe(path):
    return json.loads(run([ROOT / 'bin/fm-context-size.sh',path]).stdout)

def fixture(name, tokens, model='claude-opus-5-5', timestamp=True, tail=None):
    cwd, path = meta(name, account=CLAUDE)
    logs = CLAUDE / 'projects' / re.sub('[^A-Za-z0-9]', '-', str(cwd))
    logs.mkdir(parents=True, exist_ok=True)
    event = {'message': {'role':'assistant','model':model,'usage': {'input_tokens':tokens,'output_tokens':999999}}}
    if timestamp: event['timestamp'] = datetime.datetime.fromtimestamp(time.time()-65,datetime.timezone.utc).isoformat()
    log = logs / 'new.jsonl'
    log.write_text(json.dumps(event)+'\n')
    if tail:
        with log.open('a') as f: f.write(tail)
    return path, log

try:
    pi_cwd, pi_meta = meta('pi-real', 'pi', account=AGENT)
    run(['pi','--offline','--no-extensions','--no-mcp','--no-skills','--no-prompt-templates','--no-themes','--no-context-files','--no-approve','--no-tools','--system-prompt','Reply with a short acknowledgement.','--model','sandbox/sandbox-model','--mode','json','-p','Reply briefly.'], cwd=pi_cwd)
    row = observe(pi_meta)
    (EV / 'pi-real-without-model-store.json').write_text(json.dumps(row,indent=2))
    assert row['tokens'] == 130000, row
    # Offline Pi does not refresh its catalog. Supply disposable host model-store data
    # independently of the real vendor-emitted session and exercise the defined store contract.
    (AGENT / 'models-store.json').write_text(json.dumps({'sandbox': {'models': [{'id':'sandbox-model','contextWindow':500000}]}}))
    row = observe(pi_meta)
    (EV / 'pi-real-observation.json').write_text(json.dumps(row,indent=2))
    assert row['tokens'] == 130000 and row['context_window'] == 500000 and row['percentage'] == 26 and row['over_threshold'] is True, row
    for i,p in enumerate((AGENT/'sessions').rglob('*.jsonl')): shutil.copyfile(p, EV/f'pi-vendor-session-{i}.jsonl')

    claude_cwd, claude_meta = meta('claude-real', account=CLAUDE)
    run(['claude','-p','Reply briefly.','--model','claude-opus-5-5','--tools','','--disable-slash-commands','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--setting-sources','','--system-prompt','Reply with a short acknowledgement.'], cwd=claude_cwd,
        overrides={'ANTHROPIC_BASE_URL':url,'ANTHROPIC_API_KEY':'sandbox-local-only'},timeout=60)
    claude_row = observe(claude_meta)
    (EV / 'claude-real-observation.json').write_text(json.dumps(claude_row,indent=2))
    assert claude_row['tokens'] == 250100 and claude_row['context_window'] == 1000000 and claude_row['over_threshold'] is True, claude_row

    scenarios = {'real_pi':row,'real_claude':claude_row}
    for name,tokens,marker in [('boundary',200000,False),('above',200001,True),('below',199999,False)]:
        path,log = fixture(name,tokens)
        row = observe(path)
        assert row['tokens']==tokens and row['over_threshold'] is marker and 65 <= row['age_seconds'] <= 75,row
        scenarios[name] = row
    path,log = fixture('unknown-window',23456,model='unlisted-model',timestamp=False)
    row = observe(path)
    assert row['tokens']==23456 and row['percentage'] is None and row['age_seconds'] is None and row['over_threshold'] is None,row
    scenarios['unknown_window']=row
    path,log = fixture('bounded-tail',1234,tail='x'*4000100+'\n')
    row=observe(path)
    assert row['status']=='unknown' and row['reason']=='no assistant usage in bounded tail',row
    scenarios['bounded_tail']=row
    path,log = fixture('newest',17)
    old=log.with_name('older-larger.jsonl'); old.write_text(json.dumps({'message':{'role':'assistant','usage':{'input_tokens':900000}}})+'\n')
    os.utime(old,(time.time()-1000,time.time()-1000))
    with log.open('a') as f: f.write('{"message":{"role":"user","usage":{"input_tokens":999999}}}\n{unfinished\n')
    row=observe(path); assert row['tokens']==17,row
    scenarios['newest_last_assistant']=row
    _,path=meta('unsupported','codex'); row=observe(path)
    assert row['status']=='not_read',row
    scenarios['unsupported']=row
    _,path=meta('missing','pi',account=AGENT); row=observe(path)
    assert row['status']=='unknown',row
    scenarios['missing']=row

    # Exercise actual OpenSSH against a localhost endpoint that never sends its banner.
    stall=socket.socket(); stall.bind(('127.0.0.1',0)); stall.listen()
    connections=[]
    def accept():
        try:
            while True:
                c,_=stall.accept(); connections.append(c)
        except OSError: pass
    threading.Thread(target=accept,daemon=True).start()
    sshconfig=LAB/'sshconfig'
    sshconfig.write_text(f'Host sandbox-stall\n HostName 127.0.0.1\n Port {stall.getsockname()[1]}\n BatchMode yes\n StrictHostKeyChecking yes\n UserKnownHostsFile {LAB}/known_hosts\n GlobalKnownHostsFile /dev/null\n IdentityAgent none\n IdentitiesOnly yes\n IdentityFile none\n')
    sshwrapper=LAB/'ssh-local'
    sshwrapper.write_text('#!/bin/sh\nexec /usr/bin/ssh -F '+str(sshconfig)+' "$@"\n'); sshwrapper.chmod(0o755)
    remote_home=LAB/'remote-home'; remote_home.mkdir(exist_ok=True)
    (FLEET/'data/secondmates.md').write_text(f'- remote-stall - Sandbox (host: sandbox-stall; root: {ROOT}; home: {remote_home}; scope: sandbox; projects: ; added 2026-10-18)\n')
    _,remote_meta=meta('remote-stall','pi',kind_override='unused')
    remote_meta.write_text(f'kind=secondmate\nharness=pi\nhome={remote_home}\nremote_host=sandbox-stall\n')
    ENV['FM_SSH_BIN']=str(sshwrapper)
    start=time.monotonic(); row=observe(remote_meta); elapsed=time.monotonic()-start
    assert row['status']=='unknown' and 2.5 < elapsed < 5,row
    scenarios['real_ssh_stall']={'observation':row,'elapsed_seconds':elapsed,'accepted_connections':len(connections)}
    assert connections, 'SSH never connected to the local stalled peer'

    def fingerprint():
        return {str(p.relative_to(LAB)):{'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'mtime_ns':p.stat().st_mtime_ns}
                for parent in (FLEET,HOME) for p in parent.rglob('*') if p.is_file()}
    before=fingerprint()
    snapshot=run([ROOT/'bin/fm-fleet-snapshot.sh','--json']).stdout
    (EV/'fleet-snapshot.json').write_text(snapshot)
    parsed=json.loads(snapshot); rows={t['id']:t['conversation'] for t in parsed['tasks']}
    assert rows['pi-real']['tokens']==130000 and rows['claude-real']['tokens']==250100,rows
    assert rows['remote-stall']['status']=='unknown' and rows['unknown-window']['tokens']==23456,rows
    view=run([ROOT/'bin/fm-fleet-view.sh']).stdout
    (EV/'fleet-view.md').write_text(view)
    assert '250100 / 1000000 tokens (25%) OVER, last call' in view,view
    assert '130000 / 500000 tokens (26%) OVER, last call' in view,view
    assert '23456 / unknown tokens (window unknown), last call unknown' in view,view
    assert '200000 / 1000000 tokens (20%), last call' in view,view
    after=fingerprint()
    # Snapshot's existing observational remote-summary cache is allowed; no session or lifecycle changes.
    mutations={k:{'before':before.get(k),'after':after.get(k)} for k in before.keys()|after.keys() if before.get(k)!=after.get(k)}
    assert all(k.startswith('fleet/state/secondmate-summary-cache/') for k in mutations),mutations
    scenarios['read_only']={'mutations':mutations,'session_and_metadata_files_unchanged':True}
    (EV/'live-results.json').write_text(json.dumps(scenarios,indent=2))
    # Real vendor-emitted files, not reconstructed session fixtures.
    for name,base in [('pi',AGENT/'sessions'),('claude',CLAUDE/'projects')]:
        files=list(base.rglob('*.jsonl'))
        real=[p for p in files if 'real' in str(p.parent)]
        for i,p in enumerate(real): shutil.copyfile(p,EV/f'{name}-vendor-session-{i}.jsonl')
    print(json.dumps(scenarios,indent=2))
finally:
    server.shutdown(); server.server_close()
    if 'stall' in globals():
        stall.close()
        for c in connections: c.close()
    shutil.rmtree(LAB)
