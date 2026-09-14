# The serialized merge pipeline

How a lane's PR lands under an **auto** merge policy: one PR at a time, verified inside the landing
sequence rather than before it, and merged pinned to the commit the verifier examined. This file is
the single home for the five steps; SKILL.md steps 5 and 6 point at it and do not restate it.

**Under `pm-merge` — and under any name the catalog does not carry — none of this runs.** The merge
point there has no loop-side machinery at all ([MERGE-POLICY.md](./MERGE-POLICY.md)): no branch
update, no freshness read, no pinned merge. SKILL.md step 5's verifier dispatch and step 6's PM
hand-off are the whole of it, unchanged. That is not only doctrine — `merge-pinned.sh` asks the
catalog's executor whether the policy name is an auto one and refuses before its first host call
under anything else, so a caller that skipped this paragraph still cannot merge.

## Why the pipeline exists

The verifier used to examine a PR's branch tip and the orchestrator merged some time afterwards.
Between those two moments the branch can move and the base certainly does, so the tree that merged
was not always the tree that was examined — and every artifact still read clean. Under an auto
policy that is a merge no witness ever looked at. Serializing the landing sequence and pinning the
merge to the examined commit closes it: the host itself refuses when the head moved, which is a
guard the loop shares with the server rather than one it keeps to itself.

Because verification happens **inside** the sequence, each ticket is verified once in the common
case. There is no re-verify cascade after a neighbour lands and no freshness bookkeeping between
lanes.

## The order — oldest open loop PR first

One PR at a time. Which PR is next is read off the blackboard, never held: the oldest open loop PR
that has a recap. No state survives a restart, which is what lets a restarted orchestrator resume
the pipeline without knowing what the previous one was doing.

## 1. Update the branch, server-side

```bash
gh pr update-branch <pr> --repo "$(gh repo view --json nameWithOwner -q .nameWithOwner)"
```

The base is merged into the head. **Never `--rebase`** — a rebase rewrites the branch's commits, so
every commit any earlier verdict named stops existing and ancestry reasoning breaks. And never a
`git` command in a worker's worktree: the update happens on the host, where the loop is not racing
an operative that may still be alive.

The command's own exit code does not classify the outcome — step 3's read does, and a branch that
was already up to date reports an error while being perfectly fine.

**A conflicting update parks the PR.** When step 3 answers
`FRESH-REFUSED:… conflicts with its base …`, the base and the head disagree in a way no script
resolves. Report the line and **park the PR** — § *The park conditions* below is the whole list and
says what parking does. Never resolve a conflict on the loop's behalf.

## 2. Wait out the checks, where checks exist

`bash "$SKILL/scripts/pr-checks.sh" <pr>`. The update restarted them, so a pending state here is
expected pipeline behaviour, not step 5's existing "re-run once then hand over" case: wait and read
again until the bucket is terminal.

**The no-CI proceed rule.** `CHECKS-NONE` is a repo with no CI, which for some repos is a standing
decision rather than a gap. Report it **once** and carry straight on to step 3 — never hold the
pipeline on it, and never read it as a failure. Whether a repo without CI may then auto-merge at all
is the policy's question, answered at step 4 by `merge-decision.sh`, not here.

`CHECKS-FAIL` needs no special handling in the pipeline: it reaches step 4 and the decision script
refuses on it.

## 3. Read the head from the host, and brief it

```bash
bash "$SKILL/scripts/merge-freshness.sh" <pr> -
```

`FRESH-OK:<commit>` is the commit the update produced, read from the host's API — the same read that
clears the merge state, so one call answers "did the update land clean?" and "what do I brief?"
together. A local ref cannot answer either question: it is stale exactly when it matters.

Dispatch the verifier briefed to examine **that commit**, per SKILL.md step 5. The verifier confirms
the tree it got is that commit and records it in the block ([VERDICT.md](./VERDICT.md)); a `refused`
verdict means the branch moved underneath it, so read the head again and re-dispatch.

**The `-` is the second argument and it is not decoration:** there is no examined commit yet — this
read is what produces one — so the comparison is skipped and every other refusal still applies. The
examined-commit mismatch is the one park condition that cannot reach this call.

Any `FRESH-REFUSED` here is a findings line, and **the exit code says what happens next**. Exit 2 is
the one reading that means "not yet", a mergeability the host has not finished computing. The PR
re-enters the pipeline once from step 1, spending the single re-entry § *The park conditions* gives
it. Exit 1 is every other refusal: a conflict for the reason above, `BEHIND`, a state that is not
`OPEN`, a host that could not be read at all. Each of those parks on its first firing, because each
is a PR the host will not merge as it stands.

## 4. Decide, then check freshness — both, chained

Use the four-argument merge entry point for a Claude Code lane.

```bash
bash "$SKILL/scripts/merge-decision.sh" <verdict> "<checks-line>" <merge_policy> "<MARKER>" \
  && bash "$SKILL/scripts/merge-freshness.sh" <pr> <commit from step 3> \
  && bash "$SKILL/scripts/merge-pinned.sh" <pr> <commit from step 3> <merge_method> <merge_policy>
```

Use the five-argument entry point only for a Firstmate-dispatched Codex task, with the stable task id chosen at dispatch.

```bash
bash "$SKILL/scripts/merge-decision.sh" <verdict> "<checks-line>" <merge_policy> "<MARKER>" \
  && bash "$SKILL/scripts/merge-freshness.sh" <pr> <commit from step 3> \
  && bash "$SKILL/scripts/merge-pinned.sh" <pr> <commit from step 3> <merge_method> <merge_policy> <task-id>
```

The decision script is unchanged: the verdict word **this** iteration's dispatch returned, the checks
line, the policy name, and the marker the verifier reported. It runs first because it is free and
offline — a PR that was never going to merge costs no host call.

The freshness check then reads the PR's head and merge-state **from the host's API, never from local
refs**, and refuses on anything it cannot establish. A read that fails refuses; it never passes.
**This call passes the examined commit where step 3 passed `-`**, so it makes one comparison step 3
could not: a head that is no longer the commit the verifier examined. Its `FRESH-REFUSED` lines are
read exactly as step 3's. Exit 2 re-enters once, exit 1 parks, and the mismatch is an exit 1
(§ *The park conditions*).

## 5. Merge pinned to the examined commit

`merge-pinned.sh` is the third link of that chain. It carries `--match-head-commit <commit>`, so the
host refuses the merge itself if the head moved after verification. Under `squash` it also carries
`--subject`, the branch's first commit subject plus the PR number — without it gh takes the PR
title, prose no verdict covers (#235). Its three exit codes are the
whole decision:

- **exit 0, `MERGE-PINNED:…`** — it landed. Count it toward `auto_merge_checkin`, then step 7's
  ledger row.
- **exit 2, `MERGE-PIN-REFUSED:…`** — the host refused because the branch moved. **The PR re-enters
  the pipeline once**, from step 1, with a fresh update, a fresh head read and a fresh verifier
  dispatch, where this PR's single re-entry for this run is unspent. A second refusal parks it, and
  so does a first one when an uncomputed mergeability already spent the budget.
- **exit 1, `MERGE-FAILED:…`** — anything else, including an outcome the host could not be re-read
  to explain. Park it. Never retry, never merge by hand, never `--admin`.

**A pin refused twice parks the PR.** One re-entry is a race that lost; two is something
systematically pushing to that branch, and the loop is not the actor to work out what.

The refusal is classified by re-reading the host, not by matching a message: a failed merge fits a
moved head, branch protection and a fresh conflict at once, and only the host can say which. That
is also why an unreadable outcome parks instead of re-entering — a re-entry is for a cause that was
measured.

## The park conditions

**This section is the single home for the list. Nowhere else states a count** — a number restated
in another file is one that goes stale the next time a script grows an exit path, silently, because
both copies still read fine.

Read off the three scripts' own findings-line enumerations, the pipeline parks a PR in **seven**
places:

| # | What fires | Where | Script line |
|---|---|---|---|
| 1 | a conflicting update | steps 3 and 4 — both freshness reads | `FRESH-REFUSED:… conflicts with its base …` |
| 2 | a mergeability the host has not finished computing, one re-entry then park | steps 3 and 4 | `FRESH-REFUSED:… mergeability is still UNKNOWN after <n> read(s) …` (exit 2), once the budget is spent |
| 3 | any other refusal the freshness read cannot clear — `BEHIND`, a state that is not `OPEN`, a host that could not be read | steps 3 and 4 | every `FRESH-REFUSED:` but the three named in this table (exit 1) |
| 4 | the merge decision refusing — a `concerns`, `fail` or `refused` verdict, no verdict, a superseded marker, `CHECKS-FAIL`, a policy the catalog does not carry | step 4, first link of the chain | `MERGE-REFUSED:` (exit 1) |
| 5 | the head no longer being the commit the verifier examined | step 4 only, second link | `FRESH-REFUSED:PR #<pr> head is <head>, not the examined <examined>` (exit 1) |
| 6 | a pin refused twice, one re-entry then park | step 5 | `MERGE-PIN-REFUSED:` (exit 2), once the budget is spent |
| 7 | anything else, including an outcome the host could not be re-read to explain | step 5 | `MERGE-FAILED:` (exit 1) |

**The examined-commit mismatch is the one that cannot fire at step 3, and the reason is the
argument.** `merge-freshness.sh` runs twice with one contract: step 3 passes `-` and step 4 passes
the examined commit. Measured at `merge-freshness.sh:128`, the comparison is gated on that argument
(`[ "$examined" != "-" ] && [ "$head" != "$examined" ]`), and `-` skips **that check and nothing
else** — which is why the conflict and the other freshness refusals fire at both calls and this one
only at the second.

**Re-entry is for a cause that was measured, and a PR gets one per pipeline run.** Two rows re-enter
instead of parking on their first firing. Row 2 is a mergeability the host has not finished
computing, and row 6 is a pin the host refused. **They share one budget**, a single re-entry per PR
per run, whichever of them spends it. So a PR that re-enters for an uncomputed mergeability and then
meets a pin refusal parks. It never cycles twice. The budget lives in the run and not on disk, so a
restarted orchestrator hands the PR a fresh one, the same way it reads everything else back off the
blackboard.

**Both are decided by an exit code, never by a message.** `merge-freshness.sh` exits 2 for the
uncomputed mergeability and `merge-pinned.sh` exits 2 for the refused pin. Every other refusal from
either script is exit 1. A step that matched prose would decide on a string the host is free to
reword.

Every other row parks on its first firing, the examined-commit mismatch (row 5) included. A detection
that earns a re-entry later joins this budget rather than getting one of its own.

**A re-entry keeps the claim.** The PR goes back to step 1. Nothing annotates the ticket's claim,
nothing writes a ledger row, and nothing releases it ([CLAIM.md](./CLAIM.md)). A released claim would
let the next pick dispatch the same ticket and open a second PR for it. The re-entry takes the person
out of the loop, not the claim.

## What parking does

A parked PR is a findings line **every cycle until the PM resolves it**. Parking means: annotate the
ticket's claim with a `PARKED: <why>` line ([CLAIM.md](./CLAIM.md)), leave the ticket out of the
pick, which that annotation does *not* change because a park is not a release, and leave the PR
open. No ledger row is written: the row is the release, and the dispatch is not over. Parking never
kills a running worker and never deletes a branch.

**Above 1 lane, no lane fills while a PR is parked.** `claim-status.sh` answers `CLAIM-PARKED`, and
`check-holds.sh` holds every candidate on that word, whatever files the candidate would touch.
So a park stops new dispatch across the whole run, and only the PM's `RELEASED:` line lifts it.
In-flight lanes are untouched and finish their work.

**At 1 lane the stop does not fire, and that is not an oversight.** SKILL.md step 3 runs
`check-holds.sh` only above 1 lane, so a serial drain parks its PR, frees its one slot through
`check-capacity.sh`, and takes the next candidate. That is the behaviour a serial drain has always
had, and the hold this replaces never ran there either. The rule is a parallelism rule, like every
other rule [SCHEDULER.md](./SCHEDULER.md) states.

The stop replaces a narrower hold. A parked PR's measured files used to serialize dispatch against
candidates that declared an overlapping surface, and that declaration is gone (ADR 0007). Holding
everything is the conservative reading of the same intent: a PR the PM has not finished with is a
tree nobody should be building on. It is also blunt, and the honest cost is that one parked PR idles
a three-lane run. That is deliberate. A park means a person has to look, and dispatching more work
into the meantime is how a parked PR becomes three of them.

`check-capacity.sh` reads a parked claim as occupying no lane at every lane count, so the slot itself
returns to the count and is available the moment the park clears.
[SCHEDULER.md](./SCHEDULER.md) holds the slot rule those two answers combine into.

## The orchestrator sequences its own writes to `main`

The loop writes to `main` itself: step 7's ledger commit and its pull-before-push. Every one of
those writes moves the base and can leave an open PR `BEHIND`, which is the state this pipeline
refuses on.

**So the orchestrator's own `main` writes happen between pipeline runs, never during one.** Finish
the PR in flight — merged, or parked — before appending its row, and append the row before the next
PR enters at step 1. `ledger-append.sh --commit --push` already syncs when the iteration's own merge
moved the remote (RATIONALE § 7); this rule is the other half, and it is what stops the loop's own
bookkeeping from invalidating the merge it is bookkeeping about.

## The host's own guard, where the host has one

Where the code host supports **requiring branches to be up to date before merging**, enable it on the
base branch. The server then enforces independently what step 4 checks, so a merge that slipped past
the pipeline still cannot land a stale tree. The setup skill says to turn it on when a repo picks an
auto policy; it is a belt to the pipeline's braces, never a replacement for either.

## Cross-reference

- [SKILL.md](./SKILL.md) — step 5 runs pipeline steps 1–3, step 6 runs steps 4–5
- [MERGE-POLICY.md](./MERGE-POLICY.md) — the catalog; which policies are auto policies
- [VERDICT.md](./VERDICT.md) — why a verdict is a claim about an identified commit
- [CLAIM.md](./CLAIM.md) — the claim a park annotates, and the two release paths
- [RATIONALE.md](./RATIONALE.md) — §§ 5 and 6, why the witnesses and the merge are shaped this way
