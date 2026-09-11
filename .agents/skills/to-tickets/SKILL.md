---
name: to-tickets
description: Break a plan, spec, or the current conversation into a set of tracer-bullet tickets, each declaring its blocking edges, published to the repo's issue tracker with native blocking links drawn between them.
disable-model-invocation: true
---

# To Tickets

Break a plan, spec, or conversation into a set of **tickets** — tracer-bullet vertical slices, each declaring the tickets that **block** it.

**Where the paths below point.** A `../<skill>/FILE.md` path resolves against **this file**: both install shapes — the Claude Code plugin's `skills/` and the `npx skills` vendored `.agents/skills/` — put every skill directory side by side. If a named sibling skill is not installed its files are simply absent: say which one you could not read and take the stated fallback, never recite it from memory.

The issue tracker should have been provided to you — run `/setup-engineering-skills` if `docs/agents/issue-tracker.md` is missing. The label vocabulary is the plugin's and fixed, so the labels below are named literally rather than resolved through a per-repo mapping.

## Process

### 1. Gather context

Work from whatever is already in the conversation context. If the user passes a reference (a spec path, an issue number or URL) as an argument, fetch it and read its full body and comments.

### 2. Explore the codebase (optional)

If you have not already explored the codebase, do so to understand the current state of the code. Ticket titles and descriptions should use the project's domain glossary vocabulary, and respect ADRs in the area you're touching.

Look for opportunities to prefactor the code to make the implementation easier. "Make the change easy, then make the easy change."

### 3. Draft vertical slices

Break the work into **tracer bullet** tickets.

<vertical-slice-rules>

- Each slice cuts a narrow but COMPLETE path through every layer (schema, API, UI, tests) — vertical, NOT a horizontal slice of one layer
- A completed slice is demoable or verifiable on its own
- Each slice fits — and should nearly fill — a fresh agent's [smart zone](https://www.aihero.dev/ai-coding-dictionary/smart-zone) (~150k tokens, within which the model still reasons sharply)
- Any prefactoring should be done first

</vertical-slice-rules>

**Default to fewer, bigger tickets.** Every ticket carries a fixed overhead — a dispatch, a
fresh agent re-exploring the repo, a PR, a verification pass — so ticket count, more than ticket
size, sets how long the implementation takes. Merge adjacent slices until the result would no
longer fit the smart zone. A split must buy something you can name: parallel work on different
parts of the codebase, an earlier unblock of a downstream ticket, or fit in the smart zone.

Give each ticket its **blocking edges** — the other tickets that must complete before it can start. The edges are what make the set takeable: they are drawn as native links in the tracker's own UI, so the **frontier** — every ticket whose blockers are done — is visible without reading the spec. A ticket with no blockers is on the frontier from the start.

**Wide refactors are the exception to vertical slicing.** A **wide refactor** is one mechanical change — rename a column, retype a shared symbol — whose **blast radius** fans across the whole codebase, so a single edit breaks thousands of call sites at once and no vertical slice can land green. Don't force it into a tracer bullet; sequence it as **expand–contract**. First expand: add the new form beside the old so nothing breaks. Then migrate the call sites over in batches sized by blast radius (per package, per directory), each batch its own ticket blocked by the expand, keeping CI green batch to batch because the old form still exists. Finally contract: delete the old form once no caller remains, in a ticket blocked by every migrate batch. When even the batches can't stay green alone, keep the sequence but let them share an integration branch that all block a final integrate-and-verify ticket — green is promised only there.

### 4. Quiz the user

Present the proposed breakdown as a numbered list. For each ticket, show:

- **Title**: short descriptive name
- **Blocked by**: which other tickets (if any) must complete first
- **What it delivers**: the end-to-end behaviour this ticket makes work

Ask the user:

- Does the granularity feel right? (too coarse / too fine)
- Are the blocking edges correct — does each ticket only depend on tickets that genuinely gate it?
- Should any tickets be merged or split further?

Iterate until the user approves the breakdown.

### 5. Publish the tickets to the tracker

Publish one issue per ticket, in dependency order (blockers first) so each ticket's blocking edges can reference real identifiers, then link and wire them as the tracker doc's **Ticket graph operations** section describes. Apply the `ready-for-agent` label unless instructed otherwise — the tickets are agent-grabbable by construction.

Work the **frontier**. For a purely linear chain that means top to bottom.

Set each ticket's milestone to the parent spec's (ask the PM when the spec names none) — the drain
can then be scoped to that slice. After publishing, offer to run
`/triage-and-score` in score-only mode over the published set so the batch arrives ranked instead
of sorting last in the drain; scoring is optional, and the tickets are dispatchable without it.

Where these tickets came from an issue on the tracker, that issue is their parent: link each ticket to it, and leave it as written — closing it or editing its body breaks the record of what the tickets were derived from.

**The parent link is a verified postcondition, not a suggestion.** Attach each ticket to its parent the way the tracker doc's **Ticket graph operations** section says (on GitHub, a native sub-issue), then **read the count back** and compare it to the number of tickets you published. Publishing is not done until they match. This line used to read as optional, and the measured result was a tracker where most specs had no edges to their tickets — a graph nothing downstream could query.

### 6. Touch the atlas

Only when `docs/atlas/` exists and the work names an area — read it off the parent spec's `Area:`
line, and carry it onto every ticket you publish. Link the published ticket set from that area's
file and move the axes exactly as
[TOUCH.md](../atlas/TOUCH.md) states; filing tickets may move
*Understood*, never *Built* — nothing has merged yet.

Then **read the atlas back**, the same way the parent link above is read back: re-read the area
file, confirm the link and the axis lines are there, and run
`../atlas/scripts/atlas-touch.sh`. Both of those paths are relative to **this file**, not to the
repo you are working in. The script regenerates the index from the area files and then checks, and
it must exit 0. No `docs/atlas/`, or no area named: touch nothing and say so in one line. And if the
`atlas` skill is not installed beside this one, both paths are absent — say that in one line and
touch nothing, rather than guessing at the rule.

<issue-template>

## What to build

The end-to-end behaviour this ticket makes work, from the user's perspective — not layer-by-layer implementation.

## Acceptance criteria

- [ ] Criterion 1
- [ ] Criterion 2

## Blocked by

- A reference to each blocking ticket, or "None — can start immediately".

Area: <the atlas area this ticket advances, or omit the line entirely>
Locks: <global-lock names, or `none`>

</issue-template>

**Every acceptance criterion must name an observation an agent can make by running something** — a
command, a query, a request — and the output that counts as passing. "Works correctly" and "is
handled properly" are not criteria; an independent verifier will later execute these lines
verbatim, and a criterion it cannot execute is a ticket-quality defect it will file. Write "running
`<command>` prints/returns `<observable>`", not "the feature works".

**A behaviour the spec puts under a condition gets a criterion for the condition, not only the
behaviour.** When the spec says a check fires between iterations, under one policy, or in one mode,
write the criterion that observes the boundary from both sides — the check firing where it should
*and* staying quiet where it should not ("the same fixture is silent at `start`"). A ticket whose
criteria all pass with the condition on the wrong side cannot fail on the thing the spec cared
about.

**`Locks:` is a machine-readable line**, written only when the repo has a `docs/agents/loop.md`
with a `global_locks` table (omit the line when it doesn't — never invent a lock name). It names any
of the config's `global_locks` the work will hit (a migration is the canonical case), else `none`.
The drain's lock hold is its only reader: a candidate declaring a lock waits while another lane
holds it. A ticket without the line is not penalised — it declares no lock and dispatches like any
other. Declare a lock the diff will really take, not the neighbourhood the work sits in: the hold
believes the line, never the diff, so an over-declared lock serializes tickets that could have run
in parallel. File overlap needs no declaration at all — the merge pipeline resolves it at landing.

Put it in the ticket body, as the template above does — that is one of the two places a reader
looks, the other being an agent brief posted later. Which one wins when both carry a line is stated
once, in [TICKET-BRIEF.md](../triage/TICKET-BRIEF.md); don't restate it.

**`Area:` is machine-readable too**, and written only when the repo has a `docs/atlas/` and the
work was carved from an area — omit the line entirely otherwise, and never invent an area name. It
is how the carve travels: everything that lands downstream reads this line to know which part of
the map it advances, and the atlas's drift checker reads it to find work that landed unlinked.

Avoid specific file paths or code snippets — they go stale fast. Exception: if a prototype produced a snippet that encodes a decision more precisely than prose can (state machine, reducer, schema, type shape), inline it and note briefly that it came from a prototype. Trim to the decision-rich parts — not a working demo, just the important bits.
