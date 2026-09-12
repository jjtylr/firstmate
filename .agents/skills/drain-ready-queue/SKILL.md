---
name: drain-ready-queue
metadata:
  internal: true
description: Drain the ready-for-agent backlog — one fresh subagent per ticket implements and opens a PR, a verifier and CI witness it, and the repo's merge_policy decides who merges. Never deploys.
disable-model-invocation: true
---

# Drain the ready-for-agent queue

**Where the paths below point.** A `../<skill>/FILE.md` path resolves against **this file**: both
install shapes — the Claude Code plugin's `skills/` and the `npx skills` vendored
`.agents/skills/` — put every skill directory side by side. If a named sibling skill is not
installed its files are simply absent: say which one you could not read and take the stated
fallback, never recite it from memory.

Claude Code uses `toolkit:operative` and `toolkit:verifier`. Codex installs bare roles, but its
operative uses [CODEX-OPERATIVE.md](./CODEX-OPERATIVE.md). Portable rails live in `agent-roles/`.

**Read before step 1:** `docs/agents/loop.md` for this repo's `gates`, `effort_threshold`,
`merge_policy` (with `merge_method` and `auto_merge_checkin` beside it), `global_locks`,
`workspace_setup` and `brief_addendum` (no file → `/setup-engineering-skills`
Section D first), and [ORCHESTRATION.md](./ORCHESTRATION.md) for the four rules every loop
orchestrator runs on. The label strings below are the vocabulary itself, not defaults over a
per-repo mapping (RATIONALE § *The label vocabulary is fixed*).
Every script in `scripts/` exits 0 on a finding: findings lines are report material, not errors, and
you relay every one to the PM, every cycle it appears. (Two kinds of script are the exception, and
neither is a cycle step below: the chain-guards `validate-verdict.sh` and `merge-decision.sh`, whose
non-zero exit stops the command chained behind them, and the `run-issue-*.sh` family together with
`runner.sh`, whose non-zero exit *is* the headless runner's interlock.) **The *why* behind every step
is [RATIONALE.md](./RATIONALE.md) (`$SKILL/RATIONALE.md`), numbered to match — read it when a step is
in question, never to run the loop.**

## Before the cycle — once per run, in order

### 0a. Ask whether a headless run is already live — `bash "$SKILL/scripts/runner.sh" lock-status`

`RUNNER-LOCK-HELD` (exit 1) means **another** runner holds this repo's lock: **stop and tell the
PM**, because two orchestrators draining one repo double-dispatch a ticket, and the lock is the only
thing that sees the other one. `RUNNER-LOCK-SELF` (exit 0) is your own run's lock, and it is what
every headless session sees, because the runner claims the lock before it starts the first session.
Report it, then run the loop. The script compares pids, so the exit code is the whole answer and you
never decide whose lock it is. `RUNNER-LOCK-FREE` is the clean answer; `RUNNER-LOCK-STALE` is a
runner that died holding it — report it, then run the loop.

### 0b. Resolve who merges — the config's `merge_policy` against [MERGE-POLICY.md](./MERGE-POLICY.md)

Under `pm-merge` this loop **never merges** — the PM does —
and under an auto policy step 6 merges only through the decision script. **The fail-safe:** a
missing name, or one the catalog does not carry, reads as `pm-merge` and is a findings line — a
config typo degrades to "the PM merges", never to silent auto-merging. Under every policy the loop
**never deploys**: a ticket whose *implementation* is a production operation is out of scope, so
flag it. It provisions no workspaces but reaps each subagent's worktree under
`<repo>/.claude/worktrees/` (RATIONALE § 0).

### 0c. Read the lane count — `lanes=$(bash "$SKILL/scripts/resolve-lanes.sh")`

It prints 1, 2 or
3, and 1 for every reading it cannot use, with a `LANES-FALLBACK` line on stderr you relay. **At 1
the cycle below is one ticket at a time, exactly as it has always been.** Above 1 the cycle fills
each free slot by the slot rule, and [SCHEDULER.md](./SCHEDULER.md) (`$SKILL/SCHEDULER.md`) owns
that rule, the brakes, the restart recovery and the findings contract. Read it once, before your
first dispatch of a run, whenever the count is above 1.

## The cycle — run it from the repo root; one pass fills every free lane, one ticket each

### 1. Reap what merged while the PM was reviewing — `bash "$SKILL/scripts/reap.sh"`

Teardown sits at the **top** of the iteration (RATIONALE § 1). The reap acts only on **owned**
worktrees — the ones the harness's own lock or `agent-*` directory proves it made — and it measures
liveness itself, so no cycle spends a judgment step on it (RATIONALE §§ 0, 4). Merged PRs' worktrees
and branches go silently and `OPEN` PRs are left alone; everything else is a `REAP-*` finding.
`reap.sh`'s header is the contract for every line, and the standing rule covers them: relay each
one, touch nothing. Three need more than the relay:

- `REAP-NONE` — the sweep root `<main checkout>/.claude/worktrees/` does not exist. On a repo that
  has never dispatched, that is the plain truth. On one that has, it says the reap looked in the
  wrong place: check the path the line names against `git worktree list`, and if a harness
  worktree sits outside it, stop and report before you dispatch, because nothing is measuring
  liveness in there.
- `REAP-HELD-LIVE` — the hosting session's pid is alive. Hands off, whatever the PR says. On a
  worktree with **no PR** whose ticket carries a fresh open claim, this is the expected in-flight
  state — the pre-push window of a dispatch you claimed at step 4. Read it as in flight, never as a
  run to investigate.
- `REAP-HELD-DEAD` — no PR and the pid is gone: **established dead**. The dead reading is this
  line's alone. The line names the branch, whose numeric suffix is the ticket, and **the cycle
  clears that dead lane itself**, attended exactly as headless, at every lane count. Move the
  ticket out of the queue, write its row, take the mirror down:

  ```bash
  gh issue edit <N> --remove-label ready-for-agent --add-label needs-info
  bash "$SKILL/scripts/ledger-append.sh" --commit --push <N> - died - - <today> <lanes>
  gh issue edit <N> --remove-label claimed
  ```

  Then leave the worktree and the branch standing and report the finding: they are the only record
  the run happened, and salvage or discard is the PM's (RATIONALE § 4). Never re-dispatch a dead
  ticket silently.

  **The relabel comes first because the row is the release.** Written first, the row would release
  the claim on a ticket still carrying `ready-for-agent` and invite exactly that silent
  re-dispatch. Relabelled first, the released claim can qualify nothing, because the label the pick
  selects on is already gone ([CLAIM.md](./CLAIM.md)).

### 2. Pick the next ticket — `bash "$SKILL/scripts/pick.sh"`

To drain one slice of a large tracker, set `MILESTONE=<title>` — the queue narrows to that
milestone's tickets (ADR 0003). Blocking edges and global locks stay global; report a run scoped
this way as scoped, so an empty array reads as "this milestone is drained", not "the queue is".

Take the **first** entry of the JSON array — ratio descending (the score block `triage-and-score`
posts), ties on lower PM cost, then lowest number; unscored sort last (`ratio: -1`); `needs-info`,
`ready-for-human`, `spec` and `wayfinder:*` are silently excluded; empty array → stop the loop, the
queue is drained. A candidate with an open blocking edge (`blocked_by`) is held out of the array,
never dropped quietly, and reported on **stderr** as `PICK-BLOCKED` lines, lowest first — relay
them, act on none of them. An `updated` that post-dates
`scored_on` — or a `null` `scored_on` on a scored ticket — is a **stale score**: note it in your
report and dispatch anyway, since it warns the PM rather than gating. (RATIONALE § 2 for the *why*.)

- `PICK-CLAIMED: #<n> "<title>" …` — an open lane claim holds it: a dispatch for it is in flight, or
  a claim needs releasing. Relay it every cycle it appears, and never dispatch past it. A claim the
  cycle could not read holds its ticket too, and says so in the same line.
- `PICK-UNKNOWN` (exit 1) — the listing failed, so there is no queue: report it, never stop on it.

**A ledger row releases a claim; the PM's `RELEASED:` annotation is the only other way**
([CLAIM.md](./CLAIM.md)). To ask about one ticket on its own:
`bash "$SKILL/scripts/claim-status.sh" <N>` — `CLAIM-OPEN`, `CLAIM-PARKED`, `CLAIM-RELEASED`,
`CLAIM-NONE`, or `CLAIM-UNKNOWN` (exit 1), which holds the ticket, because an unread claim is never
a free one. `CLAIM-PARKED` is unreleased like `CLAIM-OPEN` and named apart so that every reader
decides parkedness on the word and never on the prose after it. The annotation is for a **parked**
claim alone, the one no row is coming for. A dead worker's claim is released by the `died` row
step 1 wrote for it, in the cycle that found it.

**The effort bounce — `e` above `effort_threshold` never dispatches** (an unscored `e: null` is
**not** bounced). Bounce it, note it, take the next candidate:

```bash
gh issue edit <N> --remove-label ready-for-agent --add-label needs-info
gh issue comment <N> --body "> *This was generated by AI during the drain loop.*

Bounced from the drain queue without dispatching: scored AGENT-EFFORT <e>, and this repo
dispatches E <= <effort_threshold>. Needs a PM split into independently-shippable tickets."
```

### 3. Hold if a global lock is occupied — `bash "$SKILL/scripts/check-lock.sh" "<prefix>" ...`

One call, every entry in the config's `global_locks` as arguments (RATIONALE § 3); the script
answers one line per prefix. `CHECK-LOCK-HELD` **and** the candidate declares the lock — step 2's
`locks` field, resolved per
[TICKET-BRIEF.md](../triage/TICKET-BRIEF.md), not re-read by eye from the
body — or plausibly hits it → skip to the next candidate and note the hold. Cannot tell → dispatch.
`CHECK-LOCK-UNKNOWN` (exit 1) — the PR list could not be read, and an unread lock is never a free
one: report it, and this cycle treat a candidate that declares or plausibly hits any global lock as
held.

**When the lane count is more than 1**, this step also runs
`bash "$SKILL/scripts/check-holds.sh" <N> "<step 2's locks>"` — the whole question of whether
the candidate may take a lane beside the open claims and open loop PRs already in flight. Two things
hold it and no others (ADR 0007): a global lock another lane already holds, and any parked PR
waiting on the PM. File overlap does not, because the merge pipeline resolves that at landing.
`COLLISION-CLEAR` (exit 0) dispatches; anything else (exit 1) skips to the next candidate and is
reported. `COLLISION-UNRESOLVED` lines come out first and are relayed whatever the verdict: they
name a declared lock no row of the `global_locks` table carries, which is a config defect the PM
fixes, not a hold to wait out. Under more than one lane a `COLLISION-UNKNOWN` holds — a listing that
could not be read is a hold, never a clear.

**When no candidate clears, the slot waits.** An empty slot is the right answer to a queue whose
head is held, and filling it anyway is what the check exists to stop (SCHEDULER.md).

### 4. Claim the ticket, then dispatch ONE subagent into the slot

**The claim goes up before the spawn, or the dispatch exists only in your head.** Write the claim,
let the script refuse a malformed one, post it, then mirror it for human eyes:

```bash
scratch="$(mktemp -d)"   # ORCHESTRATION.md § 4 — this block is one command, so the variable holds
cat > "$scratch/claim-<N>.txt" <<'EOF'
> *This was generated by AI during the drain loop.*

<!-- lane-claim v1 -->
TICKET: #<N>
BRANCH: agent/<SLUG>-<N>
LOCKS: <step 2's locks, or - when it resolved null>
DISPATCHED-ON: <today, ISO>
EOF
bash "$SKILL/scripts/check-capacity.sh" \
  && bash "$SKILL/scripts/validate-claim.sh" <N> "$scratch" \
  && gh issue comment <N> --body-file "$scratch/claim-<N>.txt" \
  && gh issue edit <N> --add-label claimed
```

`CAPACITY-FREE` (exit 0) opens the chain; `CAPACITY-FULL` or `CAPACITY-UNKNOWN` (exit 1) stops it
with nothing posted — the lane count in force is enforced here, not honoured by hand, and a parked
claim holds no slot. Then `OK …` posts it; `INVALID …` (exit 1) stops the chain too — fix the file. The
snapshot is step 2's resolved `locks` **as step 3 cleared them**, never a re-read of
the body. **An amendment posted after this moment describes the next dispatch, not this one.**
The `claimed` label is display-only. [CLAIM.md](./CLAIM.md) (`$SKILL/CLAIM.md`) owns what the block
asserts, both release paths, and why the label decides nothing; read it before you change the shape
of a claim.

Read [DISPATCH-BRIEF.md](./DISPATCH-BRIEF.md) fresh each dispatch and produce a file from it
**verbatim after substitution**: `<N>`, `<TITLE>`, `<SLUG>`, step 2's `area` when non-null, the
config's `gates` with their triggers, `<workspace_setup>` if non-empty, and `brief_addendum`
appended verbatim. Write it inside a new `mktemp -d` directory. The `area` line is passed through,
not acted on. Where the repo has `docs/atlas/`, the atlas touch rides the operative's PR: same
diff, gates and merge. **This loop never writes to `docs/atlas/` itself** (RATIONALE § 4).

**Claude Code:** spawn `toolkit:operative` with **`isolation: worktree`** and send only that file.
If unresolved, spawn a generic worktree-isolated subagent with [the operative role](./agent-roles/operative.md)
ahead of it. No isolation or readable role means stop. Never dispatch into the parent checkout.

**Codex:** Firstmate owns Codex dispatch. Create and record the task brief with Firstmate's
`bin/fm-brief.sh`, then invoke `bin/fm-spawn.sh` with explicit mode, yolo posture, and `--harness
codex`. The adapted `run-codex-operative.sh` accepts the legacy arguments only to verify the
recorded brief and delegates through that Firstmate owner; it never launches Codex directly.
Never use `spawn_agent` or bypass Firstmate dispatch after a refusal.

**One ticket takes one slot, and a slot is free only until it is filled.** A second ticket starts
only when the lane count leaves a slot free and step 3 cleared it against everything in flight
(SCHEDULER.md's slot rule).

**If a subagent dies mid-ticket**, never silently re-dispatch — RATIONALE § 4 has the procedure.

### 5. Verify closure, then a verdict — `bash "$SKILL/scripts/ensure-closes.sh" <pr> <N>`

Never trust the brief — read the PR back. `CLOSES-OK` or `CLOSES-ADDED`; anything else is a finding.
If the recap's `FOLDED` line names an issue the PR also fully resolves, append that number to the
same call — one closing keyword per issue. Then a verdict, then CI, then hand all three over.

**Hold the PR against its ticket's `Locks:` line, once, at every lane count** —
`bash "$SKILL/scripts/check-declared-locks.sh" <N> <pr>`. `LOCKS-MATCH` (exit 0) needs no relay;
every other line is a **finding, not a hold**: relay it verbatim, let the PR carry on, leave the
mis-declaration to the PM (RATIONALE § 3).

**Under an auto policy the PR enters the serialized merge pipeline here** — one PR at a time, oldest
open loop PR first, all five steps owned by [MERGE-PIPELINE.md](./MERGE-PIPELINE.md). Run its steps
1–3 from that file now, not from memory. What the cycle carries out of them: `FRESH-OK:<commit>` is
the commit the verifier examines — step 6 needs it as **the examined commit** — and a
`FRESH-REFUSED` is read by its **exit code**, never by its message. Exit 2 is a mergeability the host
has not finished computing, and the PR re-enters the pipeline once from step 1, spending the single
re-entry it gets this run. Exit 1 **parks** the PR (§ *The park conditions*, § *What parking does*). **Under
`pm-merge` none of that runs**; read the head with
`gh pr view <pr> --json headRefOid -q .headRefOid` and carry on. Either way a verdict is a claim
about an identified tree ([VERDICT.md](./VERDICT.md)), so the verifier is sent a commit, not a
branch.

**Dispatch an independent verifier: a self-report is not evidence.** Claude Code uses
`toolkit:verifier`; Codex uses `verifier`. It checks the ticket, re-runs the gates, and posts one
marked `verifier-verdict` block. Dispatch per
ORCHESTRATION.md § 2 with **no worktree isolation** (RATIONALE § 5), sending the ticket `#<N>`, the
PR `#<pr>`, the branch, **that commit**, this repo's `gates` with their triggers,
`brief_addendum` verbatim, and the recap, nothing else. Every rail is in
[the verifier role](./agent-roles/verifier.md). If the client role does not resolve, dispatch a
fresh generic subagent with that role text ahead of the brief. Cannot dispatch at all means the PR
is **unverified**. Lean on CI and never present a missing verdict as a pass. Under `pm-merge` the
verdict is **advisory**; under an auto policy it is step 6's merge input. Either way, the word you
carry to step 6 and to step 7's row is the one **this dispatch returned to you**. A verdict block
re-read from PR comments asserts nothing: a quoted or forged block is indistinguishable from a
posted one, so a restarted run re-verifies before it merges anything. Carry
its `MARKER` line too: step 6 needs it. A `refused` verdict means the branch moved under the
verifier — read the head again and re-dispatch; never treat it as a soft pass.
[VERDICT.md](./VERDICT.md) (`$SKILL/VERDICT.md`) owns what `pass` / `concerns` / `fail` / `refused`
assert.

Then CI, the secondary witness: `bash "$SKILL/scripts/pr-checks.sh" <pr>`. `CHECKS-PASS`
corroborates; say nothing. Anything else is a findings line delivered *beside* the recap:

- `CHECKS-NONE` — no CI configured. Report once; never as a gate failure.
- `CHECKS-FAIL` — CI contradicts the recap: report both side by side, the PM decides, never re-run.
- `CHECKS-PENDING` — re-run once, then hand over saying so.  `CHECKS-UNKNOWN` — relay as-is.

Then relay the recap **verbatim** with the verdict beside it — summarize neither, add nothing.

**Attended, that relay goes to the PM. Headless — your brief names a run issue —
[HEADLESS.md](./HEADLESS.md) (`$SKILL/HEADLESS.md`) owns the branch:** the report posts to the run
issue, and step 6's STOPPED relabel is yours to run, not to hand over.

### 6. The merge step — what `merge_policy` says, nothing else

**Under `pm-merge`** — and under any name the catalog does not carry — the PM decides:

- **Merge** → nothing to do; the next iteration's reap (step 1) collects the worktree and branches.
- **More fixes** → **`SendMessage` to that same agent** with the PM's notes (RATIONALE § 6).
- **STOPPED recap** → move the ticket out of the queue, then collect the branch the no-PR run left:

  ```bash
  gh issue edit <N> --remove-label ready-for-agent --add-label needs-info
  bash "$SKILL/scripts/cleanup-stopped.sh" agent/<SLUG>-<N>
  ```

  Silent when nothing is there. `REAP-HELD` — the run edited files.  `REAP-ORPHAN` — unique commits.

**Under an auto policy** (the catalog's `auto-on-verdict*` entries) the decision script holds the
merge button ([MERGE-POLICY.md](./MERGE-POLICY.md)), and what runs here is pipeline steps 4 and 5 —
run them from [MERGE-PIPELINE.md](./MERGE-PIPELINE.md), which owns the chain, its exit codes and
the park conditions. The toolkit never invokes a forge merge command directly; carry the Firstmate
merge owner's verified result into this cycle. Carry in what this cycle established: the verdict word your own step-5 dispatch returned, the `pr-checks.sh` line, the
config's `merge_policy` and `merge_method`, the verdict block's `MARKER` line, and the examined
commit. A missing or superseded marker reads as **no verdict** and the decision script refuses:
re-verify such a PR, never re-label it by hand.

- `MERGE-PINNED:` (exit 0) → merged. Count it toward the `auto_merge_checkin` bound and name the
  policy and the reason in your report, so the PM can audit the run afterwards.
- Every other line → the pipeline's § 5 and § *The park conditions* decide: a first
  `MERGE-PIN-REFUSED` re-enters the pipeline once where this PR's re-entry for this run is unspent,
  and everything else **parks** to the PM path above. A STOPPED recap is handled the same under both
  policies.

**Parking keeps the ticket.** Annotate the claim with a `PARKED: <why>` line. `claim-status.sh`
answers `CLAIM-PARKED`, so the pick still skips the ticket. **Above 1 lane the park also stops new
dispatch**: step 3's `check-holds.sh` holds every candidate on that word until the PM writes
`RELEASED:`, so let the in-flight lanes finish and fill no new one. At 1 lane step 3 runs no such
check, so take the next candidate into the freed slot. Write **no** ledger row: the row is the
release, and the dispatch is not over. A findings line every cycle until the PM resolves it.
([SCHEDULER.md](./SCHEDULER.md), [MERGE-PIPELINE.md](./MERGE-PIPELINE.md) § *The park conditions*
for what fires.)

### 7. Record the outcome, then loop

One row per ticket that left the queue, dispatched or bounced, written **before** looping
(RATIONALE § 7): `bash "$SKILL/scripts/ledger-append.sh" --commit --push <N> <pr|-> <outcome> [verdict|-]
[tokens|-] [date|-] [lanes|-]` — the issue; the PR (`-` if none was opened); the outcome; step 5's
verdict word (`-` if no verifier ran); the harness's reported tokens (`-` if none); the date, which
defaults to today; and the **lane count in force at this ticket's dispatch** — what
`resolve-lanes.sh` printed, so `1` on a serial drain, and a value outside `{1, 2, 3}` is refused
([LEDGER-REFERENCE.md](./LEDGER-REFERENCE.md) for what the cell is for). The
ledger `docs/agents/ledger.md` is created on first append with the version marker the script
owns, and
`<outcome>` is the one judgment — `merged-clean` | `rework` | `reverted` | `bounced` | `stopped` |
`died`, with [LEDGER-REFERENCE.md](./LEDGER-REFERENCE.md) (`$SKILL/LEDGER-REFERENCE.md`) saying what
each asserts; read it first. The three no-PR words are the ones to get right: a STOPPED recap is
`stopped`; a dispatch whose pid step 1 measured gone is `died`; `bounced` is the effort bounce
alone — nothing was tried.

`LEDGER-APPENDED` is the row written. `ledger-append.sh`'s header is the contract for every other
line, and the standing rule covers them: relay each one, touch nothing. These carry an action
beyond the relay:

- `LEDGER-COMMITTED` — the row is committed. **Read the branch it names**: a row on an agent branch
  is not on the blackboard.
- `LEDGER-PUSH-FAILED` — the row never left your checkout, so the next iteration's gate reads a
  ledger that is short a row. **Never force the push and never resolve a conflict by hand
  mid-iteration** — a row is the PM's to correct.
- `LEDGER-MIGRATION-BLOCKED` (exit 1) — rows under the old marker need reclassifying: a PM
  correction, so leave the file alone.
- `LEDGER-REFUSED` (exit 1) — a field was malformed. Fix the call.

**The row is the release** — all six outcomes, since all of them mean the dispatch is over, and
step 2 reads it that way with no PM action ([CLAIM.md](./CLAIM.md)). Take the mirror down after an
appended row: `gh issue edit <N> --remove-label claimed`. The label is display-only, so a failure
there is a findings line, never a reason to re-run the append.

`--commit` commits the ledger path and nothing else; `--push` then sends it to the branch's
upstream, syncing first when the iteration's own merge has moved the remote under you — which is
the normal case, not the rare one (RATIONALE § 7). Run no git command of your own here: both flags
are one call, and the script reports what it could not do.

**This write moves `main`, so it is sequenced against the pipeline** — finish the PR in flight,
merged or parked, before appending its row, and append the row before the next PR enters at pipeline
step 1. A ledger commit landing mid-pipeline leaves the open PR `BEHIND`, which the freshness check
refuses on ([MERGE-PIPELINE.md](./MERGE-PIPELINE.md)).

At the **end of a run**, not every iteration, check the ledger against what `gh` and `git` prove:
`bash "$SKILL/scripts/ledger-corroborate.sh"`. One `LEDGER-ROW` per merged loop PR, then findings —
relay them, since correcting a row is the PM's call:

- `LEDGER-MISSING` — a merged loop PR with no row.  `LEDGER-ABSENT` — no ledger yet.
- `LEDGER-MISMATCH` — a row a revert or a follow-up contradicts.
- `LEDGER-UNKNOWN` (exit 1) — corroboration could not run at all. Never read that as a pass.

## Running it, and stopping

Once the row is written, loop back to step 1. Run the whole thing as `/loop drain-ready-queue`,
self-paced — no interval (RATIONALE § *Running it*); a one-shot works too. **Every stop below gates
dispatch and merge only: in-flight lanes finish and their PRs wait.** Stop and say why:

- the queue is empty — nothing dispatchable in the run's scope;
- **two `STOPPED` recaps with no successful merge between them.** Across all lanes, read off the
  ledger rows this run wrote, not per lane — recaps interleave;
- **a full cycle with candidates present, nothing dispatched and nothing merged** — a live-locked
  scheduler, and the check-in is the PM's chance to clear whatever every slot is waiting on;
- the review brake for the policy in force: under `pm-merge`, unreviewed PRs at ~4; under an auto
  policy, auto-merged PRs since the last PM check-in at the config's `auto_merge_checkin` bound
  (**default 5**), **counted across every lane** — the bound is on the PM's attention, not on one
  lane's throughput.

**The run report carries the stale-merge refusal count** — how many times `merge-freshness.sh`
refused or `merge-pinned.sh` reported `MERGE-PIN-REFUSED`. That counter is the direct measurement of
the failure class the merge pipeline exists to stop, so it is reported even when it is zero; a zero
that was measured says something a silence does not. Report the lane count in force beside it.

## Cross-reference

- [RATIONALE.md](./RATIONALE.md) — why each step is shaped as it is; read once, not per run
- [STAGE-CONTRACT.md](./STAGE-CONTRACT.md) — the five clauses every stage satisfies; read it before
  building a new stage, not before a run
- [ORCHESTRATION.md](./ORCHESTRATION.md), [CLAIM.md](./CLAIM.md), [VERDICT.md](./VERDICT.md), [LEDGER-REFERENCE.md](./LEDGER-REFERENCE.md) —
  the orchestrator's four rules, the lane claim, the verdict block, the outcome row; each linked
  from its step
- [MERGE-POLICY.md](./MERGE-POLICY.md) — the merge-policy catalog: the closed vocabulary
  `merge_policy` names resolve against, one entry per policy, executed at step 6
- [MERGE-PIPELINE.md](./MERGE-PIPELINE.md) — the serialized landing sequence an auto policy runs
  across steps 5 and 6: five steps, the pinned merge, and the park conditions it owns the list of
- [SCHEDULER.md](./SCHEDULER.md) — the slot rule above 1 lane and its two holds, the brakes, the
  restart recovery, and the findings contract at queue depth
- `docs/agents/` — this repo's corner: `loop.md` parameters, `ledger.md` outcomes, `issue-tracker.md`
  conventions and blocking-edge mechanics; the label vocabulary is the plugin's, in
  [LABELS.md](../setup-engineering-skills/LABELS.md); `triage-and-score` fills the
  queue this loop consumes
