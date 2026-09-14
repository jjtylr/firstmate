# Spec Sizing

How big one spec should be. This file is the single home for the rule — a skill or session where
sizing arises points here and does not restate it. The recorded failure mode this exists for is
the oversized spec: bitten off, not chewed, and only discovered mid-flight.

## Upper bound — one grill session, one problem statement, one demo

A spec is at most:

- **One grill session.** Every decision the spec states was settled in a single sitting. If the
  decisions will not fit in one session, it is more than one spec — or it is fog, and `/wayfinder`
  territory.
- **One problem statement.** The spec names one problem. An "and" joining two unrelated pains is
  two specs.
- **One demo.** Done is showable as a single demonstration. Needing two demos to show it works
  means it splits.

Apply this bound before work starts — at the routing branch, at the brainstorm's exit gate, at the
draft — never mid-flight.

## Lower bound — tickets within the effort threshold

A spec has decomposed far enough when **every ticket it yields is within the repo's
`effort_threshold`** — the drain loop's per-ticket effort cap, whose value lives in each repo's
loop doc. This file states the relationship, not the number.

That is the floor. Once the tickets fit the threshold, stop: splitting the spec itself any further
buys nothing the decomposition did not already buy, and shreds one coherent decision record into
confetti.

## Severability — a candidate heuristic, not a rule

**One spec = one severable area whose blockers are already lit.** Cut the spec at a boundary where
the work inside depends on nothing still undecided outside it — its blocking edges are already
visible and stated, not waiting to be discovered mid-build.

This is a **candidate** with exactly one data point: the darkpoolz platform map, where the
Connectivity area severed cleanly along this line. One observation does not make a rule. Use it as
a tiebreaker when the two bounds above leave more than one carving open, and record whether it
held — promotion takes more data points.
