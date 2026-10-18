"""Real SSH + selected-home fm-on transport in a disposable Linux container.
All fixture/config/package files live under .test-local; Docker image/container
are ephemeral verification toolchain state and are removed in finally.
"""
from pathlib import Path
import os, subprocess, json, time, datetime, shutil
ROOT=Path.cwd(); EV=Path(__file__).parent; LAB=ROOT/'.test-local'; FS=LAB/'linux'
NAME='fm-context-gate-01m56'; IMAGE=NAME+':test'
transcript=[]
def run(args,env=None,check=True,timeout=60):
    t=time.monotonic()
    p=subprocess.run(list(map(str,args)),text=True,capture_output=True,env=env,timeout=timeout)
    transcript.append({'argv':list(map(str,args)),'exit':p.returncode,'seconds':time.monotonic()-t,'stdout':p.stdout,'stderr':p.stderr})
    (EV/'remote-live-transcript.json').write_text(json.dumps(transcript,indent=2))
    if check and p.returncode: raise RuntimeError(f'{args}: {p.stderr}\n{p.stdout}')
    return p
for p in (FS/'root/.ssh',FS/'home/mate/state/parent-route',FS/'root/.pi/agent/sessions/--home-mate--',FS/'usr/local/bin',FS/'etc/ssh',LAB/'parent/state',LAB/'parent/data',LAB/'parent/config',LAB/'parent/projects'):
    p.mkdir(parents=True,exist_ok=True)
(FS/'etc/passwd').write_text('root:x:0:0:root:/root:/bin/bash\nsshd:x:22:22:sshd:/var/empty:/sbin/nologin\n')
(FS/'etc/shadow').write_text('root::19000:0:99999:7:::\nsshd:!:19000:0:99999:7:::\n')
(FS/'var/empty').mkdir(parents=True,exist_ok=True)
(FS/'tmp').mkdir(exist_ok=True); (FS/'tmp').chmod(0o1777)
(FS/'run').mkdir(exist_ok=True)
(FS/'etc/ssh/sshd_config').write_text('Port 2222\nListenAddress 0.0.0.0\nHostKey /etc/ssh/lab_host\nPermitRootLogin prohibit-password\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nStrictModes no\nAuthorizedKeysFile .ssh/authorized_keys\nPidFile /run/sshd.pid\nLogLevel VERBOSE\n')
key=LAB/'ssh-client'
if not key.exists(): run(['ssh-keygen','-q','-t','ed25519','-N','','-f',key])
if not (FS/'etc/ssh/lab_host').exists(): run(['ssh-keygen','-q','-t','ed25519','-N','','-f',FS/'etc/ssh/lab_host'])
(FS/'root/.ssh/authorized_keys').write_text(key.with_suffix('.pub').read_text())
(FS/'root/.gitconfig').write_text('[safe]\n directory = '+str(ROOT)+'\n')
(FS/'root/.pi/agent/models-store.json').write_text(json.dumps({'remote-provider':{'models':[{'id':'remote-model','contextWindow':1000}]}}))
(FS/'root/.pi/agent/sessions/--home-mate--/real-remote.jsonl').write_text(json.dumps({'type':'message','timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat(),'message':{'role':'assistant','model':'remote-model','provider':'remote-provider','usage':{'input':300,'cacheRead':20,'cacheWrite':4,'output':99999}}})+'\n')
(FS/'home/mate/.fm-secondmate-home').write_text('mate\n')
(FS/'home/mate/state/parent-route/mate.meta').write_text('kind=secondmate\nharness=pi\nhome=/home/mate\naccount=/root/.pi/agent\n')
if not (FS/'usr/local/bin/fm-remote-entrypoint.sh').is_symlink():
    (FS/'usr/local/bin/fm-remote-entrypoint.sh').symlink_to(ROOT/'bin/fm-remote-entrypoint.sh')
git_env=dict(os.environ,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null')
run(['git','init','--quiet','--separate-git-dir='+str(LAB/'remote-index.git'),LAB/'index'],env=git_env)
run(['git','--git-dir='+str(LAB/'remote-index.git'),'--work-tree='+str(ROOT),'add','bin'],env=git_env)
(LAB/'remote-git-pointer').write_text('gitdir: '+str(LAB/'remote-index.git')+'\n')
try:
    # Import only the workspace-local test rootfs; no host packages are installed.
    tar=subprocess.Popen(['tar','--uid','0','--gid','0','-C',str(FS),'-cf','-','.'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
    imported=subprocess.run(['docker','import','-',IMAGE],stdin=tar.stdout,text=True,capture_output=True,timeout=90)
    tar.stdout.close(); tar.wait()
    if imported.returncode: raise RuntimeError(imported.stderr)
    run(['docker','run','-d','--name',NAME,'-p','127.0.0.1::2222',
         '-v',str(ROOT)+':'+str(ROOT)+':ro',
         '-v',str(LAB/'remote-git-pointer')+':'+str(ROOT/'.git')+':ro',
         '-v',str(FS/'root')+':/root', '-v',str(FS/'home')+':/home',
         IMAGE,'/usr/sbin/sshd','-D','-e','-f','/etc/ssh/sshd_config'])
    port=run(['docker','port',NAME,'2222/tcp']).stdout.strip().rsplit(':',1)[1]
    hostpub=(FS/'etc/ssh/lab_host.pub').read_text().split()
    known=LAB/'ssh-known-hosts'; known.write_text('[127.0.0.1]:'+port+' '+hostpub[0]+' '+hostpub[1]+'\n')
    config=LAB/'ssh-remote-config'
    config.write_text(f'Host sandbox-remote\n HostName 127.0.0.1\n Port {port}\n User root\n IdentityFile {key}\n IdentityAgent none\n IdentitiesOnly yes\n BatchMode yes\n StrictHostKeyChecking yes\n UserKnownHostsFile {known}\n GlobalKnownHostsFile /dev/null\n')
    wrapper=LAB/'ssh-remote'; wrapper.write_text('#!/bin/sh\nexec /usr/bin/ssh -F '+str(config)+' "$@"\n');wrapper.chmod(0o755)
    (LAB/'parent/data/secondmates.md').write_text(f'- mate - Sandbox (host: sandbox-remote; root: {ROOT}; home: /home/mate; scope: sandbox; projects: ; added 2026-10-18)\n')
    meta=LAB/'parent/state/mate.meta';meta.write_text('kind=secondmate\nharness=pi\nhome=/home/mate\nremote_host=sandbox-remote\n')
    env={'PATH':os.environ['PATH'],'HOME':str(LAB/'parent'),'TMPDIR':str(LAB/'tmp'),'FM_HOME':str(LAB/'parent'),'FM_ROOT_OVERRIDE':str(ROOT),'FM_SSH_BIN':str(wrapper)}
    doctor=run([ROOT/'bin/fm-on.sh','mate','fm-remote-doctor.sh','--fix'],env=env,timeout=60,check=False)
    result=run([ROOT/'bin/fm-context-size.sh',meta],env=env,timeout=10)
    row=json.loads(result.stdout)
    (EV/'remote-live-observation.json').write_text(json.dumps(row,indent=2))
    assert row['tokens']==324 and row['context_window']==1000 and row['percentage']==32.4 and row['over_threshold'] is True,row
    snapshot=run([ROOT/'bin/fm-fleet-snapshot.sh','--json'],env=env,timeout=20)
    (EV/'remote-fleet-snapshot.json').write_text(snapshot.stdout)
    assert json.loads(snapshot.stdout)['tasks'][0]['conversation']['tokens']==324
    print(json.dumps(row,indent=2))
finally:
    logs=run(['docker','logs',NAME],check=False)
    (EV/'remote-sshd.log').write_text(logs.stdout+logs.stderr)
    run(['docker','rm','-f',NAME],check=False)
    run(['docker','image','rm',IMAGE],check=False)
