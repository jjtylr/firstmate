# The atlas touch

Update-on-write: the flows that land work touch the atlas as part of landing it, so the map can
only go stale if work stops. This file is the single home of that procedure — `to-spec`,
`to-tickets`, `implement`, and a drained ticket's operative all point here, and none of them
restates it.

## When it applies

Both conditions must hold, and both are cheap to look at:

1. `docs/atlas/index.md` exists in the repo you are writing to.
2. The work names an area key in the `Area:` line on the spec, ticket, or dispatch brief.

Either one missing: **touch nothing, and say so in one line**. A repo without an atlas sees no
behaviour change at all, and work carved from no area has no area to record it. Never infer the
area from the diff; a missing `Area:` line is a missing fact, not a puzzle to solve.

The fleet atlas, `docs/fleet-atlas/`, is never touched by a repo landing: relations live only
there, so no landing can know it touched a shared area, and the fleet touch lives in
[SITTING.md](SITTING.md).

## The touch

The `Area:` entry is a key. Open `docs/atlas/<key>.md` directly ([SCHEMA.md](SCHEMA.md)). There is
no normalizing step and no second spelling: a key is lowercase letters, digits and hyphens, and an
entry in any other form is an error the gate reports. Never find the file by comparing its `# Title`
heading.

If the key file does not exist, stop and report that the `Area:` entry names no area. Do not create
one. Atlas sessions discover areas; landing flows do not.

1. **Link what just landed.** Add one bullet to the area's `## Links` section — the spec issue, the
   ticket set, the merged PR, the ADR, or the repo file: a title and a pointer, nothing restated. A
   section that reads `None yet.` is replaced by the bullet, not appended to.

   **Head the title by what the bullet records.** The built axis is a query over this section, and
   [scripts/check-atlas.sh](scripts/check-atlas.sh) answers it from the title head alone — the
   pointer cannot, because a landed ticket and a filed ticket carry the same kind of URL. This
   table is the single home of the convention; [SCHEMA.md](SCHEMA.md) points here rather than
   restating it.

   | The bullet records | The title heads | Reads as |
   | --- | --- | --- |
   | A merged PR | `PR #<n> — <title>` | landed |
   | The ticket a drained PR closes | `#<n> — <title>` | landed |
   | One filed ticket | `Ticket #<n> — <title>` | filed |
   | A filed ticket set | `Tickets #<a>–#<b> — <title>` | filed |
   | A spec | `Spec: <title>` | filed |
   | An ADR | `ADR-<nnnn>: <title>` | filed |
   | A repo file | the file's own title | filed |

   ```markdown
   - [PR #12 — first storage cut](https://example.invalid/gridwatch/pull/12)
   - [#14 — daily price chart renderer](https://example.invalid/gridwatch/issues/14)
   - [Ticket #25 — nightly CSV drop](https://example.invalid/gridwatch/issues/25)
   - [Tickets #22–#24 — CSV export](https://example.invalid/gridwatch/issues/22)
   - [Spec: CSV export](https://example.invalid/gridwatch/issues/21)
   - [ADR-0003: one store per area](../adr/0003-one-store-per-area.md)
   - [scrape loop](../specs/scrape-loop.md)
   ```

   A **bare** `#<n>` head is reserved for the one landed unit that has no PR number to write: the
   ticket a drained operative links while its own PR is still unopened. So filed work never heads
   its title with a bare number — write `Ticket #25 — …`, not `#25 — …`, or the checker reads the
   bullet as landed and reports `axes-contradiction` on an area where nothing has merged.

2. **Move the axes only on the enumerable transitions** [SCHEMA.md](SCHEMA.md) states, never on how
   the work felt. Which axis a flow may move follows from what that flow actually observed:

   | Flow | May move | On what |
   | --- | --- | --- |
   | `to-spec`, `to-tickets` | Understood | A decision the session resolved comes off `## Open decisions` and lands in `## Options and why`; an emptied list is ✅ |
   | `implement`, a drained ticket's PR | Built | The change lands: ❌ → 🔶, and → ✅ only once everything carved from the area has landed and the area holds no fog |

   Neither flow moves the other axis. Filing work does not move Built; landing work does not move
   Understood. Most touches move no axis at all — a link alone is a complete touch.

   **When a touch moves an area to ✅ understood, free the areas that waited on it.** Find every
   `Pending-on:` entry across the atlas that names the area (`grep -l '^Pending-on:' docs/atlas/*.md`
   and read the entries), remove the entry, and drop the line when it was the entry's only one. The
   read-back would report `pending-resolved` on each of those files anyway; this instruction makes
   the fix known before the finding is. Removing the edge deletes state, not history: the waiting
   area's own record of what it waited on lives in its Options and why and its Links.

**Never hand-edit the index.** Its area table and dependency graph are generated from the area
files, so the area file is the only place you write an axis or an edge. The read-back below
regenerates both from what you just wrote.

## Read the atlas back — the postcondition

The touch is not done when you have written it. It is done when you have **read it back**:

1. Re-read `docs/atlas/<key>.md`. Confirm the link you added is present, and that each axis line
   reads what you set it to.
2. Run [scripts/atlas-touch.sh](scripts/atlas-touch.sh) against the repo root. It regenerates the
   index from the area files and then checks, in that order, and it must print nothing and exit 0.
   A `DRIFT` line your touch caused is yours to fix, whichever area file it names: your own area,
   your artifact, or a `pending-resolved` on an area that waited on the axis you moved. Fix it and
   read back again. A line your touch did not cause is drift that predates you. Report it in your
   summary, and do not fix it on the way past.

Report the result in one line: the area, what you linked, and any axis that moved. This repo has
already measured that an unverified prose step silently does not happen, so the read-back is what
makes the touch real.
