---
name: to-spec
metadata:
  internal: true
description: Turn the current conversation into a spec and publish it to the project issue tracker — no interview, just synthesis of what you've already discussed.
disable-model-invocation: true
---

This skill turns the current conversation and your understanding of the codebase into a spec. The decisions have already been made — in the grilling, in a prototype, in a map that cleared — so the work here is synthesis, not interview. Reaching for a question is the signal that something the conversation already settled is being re-opened; go back and find where it was settled.

The issue tracker and triage label vocabulary should have been provided to you — run `/setup-engineering-skills` if not.

## Process

1. Explore the repo to understand the current state of the codebase, if you haven't already. Use the project's domain glossary vocabulary throughout the spec, and respect any ADRs in the area you're touching.

2. Sketch out the seams at which you're going to test the feature. Existing seams should be preferred to new ones. Use the highest seam possible. If new seams are needed, propose them at the highest point you can. The fewer seams across the codebase, the better - the ideal number is one. Where you propose more than one, say why one won't do.

Check with the user that these seams match their expectations.

3. Draft the spec using the template below. Size it against [SIZING.md](SIZING.md) — the single home for how big one spec should be. Do not publish yet.

4. **Offer a red-team.** Ask the user one question: do they want a second opinion on the draft
   before sign-off? Recommend yes when the spec changes loop safety, merge behavior, or a
   cross-skill contract.

   On yes: dispatch one fresh sub-agent — no session history, just the draft spec and the repo —
   briefed to argue the strongest case against it: technical risks, a simpler alternative the
   draft missed, mismatches with how the codebase actually works, decisions the draft states that
   the conversation never settled. Fix what it catches; anything material that changes what the
   user would experience goes back to them as a question in their vocabulary.

5. **Confirm the direction with the user.** Summarize the spec in plain language — what problem
   it solves, what was decided, and what the document contains — short enough that they never
   need to read the full spec. Note in one line whether the red-team ran. Ask: is this the thing
   you asked for? Publish only after they confirm.

6. Publish the spec to the project issue tracker. Apply the `spec` label and no triage state
   label — a spec is a category, not pipeline work; it is consumed by `/to-tickets`, and the
   drain's `pick.sh` excludes `spec`-labeled issues from its queue.

   Where the tracker supports milestones, ask the PM which milestone this spec's tickets belong to
   (offer the spec's title; an existing "general" bin is a fine answer), create it if it doesn't
   exist, and set it on the spec issue — `/to-tickets` reads it from there so every ticket inherits
   it consistently, and the drain can be scoped to it (ADR 0003).

7. **Touch the atlas — only when `docs/atlas/` exists and the spec names an area.** Link the
   published spec from that area's file and move the axes exactly as
   [TOUCH.md](../atlas/TOUCH.md) states; a spec may move *Understood*,
   never *Built*. Then **read the atlas back**: re-read the area file, confirm the link and the
   axis lines, and run `../atlas/scripts/atlas-touch.sh`. Both of those paths are relative to
   **this file**, not to the repo you are working in. The script regenerates the index from the area
   files and then checks, and it must exit 0. No `docs/atlas/`, or no area on the spec: touch nothing
   and say so in one line. And if the `atlas` skill is not installed beside this one, both paths are
   absent — say that in one line and touch nothing, rather than guessing at the rule.

<spec-template>

Area: <the atlas area this spec advances, or omit the line entirely — see step 7>

## Problem Statement

The problem that the user is facing, from the user's perspective.

## Solution

The solution to the problem, from the user's perspective.

## User Stories

A LONG, numbered list of user stories. Each user story should be in the format of:

1. As an <actor>, I want a <feature>, so that <benefit>

<user-story-example>
1. As a mobile bank customer, I want to see balance on my accounts, so that I can make better informed decisions about my spending
</user-story-example>

This list of user stories should be extremely extensive and cover all aspects of the feature.

## Implementation Decisions

A list of implementation decisions that were made. This can include:

- The modules that will be built/modified
- The interfaces of those modules that will be modified
- Technical clarifications from the developer
- Architectural decisions
- Schema changes
- API contracts
- Specific interactions

Do NOT include specific file paths or code snippets. They may end up being outdated very quickly.

Exception: if a prototype produced a snippet that encodes a decision more precisely than prose can (state machine, reducer, schema, type shape), inline it within the relevant decision and note briefly that it came from a prototype. Trim to the decision-rich parts — not a working demo, just the important bits.

## Testing Decisions

A list of testing decisions that were made. Include:

- A description of what makes a good test (only test external behavior, not implementation details)
- Which modules will be tested
- Prior art for the tests (i.e. similar types of tests in the codebase)

## Out of Scope

A description of the things that are out of scope for this spec.

## Further Notes

Any further notes about the feature.

</spec-template>
