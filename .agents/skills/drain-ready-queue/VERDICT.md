# The verifier's verdict

What an independent reading of a PR found when held against its ticket's acceptance criteria, **at
one named commit**. One block, in one comment on the PR, posted by the `verifier` worker the drain
dispatches at step 5.

A recap is self-reported: it says its gates passed and its criteria are met, and both claims come
from the agent whose work is being judged. The verdict is the only place in the cycle where someone
else looks. That is its whole value, and it is why the anti-rubber-stamp rule below is load-bearing
rather than decorative.

## A verdict is a claim about an identified tree

A verdict with no commit on it says a repository passed at some unnamed moment. That is not something
a merge can rest on: the branch it was read from moves, and nothing afterwards can say whether the
tree that merged is the tree that was examined. So the block carries `EXAMINED-COMMIT`, the commit
the verifier actually had checked out, and its brief names the commit it was sent to examine. The two
must agree, or the verifier refuses.

This is a **meaning change**, not a field addition, so the marker version moved with it
(`validate-verdict.sh` carries the digit). A block under the earlier marker is never merge input:
`merge-decision.sh` reads it as **no verdict** and refuses, because there is no honest way to read a
commit-free claim as a claim about a commit. Such a PR is re-verified, never re-labelled.

## The block

```
<!-- verifier-verdict v2 -->
VERDICT: pass  CRITERIA: 5/5  GATES: pass
TICKET: #24  PR: #57  VERIFIED-ON: 2026-08-19
EXAMINED-COMMIT: 4f0e2c9a1b7d3e5f60a8c2d4e6f8091a2b3c4d5e
CRITERIA-WHY: <one line — every unmet criterion named, or what proved the last one>
GATES-WHY:    <one line — which gates re-ran, in which tree, and what they printed>
RECAP:        corroborated | contradicted | unverifiable
RECAP-WHY:    <one line — which of the recap's claims held; a contradiction is tagged and measured>
CONCERNS:     none
```

| Field | What it holds |
|---|---|
| `VERDICT` | `pass` \| `concerns` \| `fail` \| `refused` — the four below |
| `CRITERIA` | `<met>/<total>`, counted off the ticket's checkboxes |
| `GATES` | `pass` \| `fail` \| `not-rerun` — what the verifier's own re-run showed |
| `TICKET` / `PR` | the issue and the PR, as `#<n>` |
| `VERIFIED-ON` | the ISO date the block was written or last edited |
| `EXAMINED-COMMIT` | the full 40-character commit the verifier had checked out — no abbreviation |
| `RECAP` | `corroborated` \| `contradicted` \| `unverifiable` — what the recap's claims did |
| `CONCERNS` | `none`, or one tagged and measured line per concern |

Exactly **one** block per PR: re-verifying **edits** the existing comment, never posts a second — the
same rule the score block runs on, and for the same reason. `VERIFIED-ON` says which reading you are
looking at, and `EXAMINED-COMMIT` says which tree it read.

## A concern is tagged and measured, or it is not a concern

`CONCERNS` is the most expensive line in the block. Under every auto policy a `concerns` verdict
parks the PR, and for a long time nothing read the line that earned the word. One drain run paid for
both halves of that: it parked a PR on a claim nobody had run, and it carried a finding about code
outside the diff inside the same field. So the field has a shape now, and `validate-verdict.sh`
refuses a block that does not have it.

```
CONCERNS: [diff] <what the PM should look hardest at> MEASURED: <command> -> <output>
CONCERNS: [adjacent #183] <the finding, and it went to that issue> MEASURED: <command> -> <output>
```

**The scope tag answers one question: does this reach the examined tree?**

- **`[diff]`** — yes. This is about the tree you verified, so it is the PM's to weigh before the PR
  lands. A `[diff]` element is what the word `concerns` means; the validator refuses `concerns`
  without one, and refuses a `pass` that carries one.
- **`[adjacent #<n>]`** — no. The finding is real and it is beside the diff, so it goes to its own
  issue and the tag names that issue. An adjacent finding **never** lowers the verdict. Routing one
  by hand has worked before, but only because the orchestrator chose well, not because a rule made
  it.

**The measurement is the command and what it printed.** Both halves, either side of `->`. A gate you
could not run has one too: the attempt is the command and the error is the output. This is the half
that catches a false concern: the one that produced this rule asserted that a test file pinned
nothing when two lines of that file already did, and nobody had run the grep.

One `CONCERNS:` line per concern, each validated on its own. `none` and a real concern in the same
block is refused rather than guessed at.

**Shape is what the script checks. Truth is not.** A command that does not support its concern still
validates, and so does an `[adjacent]` tag on something that does reach the diff. That is the
ceiling, and it is deliberate: judging whether a concern is true is the advisor's job, not a
script's. What the shape buys is that a verdict which parks a PR can no longer be written without
running anything.

## The recap axis carries the same two kinds

`RECAP` is a field, not prose, because a contradicted recap claim sets the verdict word exactly as a
concern does. Two re-verifications in one drain run both came back `concerns` on
`RECAP: contradicted`, and the two contradictions were nothing alike. One was a test case that
asserted nothing, proven by deleting a filter and watching the suite stay green. The other was a
sentence that miscounted something the diff did correctly. The word could not tell them apart, so a
PR with every criterion met and green gates could not merge over a miscount.

So a contradiction is tagged and measured on `RECAP-WHY`, with the same two tags reading the same
way:

```
RECAP: contradicted
RECAP-WHY: [diff] the recap says the marker filter is pinned; deleting it leaves the suite green MEASURED: sed '/marker/d' + run-tests.sh -> 410 ok, 0 failures
RECAP: contradicted
RECAP-WHY: [adjacent] the recap says three refusals collapse; it is four MEASURED: grep -c 'unknown "' check-lock.sh -> 6 here, 4 in the parent
```

`[adjacent]` on this axis needs no issue number. There is nothing to file: a posted recap is the
record of what the operative reported, so a correction is posted beside it and the recap is never
rewritten. `[diff]` means the contradiction changes what the PR does, and the verdict follows it.

## Find the block by its marker and its id, never by "last comment"

The loop's actors — orchestrator, operative, verifier — all speak through one authenticated account,
so "the last comment I made" is not "my verdict". Between two readings, the same account can post a
run report, a closure note, or a second verifier's block. Editing the last comment therefore
overwrites whatever happened to be there, silently and unrecoverably.

So a re-verifying verifier **selects** the comment whose body opens with the `verifier-verdict`
marker, takes that comment's id, and edits **that id** — the same discipline `run-issue-post.sh`
already uses to read its own comment back. No marked comment means there is no block to edit: post a
new one. More than one is a finding for the PM, not a comment to pick from.

## The four verdicts

- **`pass`** — every acceptance criterion met against something the verifier ran or read, the gates
  re-ran clean, and nothing the block carries is tagged `[diff]`. An adjacent finding and a
  narrative-only recap contradiction both sit under this word, reported in full. Nothing weaker
  earns it.
- **`concerns`** — the ticket is satisfied but something in the examined tree wants the PM's eye: a
  criterion met only in spirit, a claim that could not be corroborated, a gate that could not be
  re-run, a change in the diff wider than the ticket asked for, or a recap contradiction that
  changes what the PR does. **A criterion the verifier could not check is `concerns`, never
  `pass`.** Every one of those is a `[diff]` element, which is why the validator refuses the word
  without one.
- **`fail`** — a criterion is unmet, a gate the recap claimed passed does not pass, or the diff does
  something the ticket never asked for.
- **`refused`** — the tree the verifier had is not the commit its brief named, so it measured
  nothing. The branch moved between the dispatch and the clone. This is a **verdict outcome, not an
  error**: the block still posts, recording under `EXAMINED-COMMIT` the commit that was actually
  there, which is the evidence of the move. A refusal therefore always carries `CRITERIA: 0/<total>`
  and `GATES: not-rerun`, and the validator refuses any other combination — a verifier that had
  already run the gates checked the wrong tree with them. The orchestrator re-verifies at the
  current head; it never reads a refusal as a soft pass.

`fail` is a finding, not a veto: under `merge_policy: pm-merge` the PM reads the verdict and
decides. Under an auto policy the verdict word becomes merge input — the drain's
`merge-decision.sh` lets a merge through only on `pass`, under the current marker, with a checks line
the policy in force accepts ([MERGE-POLICY.md](./MERGE-POLICY.md)); `concerns`, `fail` and `refused`
always fall back to the PM. Under either policy the verifier never merges, never closes, never
re-labels.

**The word is the only place a concern's scope reaches the merge.** `merge-decision.sh` does not
read the block and does not learn the tags; it does not need to, because the validator has already
made the word mean them. A `[diff]` concern is the only thing that can produce `concerns`, and
`concerns` parks the PR; an adjacent-only block is a `pass`, and a `pass` merges on its other two
witnesses. Reading the tag a second time at the button would give one decision two homes, and they
would drift. `concerns` parks whatever the tag says — ship-only-on-pass is not something an adjacent
finding can talk its way past.

## Validated before it posts

`scripts/validate-verdict.sh <pr> [dir]` reads `verdict-<pr>.txt` from `[dir]` — the verifier's own
`mktemp -d`, per [ORCHESTRATION.md](./ORCHESTRATION.md)
§ 4 — and is chained
in front of the post — `validate-verdict.sh <pr> "$tmp" && gh pr comment …` — so a malformed block *cannot*
reach the PR. One line on stdout per run: `OK …` and exit 0, or `INVALID …` and exit 1. It checks the
marker — naming a superseded one as superseded — the field vocabulary, the `<met>/<total>` shape, the
date, and `EXAMINED-COMMIT`, which must be present and a full 40-character lowercase hex commit id.
It then reads the two fields that produce the verdict word:

- `RECAP` is required and one of the three words; `CONCERNS` is required, because an absent field
  does not read as `none`;
- every concern that is not `none` opens with `[diff]` or `[adjacent #<n>]` and carries
  `MEASURED: <command> -> <output>`, each line on its own;
- a `RECAP: contradicted` carries the same tag and the same measurement on `RECAP-WHY`.

Then it refuses the combinations that make a verdict dishonest rather than merely wrong:

- a `pass` whose `CRITERIA` are not all met, or whose `GATES` are not `pass`;
- a `GATES: fail` under any verdict but `fail`;
- a `refused` whose `CRITERIA` met is not 0, whose `GATES` are not `not-rerun`, or whose `RECAP` is
  not `unverifiable`;
- a `concerns` with no `[diff]` element, and a `pass` that carries one.

A `refused` is exempt from the tag and the measurement, and from those only. It examined nothing, so
it has nothing to measure: its `CONCERNS` line carries the briefed commit and the one it got.

Those are the rubber-stamp shapes, and a script is where they belong: an instruction to be careful
is not a constraint that holds regardless of judgment.

**The marker digit did not move for this.** [STAGE-CONTRACT.md](./STAGE-CONTRACT.md) § 3 bumps on a
change of **meaning** and lets a field **addition** land in place while the population is small.
`RECAP` is an addition, `CONCERNS` gained a shape nothing had been reading, and nothing re-reads an
old block: `merge-decision.sh` takes the word its own dispatch returned this iteration, never one
read back off a PR. The licence is time-limited by its own wording, so this was cheap now and would
not have been later.

## Rubber-stamping is the failure mode

A verifier that says `pass` too often is worse than no verifier, because the PM will believe it. Two
things guard against it. Each criterion names the command run or the file read that settled it — an
assertion with nothing behind it is not a check. And the verdict is recorded on every ledger row, so
a run of `pass` verdicts sitting beside a `rework` and `reverted` rate is visible as a population
even when no single verdict looked wrong.

When two verdicts look defensible, prefer the worse one. That is the same rule
[LEDGER-REFERENCE.md](./LEDGER-REFERENCE.md) applies to outcomes, for the same reason.

## Against the stage contract

[STAGE-CONTRACT.md](./STAGE-CONTRACT.md) § 1 asks a stage to move each item to exactly one successor
state. **The verifier moves nothing.** Under `pm-merge` the transition out of the drain is the PM's
merge, and the verdict is an input to it; under an auto policy the transition is the
orchestrator's script-gated merge, and the verdict is the input the script reads. Which policy
holds is a PM choice made at setup from the catalog ([MERGE-POLICY.md](./MERGE-POLICY.md)) —
nothing in the loop promotes a repo between policies. Either way, verification runs inside the
drain's cycle rather than owning a queue of its own.

The other clauses bind normally: § 2, rails live in `agents/verifier.md` and only the PR's specifics
travel in the brief; § 3, this block is versioned and script-validated; § 4, an unverified PR is a
findings line, never silence; § 5, the verifier holds nothing — the block on the PR is the record.

## Cross-reference

- [SKILL.md](./SKILL.md) — step 5, where the verifier is dispatched
- [LEDGER-REFERENCE.md](./LEDGER-REFERENCE.md) — the `verdict` cell this fills
- [STAGE-CONTRACT.md](./STAGE-CONTRACT.md) — § 3's versioning and evolution rule
- `agents/verifier.md` — the worker's rails
