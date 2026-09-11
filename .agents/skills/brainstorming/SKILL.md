---
name: brainstorming
metadata:
  internal: true
description: Establish the ground before a grilling — what you know, what I verified, and what nobody knows — and write it up as a brief.
disable-model-invocation: true
argument-hint: "the idea you can't state yet"
---

The user arrives with an idea they cannot yet state precisely. Two things then go wrong and compound:
you read the request as a specification, and you read their mechanism guesses as constraints. The
metric is **turns-to-productive** — not answer quality, not thoroughness. Ten turns to reach where one
turn could have landed is the failure, however good the tenth turn is.

## The two ignorances

Say it at the open: _"I wasn't there when this was built, so I'll be leaning on you for most of it —
and where neither of us knows, I'll go and find out."_ Then talk about a fifth as much as they do.

Two ignorances close in one loop. They do not know the options or the vocabulary. **You do not know
the system** — your greps and your priors are both guesses, and you cannot grep for what you don't
know to look for. So your questions come from **how this class of system fails**, not from what you
just read.

## Three answer states

Every claim, in the session and in the brief, carries one:

- **known** — the user supplied it from lived experience.
- **verified** — you went and got it. Carries what was run, against what, and when.
- **unknown** — nobody knows. It becomes a research task in this session, or it travels to the brief
  marked open.

An unknown is never promoted to a decision. This is the guard, and it is load-bearing: this skill
generates claims _about the system_, and a verified-sounding claim is far easier to bank than a
recommendation. Plausible-wrong with a citation attached is the thing this skill is most likely to
ship, and the states are what catch it.

## One move per turn: reflect

Say back what they said. That is the move — hearing their own idea in different words makes them
re-read it, and they move themselves toward what they meant. Resist adding to it: no
reflect-and-commit-further-and-list-doubts. The mirror's power is that you are not in it.

- **Take responsibility first.** _"I want to check that I've followed that"_ — never _"I want to check
  you've explained it."_ The burden is yours every time.
- **Chunk and check.** Reflect per concept as you go; holding it to the end gives them nowhere to start.
- **Their words are the test; yours are the probe.** Paraphrase, so the re-read fires. Where one of
  their terms is load-bearing, offer a concrete either/or rather than picking for them — _"when you say
  ssh and 1Password, do you mean X or Y?"_ That buys the re-read without leading.
- **A parrot is a false pass.** Your own sentence handed back has checked nothing.
- **Reflect at the grain of a decision**, not the grain of the session.
- **Vary the route; never re-ask.** Ten angles find more; ten repetitions find nothing.
- **Weight late arrivals lower.** What surfaces on the third pass is less reliable than what was said
  first, so record _when_ a claim arrived, not only what state it is in.

These moves are practice-backed, not evidence-backed — see [`EVIDENCE.md`](EVIDENCE.md) before citing
any of them as established. They are a menu to try, not a protocol to obey.

## Triage, then go and get it

Pick **1–3 topics** and work those. Everything else waits; dumping the whole surface is how the
interviewer wastes the session.

Going and getting evidence is the point here, not a side-effect. Mapping the option space is your
work — _"it doesn't exist"_ and _"someone solved this better another way"_ are findings. **Choosing
among the options is not.** Present options with their costs and stop; the choosing is `/grilling`.

Where the evidence sits in a system you can't reach, write the exact query and have the user run it —
the `/wizard` pattern.

## The ceiling

**Three rounds.** Within a round, a chunk is done when they describe it back correctly in their own
words. Rounds end whether or not every chunk landed; what did not land goes to the brief as unknown.

Simple does not imply terminating. Pure reflection has its own runaway mode — every turn is _"so what
I'm hearing is…"_ and nothing advances. The ceiling is the only thing that stops it, so it holds
however simple the move has become.

## The exit gate

Three yes/no questions, asked once, at the end:

1. **Did we learn anything worth acting on?** No → the brief _is_ the deliverable, a verified negative.
   Stop.
2. **Is it bigger than a session?** Yes → clear context, then `/wayfinder` charts it.
3. **Are preferences still unsettled?** Yes → clear context, then `/grill-with-docs` → `/to-spec` →
   `/to-tickets`. This is the normal, healthy ending, not a fallback.
4. Otherwise → `/to-spec` in this session; the decisions are live in the conversation, so no clear.

Three of the four are non-success, and all four are legitimate results — leaving is an outcome, not a
failure to converge.

An exit that lands on `/to-spec` — 3 and 4, and 2 once wayfinder's map clears — sizes the hand-off
against [SIZING.md](../to-spec/SIZING.md) — a path relative to **this file** — the single home for
how big one spec should be. If the `to-spec` skill is not installed beside this one that file is
absent: say so and size the hand-off by judgement, rather than inventing the rule.

**Exit 1 carries the strictest bar of the four.** _"Not possible"_ stops work permanently and is
unfalsifiable from the user's side, so it ships with what was run, against what, and when — or it
ships as _"we could not establish that it is possible"_, which is a weaker and different claim. State
it as cheap and blameless: twenty turns into research is maximum pressure to justify the spend with an
artifact, and this is the exit that pressure eats first.

**Size is a finding, not an entry condition.** You cannot size an unknown before probing it, so exit 2
is detected after the work, never at the door.

## The brief

Always written, in all four cases. The exit decides what happens _after_ the brief, never whether it
gets written. Publish it to the project issue tracker under the `brief` label — the tracker's
conventions should have been provided to you; run `/setup-engineering-skills` if not. It takes no
triage label: a brief is ready for a grill, and the exit gate already chose the next actor.

It carries the three answer states and nothing else:

- **Known** — what the user supplied from experience, in their own words.
- **Verified** — each finding with what was run, against what, and when.
- **Unknown** — marked open. Never promoted.
- **Options and their costs**, where the option space was mapped. No pick.

A brief is not a spec: a spec states a solution, a brief states the ground a solution will be argued
on. Nor is it a handoff — a handoff continues the same work, and this changes the kind of work.

**Done when a fresh agent holding none of this conversation can read the brief and run a useful grill
session from it.** Read it back as though you had never seen the session; that is the check.

Then clear context. Nothing of value dies at the clear: the user's gain is internalised — they carry
the clarified idea out in their head — and yours was never in your head, it is evidence, already
written down with dates.
