# The outcome ledger

What happened to every ticket the drain touched, one row each, in the target repo at
`docs/agents/ledger.md`. Read this at step 7 of the cycle, when you have an outcome to record.

The loop's own claims are self-reported: a recap says its gates passed, a PR says it closes an
issue. The ledger is where those claims become a **population** — slop rate, how much consolidation
actually saved, and how the repo's chosen `merge_policy` is serving it. The policy itself is a PM
choice made at setup from the catalog ([MERGE-POLICY.md](./MERGE-POLICY.md)) — the ledger informs
that choice and its revisiting; it never promotes a repo between policies. None of those questions
can be answered from one iteration's window, which is exactly why the answer cannot live there.

## The row

Seven fields, written by `scripts/ledger-append.sh` — you supply the values, never the formatting:

| Field | What it holds |
|---|---|
| issue | `#<N>`, the ticket that left the queue |
| pr | `#<n>`, or `-` when no PR was opened (a bounce, a STOPPED recap, a dead run) |
| dispatched | the ISO date the subagent was dispatched — defaults to today |
| verdict | the verdict word **step 5's dispatch returned to you**, which is the word its block posted on the PR — `pass`, `concerns`, `fail`, `refused` ([VERDICT.md](./VERDICT.md)); `-` when no verifier ran |
| outcome | one of the six words below |
| tokens | what the harness reported for the dispatch; `-` when it reported none |
| lanes | the `max_lanes` in force when this ticket was dispatched — what `resolve-lanes.sh` printed, so `1`, `2` or `3`; `-` when it was not recorded, and **absent** on every row written before the column existed |

**`lanes` is a fact about the run, not about the ticket**, and it is the field that makes the
ledger answer the question parallelism is on trial for: a slop rate, a rework rate or a token cost
measured over a mixed population says nothing, because the serial baseline and the parallel
population are mixed into one number. Separating them needs the lane count on the row, at the time,
from the script that resolved it — never inferred afterwards from how many PRs happened to be open.

`-` is the written form of "not recorded", in every field. A blank cell and a missing cell read the
same to `awk`, and the corroboration script reads these rows by column.

**A multi-round ticket still has one verdict word, and one source for it: the word step 5's
dispatch returned in the final round** — the word the merge decision was fed, never round 1's.
That earlier rounds existed is what the outcome cell's `rework` records (PM ruling, 2026-08-26).
[SKILL.md](./SKILL.md)'s step-5 rail governs this cell too — never
fill it by re-reading a block from PR comments, where a quoted or forged block is indistinguishable
from a posted one. The posted block is the **audit trail, never the input**: exactly one exists,
because re-verifying **edits** it rather than adding a second ([VERDICT.md](./VERDICT.md)), and the
verifier reads it back before it reports. So an audit that finds a written row disagreeing with the
block reports a correction, and correcting a row is the PM's call, as every edit to a row is.

**Writing the row includes landing it.** Step 7 passes `--commit --push`. The script commits the
ledger path — only that path, on the repository's own identity, with a `docs(ledger):` subject it
composes — and then pushes it to the branch's upstream, fetching and rebasing first when the push is
refused, which is what the iteration's own merge normally makes it. It reports each step:
`LEDGER-COMMITTED` naming the branch, `LEDGER-PUSHED` naming the upstream, or the matching
`-FAILED` line with the row left where it stopped.

Until the row is pushed it exists in one working tree, and everything that reads this ledger reads
it by path in whatever checkout it runs in — so an unpushed row is not a slower blackboard, it is a
blackboard of one.

## The six outcomes

- **`merged-clean`** — merged on the first recap: the PM's button under `pm-merge`, the
  script-gated auto-merge under an auto policy. The word asserts the clean landing, not who
  pressed the button; which policy was in force is the repo's `loop.md` as of the row's date, not
  a field on the row. No more-fixes round, no follow-up PR.
- **`rework`** — a fix round while the PR was still open, whatever sent it back, or a follow-up PR
  after the merge. One rework round and five are the same row; the count is not a field, because a
  rate over the population is what the ledger is for. An auto policy does not close the pre-merge
  round off: step 5's verify gate sits in front of step 6's button, and `merge-decision.sh` refuses
  on anything but `pass` — so a ticket can and does go round before it lands. What the auto policy
  removes is the PM's *own* pre-merge read, so PM disagreement arrives afterwards as `reverted`
  instead.
- **`reverted`** — merged, then undone. Almost never known at step 7; it is normally a correction
  made later, when `ledger-corroborate.sh` finds the revert. Under an auto policy this is also
  what PM disagreement looks like — review happens after landing, so "I'd have sent it back"
  becomes a revert.
- **`bounced`** — the queue was wrong about the ticket's *cost*, so **nothing was attempted**: the
  effort bounce at step 2, and only that. `pr` is `-`.
- **`stopped`** — a worker was dispatched, read the ticket, and returned a STOPPED recap: the
  premise was wrong, the fix was larger than the ticket, a gate failed for a reason predating the
  change, or the work was a production operation. `pr` is `-`. It is a *successful* refusal, and it
  is split out of `bounced` because a run of them says the **queue is mislabeled**, which is a
  different thing to fix than a run of tickets that were too big. Two in a row is what stops a
  headless run, so this word is a brake input, not just a record.
- **`died`** — a worker was dispatched and its run ended before it opened a PR, established dead by
  a pid measured gone: step 1's `REAP-HELD-DEAD`. `pr` is `-`, and the script refuses the row given
  one, because the finding that produces it *is* the absence of a PR. It is neither of the two words
  above: `bounced` asserts nothing was tried, which is false of a run that edited files, and
  `stopped` asserts a worker read the ticket and refused it, which is false of a run that was
  killed. Two in a row is a second headless stop, and it says a different thing. The harness is
  breaking workers, not the queue mislabeling tickets.

The judgment is only ever which of these six; everything else on the row is a fact you already
have. When two look defensible, prefer the worse one — a ledger that flatters the loop is worse
than no ledger, because it will be believed. The three no-PR words are the set to get right rather
than to hedge, and two questions separate them: was a worker ever spawned? If not, it bounced. Did
it come back with a recap? If it did, it stopped; if its pid was measured gone, it died.

## One row per outcome, and where the dedupe stops

The `pr` cell draws the line, and `ledger-append.sh` holds it.

**A row that carries a PR dedupes on issue+PR.** The script writes nothing when that pair already
has a row, and says `LEDGER-DUPLICATE` — so re-running an iteration cannot double-count a landing.

**A row whose `pr` cell is `-` is never deduped** — `stopped`, `bounced`, `died`, any outcome
recorded without a PR. Nothing in such a row tells two events apart: the cell that does the telling
is the same `-` both times, so a dedupe there collapses every no-PR outcome for one ticket into the
first one. Both events are real. A ticket the PM re-readies after a stop can honestly stop again,
one re-scored after a bounce can honestly bounce again, and a re-dispatched one can honestly die
again. The second row is the point. Both streaks are read off the ledger, and a hidden repeat is a
brake that never fires; the bounce rate is read the same way, and a hidden repeat flatters the
queue.

Those rows are outside `ledger-corroborate.sh`'s population, which walks merged PRs and matches by
the `pr` cell, so nothing downstream re-collapses them either.

The script **refuses** a `stopped` or a `died` row given a PR, rather than treating the `-` above as
a convention. A worker opens a PR or it stops, never both; and a dead run is *established* by a
branch with no PR, so a PR would contradict the finding that produced the row. Either row carrying a
PR number would answer for that PR when the corroborator reads rows by their `pr` cell, which is how
a contradiction gets reported as `LEDGER-OK`.

## Creating it, and versioning it

The first append creates the file, whose first line is the ledger's version marker —
`ledger-append.sh` owns the canonical string, and no other file may quote it at another version
(`scripts/check-markers.sh` in this repo enforces that). The script
refuses to write to a ledger opening with a version it neither writes nor migrates: a different
version writes different rows, and appending under the wrong marker corrupts the population
silently. Per [STAGE-CONTRACT.md](./STAGE-CONTRACT.md) § 3's evolution rule, bump the marker when a
field's *meaning* changes; a new field lands in place while the population is still small.

**`lanes` was that rule's first outing.** The marker did not move for it: nothing any earlier row
asserted changed meaning, so every consumer of a row written before the column still read it
correctly. What did move is the table header — a markdown renderer drops the cells a body row
carries past its header, so a value written under a header that predates it is written and
invisible. The script adds the header column in place on its next append and says so
(`LEDGER-COLUMN-ADDED`); the rows already written are not touched, so their `lanes` cell does not
exist, which is what "reads null" means here. The licence is temporary by construction: once there
is history worth keeping, the next field addition needs a bump too.

**`died` is the other half of the rule, and the marker did move for it.** Adding the word changed
what `bounced` asserts. It covered the dead run as well until then, and it now covers the effort
bounce alone, so every reader of an older `bounced` row would be reading a different claim than the
one the row was written to make. That is a meaning change, and a meaning change bumps the marker
(#213).

**Migration is the script's job, not yours.** Meeting a ledger under the immediately-previous
marker, `ledger-append.sh` rewrites line 1 in place and appends — but only when no row's outcome
word changed meaning. It reports the rewrite (`LEDGER-MIGRATED`) rather than editing quietly.

Where rows *did* change meaning it stops instead: `LEDGER-MIGRATION-BLOCKED` (exit 1), nothing
written. Splitting `died` out of `bounced` is the case in hand. No `bounced` row says whether a
worker was ever spawned, so no machine can tell which of them were dead runs, and reclassifying them
is a PM correction, like every other edit to a written row. Relay the finding; do not migrate by
hand mid-iteration.

**One previous version, and no further back.** The script migrates a ledger opening with the
immediately-previous marker and refuses anything older, exactly as it refuses a version ahead of
canon. A file two markers back would have to be walked across two meaning changes at once, and the
rows that would need splitting are the ones no machine can split.

## Corroboration

`scripts/ledger-corroborate.sh` re-derives, from `gh` and `git`, what it can prove about every
merged loop PR, and holds the ledger against it. It proves three states — `merged-clean`,
`reverted` (a revert PR or a revert commit), and `superseded` (a later loop PR closing the same
issue). It cannot see `rework` inside a single PR and does not try: a recorded `rework` against a
derived `merged-clean` is not a contradiction, and the script says nothing about it.

Run it at the end of a run, not every iteration — its input is the whole merged history, and it
answers the same way whether you ask once or fourteen times. It reports; it never edits. Correcting
a row is a PM decision, and `reverted` rows are the ones that will need it.
