# The scoring rubric — structure

This file is the **repo-neutral half** of the rubric: the axes, the gates, the block format, and
the defensive queries. The **numbers** — effort quintile boundaries, named anchor issues, gate
costs — are measurements of one repo and live in that repo's `docs/agents/loop.md` (`scoring`
section). A scorer needs both open; when the repo has no local anchors yet, the exemplar library
at the bottom is the yardstick until ~20 merged PRs exist to measure.

## The three axes

Standard frameworks (RICE, ICE, WSJF) collapse cost into one number. That is wrong here:
agent-hours are close to free, and **the PM's attention is the scarce input**. So cost splits in
two, and the split is the point.

| Axis | Range | Question |
|---|---|---|
| **Value** | 1–5 | What breaks, or stops being paid for, when this ships? |
| **Agent effort** | 1–5 | How much work is the change itself? |
| **PM cost** | 0–3 | How many decisions must a *human* make before or during it? |

`RATIO = VALUE / AGENT-EFFORT`, to one decimal. Rank descending; break ties on lower PM cost.

**PM cost is a gate, not just a tiebreak.** PM cost ≥ 2 ⇒ `needs-info`, whatever the ratio —
that is exactly what the label means. Wiring the axis to the label is what stops the score being
decoration.

## Value (1–5): the ladder

Judge the **consequence of the status quo continuing**, not the elegance of the fix. The ordering
is fixed across repos; the repo config names one anchor issue per band.

| | Meaning |
|---|---|
| **5** | Something is silently wrong, or silently absent, where it counts — and nothing surfaces it. |
| **4** | A recurring cost is paid every day, or a question the project exists to answer can't be answered. |
| **3** | A guard or check that is *supposed* to catch something doesn't. Failure contained; safety net fictional. |
| **2** | Real friction, correctly handled today by a human who knows the workaround. |
| **1** | Hygiene. Nothing downstream changes. |

**The trap:** a loud symptom is not high value and a silent one is not low value. Score the
consequence, not the volume.

## Agent effort (1–5)

Bands are the **measured quintiles of the repo's own merged PRs** (added lines), from the repo
config — never a feel. The measurement procedure is global; re-run and re-stamp it when the
distribution drifts:

```bash
gh pr list --state merged --limit 120 --json number,title,changedFiles,additions,deletions
```

Rules that override the line count:

- **A schema migration floors effort at 3** — the migration is never the whole cost.
- **Fold blast radius into this axis, don't add a fourth.** A 40-line change to a registry or
  bootstrap path every surface imports is a 3, not a 1.
- **A file-count spike is not effort.** A mechanical sweep across 260 files can be an E2. Score
  the thinking, not the diff surface.

## PM cost (0–3)

Count **decisions only a human can make** — not review time, which is set by the repo's
`merge_policy` (every PR under `pm-merge`, after landing under an auto policy), never by the
ticket.

| | Meaning |
|---|---|
| **0** | Fully specified. An agent starts cold and finishes. Drainable AFK. |
| **1** | One bounded judgement call inside a decided shape, safe to make and report. |
| **2** | A scope or design decision the ticket does not contain. **⇒ `needs-info`** |
| **3** | An open question, a privileged operation, or work needing host/credential access. **⇒ `needs-info` or `ready-for-human`** |

**Question marks in the title are the cheapest tell** — a title that asks rather than asserts has
almost never been PM cost 0.

## `VERIFIED` — a fact, not a fourth axis

**The check that produces this value is not described here.** It lives once, in
[CHECKS.md](../triage/CHECKS.md) § 1 — probe precedence, what a
failed search does and does not prove, and the `yes`/`no`/`n/a` consequence with its
*did-not-reproduce* vs *could-not-check* split. Run it there. What follows is only why the result
is recorded rather than scored.

The axes rank *what is worth doing*; `VERIFIED` predicts **whether handing the ticket to an agent
produces a PR or a STOPPED recap** — the dominant drain failure is a premise nobody re-measured.
It is deliberately binary: a scored axis drifts and bunches; a recorded fact cannot. `no` is a
finding, not a failure, and only *did-not-reproduce* pulls a ticket from the queue. Verification
and effort-scoring are the same work: you cannot say E2-not-E4 without reading enough to know
whether the premise holds.

## Where a score lives

An HTML-commented block in a comment on the issue — greppable, diffable, versioned. **Exactly one
block per issue**: re-scoring **edits** the existing block, never posts a second.

```
<!-- triage-score v1 -->
VALUE: 4  AGENT-EFFORT: 2  PM-COST: 0  RATIO: 2.0
SCORED-ON: <YYYY-MM-DD>
VERIFIED: yes — <what you probed and what it showed>
VALUE-WHY:  <one line — the consequence of the status quo>
EFFORT-WHY: <one line — the comparable, or why a rule overrode the line count>
PM-WHY:     <one line — the decisions counted, or "none">
```

`SCORED-ON` is the date the block was written or last edited. Every score is a prediction against
the issue *as it read that day*; the date lets the drain loop warn when `updatedAt` post-dates
the score. An edit refreshes it — the edit is a fresh judgement.

**Validate before posting** — `scripts/validate-block.sh <N> <dir>` (this skill's folder), where
`<dir>` holds `block-<N>.txt` and defaults to `.`. It is the same parse every consumer runs: `OK …` and exit
0, or `INVALID …` and exit 1 — chain it in front of the post so a malformed block cannot reach
the tracker. It refuses a missing or wrong-version marker line before it looks
at a single field: the marker is what every consumer selects on, so a block without it is not a
low-ranked block, it is an invisible one.

Make your own directory with `mktemp -d` first, write the block to `block-<N>.txt` **inside that
directory**, and **read the posted comment back** before reporting success. Never write into the
scratchpad you were handed: it is shared with every other dispatch of the run. The directory is
what keeps two scorers apart; the number is in the filename because `validate-block.sh` opens that
name.

> **Both halves are load-bearing, and this is measured, not theoretical.** Scorers share a working
> directory, so concurrent scorers writing one `block.txt` race between write and post. On
> 2026-08-18 a wave of six corrupted **4 of 56** issues — each got a *different* issue's score, and
> one issue's real score never reached the tracker at all while its scorer reported success. A
> subagent's return message is not evidence its write landed.
>
> Detector, if it recurs: `scripts/find-dup-blocks.sh` (this skill's folder) — it dedupes posted
> blocks by **content**, never by length (two unrelated blocks in the measured batch were both
> 3,163 bytes). A partial collision shares the scored content but not the whole body, so also grep
> for a doubled AI-generated-during-triage disclaimer line.

A malformed block does not rank badly — under a naive query it makes the ticket **vanish**
(`capture` emits nothing on no-match; an empty stream annihilates the enclosing object) and an
`AGENT-EFFORT: 0` aborts the whole board. The board query below degrades both to a visible
`ratio: -1` instead; the entry path is an LLM writing free text against a prose rubric, so a
malformed block is the *expected* failure mode, and the defence is two-layer on purpose.

**The board query** — `scripts/board.sh` (this skill's folder) — reads every posted score back,
ranked.

Two of its properties are load-bearing and must survive any edit: **`last` of a collected list**
(iterating `.comments[]` emits one row per matching comment, and a stale score can outrank the
fresh one) and **every capture bound with `// null`, divisor guarded** (see above). `v1` is in the marker so a rubric change can be
told from an unscored issue: **bump the version when a band moves** and treat older blocks as
unscored under the new one; a field *addition* lands in place while the scored population is
small, with older blocks parsing the field as a visible `null`.

## A claimed ticket is not scored at all

**A ticket carrying a lane claim is held out of the queue** — open or parked. `scripts/queue.sh`
does it, one findings line per ticket. A claim means a dispatch is already in flight, and every
write this stage makes lands on the ticket that dispatch is working: the score block, a label, an
edge, a brief. That is the single seam where scoring could disturb the drain's lanes, so the stage
closes it by not scoring the ticket at all.

The exclusion is the script's, not the scorer's — ordinarily the scorer never sees the ticket. The
scorer definition holds the same rail for the case where one reaches it anyway: it writes nothing
and returns the ticket flagged.

## Calibration

A fresh context scoring one issue alone regresses to 3s and 4s. Two mechanisms hold the scale,
both required: **anchors** (repo config, or the exemplars below) compared against by name, and a
**cross-batch calibration pass** — one agent reads only the scoring blocks, together, and re-ranks.
It may move a score by **±1 at most**, naming each comparison; wider means re-score. It never
moves a score to reconcile it with `VERIFIED` — that hides the unverified-ness inside a number.

**Scorer failure modes** (properties of the scorer, not of any repo — watch for all four):
bunching toward the middle (more than half a batch at V3–4/E2–3 is a finding about the batch);
axis confusion (Value justified by difficulty, or Effort by importance); migrations-cost-more-
than-their-diff; loud-symptom ≠ high-value.

## The exemplar library — repo-neutral, outcome-confirmed

Cold-start yardstick for a repo with no local anchors, and the cross-repo transfer mechanism: the
scorer is the same model everywhere, so generic exemplars calibrate it everywhere. Local anchors
take precedence once they exist. A library entry must make sense with the repo's name removed —
a repo-flavored entry is a routing failure, not a contribution.

| Exemplar | Score | Why |
|---|---|---|
| One-line doc or changelog fix; nothing downstream changes | E1, V1 | Hygiene band by definition. |
| Add a field + schema migration + backfill | E3–4 | The migration floors it at 3; the backfill decides 3 vs 4. |
| A guard that fires but checks the wrong thing | V3 | The safety net is fictional — the definition of the band. |
| Title asks a question ("should we…?", "what cadence?") | P ≥ 2 | The ticket contains the question, not the answer. |
| Warning noise a human correctly ignores daily | V2 | Handled friction — loud, but the consequence is small. |
| Silent data absence with no alert, however small the fix | V5 | The ladder tops on silence, not on size. |
