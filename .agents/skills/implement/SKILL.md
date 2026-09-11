---
name: implement
description: Implement work that is already written down. Takes a spec or a set of tickets, edits the code, runs the tests, reviews the result, and records the change on the atlas. Use when the user asks to implement or build an existing spec, ticket, or set of tickets. Writing the spec is to-spec; draining the whole backlog with subagents is drain-ready-queue.
---

Implement the work described by the user in the spec or tickets.

Use /tdd where possible, at pre-agreed seams.

Run typechecking regularly, single test files regularly, and the appropriate set of tests once at the end.

Once done, use /code-review to review the work and calibrate to the depth appropriate for the ticket.

**Touch the atlas — only when `docs/atlas/` exists and the spec or ticket names an area** on its
`Area:` line. Link the change you just made from that area's file and move the axes exactly as
[TOUCH.md](../atlas/TOUCH.md) states; implementation may move *Built*,
never *Understood*. Then **read the atlas back**: re-read the area file, confirm the link and the
axis lines, and run `../atlas/scripts/atlas-touch.sh`. Both of those paths are relative to **this
file**, not to the repo you are working in. The script regenerates the index from the area files and
then checks, and it must exit 0. No `docs/atlas/`, or no area named: touch nothing and say so in one
line. And if the `atlas` skill is not installed beside this one, both paths are absent — say that in
one line and touch nothing, rather than guessing at the rule.

Commit your work to the current branch — the atlas touch rides in the same commit as the work it
records, so it passes the same gates and lands in the same merge.
