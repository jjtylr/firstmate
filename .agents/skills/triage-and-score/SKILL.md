---
name: triage-and-score
description: Triage and score the backlog — one fresh subagent per issue verifies the claim and scores value / agent-effort / PM-cost against the repo's anchors, then a calibration pass re-ranks the batch. Labels and comments only; never writes code.
disable-model-invocation: true
---

# Triage and score the backlog

**Where the paths below point.** A `../<skill>/FILE.md` path resolves against **this file**: both
install shapes — the Claude Code plugin's `skills/` and the `npx skills` vendored
`.agents/skills/` — put every skill directory side by side. If a named sibling skill is not
installed its files are simply absent: say which one you could not read and take the stated
fallback, never recite it from memory.

Worker names differ by client. Claude Code uses the plugin types `toolkit:scorer` and
`toolkit:score-calibrator`. The Codex project bootstrap installs the bare `scorer` and
`score-calibrator` roles. Their portable instructions live under this skill's `agent-roles/`
directory in both install shapes.

Turns an unordered backlog into a **ranked** one, without the PM sitting through 40 interactive
triage sessions. Two things happen per issue: `triage`'s judgement (category, state, verify the
claim) and a **priority score**.

**The rubric is split on purpose.** [SCORING.md](./SCORING.md) (this folder) owns the structure —
axes, gates, block format, defensive queries, the repo-neutral exemplars. The repo's
`docs/agents/loop.md` (`scoring` section) owns the numbers — effort quintiles and named anchor
issues, because those are measurements of that repo. A scorer reads both; with no local anchors
yet, the exemplars are the yardstick. Label strings below are the plugin's fixed vocabulary
([LABELS.md](../setup-engineering-skills/LABELS.md)) — every repo carries them verbatim,
so there is nothing to substitute.

**Read [ORCHESTRATION.md](../drain-ready-queue/ORCHESTRATION.md) before
step 1.** It is the single home for the four rules both loop skills run on — § 1 the orchestrator
holds nothing, § 2 dispatching a worker, § 3 the scripts decide and the skill file explains, § 4
every dispatch writes into a scratch directory it made itself, which is why a scorer runs `mktemp -d`
before its first file. Nothing below restates them. The contract this stage satisfies is its neighbour
[STAGE-CONTRACT.md](../drain-ready-queue/STAGE-CONTRACT.md) — five clauses,
for building a stage rather than running one.
Both files ship beside this folder in either install shape, which is what the `../` reaches.
Scoring-specific: `READY_LABEL` / `TRIAGE_LABEL` exist to point the scripts at a scratch label
under test, not to remap the vocabulary, and the rule against
`/compact` bites hardest here — the haze of issues 1–29 becomes the yardstick for issue 30, when the
whole point of anchors is a yardstick that lives on disk, identical for every subagent.

**There is no local ledger.** Each subagent posts its score before returning; the tracker is the
only state. A crashed batch loses nothing — re-run step 1 and scored issues drop out on their own.

## What this is not

- **It does not write code.** It fills the queue `drain-ready-queue` consumes.
- **It does not decide what to work on.** Ranking is not authorisation; the PM picks.
- **It does not close issues on its own judgement.** `wontfix` and "already implemented" are
  recommendations the PM confirms in step 5.
- **It does not touch privileged systems.** If the fix is a production operation, score it and
  flag it.

## The cycle

Ask the PM which mode before starting:

| Mode | Queue | What each subagent does |
|---|---|---|
| **score-only** | `ready-for-agent`, unscored | Verify the claim and score. State and brief already exist; don't re-litigate them, don't touch labels. The higher-value first run — these are what the drain loop is about to pick. |
| **full** | `needs-triage`, unscored | Full `triage` (verify, categorise, recommend state) **and** score. |

### 1. Build the queue

```bash
bash "$SKILL/scripts/queue.sh"          # full mode
bash "$SKILL/scripts/queue.sh" --ready  # score-only mode
```

The queue is an **allowlist on the state each mode consumes** (ADR 0001) — category labels
(`spec`, `brief`, `wayfinder:*`, `bug`, …) are invisible to it, and an issue with no state label is
not in the pipeline. Still excluded: an existing `v1` block (re-scoring is a *second* opinion, not
a better one — re-score only on PM request, by **editing** the block). `needs-info` is never
scored: it means the scope changed or was wrong, so a score against it is false precision
(ADR 0002).

**A ticket carrying an open lane claim is held out too** — one `QUEUE-CLAIMED:` line per ticket on
stderr, why in SCORING.md. Relay them to the PM every pass; releasing a claim is the PM's.

Report the count before dispatching. Empty → say the backlog is scored and stop.

### 2. Dispatch scorers — serial first, then waves

Scorers are independent by construction: each reads one issue, writes one per-issue block file
(`block-<N>.txt`, per SCORING.md), and posts to its own issue. So the batch runs **serial or in
waves** — the discipline is the same brief either way:

- **Start serial.** The first ~3 issues of a batch go one at a time: a mis-calibrated scorer
  caught here costs one re-run; caught after a wave it costs the wave. Widen once the lines
  coming back compare against anchors by name.
- **Then waves of up to 5.** Dispatch the wave in one message, record each line as its
  notification arrives, and send the next wave when all have returned. The bound is the
  tracker's, not ours: GitHub's REST best-practices doc tells integrators to avoid concurrent
  content-creating requests, and a tripped secondary rate limit turns a post into a failure only
  the scorer's read-back will catch.
- The per-dispatch scratch directory and the posted-comment read-back (both in SCORING.md) are
  what make waves safe. Measured 2026-08-18: a wave of six sharing one directory and one
  `block.txt` corrupted 4 of 56 issues. Never relax either half.

Dispatch per ORCHESTRATION.md § 2 — including within a wave, where the notification is what tells
you the wave is done and the next one may go.

**Dispatch one fresh scorer.** Claude Code uses `toolkit:scorer`; Codex uses the project role
`scorer`. Every rail is in [the scorer role](./agent-roles/scorer.md): what to read,
verify-the-claim, prose-parking, the axes, validate-before-post, the mode split, and the recap
shape. **Send the dispatch brief and nothing else.** A rail restated here will drift from the role
the scorer runs on.

Substitute `<N>`, `<TITLE>`, `<MODE>` and `<LABELS>` — for `<LABELS>`, the **absolute** path of
`../setup-engineering-skills/LABELS.md` resolved against **this file**, because the scorer never
read this file and cannot resolve a relative path against it; if that skill is not installed, drop
the sentence and say so — and append this repo's `brief_addendum` from `docs/agents/loop.md`
verbatim:

> Triage and score backlog issue **#\<N\> — \<TITLE\>**. Mode: **\<MODE\>**.
>
> Repo config, in the repo you are scoring: `docs/agents/loop.md` (the `scoring` section's anchors
> and `effort_threshold`). The label vocabulary is the toolkit's, in `\<LABELS\>`.
>
> \<brief_addendum, verbatim\>

**If the client-specific scorer does not resolve**, dispatch a fresh generic subagent and put
[the scorer role](./agent-roles/scorer.md) ahead of the substituted brief. Never dispatch a scorer
with no rails. It will fall back to its own sense of "medium", the failure the anchors exist to
prevent. If the role file is absent, say which path you could not read and stop.

### 3. Record the line, keep dispatching

Keep one line per issue — `SCORE` and `FLAG` are enough. Do not re-read the issue or summarise
the reasoning. Say which issue is running as you dispatch, so the PM can watch calibration drift
in real time. Then back to step 2.

### 4. The calibration pass

**Required: the batch is not done without it.** Dispatch one final subagent per ORCHESTRATION.md
§ 2. Claude Code uses `toolkit:score-calibrator`; Codex uses the project role
`score-calibrator`. Every rail is in [the score-calibrator role](./agent-roles/score-calibrator.md):
what it reads, compare-don't-re-triage, the ±1 bound, and its return shape. **Send the brief and
nothing else**, one line:

> Calibrate the scores of this batch: issues **#\<N\>, #\<N\>, …**. Repo: **\<owner/repo\>**.

**If the client-specific calibrator does not resolve**, dispatch a fresh generic subagent and put
[the score-calibrator role](./agent-roles/score-calibrator.md) ahead of that line. An unrailed
calibration pass re-triages the tickets, which returns a second opinion rather than a calibration.

Apply its moves yourself, by **editing** each affected block — never posting a second one —
refreshing `SCORED-ON` as you do. The calibrator writes nothing.

### 5. Hand the board to the PM

In order: (1) the ranked board — top ~15 with ratio, `VERIFIED`, state; (2) **every
`VERIFIED: no`, separately and by name** — did-not-reproduce vs could-not-check, only the first
is a reason to pull the ticket; (3) `RECOMMEND` decisions awaiting the PM, batched one line each — **consolidation
recommendations among them**, each naming the tickets and what they share, because only the
PM approves one and the combined ticket must then be re-scored within `effort_threshold` — **and
every ticket the effort gate held at `needs-info`**, named with its score; a ticket kept out of the
drain queue is never a silent drop;
(4) `FLAG` lines, named with their tickets; (5) any bunching finding, plainly.

Then stop. Working the board is `drain-ready-queue`'s job; picking from it is the PM's.

## Feeding the drain loop

Once a batch is scored, `drain-ready-queue` sorts on ratio descending — that is the payoff.
Unscored tickets sort last, not first: a ticket arriving from `/to-tickets` is agent-ready by
construction and must not be run through triage; score it or leave it at the bottom.
