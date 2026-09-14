# The stage contract

The plugin-level declaration of what every **stage** consumes, dispatches, emits, and reports. It is
the extension mechanism: a new stage that satisfies these five clauses plugs into the existing ones
without archaeology, and one that does not will leak state, drop work silently, or break a consumer
that parses its output.

*Stage*, *orchestrator*, *worker*, *dispatch brief*, *blackboard* and *findings lines* are used as
the repo's `CONTEXT.md` defines them. `drain-ready-queue` and `triage-and-score` are the two stages
that exist today. Verification was the first thing built against this file: it runs inside the
drain's cycle rather than owning a queue, and [VERDICT.md](./VERDICT.md) § *Against the stage
contract* is the worked example of a stage declaring itself clause by clause.

**Why it lives here and not in `docs/agents/`.** `docs/agents/` is the *per-repo* corner —
`loop.md`'s parameters, this repo's label mapping, this repo's ledger — and `loop.md` says outright
that a rule which is not a number, path, or short command belongs in the plugin. The contract is
doctrine, identical in every repo the loop runs in, so it is plugin-shipped and single-sourced like
`ORCHESTRATION.md` beside it: skills point at `../drain-ready-queue/STAGE-CONTRACT.md`, resolved
against the file doing the pointing, rather than each repo carrying a copy that drifts.

## 1. One state in, one state out

A stage consumes exactly **one** tracker state and moves each item it touches to exactly **one**
successor state. On the issue itself: one category role (`bug`, `enhancement`, `spec`, …) and one
state role (the five of [LABELS.md](../setup-engineering-skills/LABELS.md)) at a time —
never two states at once. An
issue with **no** state role is not in the pipeline at all: that is how process artefacts (a spec,
a brief, a wayfinder map) stay visible to the PM and invisible to every stage (ADR 0001).

The point is that the blackboard alone says which stage owns an item. Two state labels, or a stage
that reads three queues, and ownership becomes a judgment call made separately by each orchestrator.

*Where a stage reads more than one state, it declares the split as named modes and each mode obeys
the clause on its own* — `triage-and-score`'s `full` mode consumes `needs-triage`, `score-only`
consumes `ready-for-agent`. That is the tolerated form; an undeclared multi-queue read
is not.

## 2. Rails in the definition, specifics in the brief

A stage dispatches a **named worker type** — an agent definition in `agents/`, dispatched
namespaced (`toolkit:<name>`) — and sends it a **dispatch brief** carrying only: the ticket
specifics — its number, its title, its branch slug, and the declaration lines the tracker resolved
for it, `Area:` among them where the repo has an atlas — the repo config from `loop.md` (`gates`,
`workspace_setup`, and any stage-specific numbers), and `brief_addendum` **verbatim**. A declaration
is passed through as it resolved; what the worker does with it is a rail.

**Rails live in the agent definition.** A rail restated in the dispatching skill is a rail that will
drift from the one the worker actually runs on, and the drift is invisible — both copies read fine.
When a rail needs changing, change the definition. A stage must also name what to do when the
namespaced type does not resolve, because a worker dispatched without rails is worse than no
dispatch.

## 3. Machine-readable, versioned, validated before posting

A stage's tracker output is machine-readable and opens with a version marker on a line of its own, and a
**script** validates it before it is posted. The entry path is a language model writing text against
a prose spec, so malformed output is the expected failure mode, not the exceptional one — and
validation is deterministic work, which makes it a script rather than an instruction to be careful.

Today, each marker with the script that actually refuses output missing it: `triage-score`
(`validate-block.sh`), `agent-brief` (`validate-brief.sh`), `verifier-verdict`
(`validate-verdict.sh`), `lane-claim` (`validate-claim.sh`, and
[CLAIM.md](./CLAIM.md) is what the block asserts), `ledger`
(`ledger-append.sh` refuses any marker it does not write, except
the one immediately below canon, which it migrates in place — see [LEDGER-REFERENCE.md](./LEDGER-REFERENCE.md)), and the
edge lines (`validate-edges.sh`). A marker earns a place on this list only once a script enforces
it — naming one that nothing checks reads as a guarantee and is worth less than an empty list.
The `loop-config` marker is therefore **not** on it: it is repo configuration written during setup,
not a stage's tracker output, so this clause does not bind it and no script validates it.

Each marker's canonical version lives in exactly one **machine-owned home** — the validating
script named above, or, for `loop-config`, the setup skill's shipped `LOOP-TEMPLATE.md` that
writes it. Prose cites the marker by name and points at that home rather than restating the
version digit: a version quoted in prose is a cache that rots on the next bump.
`scripts/check-markers.sh` (run by the toolkit's bare `check-skill.sh`) enforces this as
consistency, not prohibition — a template legitimately carries the literal, and the check fails
naming any file that quotes a marker at a version its home no longer carries.

Every one of them requires the marker on a **line of its own** — the half that matters most, since
that line is exactly what consumers select on, and a marker quoted inside prose is not one. They
differ on position, and honestly so: the verdict and the ledger are files a script owns end to end,
so their marker must be line 1; the score block, the agent brief and the lane claim are
posted under the AI-generated disclaimer, so theirs must be present exactly once and
may sit below that line.

**The evolution rule.** Bump the marker when a field's **meaning** changes; treat everything written
under an older marker as unread by the new consumer. A field **addition** lands in place while the
population is still small, older records parsing the new field as a visible `null`. The rule holds
only while the population is small — it is a licence to move fast now, not a permanent exemption,
and the moment there is history worth keeping the addition needs a bump too.

**A stage's outputs are not only the artefact it is named for.** The scoring stage emits **two**
per ticket: the `triage-score` block, and the ticket's `Locks:` declaration, which the scorer writes
into the agent brief to the template `TICKET-BRIEF.md` owns. `pick.sh` resolves that line per
candidate and hands it to the claim and to `check-holds.sh`; `check-declared-locks.sh` audits it
against the PR's measured files. A brief that posts without it costs the loop both. The declaration
needs
no marker of its own because it rides one already on this list: it lives in the issue body or in an
`agent-brief` comment, which is exactly what `validate-brief.sh` refuses an unmarked brief for.
Where a stage's output is carried by another stage's artefact, say so here. An output nobody
declares is an output no consumer knows to look for.

## 4. Findings lines — no silent drops

A stage reports findings lines to the PM naming **everything** it skipped, bounced, held, or filed,
every cycle the condition persists. Not a summary of the batch: one line per item, with the reason.

Starvation is the failure this prevents, and it is invisible by construction — an item that never
gets picked produces no output at all unless the stage is obliged to produce one. Repetition is
load-bearing too: only seeing the same held ticket cycle after cycle tells the PM the blocker is
stale rather than in flight.

An orchestrator relays a finding; it never acts on one. Clearing a blocking edge, re-labelling,
re-ordering the queue are all the PM's.

## 5. Workers hold no state between dispatches

A worker performs one dispatch and is discarded. Everything that must outlive it goes back to the
blackboard — a score block, a label, a PR, a ledger row — before it returns. Where the repo keeps a
`docs/atlas/`, the atlas touch for the work is part of the **worker's PR**: one more thing the
worker emits, on the branch it already owns, passing the gates the PR already passes. Neither the
orchestrator nor the recap writes it — a recap-time write records work outside the gates the work
itself was held to, and the record would land in a different merge than the change it describes.

The orchestrator holds
nothing either (ORCHESTRATION.md § 1): what it carries between iterations is state in the wrong
place, and a stage that needs it has a missing blackboard record, not a memory problem.

The consequence is testable: kill a stage mid-run and re-start it, and it must lose nothing but the
in-flight dispatch.

## Adding a stage

1. Write `agents/<name>.md` — rails plus the `tools:` allowlist, which is the only capability
   boundary that is enforced rather than advisory.
2. Write the stage skill: which state in, which state out (§ 1), the dispatch brief (§ 2).
3. Define its tracker output with a `v1` marker and the script that validates it (§ 3).
4. Enumerate what it can skip or bounce, and report each (§ 4).
5. Point at this file from the SKILL.md rather than restating any of it.

## Cross-reference

- [ORCHESTRATION.md](./ORCHESTRATION.md) — the four rules a stage's *orchestrator* runs on,
  including § 4, which names every scratch file a new stage writes
- [LEDGER-REFERENCE.md](./LEDGER-REFERENCE.md) — the outcome ledger, § 3's evolution rule applied
- [SCORING.md](../triage-and-score/SCORING.md) — the score block, § 3's
  first instance
- `CONTEXT.md` — the vocabulary this file uses
