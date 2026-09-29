# stojack CI runner

This fork's CI runs on one self-hosted runner, `firstmate-stojack`, inside a Linux VM on the stojack Mac mini.
GitHub stopped starting hosted jobs over a billing limit, and hosted minutes are not wanted, so every `ci.yml` job targets `[self-hosted, linux, stojack]`.
The setup copies the ripplez and edgez runners ([jjtylr/ripplez#81](https://github.com/jjtylr/ripplez/pull/81), [jjtylr/edgez#79](https://github.com/jjtylr/edgez/pull/79)).
The runner holds no secrets.

## The VM

An OrbStack machine named `firstmate-ci`, Ubuntu 24.04 arm64:

```bash
orb create --isolated --isolate-network --cpus 4 --memory 4G --disk 40G -a arm64 ubuntu:noble firstmate-ci
```

`--isolated` removes the Mac filesystem mount and makes the `mac` command fail, and `--isolate-network` blocks the Mac's own services and the other OrbStack machines while the internet stays reachable.
The LAN is still reachable; what keeps anything else safe is that the runner holds no credential.
The CPU and memory values are per-machine ceilings; never change OrbStack's global settings to make room.

## Inside the VM

Apt packages: `git`, `jq`, `curl`, `ca-certificates`, `tar`, `xz-utils`, `unzip`, `zip`, `python3`, `python-is-python3`, `perl`, `ruby`, `tmux`, `zsh`, `build-essential`, `lsof`, `sqlite3`, `file`, `procps`, `psmisc`, `openssl`, `gnupg`, and `gh` from GitHub's apt repository.
Node 22 is installed from the nodejs.org tarball into `/usr/local`, because Ubuntu's `nodejs` is 18.
The jobs install ShellCheck, actionlint, Herdr, Treehouse, tasks-axi, and the Pi package themselves.

The runner (v2.337.0, labels `self-hosted, Linux, ARM64, stojack`) lives in `/home/runner/actions-runner` and runs as the no-sudo `runner` user under `actions.runner.jjtylr-firstmate.firstmate-stojack.service`, enabled at boot.
Its `.env` sets `TMPDIR`, a user-owned `NPM_CONFIG_PREFIX` so the jobs' `npm install -g` works without root, a `PATH` that includes that prefix, and `/home/runner/hooks/clean.sh` as the job-started and job-completed hook.
The hook stops stray `tmux` and `herdr` servers the tests left behind and empties `TMPDIR` and the job's workspace.

IPv6 is off (`/etc/sysctl.d/99-no-ipv6.conf`, applied at boot by `disable-ipv6.service`), because `--isolate-network` leaves an IPv6 default route with no egress.

One runner takes one job at a time, so a CI run's jobs queue behind each other.

## Dropped jobs

The stock macOS Bash 3.2 job is dropped: stojack has no sandboxed macOS user, and a native runner would execute pull-request code as the Mac's own user.
The manual Windows Herdr spike workflow and the no-mistakes PR-body compliance check are also removed.

## Starting on boot

The unit starts with the VM, the VM starts with OrbStack, and OrbStack starts at josh's login; stojack has no automatic login, so after a reboot nothing runs until someone logs in.

## Operating it

```bash
ssh stojack '/opt/homebrew/bin/orb -m firstmate-ci -u root systemctl status actions.runner.jjtylr-firstmate.firstmate-stojack'
ssh stojack '/opt/homebrew/bin/orb -m firstmate-ci -u root journalctl -u actions.runner.jjtylr-firstmate.firstmate-stojack -n 100'
gh api repos/jjtylr/firstmate/actions/runners --jq '.runners[] | {name, status, busy}'
```

To re-register, mint a one-time token (it expires in an hour; no PAT goes on the machine):

```bash
TOKEN=$(gh api -X POST repos/jjtylr/firstmate/actions/runners/registration-token --jq .token)
ssh stojack "/opt/homebrew/bin/orb -m firstmate-ci -u root bash -c 'cd /home/runner/actions-runner && ./svc.sh stop && sudo -u runner ./config.sh --unattended --replace --url https://github.com/jjtylr/firstmate --token $TOKEN --name firstmate-stojack --labels stojack --work _work && ./svc.sh start'"
```

To rebuild from nothing, `orb delete firstmate-ci` removes only this VM.
