# Working the queue

[scripts/gap-queue.sh](scripts/gap-queue.sh) prints the questions a return sitting works, in one
order, biggest question first. This file holds the one move per class. The classes, their order and
the roll-up rule are the script's header; the facts each move touches are in [SCHEMA.md](SCHEMA.md).
The sitting takes the classes in the order printed, records each move before it goes on, and treats
the moves as what it records on the way to the carve, never as a replacement for it.

Each move below says what the sitting does, what it records, and which axis may move. Every move
ends the same way: run [scripts/atlas-touch.sh](scripts/atlas-touch.sh) before the next class. It
regenerates the index from the area files and then checks, in that order, so no move has to carry
the order itself.

## Undeclared dependency

The finding is one importing area and the areas its code imports with no direct `Blocked-by:` edge,
each with its count of importing files. The map and the code disagree about the architecture, and
the sitting settles it with the PM one imported area at a time, with three moves. The map should
learn the dependency: add the imported area to the importer's `Blocked-by:` line. The code is in the
wrong place: move it, or narrow the claim that put it there, so the import stays inside one area.
The area imports freely by design, as a test tree or a presentation layer does: write `Imports: any`
in its file, once, and the whole importing side of that area leaves the queue. A pervasive count
points at the first move; a stray count points at the second; an area whose every line is a
dependency points at the third. The symbol listing in [SKILL.md](SKILL.md) shows what the importing
files reach for.

The sitting records the changed `Blocked-by:` line, the moved code or narrowed `Owns:` line, or the
`Imports: any` line, per [SCHEMA.md](SCHEMA.md). An added edge redraws the graph, so the index is
re-rendered. No axis moves.

## Contested

The finding is a file two or more areas both claim. There is no precedence rule and no tie-break,
so the overlap is a boundary question, and the sitting settles it with the PM by narrowing one
pattern: the area that does not own the file gets its `Owns:` pattern tightened, or an exclusion
added, until the file has one claimant. A file both areas honestly own says the two areas are one,
or that a third sits between them. Put that to the PM as a merge or split question rather than
choosing a winner.

The sitting records the changed `Owns:` line in the narrowed area, or the area files a merge or
split produces, minted per SCHEMA.md. No axis moves.

## Unclaimed

The finding is tracked code no area claims, rolled up to the shallowest directory whose in-scope
files are all unclaimed, or a loose file where the roll-up does not hold. This is where the sitting
reruns the brownfield survey, scoped to every unclaimed path the queue lists, roll-ups and loose
files alike. Dispatch sub-agents over exactly those paths. Each proposed group states its code
evidence, a path or a symbol; the claim pattern it would own; and its proposed built axis read off
that evidence. The PM confirms, corrects, merges, splits and names; the survey never names. A group
the PM confirms becomes a new area or joins an existing one, whose `Owns:` line widens to cover it.

Two shortcuts skip the survey. A loose file whose home is already on the map is claimed to the area
whose gist covers it. A tree the map deliberately does not cover, generated output or a vendored
copy, goes on the index's `Ignore:` line.

The sitting records new area files, minted per SCHEMA.md; widened or added `Owns:` lines; and any
extension of the `Ignore:` line. A new area's built axis is set from the cited evidence, exactly as
the survey proposed it at chart time, and moves on merge state from then on. Its understood axis
starts at ❌ or 🔶, because code shows what was built and not why. No existing area's axis moves.

## Dead-claim

The finding is an `Owns:` pattern in a Built ✅ area that matches no tracked file. Below ✅ the same
pattern is an intention and the queue says nothing. There are two readings, and the sitting picks
with the code and the area's Links in view. The code moved or was deleted: remove the pattern, or
rewrite it to where the code now lives. The code was never built and the ✅ was wrong: reopen the
built axis. A ✅ area with no landed work linked under the pattern is the second case.

The sitting records the corrected `Owns:` line, or the built axis moved to 🔶. The built axis is
the only axis this move touches, and it only moves down.

## Unphrased

The finding is an area at ❌ understood with no open decision recorded. The map says nothing is
decided and does not say what is open. Open the area with the PM and write the decisions the area
actually has, one checkbox each, into its Open decisions section. A decision the PM can feel but
cannot phrase is fog and goes in the index's Fog section instead. A decision that cannot be made
until another area decides something first is a `Pending-on:` entry naming the deciding area, and
the sitting draws it here.

The sitting records the Open decisions list and any `Pending-on:` line it drew. No axis moves.
Understood stays ❌ until a decision resolves, and resolving one is record-step work in SKILL.md,
not queue work.

## Fog

The finding is one index Fog bullet, unadorned and with no age on it. Ask the PM whether its gist
can now be stated. When it can, name it into an area: the PM names, the key is minted once per
SCHEMA.md, the bullet leaves the Fog section, and the new area file carries the open decisions the
fog turned out to hold, its `Blocked-by:` line, a `Pending-on:` line when it waits on a decision
held elsewhere, and its `Owns:` claim as an intention. When it cannot, leave it. The queue position
already says still unnamed.

The sitting records a new area file and the shortened Fog section, or nothing. A new area starts at
❌ understood and ❌ built. No existing area's axis moves.

## After the queue

The rest of the sitting is advise, record and one carve, as [SKILL.md](SKILL.md) states. A sitting
that spent itself on the queue and finds nothing carvable ends at record.

## The fleet queue

[scripts/fleet-queue.sh](scripts/fleet-queue.sh) prints the questions a fleet sitting works, in one
order, and the four moves below are the fleet sitting's. The classes and their order are the
script's header; the facts each move touches are in [FLEET.md](FLEET.md). The script takes the
fleet root and every attached repo's checkout as `<repo>=<path>`, and the sitting reads it the way
it reads the repo queue: from the top, one move per class, each recorded before the next. Every
fleet move ends with the fleet touch at the end of this file.

## Stale contract

The finding is a contract side pinned below the contract's current `Revision:`, one line per side,
naming the repo, the head, the pin and the revision. The contract moved and that side has not, and
the finding measures the other repo's progress, which is why it is a question and never a gate
failure. Two moves. The side should catch up: the plane files the issue on the lagging repo, and
the sitting records nothing, because the pin moves when that work lands and the plane observes it.
The side may lag: the sitting rules it, with the PM, and records why in the shared area's Options
and why, so the next sitting reads the ruling instead of asking again. The pin is not touched; a
pin says what a side implements, never what was excused.

The sitting records an Options and why bullet, or nothing. No axis moves.

## Cross-repo cycle

The finding is a cycle in the repo dependency graph, where each implementation draws an edge from
every consumer repo to its owner repo and contracts draw nothing, one line per distinct cycle. A
data plane that consumes what the control plane owns while the control plane consumes the data
plane's model server is a normal shape, so the finding is a question, not a defect. Two moves. The
cycle is intended: the sitting names it so in the Options and why of one shared area on the cycle,
and the queue keeps printing it as a fact the map knows. The cycle is a misclassification: one of
the shared areas on it is a contract every side implements and not an implementation one side
owns, and the sitting reclassifies it, `Kind:` to `contract`, `Owner:` replaced by `Revision: 1`
with its first Revisions bullet, and every side given its pin.

The sitting records the Options and why bullet, or the rewritten header block and Sides of the
reclassified shared area. No axis moves.

## Uncharted side

The finding is a side whose head is `<repo>:uncharted`, or a charted head in a repo whose checkout
has no `docs/atlas/`, one line per side. The fleet atlas was drawn ahead of that repo's map, and
the question is who charts it and when. Two moves. The repo has no map yet: request a charting
session there, a bare `/atlas` in that repo, and record nothing here; the head stays uncharted
until the area exists. The repo has since charted: resolve the head to the key of the area that
holds that side, `<repo>:uncharted` to `<repo>:<key>`, and on a contract give it the pin it
implements, read off that repo's atlas and its code. A whole-repo head needs no charting and never
appears here.

The sitting records the rewritten Sides bullet, or nothing. No axis moves.

## Fleet fog

The finding is one index Fog bullet, unadorned. Ask the PM whether its kind and its sides can now be
stated. When they can, name it into a shared area: the PM names, the key is minted once per
[FLEET.md](FLEET.md), the bullet leaves the Fog section, and the new file carries its `Kind:`, its
`Revision: 1` or `Owner:`, its `Blocked-by:` line, a `Pending-on:` line when it waits on a decision
held on another shared area, one Sides bullet per side, and the open decisions the fog turned out
to hold. When they cannot, leave it. The queue position already says still unnamed.

The sitting records a new shared area file and the shortened Fog section, or nothing. A new shared
area starts at ❌ understood.

## The fleet touch

Every edit inside `docs/fleet-atlas/`, in a sitting or by the plane, ends the same way, and the
edit is not done until it has run [scripts/fleet-touch.sh](scripts/fleet-touch.sh) against the
fleet root with every attached repo's checkout, one `<repo>=<path>` per name on the `Repos:` line.

It rewrites the index's shared-area table and graph from the shared area files, then runs the gate
over what it wrote. Never hand-edit either region. The gate must print nothing and exit 0. A
`DRIFT` line the edit caused is the edit's to fix, whichever file it names. A line the edit did not
cause predates it: report it and do not fix it on the way past.

The fleet touch lives here and not in [TOUCH.md](TOUCH.md) because relations live only in the fleet
atlas. A repo landing carries an `Area:` key in its own repo and never names a shared area, so no
repo landing can know it touched one, and the repo touch stays exactly as it is. The flow that
edits the fleet atlas is the flow that runs its gate: a fleet sitting, or the plane in the repo
that holds it, which knows the attached checkouts and hands them to the gate.
