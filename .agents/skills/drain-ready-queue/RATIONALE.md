# Why the cycle is shaped this way

The justification behind each step of `drain-ready-queue`'s cycle. **You do not need this file to
run the loop** — SKILL.md carries every step, every command, and the meaning of every finding line.
Read a section here when a step's design is in question: when you are tempted to reorder, skip, or
"improve" it, or when you are building a stage against
[STAGE-CONTRACT.md](./STAGE-CONTRACT.md) and want the worked reasoning.

Section numbers match the cycle step numbers in SKILL.md.

## 0. Why reaping is needed at all, and what it may touch

Each subagent runs in an ephemeral worktree the harness creates (`Agent` tool, `isolation:
worktree`) under `<repo>/.claude/worktrees/`. The harness auto-removes only an **unchanged**
worktree, and an operative's is usually not unchanged — measured 2026-08-18: a subagent that
committed left its worktree and both branches behind. So finished worktrees persist until something
collects them, and that something is step 1.

**The exception, and the residue it leaves.** A run that dies *before its first edit* leaves an
unchanged worktree, which the harness removes itself — measured 2026-08-19, the first #66 operative,
killed by an API 500 mid-survey. So an early death leaves **no worktree at all**: only its
zero-commit branches survive, and they are the only marker that the dispatch ever happened. That is
why `REAP-RESIDUE` exists. Do not expect a worktree to be the evidence in every death; it is the
evidence only once the run has changed something.

**Why ownership is measured rather than assumed.** That directory is a shared path — a PM session or
any second session can hold a worktree in it. Observed 2026-08-19: the reap interrogated a live
session's worktree and reported it every cycle. Noise is the mild failure; the sharp one is that the
old reap matched a PR by **branch name alone**, so any collision with a merged PR's head branch was
enough to remove a live session's worktree and force-delete its branch. So the reap now acts only on
what the harness itself wrote: the lock reason's owner class (`claude agent …` owned, `claude
session …` another session's), or, unlocked, the harness's `agent-*` directory. Anything else is
foreign and is reported, never touched.

**Rejected: an ownership marker file** the loop writes into each dispatched worktree. It would be
authoritative, but the loop does not create the worktree — the harness does, before the operative's
first turn — so the loop can only write the marker *after* the fact, and a run that dies early dies
before the marker exists. The state that most needs identifying is the one the marker would miss.

**Rejected: branch-name authority** — treating `agent/*` or `worktree-agent-*` as proof of a drain
dispatch. `worktree-agent-*` is the harness's naming for *every* Agent-tool worktree in *any*
session, and `agent/*` is also how humans name branches they manage by hand. Both name a
convention, not an owner, and a convention cannot be checked against a forger or a coincidence.

## 1. Why teardown sits at the top

Teardown is deliberately at the **top** of the iteration, not the end of the last: when a subagent
finishes, its PR is still open, and step 6's more-fixes path needs that worktree back for the
warm-context round. Sweeping at the top collects whatever the PM merged in the meantime, and nothing
ever blocks on a merge.

The sweep matters more than it looks: the worktrees sit *inside* the repo and are typically not
gitignored, so a stale one is visible to `git status`, to any gate that walks the tree, and to a
careless `git add -A`.

**Why liveness is measured inside the script.** "Is this dispatch still running" is a deterministic
question with a mechanical answer — the lock reason carries a pid, and `ps -p` settles it — so it
belongs in a script, not in an LLM judgment step the loop pays for every cycle (AGENTS.md: the layer
decides). The reap therefore reports `REAP-HELD-LIVE` / `REAP-HELD-DEAD` instead of asking the
orchestrator to go and check. What the pid measures is § 4.

**Why the branch sweep is guarded by unique commits.** The old sweep force-deleted every
`worktree-agent-*` branch whose worktree was gone. Deleting a branch whose tip the base branch
already contains destroys nothing, so that stays automatic; a branch holding commits the base lacks
is unreviewed work, and destroying it is not a sweep's decision (`REAP-ORPHAN`).

## 2. Why the queue is filtered the way it is

Unscored tickets sort last (`ratio: -1`) on purpose — scoring them is `triage-and-score`'s job, not
the drain's. `needs-info`, `ready-for-human`, `spec` and `wayfinder:*` are silently excluded because
they belong to another stage.

Blocking edges are counted **open**-only, so a blocker that has since closed can never hide its
ticket. A held ticket gets a `PICK-BLOCKED` line every cycle it is held because starvation must be
visible; only the repetition tells a stale edge nobody cleared from a blocker nobody is working.
Never act on the edge yourself — clearing a dependency, re-labelling, re-ordering are all the PM's
(STAGE-CONTRACT § 4).

**Why a claimed ticket is excluded here rather than checked at dispatch.** The pick is the one place
every path into a dispatch goes through — a fresh run, a restarted one, a second slot — so a filter
here holds for all of them, and a check at step 4 would hold only for whoever remembered it.
`PICK-CLAIMED` follows `PICK-BLOCKED`'s contract exactly, for the same reason: a claim nobody
releases starves its ticket exactly like a stale edge does, and the cycle-after-cycle line is what
makes it visible. The release rule itself lives in `claim-status.sh` and is asked, never copied —
two implementations of "is this claim open" would drift, and the drift would be invisible because
both would read fine.

**The effort bounce.** A ticket scored above `effort_threshold` gets split before an agent sees it.
An unscored candidate (`e: null`) is not bounced — it already sorts last, so it costs nothing to
leave alone.

## 3. Why locks are checked per candidate, and why the unknown case has two answers

PRs accumulate unmerged while the PM reviews, so two tickets can reach `main` against a shared
resource even at one lane, where only one agent ever runs. That is what `check-lock.sh` answers,
and it is why the check is per candidate rather than per run.

**The candidate half of that rule is self-reported, so it is audited afterwards.** `check-lock.sh`
measures the holder: it reads every open loop PR's real file list, so an open PR cannot hide a lock
it holds. The candidate side reads the ticket's `Locks:` line — written at triage, before the file
list exists — and any scope change during implementation invalidates it silently. Merged #136 is
the instance: its ticket said `Locks: none` and PR #138 touched `CONTEXT.md` and
`docs/agents/loop.md`, two registered locks, with no signal anywhere. So `check-declared-locks.sh`
runs once when a PR opens and compares the **measured** file list against what that ticket declared.

It is a **detector, not a guard**, and the split is deliberate. A mis-declared lock cannot be undone
by holding anything. The PR already exists, and the overlap it might have caused either happened or
did not. What is worth having is the signal, every cycle, so the PM can fix the ticket and see
whether the drift is a pattern. It runs at every lane count, because a mis-declaration is worth
knowing about in a serial run too, which is exactly where #136 slipped through.

**The unknown case inverts with the lane count, and that is not an inconsistency.** At 1 lane,
"cannot tell whether this candidate hits a lock → dispatch" is right: the subagent reports the
moment it knows, the recap catches it, and a held candidate is cheaper to skip than a wrong hold is
to undo. The whole of that reasoning rests on implementation being serial. The only work that can
be surprised is work already merged or already in review, both of which a human is looking at.
Above 1 lane that premise is gone: the work that gets surprised is a sibling lane nobody is
watching, running right now, in a worktree. So `check-holds.sh` holds on everything it cannot
establish, a failed listing, an unreadable claim, a window that may have truncated. Same question,
different cost of being wrong, so a different default. [SCHEDULER.md](./SCHEDULER.md) states the
rule; this is why it moved.

## 4. Why dispatch looks like this

**A slot, not a stream.** A lane is capacity, and the scheduler fills each free one with the
highest-ranked candidate the collision check clears against everything in flight. Nothing binds a
lane to a milestone, a chain or a set of files: serial chains stay serial because their blocking
edges hold them, and a chain that owned a lane would idle it every time the chain's head was
blocked.
At 1 lane there is only ever one slot, so this is the serial drain it replaced, reached by a rule
instead of by a prohibition. The rule, its brakes and its recovery are
[SCHEDULER.md](./SCHEDULER.md); it lives there rather than here because the orchestrator runs on it
every cycle, and this file is the one you read when a step is in question.

**Why the capacity is a number and not a judgment.** `max_lanes` is one line of the repo's config,
resolved by `resolve-lanes.sh`, and every reading it cannot use — absent, `0`, `4`, text, any value
above 1 under a policy that is not an auto one — resolves to 1 with a findings line. A config typo
degrades to today's serial drain, never to uncontrolled parallelism, which is the same fail-safe
shape an unknown `merge_policy` name gets.

**Why the claim goes up before the spawn.** Until the worker pushes a branch, a dispatch leaves no
trace anywhere except the orchestrator's own context. Everything that has to see in-flight work is
blind in that window: a concurrent scoring pass can amend the declarations a check just cleared, a
second slot can take the ticket that is already running, and a restarted orchestrator cannot recover
what it was doing. None of that is a memory problem — it is a missing blackboard record
(STAGE-CONTRACT § 5), and the ticket is where the other actors already look. Posting it *after* the
dispatch would close nothing: the window is exactly the part before the worker exists.

**Why the snapshot is frozen.** The claim records the declaration as the collision check cleared
it. Rewriting it when a later brief amends a `Locks:` line would retroactively change the input
to a decision already made, and the decision would then rest on a state nobody ever measured. So an
amendment binds the *next* dispatch of that ticket, and the claim is left standing. It costs a stale
snapshot on a ticket someone re-declared mid-flight; the alternative costs the ability to say what
any past dispatch was cleared on.

**Why a dead worker's claim is released by the cycle, and why the order is load-bearing.**
`REAP-HELD-DEAD` establishes that the run is over, not that the work is, and the hazard in releasing
it is real. Nothing on the tracker records what the run got done, so a bare release would put the
ticket back in the pick and invite a silent re-dispatch over whatever survived. The loop's first
answer was to leave the claim standing for the PM. That answer cost a whole run.

Measured on run #211, 2026-08-27: the operative for #198 died before it pushed anything, its claim
stood, and the collision check of the day held #199, #176, #177 and #193, the entire dispatchable
queue. Two iterations, eighteen minutes, nothing dispatched and nothing merged, and the runner fired
its live-lock stop. Headless there is no PM inside the run to write the annotation, so one worker's
death ended the run that caused it, and a run started again with the claim still open reached the
same stop the same way. That check compared taxonomy buckets and this one does not (ADR 0007), but
the shape survives the change: a claim nobody can release is a claim that stops the queue behind it.

So the act takes the STOPPED shape instead, and its **order** is what closes the hazard rather than
the PM's attention. The ticket loses `ready-for-agent` first, and only then does the cycle write the
`died` row. A released claim on a ticket the pick can no longer select is harmless, because the
label that would qualify it is already gone. The reverse order is the silent re-dispatch this
paragraph used to forbid by standing still. The cycle leaves the worktree and the branch where they
are, so the evidence survives and salvage or discard is still the PM's. What it takes back is the
lane, which was never the PM's to hold. [CLAIM.md](./CLAIM.md) carries the rest of the lifecycle,
and [LEDGER-REFERENCE.md](./LEDGER-REFERENCE.md) what the sixth word asserts (#213).

**The namespaced type is the one that resolves.** Probed 2026-08-19 on Claude Code 2.1.235 —
**historical: this agent was still named `implementer` then** (renamed to `operative` in #54), and
the rejection message below is quoted as measured rather than rewritten, because rewriting a
measurement falsifies it. A bare `implementer` came back `Agent type 'implementer' not found.
Available agents: … toolkit:implementer, toolkit:scorer`. What the probe measured is the
bare-vs-namespaced form, not this agent's name, so it carries over to `toolkit:operative` (DERIVED —
not re-probed under the new name).

**Why the brief carries nothing but substitutions.** Every rail lives in
[operative.md](${CLAUDE_PLUGIN_ROOT}/agents/operative.md) and travels with it —
verify-the-premise, the gates rule, the PR and closing keyword, the STOP list, the folding bound,
the recap shape. A rail restated by the dispatching skill is a rail that will drift from the one the
operative actually runs on, and the drift is invisible because both copies read fine. When a rail
needs changing, change the agent definition (STAGE-CONTRACT § 2). The definition resolves its own
reference files through `${CLAUDE_PLUGIN_ROOT}`, so the orchestrator resolves no paths.

**Why the area rides the brief and the touch rides the PR.** The `Area:` line is a ticket specific,
so it travels in the brief like the number and the slug; the atlas *procedure* is a rail, so it
stays in the agent definition and the brief does not restate it. The orchestrator itself never
writes `docs/atlas/`, and the two ways it could are both worse than the one it uses: a write before
dispatch lands outside the operative's diff, so the map records work the PR may never merge; a write
at recap time either bypasses the gate machinery altogether or arrives as a second PR, doubling the
PM's merge load for one bullet. Riding the operative's branch makes the touch pass the same gates,
get the same verdict, and land in the same merge as the work it records — the atlas can then only
be wrong about work that never landed at all (spec #64).

**Why there is a fallback.** Neither form resolves when the plugin is loaded from a checkout, or
when the harness does not know it; the rejection message names every type it does know. Never
dispatch an operative with no rails: an unrailed worker merges its own PR, skips the gates, or
chases every adjacent defect it trips over.

**A no-PR worktree under an open claim is the expected in-flight state.** Since step 4 claims the
ticket before it spawns, the pre-push window now has a record on the tracker, and `REAP-HELD-LIVE`
against a fresh open claim is that record agreeing with the pid: the run is working toward its PR.
Reading it as anything else would raise an alarm on every dispatch, every cycle, for as long as the
window lasts — noise that trains the PM to skip the line that matters. The dead reading stays with
`REAP-HELD-DEAD`, where the pid was measured gone.

**A PR-less worktree does not establish a dead run.** A missing PR means only that the branch has no
PR — a live run that has not reached its `gh pr create` yet reads identically to one that died
mid-ticket, and neither the PR state nor the git state disambiguates: an empty `main..<branch>`
log and a dirty worktree occur in both readings. Measured 2026-08-19, #57 drain: the no-PR finding
was read as a dead run and escalated to the human; the agent was alive and opened PR #58 ninety
seconds later. What distinguishes them is *liveness*, not git state.

**What the pid measures, and why that is the right assertion.** Probed 2026-08-19 on a live
dispatch, `git worktree list --porcelain` showed the worktree `locked` with a reason naming a pid
(`claude agent <id> (pid <n> start <time>)`). That pid is the **hosting session's** process, not the
subagent's turn, so pid-alive asserts "a session is live in there — hands off" rather than "this
dispatch is still thinking". Hands-off is the assertion the reap needs under either reading, which
is why the weaker measurement is still sufficient. Lock *presence* alone proves nothing: the lock is
a plain file under `.git/worktrees/<id>/`, which a killed process cannot remove, so a dead run's
worktree is expected to look locked too. The reap runs this probe itself (§ 1) and treats only a run
*established* dead — pid measured gone — as dead.

**Why a live locked worktree was never the hazard.** Probed 2026-08-19: a non-force `git worktree
remove` refuses a locked worktree outright (`fatal: cannot remove a locked working tree`, exit 128),
and this script never forces. So the lock already protected the directory; what it did not protect
was the *report*, which called that refusal a dirty worktree. The stale-lock case says stale lock,
the live case says live, and neither is ever forced.

**Why a dead run is inspected rather than re-dispatched.** Whatever survived in the worktree is the
only evidence the run happened at all. Re-dispatching silently discards that evidence and can
duplicate committed work. That is why the cycle moves the ticket to `needs-info` rather than
leaving it dispatchable, and why it collects nothing the dead run left behind.

**The procedure, when a subagent dies mid-ticket** (interrupted, crashed, killed). If it had changed
anything, its worktree survives: inspect `git -C <repo>/.claude/worktrees/agent-<id> status --short`
and the log, tell the PM what survived, and let them choose between salvaging and discarding. A
discard is `git worktree remove --force` plus deleting both branches — on the PM's word, never on
yours. If it died before its first edit there is no worktree to inspect (§ 0); the `REAP-RESIDUE`
branch is the whole record, and a re-dispatch is the normal answer.

## 5. Why closure, a verdict, and CI are three separate witnesses

**Read the PR back.** Conventions drift, and a PR that merges without the closing keyword leaves its
issue open with no signal.

**The verifier runs with no worktree isolation** because it produces no branch and clones the
briefed commit itself; a worktree left on a detached HEAD is one `reap.sh` reports (`REAP-SKIPPED`)
and never collects.

**Why the verdict names a commit.** A verdict against "the branch" is a claim with no subject: the
branch moves, and afterwards nothing can say whether the tree that merged is the tree that was
examined. Under an auto policy that gap is a merge of an unexamined tree, and it is silent — every
artifact still reads clean. So the head commit is read from the **host** (a local ref can be stale,
and a self-reported one has no provenance), it is briefed, the verifier confirms the clone it got is
that commit, and the block records it. A verifier that finds a different commit refuses rather than
measuring the tree it happens to have. This was a meaning change to the verdict, not a new field, so
the marker moved with it and `merge-decision.sh` reads the older marker as no verdict at all —
[VERDICT.md](./VERDICT.md) holds the rule.

**Why verification sits inside the landing sequence under an auto policy.** Naming a commit is not
enough on its own: the base moves while the verifier works, so the tree that merges can still differ
from the tree that was examined, and every artifact still reads clean afterwards. So under an auto
policy the branch is updated server-side first, the head is read from the host **after** that update
(`merge-freshness.sh`, which runs no `git` at all — a local ref is stale exactly when it matters),
the verifier is briefed on that commit, and the merge is pinned to it so the host refuses the merge
itself if the head moved. Each ticket is still verified once in the common case; there is no
re-verify cascade after a neighbour lands. [MERGE-PIPELINE.md](./MERGE-PIPELINE.md) holds the five
steps, the park conditions, and the rule that keeps the loop's own ledger writes from moving the
base underneath its own merges.

**The verdict's weight is the policy's** ([MERGE-POLICY.md](./MERGE-POLICY.md)): under `pm-merge`
it is advisory — it informs the PM's merge and never gates one; under an auto policy it is merge
input, and only through `merge-decision.sh`, so the highest-stakes act in the pipeline rests on an
exit code rather than on model judgment. A self-report is not evidence, which is why the verdict
exists at all.

**Why only your own dispatch's verdict is merge input.** A verdict block re-read off PR comments
could be quoted, stale, or forged — anyone who can comment can paste the marker, and the validator
checks shape, not authorship. The word the verifier returned to *you*, this iteration, is the only
copy with provenance. A restarted run has lost that provenance, so it re-verifies before it merges
anything.

**CI answers what the verifier cannot** — what the *server* made of the pushed branch.
`pr-checks.sh` reads `gh pr checks` by bucket, never by exit code: that code says the same thing for
a failing check and for a repo with no CI. `CHECKS-NONE` is the normal state in a repo without CI.

**Why the recap is relayed verbatim.** The PM is the reviewer; a third opinion makes the hand-off
less trustworthy, not more.

## 6. Why each PM outcome is handled the way it is

**More fixes** goes back to the *same* agent by `SendMessage`: it resumes with its full context
intact — the one place in the cycle where warm context is right. That round exists only under
`pm-merge`: after an auto-merge there is nothing to send back to — the PR landed before the PM read
the recap, and the reap collects the worktree once it merges, so the warm-context round has nothing
to resume into. Post-auto-merge disagreement is a revert or a follow-up ticket, never a rework.

**Why the auto-merge carries `--delete-branch --repo …`, and why `--repo` is not decoration.**
Nothing else in the loop deletes a loop branch from the remote: step 1's reap removes the worktree
and the *local* branch once a PR merges, and the remote branch stands forever. It piles up (measured
on this repo 2026-08-25: 49 `agent/*` branches on origin, 47 of them merged PRs' heads), and it is a
push collision the day a re-readied ticket reuses its slug. `--delete-branch` alone does not collect
it. Read in gh 2.98.0's `pkg/cmd/pr/merge/merge.go`, `mergeRun` calls `deleteLocalBranch()` **before**
`deleteRemoteBranch()` and returns on its error; `deleteLocalBranch` runs `git branch -D`, which
exits 1 with `cannot delete branch … used by worktree at …` while a worktree holds the branch
(measured directly against git). At step 6 the operative's worktree always still holds it — the reap
that collects it is the *next* iteration's step 1 — so the local delete fails, the merge command
returns non-zero, and the remote branch survives. That is the same outcome
`docs/research/2026-08-25-headless-permission-profile.md` recorded for `gh pr close --delete-branch`,
and it is the same code ordering. `--repo` sets gh's `CanDeleteLocalBranch` to false, so the local
step is skipped entirely and the remote delete is reached.

**Why a failed auto-merge is a fallback, not a retry.** A merge that fails under an auto policy
(branch protection, a conflict that appeared under it) failed for a reason a retry cannot see, and
retrying is how an orchestrator turns one findings line into a loop. The PM gets the line and the
parked PR.

**The one exception is the refused pin, and it is an exception because its cause is measured.**
`merge-pinned.sh` does not read gh's message to say why a merge failed — a failed merge fits a moved
head, branch protection and a fresh conflict at once. It re-reads the host: a PR that is now
`MERGED` merged, a head that no longer matches the examined commit is the pin firing, and anything
else — including a re-read that itself fails — parks. Only the measured pin refusal re-enters the
pipeline, and only once, because a race that lost is a cause a re-run can actually clear. Twice is
something systematically pushing to that branch, which is not the loop's to work out.
[MERGE-PIPELINE.md](./MERGE-PIPELINE.md) holds the sequence those exit codes sit in.

**A STOPPED recap** must leave the queue (`ready-for-agent` → `needs-info`), otherwise the next
iteration picks it straight back up. `cleanup-stopped.sh` touches only the branch you briefed, never
a pattern sweep — `agent/*` is also how humans name branches they manage by hand.

**Why `REAP-RESIDUE` reports and never deletes.** Residue is real evidence of a dispatch, and its
branch is cheap to leave standing; the authority to sweep `agent/*` by pattern is the same authority
that would delete a human's parked branch, and it stays forbidden for the reap exactly as it is for
`cleanup-stopped.sh`. Naming one branch is the PM's act, and step 6's command is where it happens.

## 7. Why the ledger row is written before looping

An outcome you carry into the next iteration is state in the wrong place (ORCHESTRATION § 1,
STAGE-CONTRACT § 5), and this ledger is the blackboard it belongs on. `ledger-append.sh` also
creates the ledger on first append with the version marker it owns, so the format is never
yours to compose.

**Why the row is committed and pushed, not merely written.** Both readers resolve the ledger by
filesystem path — `$LEDGER_FILE`, else `<repo root>/docs/agents/ledger.md` — so a row that stays in
one working tree is a blackboard nobody else can read. `runner-gate.sh` counts rows against the
merged PRs the host reports, and `ledger-corroborate.sh` holds rows against `gh` and `git`; run from
another checkout, each sees the row as missing and reports a lag that is not there. This is
measured, not feared: on the 2026-08-25 headless drain three iterations appended rows, none was
committed, and the gate reported a three-PR ledger lag.

`--commit` is the script's because the message is the script's, exactly as the row's format is — a
message each caller composes by hand drifts, and this log is read by a human looking for one row.

**`--push` is the script's for a harder reason: the obvious doctrine was measured and it fails.**
"Commit the row, then `git push`" is wrong on the ordinary path, not the rare one. Against a bare
origin, with the iteration's own `gh pr merge` having advanced remote `main` while this checkout
stood still, the push is rejected `! [rejected] main -> main (fetch first)`; the recovery an
engineer would reach for next, `git rebase`, then refuses too — `cannot rebase: You have unstaged
changes` — because the run's tree is dirty by design. The working sequence is fetch, then
`rebase --autostash`, then push again, and *that* is three commands in an order whose failure is
silent. Writing it as prose asks an orchestrator to execute it faithfully, which is the class of
defect this whole section exists to close. Deterministic work is a script.

What stays yours is the **judgment**, which is why every failure is still a finding and never an
error: a protected branch, a second rejection, a ledger the remote also changed. The script does one
sync and stops. It never forces, and it aborts a conflicted rebase and leaves the checkout as it
found it. The commit line names its branch for the same reason: the script cannot decide whether an
agent branch is the wrong place to land a row, but you can see that it did.

**The sync's guard is drawn on paths, and that is the whole of it.** A rebase rewrites every commit
it replays, so the script refuses to sync when the branch is ahead by a commit that touches anything
but the ledger path. It does *not* ask who wrote the commit. A ledger-only commit is rebased to a
new sha and pushed whoever made it — including a hand correction the maintainer has not pushed yet,
which this file elsewhere calls the PM's own act. Checking the author would not close that gap, and
the reason is worth writing down before someone adds it: the script commits under the repository's
own identity, deliberately, so its commits and the maintainer's carry the same author. Measured in
one checkout, both read `maintainer <maintainer@example.com>`. An author test would refuse neither
and discriminate nothing, so the path test is the honest bound and the finding line says exactly
that.

Corroboration runs at the **end of a run** rather than every iteration because it reads the whole
merged history; `LEDGER-ABSENT` means no ledger exists yet, and the rows are what a backfill would
consume. Correcting a row is the PM's call, never the loop's.

## The label vocabulary is fixed

The label strings in SKILL.md are the vocabulary itself, not defaults over a per-repo mapping:
[LABELS.md](../setup-engineering-skills/LABELS.md) owns them and
`skills/setup-engineering-skills/scripts/create-labels.sh` installs them, so every repo the loop runs in carries the
same strings and the orchestrator can compose a `gh` command with a literal label in it.

`READY_LABEL` survives in `pick.sh` as a test seam — it lets a probe point the query at a scratch
label without touching a real queue. A repo that sets it in earnest has left the vocabulary the
rest of the plugin assumes, and nothing else will follow it there.

## Running it, and stopping

`/loop drain-ready-queue` self-paced (no interval) is correct: iterations are gated on PM review,
not wall-clock.

Two `STOPPED` tickets with no successful merge between them means the queue is not as
ready-for-agent as it is labelled; the fix is a triage pass, not more dispatches. **"Consecutive"
had to become "with no merge between them" for lanes**, because recaps from two lanes interleave and
a per-lane streak would be a statement about one lane's luck. The ledger is where it is read, and
the reading is already what `runner-gate.sh` does: an effort bounce between two stops neither makes
nor breaks the streak, a merged row between them breaks it, both measured in
`scripts/tests/skill/drain-ready-queue/runner-gate.test.sh`. `bounced`, `stopped` and `died` are the
only outcome words that do
not record a landing, so over this vocabulary the old sentence and the new one pick out the same
pairs — the wording changed to say what was always meant, not to change what fires.

**A death is not a stop, so the two streaks are blind to each other's word.** A `died` row
between two `stopped` rows would otherwise buy a mislabeled queue another iteration, and a `stopped`
row between two `died` rows would do the same for a harness that is killing its workers. Each streak
reads past the other's word and past `bounced`; a `merged-clean` or a `rework` breaks both, because
a success says the run is working (#213).

~4 unreviewed open PRs means the PM's review backlog is
now the bottleneck, and stacked branches start colliding on `main` — a brake that assumes
`pm-merge`, because auto-merged PRs never wait for review. Under an auto policy its replacement
is the check-in bound: after `auto_merge_checkin` auto-merges (default 5) the run pauses and
reports, because an unattended run should drain without the PM but never run away from them. It
counts **across lanes** for the same reason it exists: the bound is on the PM's attention, and three
lanes spend that attention three times as fast.

**Why a live-lock is a stop and not a findings line.** A scheduler whose every slot is waiting
produces output that looks healthy — held candidates, reported one per cycle, exactly as doctrine
requires — while nothing moves at all. Starvation is visible; a *stalled* scheduler reporting
starvation correctly is not, because the report is the same either way. So the condition is read
from the cycle instead of from the queue: candidates existed, nothing was dispatched, nothing
merged. All three, or it is a drained queue or a slow one rather than a stuck one.

**Why brakes never kill a worker.** A running operative holds uncommitted work in a worktree
nothing else can see, and stopping it converts a mislabeled queue into lost work plus a dead-run
investigation. Braking dispatch and merge costs a cycle; braking a worker costs whatever it had
done. So every stop lets in-flight lanes finish and leaves their PRs waiting.

**Why a park stops the run, and why the annotation is still `PARKED:`.** A PR that fell to the PM is
waiting on a person, and a person is not a lane. Two facts were tangled together in the old design:
the ticket is not available, and the machine is. Splitting them let the lane refill while the claim
stood, and a parked PR then held only candidates that declared an overlapping surface. That
declaration is gone (ADR 0007), so the narrow hold has nothing to read and the choice is between no
hold and a run-wide one.

A run-wide one, and I do not think it is close. The park conditions are an update conflict, a
refused pin, a `concerns` verdict and a `fail` verdict, and every one of them says the tree the
lanes are building on is in a state the loop cannot resolve. Dispatching two more operatives into
that is how one park becomes three. The cost is real and worth naming: a three-lane run idles behind
one parked PR, so the PM's response time is now the run's throughput. That is the trade, and the
loop reports the park every cycle so the wait is visible rather than silent.

`check-capacity.sh` still reads a parked claim as occupying no lane, which is what makes the slot
available the moment the PM writes `RELEASED:`. The annotation is `PARKED:` and not `RELEASED:`
because a release would put the ticket back in the pick, which is the one thing parking must not do.

## Cross-reference

- [ORCHESTRATION.md](./ORCHESTRATION.md) — the four rules every loop orchestrator runs on
- [SCHEDULER.md](./SCHEDULER.md) — the slot rule, its two holds, the brakes, the restart recovery
- [STAGE-CONTRACT.md](./STAGE-CONTRACT.md) — the five clauses this stage satisfies
- [CLAIM.md](./CLAIM.md) — what the lane claim asserts, and how it is released
- [VERDICT.md](./VERDICT.md) — what each verdict word asserts
- [LEDGER-REFERENCE.md](./LEDGER-REFERENCE.md) — what each outcome word asserts
