---
name: atlas
metadata:
  internal: true
description: Maintain this repo's Atlas, the standing project map under docs/atlas/. Charts one from the PM's domain and the repo's own code where none exists; where one does, orients from the index and the gap queue, works the queue, advises, and carves the next spec-sized bite.
disable-model-invocation: true
argument-hint: "fleet, to enter the fleet sitting in the repo that holds docs/fleet-atlas/"
---

An atlas is a standing, prospective codebase map. It is drawn ahead of the code, full of fog and
placeholders, and the code grows into it one decision and one spec at a time. It has no single
destination and is never done, which is what separates it from a wayfinder map, which serves one
effort and ends. The artifact is repo files under `docs/atlas/`: an index plus one file per area, in
the exact shape [SCHEMA.md](SCHEMA.md) states. Load the index first and open areas on demand; no
sitting holds the whole map. What two or more repos share is a second atlas, `docs/fleet-atlas/` in
the one repo that reads every other, in the shape [FLEET.md](FLEET.md) states; `/atlas fleet` works
it, and a repo's own map never names it.

An atlas sitting is the board of advisors. The PM brings domain knowledge and the parameters the
project must respect; you present real options with reasons; you decide together. Technical calls
are yours to make, with reasons stated and a cheap override; direction decisions go to the PM. The
atlas links and never restates: decisions live in ADRs, vocabulary in the repo's glossary, work in
the tracker. Nothing in the atlas is dispatchable. Work exits to the issue tracker through the
existing pipeline.

## Pick the mode by looking

Two looks at the repo choose the mode. Neither is a question to the PM, and neither needs git.

1. Does `docs/atlas/index.md` exist? Yes is a return sitting.
2. If not, does the repo hold source: files a survey could cite as evidence that something is
   built? Yes is a brownfield chart. No is a greenfield chart.

A repo whose only files are its own docs and agent instructions has no source and is greenfield.
The survey confirms it by having nothing to cite. Resurvey is not a mode. It is a step inside a
return sitting, described there. `/atlas fleet` takes neither look: it is the fleet sitting, below,
and bare `/atlas` is the repo sitting in every repo, including the one that holds the fleet atlas.

## Chart, greenfield

No index and no source. The areas come from an interview, and every claim is an intention.

Interview breadth-first. Compose `/grilling` and `/domain-modeling`; `/research` and `/prototype`
are available as in wayfinder. Discover the areas from the PM's domain. Fan out across the whole
space: the feeds and volumes, concrete examples, hard requirements, which areas must be built before
which, which areas wait on a decision held in another area, what is ruled out of scope, and what is
still fog, the coming decisions the PM can feel but cannot yet phrase. Then write the map and stop.

## Chart, brownfield

No index, and the repo holds source. A survey runs first, so the map never starts empty in a repo
with code.

1. Survey. Dispatch sub-agents to explore the codebase and bring a proposed grouping to the grill.
   Each proposed group states three things: the code evidence it rests on, a path or a symbol that
   exists in the code; the claim pattern it would own, which becomes the area's first `Owns:` claim
   when the PM confirms the group; and its proposed built axis, read off that evidence. The
   understood axis stays honest. Code shows what was built, not why, so a surveyed area starts at
   ❌ or 🔶 understood, and its options-and-why record is backfilled only when a sitting revisits
   it.
2. Grill the grouping. The PM confirms, corrects, merges, splits and names; the survey never names.
   Discovery from the project's own code is not seeding. A canned taxonomy still is. Then run the
   greenfield interview for what the code cannot show: the build order and the decision order
   between areas, the out-of-scope rulings and the fog.
3. Write the map and stop.

## Write the map and stop

Write the first atlas per [SCHEMA.md](SCHEMA.md). The index carries the orientation, the generated
area table and graph block, the fog, the out-of-scope rulings, and an `Ignore:` line for any tree
the map will not cover, such as generated output or a vendored copy. Each area gets one file. The
file name is the area's permanent key, minted once by the rule SCHEMA.md states and never renamed;
the title inside stays free to change. Each area carries both axes, its `Blocked-by:` line, a
`Pending-on:` line when it waits on another area's decision, and its `Owns:` claim naming the paths
its code lives in or will live in. Claim at chart time. A claim that matches nothing is an
intention, so an area in a repo with no code yet claims where its code will go rather than waiting
for code to justify it. Run [scripts/atlas-touch.sh](scripts/atlas-touch.sh), which generates the two
index regions and then checks them, and stop at the map. Charting
draws it; a return sitting works it.

## Return, an atlas exists

The sitting's shape is orient, advise, record, one carve, end. Queue work is what the sitting
records on the way to the carve.

1. Orient. Load the index and run [scripts/gap-queue.sh](scripts/gap-queue.sh) against the repo
   root. State the horizon from the index: which areas are understood but unbuilt, which wait on
   code (a solid edge) and which wait on a decision (a dotted edge). Then work the queue from the
   top. It prints six classes in one order, and the sitting takes them in that order with one move
   each; [SITTING.md](SITTING.md) holds the detail per class.

   | Class | The move |
   | --- | --- |
   | undeclared-dependency | Add the edge, move the code, or write `Imports: any`. |
   | contested | Narrow one pattern. The overlap is a boundary question. |
   | unclaimed | Resurvey. |
   | dead-claim | Remove the pattern, or reopen the built axis if the code was never built. |
   | unphrased | Write the open decisions the area actually has. |
   | fog | Name it into an area when its gist can be stated. Otherwise leave it. |

   Resurvey is the brownfield survey scoped to every unclaimed path the queue lists, roll-ups and
   loose files alike. It brings a proposed grouping with the same three facts per group, and the PM
   names, exactly as in a brownfield chart. It is a step, not a mode.

   Open an area file only when the sitting turns to that area, and ask
   [scripts/drill-down.sh](scripts/drill-down.sh) for its code rather than recalling it: an area key
   in, the tracked files it claims out. The symbols an area defines are that output piped to one
   grep, and no flag, run from the root: `scripts/drill-down.sh <key> . | xargs grep -nE '^(async def|def|class) '`.

2. Advise. Impact analysis of a proposed feature or pivot is read off the graph. Walk both edge
   types and name every area the change touches, the areas that wait on its code and the areas
   that wait on its decisions, so the PM can judge its cost before committing. Routing advice,
   which skill an area calls for and what testing it needs, is delivered in the sitting and never
   stored in the artifact.

3. Record what the sitting decided. A resolved decision lands in its area's options-and-why
   record, the options presented, what was picked and what it cost, and comes off the
   open-decisions list. A claim the sitting narrowed, added or removed lands on the `Owns:` line.
   An edge the sitting drew or cut lands on the `Blocked-by:` or `Pending-on:` line. Status axes
   move only on the enumerable facts [SCHEMA.md](SCHEMA.md) states. An area that reaches ✅
   understood frees every area whose `Pending-on:` names it: remove those entries in the same
   sitting, as [TOUCH.md](TOUCH.md) says. Close any of these with
   [scripts/atlas-touch.sh](scripts/atlas-touch.sh) before the sitting moves on. A sitting leaves
   the gate green.

4. Carve one bite. A carvable area has every `Blocked-by:` blocker built and no live `Pending-on:`
   edge; an area that waits on a decision open elsewhere is never carved from. Foggy enough to need
   its own map goes to `/wayfinder`. One spec's worth, judged against
   [SIZING.md](../to-spec/SIZING.md) — a path relative to **this file**, absent when the `to-spec`
   skill is not installed beside this one, in which case say so and judge the size yourself — the
   single home for the sizing rule, goes to `/grill-with-docs` and then `/to-spec`. The carved work carries its area's key:
   the handoff names the area, and everything filed downstream names it too, so what lands knows
   which part of the map it advances. A sitting that worked the queue and finds no carvable area
   ends at record.

5. End. One bite per sitting. The sitting ends at the carve and does not start the carved work.

## The decision edge

`Pending-on:` names the areas whose open decisions this area waits on. It is the map's second and
last edge type. `Blocked-by:` says build that first; `Pending-on:` says decide that first. It feeds
the understood axis: an area waiting on another area's decision is not fully understood, so it is
never ✅ understood while the line is present. On the graph it is drawn dotted, so a reader tells
waits-on-code from waits-on-a-decision at a glance. It keeps its area off the carvable frontier.
The line's form, its validation and the gate's rules for it are in [SCHEMA.md](SCHEMA.md); the
freeing move when a decision resolves is in [TOUCH.md](TOUCH.md).

## Fleet, `/atlas fleet`

`/atlas fleet` enters the fleet sitting. The argument exists because the repo that holds the fleet
atlas holds a repo atlas too, and no look can tell which one the PM means. In a repo with no
`docs/fleet-atlas/`, say there is no fleet atlas here and stop.

The sitting's shape is the repo sitting's: orient, advise, record, one bite, end. Its five steps,
its four queue classes and the move each one takes are in [FLEET.md](FLEET.md), beside the shape
they read and the gate they run. A repo sitting never needs them, which is why they do not sit here.

## Invariants

- Areas come from the PM's domain and the project's own code, never from a canned taxonomy. The
  survey proposes; the PM names.
- The area files are the single source of truth. The index's area table and graph block are
  generated from them, and neither region is ever hand-edited.
  [scripts/atlas-touch.sh](scripts/atlas-touch.sh) is the one command that regenerates them and
  checks the result, so the order the two arms run in lives in the script and not in prose.
- The atlas stays alive by update-on-write: the flows that land work touch it as part of landing
  it, per [TOUCH.md](TOUCH.md), the single home of that procedure. A sitting carries no
  bookkeeping.
- Drift is detected, never felt. [scripts/check-atlas.sh](scripts/check-atlas.sh) reports unlinked
  work, contradictory axes, bad vocabulary, bad edges, resolved pending edges and a stale index. It
  reports only; fixing what it finds is sitting work.
- The queue is a report and never a gate. [scripts/gap-queue.sh](scripts/gap-queue.sh) exits 0
  with findings or none, and a long queue beside a green gate is a repo mid-mapping, not a
  failure. Nothing that compares the map to the code can fail a landing.
- Out-of-scope rulings persist. Ruled-out work stays ruled out unless the PM reopens it.
- Relations live only in the fleet atlas. A repo's area file never names a shared area or another
  repo, and a repo's gate reads only the repo it sits in. The fleet gate runs in the repo that
  holds the fleet atlas, against the checkouts it is handed.
- One bite per sitting.
