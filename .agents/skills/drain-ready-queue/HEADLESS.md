# The headless branch

What changes when the drain runs headless — the brief names a **run issue**, and nobody is watching
the terminal. This file is the single home for that branch; attended runs never read it.

## The report posts to the run issue

Step 5's relay — the verbatim recap, the verdict beside it, every findings line — goes to the run
issue as a comment, never to the terminal: a report that only reached scrollback is a lost one.
Write the content into the scratch directory you made per
[ORCHESTRATION.md](./ORCHESTRATION.md) § 4 — the directory is what keeps two lanes apart, so the
basename is free — then post it by its full path. `<scratch>` is the path `mktemp -d` printed,
spelled out: a shell variable does not survive from one of your commands to the next.

```bash
bash "$SKILL/scripts/run-issue-post.sh" <run issue> <scratch>/report-<N>.txt
```

The script reads the comment back and fails when it did not land — the `run-issue-*.sh` exception
SKILL.md's preamble names: its non-zero exit is the runner's interlock, not a findings line.

## The STOPPED relabel is yours to run

Headless there is no PM to pull a stopped ticket out of the queue, so step 6's STOPPED relabel is
yours, not a hand-over. Left labelled, the ticket is re-picked by every fresh session until the
STOPPED brake burns two iterations ending the run.
