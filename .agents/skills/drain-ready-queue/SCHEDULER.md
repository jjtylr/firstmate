# The lane scheduler and its brakes

How the drain fills more than one lane at once, what stops it, and what it says while it does.
This file is the single home for the slot rule, the brakes, the restart recovery and the findings
contract; SKILL.md's steps point at it and do not restate it.

**A lane is a capacity slot, not a stream.** It is not bound to a milestone, a chain, or a set of
files. `resolve-lanes.sh` prints how many there are. The answer is 1, 2 or 3, and it is 1 under
anything the script cannot use, including any value above 1 under a policy that is not an auto one.
**At 1 lane every rule below is inert**: the cycle runs exactly as it always has, one ticket at a
time, and nothing here changes that.

## The slot rule

Each free slot takes the **highest-ranked dispatchable candidate**. Rank is `pick.sh`'s order,
unchanged. `check-holds.sh` holds a candidate back, and it has exactly two holds (ADR 0007):

- **A global lock another lane already holds.** Read against every **open lane claim** and every
  **open loop PR** together, because the two cover different windows and one without the other
  leaves a hole exactly as long as a worker's first edit.
- **Any parked PR waiting on the PM.** While one claim carries a `PARKED:` line, no lane fills at
  all, whatever the candidate would touch. Like every rule in this file it is inert at 1 lane, where
  SKILL.md step 3 does not run the check: a serial drain parks its PR and takes the next candidate.
  [MERGE-PIPELINE.md](./MERGE-PIPELINE.md) § *What parking does* is the home for that rule.

**What files a candidate touches is not a hold.** Two tickets may run together whatever they edit.
The serialized merge pipeline resolves the overlap at landing, where the file lists exist, and at
dispatch they do not: a claim is posted minutes before its worker's first push.

- A **held** candidate is skipped to the next candidate and reported. It is never bounced,
  never relabelled, and never reordered: the hold is a fact about this cycle.
- When **no** candidate qualifies, the slot **waits**. An empty slot is the correct answer to a
  queue whose whole head is held; filling it anyway is the failure this scheduler exists to
  prevent.
- **The unknown case holds where it answers a lock.** A listing that failed, a claim that could not
  be read, a window that came back at its row limit: each holds, never clears.
  An unread lock is never a free one, the same reading `check-lock.sh` and `check-capacity.sh`
  take. The serial-era rule "cannot tell → dispatch" was justified by implementation being serial,
  and that justification is the thing parallelism removes.

**Serial chains stay serial through their blocking edges alone.** `blocked_by` already holds a
chain in order through any number of lanes, so no lane is ever assigned to a chain and no chain is
ever assigned to a lane. A depth-5 chain in a 3-lane run drains one ticket at a time and leaves the
other two slots for whatever else the queue holds.

## The brakes

**Brakes gate dispatch and merge. They never kill a running worker.** A braked run lets every
in-flight lane finish and leaves its PR waiting; there is no path here that interrupts a subagent.

**Two STOPPED recaps with no successful merge between them halt new dispatches everywhere.** Not
"two in a row on one lane" — recaps interleave across lanes, so the streak is read off the ledger
rows the run wrote. `runner-gate.sh` already reads it exactly this way: an effort bounce between two
stops neither makes nor breaks the streak, and a merged row between them breaks it (both measured,
`scripts/tests/skill/drain-ready-queue/runner-gate.test.sh`). The remaining outcome words — `rework`, `reverted` — each
record a landing too, so "no successful merge between them" and "the last two dispatched rows both
read `stopped`" are the same statement over this vocabulary. In-flight lanes finish; the queue is
mislabeled and the fix is a triage pass, not more dispatches.

**A live-locked scheduler announces itself.** A full cycle in which candidates existed but nothing
was dispatched and nothing merged **stops the run for a PM check-in**. All three conditions
together: candidates present, zero dispatches, zero merges. A cycle that dispatched nothing because
the queue was empty is a drained queue, not a live-lock, and a cycle that merged something was
making progress. Without this stop a scheduler whose whole head collides with a parked PR spins
quietly and reports held candidates forever. Attended, the orchestrator counts its own cycle and
stops. Headless, `runner-gate.sh` measures it between iterations: the runner passes the completed
cycle's start time, and no lane claim created and no loop PR merged since it, with candidates
still dispatchable, stops the run (measured, `scripts/tests/skill/drain-ready-queue/runner-gate.test.sh`).

**The auto-merge check-in bound counts merges across all lanes.** `auto_merge_checkin` is a bound on
the PM's attention, not on a lane's throughput, so three lanes reach it three times as fast and that
is the intent. `runner-gate.sh` already counts merged loop PRs from the host rather than per lane.

**A PR that falls to the PM is parked, and a park stops the run.** What fires is
[MERGE-PIPELINE.md](./MERGE-PIPELINE.md) § *The park conditions*, which is the single home for that
list. This file states no count of its own. Parking is four things at once:

1. **Annotate the claim** with a `PARKED: <why>` line ([CLAIM.md](./CLAIM.md)). This is **not** a
   release: `claim-status.sh` answers `CLAIM-PARKED`, so the ticket stays out of the pick.
2. **Give the slot back to the count.** `check-capacity.sh` reads `CLAIM-PARKED` as a claim that
   occupies no lane, so the parked ticket does not sit on capacity the PM has already released.
3. **Above 1 lane, stop every lane anyway.** `check-holds.sh` holds each candidate while any
   claim is parked, so the freed slot fills only once the PM clears the park. The two answers are
   not in conflict: capacity says the lane is not occupied, the collision check says nothing may
   enter it yet. At 1 lane step 3 never runs the check, so the freed slot takes the next candidate
   and the serial drain carries on as it always has.
4. **Leave the PR open and report it every cycle** until the PM resolves it.

Steps 2 and 3 together are what a parked PR used to buy through file overlap. The old check held
only candidates touching the parked PR's files, which is a hold on data the check did not have. The
run-wide stop is the honest version of it, and only the PM's `RELEASED:` line lifts it.

## Recovering lanes after a restart

The orchestrator holds nothing (ORCHESTRATION.md § 1), so a restarted one rebuilds every lane from
the blackboard rather than from memory. In order:

1. **Read the open claims.** `pick.sh` reports each as `PICK-CLAIMED`; `claim-status.sh <N>` says
   what each one is. `CLAIM-OPEN` is a lane that was in flight when the previous orchestrator
   stopped. `CLAIM-PARKED` is a PR waiting on the PM, and it stops the recovered run from
   dispatching at all until they clear it.
2. **Match each to its branch and its PR.** The claim names the branch. A claim with an open PR is
   a lane waiting for the merge pipeline; a claim with no PR is a pre-push window — step 1's reap
   says whether its worker is alive (`REAP-HELD-LIVE`) or established dead (`REAP-HELD-DEAD`, whose
   lane step 1 clears itself, and never by a silent re-dispatch).
3. **Verify before merging anything.** The provenance a verdict word needs is the dispatch that
   returned it, and a restart lost it. Every recovered PR re-enters the merge pipeline at step 1 —
   a fresh update, a fresh head read, a fresh verifier dispatch — whatever verdict block sits on it
   ([MERGE-PIPELINE.md](./MERGE-PIPELINE.md), [VERDICT.md](./VERDICT.md)).
4. **Then fill what is left.** Free slots take candidates by the slot rule above, which reads the
   recovered claims as in-flight work like any other.

A crash therefore loses the in-flight dispatches and nothing else, which is the property
STAGE-CONTRACT § 5 makes testable.

## The findings contract at queue depth

Held and skipped candidates are all reported, no silent drops (STAGE-CONTRACT § 4), but a fleet
queue at 65 ready tickets would drown the PM in one full enumeration per cycle. So:

- **Once per run**, the full enumeration: every held and skipped candidate, one line each, with its
  reason.
- **Every cycle after that**, the **deltas**: what became held, what stopped being held, what was
  skipped this cycle that was not skipped last cycle.
- **In between**, the **counts, with the top offenders named**, as in "14 candidates held, most
  often by #102 (claim) and PR #165", so a starving queue is visible in one line without being
  retyped in full.

Repetition is load-bearing where it is kept: a parked PR and a claim nobody released each get their
line **every cycle**, because only the repetition tells the PM that the condition is stale rather
than in flight. The delta rule bounds the candidate enumeration, never these.

## Cross-reference

- [SKILL.md](./SKILL.md) — steps 2–4 fill the slots, step 5 audits the PR's `Locks:` line, step 7
  records the lane count on the row
- [MERGE-PIPELINE.md](./MERGE-PIPELINE.md) — the serialized landing sequence every lane's PR goes
  through, and § *The park conditions*, which owns that list
- [CLAIM.md](./CLAIM.md) — the claim a lane is recovered from, its `PARKED:` annotation, and the two
  release paths
- [RATIONALE.md](./RATIONALE.md) §§ 3, 4 — why the unknown case inverted, and why the claim goes up
  before the spawn
- [STAGE-CONTRACT.md](./STAGE-CONTRACT.md) — § 4's findings rule this file bounds, § 5's
  no-state rule the recovery satisfies
