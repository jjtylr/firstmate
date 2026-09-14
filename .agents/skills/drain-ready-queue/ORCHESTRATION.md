# Loop orchestration

The doctrine every **loop-skill orchestrator** runs on, whichever stage it is driving. This file is
the single home for these four rules — `drain-ready-queue` and `triage-and-score` point at it and
do not restate it. Read it once, before your first dispatch of a run.

*Orchestrator*, *worker*, *stage* and *blackboard* are used as the repo's `CONTEXT.md` defines them.
Each rule ends in a **consequence**: what it obliges you to do differently.

## 1. The orchestrator holds nothing

**Every dispatch gets a virgin context window.** Per iteration you see one identifier going in and a
short recap coming out — a few hundred tokens. You never approach the smart zone, so you do not
degrade over a long run: item forty is reasoned about as sharply as item one. That is the property
the whole loop is built to protect, and it is cheap to lose.

**Never `/compact` between items.** Compaction carries a lossy summary of every prior item forward,
so item five is reasoned about through the haze of items one to four. A worker starts genuinely
fresh, not summarized-fresh, and the difference is the mechanism.

**Consequence.** Keep per-item notes to the one line your report needs, and drop the rest. Anything
that must survive the iteration belongs on the blackboard, not in your window — a worker that
returns state you then carry has moved the state into the wrong place.

## 2. Dispatching a worker

Use the client's fresh-worker mechanism. Claude Code uses the `Agent` tool. Codex uses its named
project roles, except for the drain operative.
Firstmate dispatches that operative asynchronously through its durable task record.
Never replace it with a Codex subagent or direct process in the parent checkout.

Harness workers already run in the background and notify you when one completes.
`run_in_background` is a **Bash** parameter, not an `Agent` one, and passing it to `Agent` is an
input error, not a no-op.
For Codex operative lanes, `run-codex-operative.sh` reports only dispatch acceptance.
Keep the lane occupied until Firstmate surfaces that task's terminal notification, then read the
durable task state before advancing the ticket.

**Concurrent dispatches are the stage's call, never yours.** Where a stage's own doctrine gives it a
capacity — `drain-ready-queue`'s lanes, resolved from `max_lanes`
([SCHEDULER.md](./SCHEDULER.md)) — several workers run at once and you wait for **whichever
completes next**, not for a particular one. Where a stage declares no capacity, one at a time is the
rule and there is nothing here that licenses a second. Either way the dispatch itself is unchanged,
and so is every rail the worker carries: capacity is how many, never how.

**Consequence.** After dispatching, say which item is running — each of them, when several are —
then wait for the next completion notification. Do not poll for it, and do not narrate progress you
cannot see.

## 3. The scripts decide; the skill file explains

Every deterministic arm of a cycle is an executable in that stage skill's own `scripts/` — run each
as `bash "$SKILL/scripts/<name>.sh"`, where `$SKILL` is the skill's base directory, printed when the
skill loads. The SKILL.md prose says what to do with a script's output; it is not a transcript of
what the script does, and the two are not interchangeable.

**Run them as they are.** Each carries defect fixes measured on live runs — shell portability, guard
ordering, `jq` edge cases — that a retyped inline version silently loses. Composing an inline `gh`
one-liner because it looks equivalent is exactly how those fixes get dropped.

**Consequence.** When a script's output surprises you, read the script; never re-implement it
inline. Exit codes and findings lines mean what the calling SKILL.md says they mean — some of these
scripts report a finding *and* exit 0, so a zero exit is not on its own evidence that nothing
happened.

## 4. Every dispatch writes into a scratch directory it made itself

**You and your workers share one scratch directory.** Measured 2026-08-26 on Claude Code 2.1.246: a
worker's scratchpad path is keyed on the **dispatching session's** id, not on the dispatch. An
operative dispatched into its own ephemeral worktree was handed
`<tmp>/claude-<uid>/<project>/<session-id>/scratchpad` — a directory created before that
dispatch existed, already holding files earlier dispatches of the same run had written
(`verdict-168.txt` beside a fixed-name `tests.out`). Worktree isolation covers the repo tree and
nothing else, and concurrency cannot make that path differ, because the key does not vary with the
dispatch.

So a file written straight into that shared directory is a cross-write waiting for a second lane,
and it has happened: a wave of six scorers sharing one `block.txt` corrupted **4 of 56** issues on
2026-08-18, each scorer reporting success
([SCORING.md](../triage-and-score/SCORING.md) holds the measurement and
the detector).

**Consequence. Make your own directory first, then write everything inside it.** One command, at the
start of your dispatch, before the first file:

```bash
mktemp -d
```

`mktemp -d` prints a path no other dispatch holds, so two lanes cannot collide whatever they call
their files. **The directory is the whole rule.** A fixed basename inside a directory of your own is
safe, because the part that varies per dispatch is the directory. This binds the file **you** compose
to hand a script as much as the ones an agent definition names.

**Keep the path, not a variable.** Measured 2026-08-27 on Claude Code 2.1.246: a shell variable set
in one of an agent's commands is empty in the next — each call gets a fresh shell. So read the path
`mktemp -d` printed, and spell it out in full in every command after it. `$scratch` below is
shorthand for that literal path, never a variable you can rely on having set.

**A per-dispatch-unique filename is not a second way to satisfy this rule.** That was the old rule,
and it scaled by memory: every new agent definition, every new skill, and every command that takes a
body file was one more place to remember it, forever.

**Where a number stays in a name, it is a script's contract and not this rule.** Four validators
build the filename from the number and take the directory as their second argument, each defaulting
it to `.` — `validate-block.sh <N> [dir]`, `validate-claim.sh <N> [dir]`,
`validate-verdict.sh <pr> [dir]` and `validate-brief.sh <N> [dir]`. Put `block-<N>.txt` inside your
own `$scratch` and hand the script that directory, or run it from there. The number is in the name
because the script opens that name; the directory is what makes it collision-proof.

`check-skill.sh` and `check-agent.sh` warn on a committed instruction that names a file nothing
varies — no directory of its own, no placeholder — so the half of the rule that is written down gets
read back to you. The warn does not block: it reads prose, it cannot tell a scratch file from a
repository file, and `lib.sh`'s header lists what it misses. The half you improvise at run time it
never sees.
