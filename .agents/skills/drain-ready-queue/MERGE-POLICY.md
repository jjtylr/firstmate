# The merge-policy catalog

The closed vocabulary for the `merge_policy` key in a repo's `docs/agents/loop.md`. Each entry
defines, once, who presses the merge button: its **trigger** (what state permits a merge), its
**merge-step action** (exactly what the drain orchestrator does at step 6), and its **PM fallback**
(what always goes back to the PM). A repo's `loop.md` carries only a name from this file plus one
line of why — behavior is defined here and nowhere else, so two repos naming the same policy can
never mean different things by it.

**A missing or unknown name reads as `pm-merge`, and is a findings line.** The safe direction is
"don't merge": a config typo degrades to "the PM merges", never to silent auto-merging.

**Adding a policy is adding an entry here.** The setup skill's interview menu is generated from
this catalog, so a new entry becomes an option in every subsequent setup run with no other edits.
The catalog lives beside the drain's doctrine because the drain is the only executor of merge
policy: executing an entry is reading it, not interpreting it.

The `auto-on-verdict*` entries are the **auto policies**: doctrine that says "under an auto
policy" means any entry whose merge-step action is the script-gated chain through
`merge-decision.sh`. They differ only in which checks bucket corroborates; everything else —
verdict provenance, the check-in bound, every PM fallback — is stated once, in `auto-on-verdict`,
and holds for both.

## pm-merge

The default, and the recommendation for any repo new to the loop. The loop never merges; every PR
waits for the PM, exactly as SKILL.md step 6 describes.

- **Trigger:** the PM's own decision, made per PR after reading the relayed recap, the verdict,
  and the CI findings. Nothing the loop measures can trigger a merge.
- **Merge-step action:** none. The orchestrator relays and waits; the next iteration's reap
  collects whatever the PM merged. Running `gh pr merge` under this policy is a rail violation,
  whatever the verdict said. **The serialized merge pipeline does not run either**
  ([MERGE-PIPELINE.md](./MERGE-PIPELINE.md)): no server-side branch update, no freshness read, no
  pinned merge. The merge point here has no loop-side machinery at all, and `merge-pinned.sh`
  refuses under this name before its first host call rather than trusting a caller to know that.
- **PM fallback:** everything — this policy *is* the fallback, which is also why an unknown or
  missing name resolves here.

## auto-on-verdict

The orchestrator merges — but only through the decision script, and only on two green witnesses.
Review happens after landing: disagreement is a revert, and the verifier's quality is
load-bearing.

- **Trigger:** the verifier this orchestrator dispatched **this iteration** returned `pass` under
  the current verdict marker, AND CI corroborates (`pr-checks.sh` printed `CHECKS-PASS`). Only that
  dispatch's returned word is merge input — a verdict block re-read from PR comments is not a
  trigger, and a restarted run re-verifies. A `pass` under a superseded marker is **not** a trigger
  either: it claimed nothing about any commit, so the script reads it as no verdict
  ([VERDICT.md](./VERDICT.md)). `CHECKS-NONE` refuses: under this policy a repo without CI cannot auto-merge (PM
  decision at spec #73 sign-off — a single-witness merge would contradict the two-witness
  doctrine), so it stays effectively `pm-merge` until it has CI. A repo whose no-CI state is a
  choice, not a gap, is `auto-on-verdict-no-ci`'s entry below.
- **Merge-step action:** Run the serialized merge pipeline in [MERGE-PIPELINE.md](./MERGE-PIPELINE.md), one PR at a time.
  Update the branch server-side, wait out the restarted checks, read the head from the host, and verify at exactly that commit.
  Then run the harness-specific chain in [MERGE-PIPELINE.md](./MERGE-PIPELINE.md).
  Claude Code uses the upstream four-argument merge entry point.
  A Firstmate-dispatched Codex task adds its stable task id as the fifth argument.
  `gh pr merge` never runs bare and never unpinned; `merge_policy` and
  `merge_method` come from the repo's `loop.md` and `<verdict-marker>` is the `MARKER` line the
  verifier reported. SKILL.md step 6 is the exact chain; `--delete-branch --repo` is what collects
  the remote loop branch, and RATIONALE § 6 says why `--repo` is required for it to reach the
  remote at all. On `MERGE-PINNED` the PR merged; count it toward the config's `auto_merge_checkin`
  bound (default 5) and pause for a PM check-in when the bound is reached. A `MERGE-PIN-REFUSED`
  re-enters the pipeline once, then parks, and so does a mergeability the host has not finished
  computing. Both spend one shared budget, whose rule MERGE-PIPELINE.md owns.
- **PM fallback:** every other state — `concerns`, `fail`, `refused`, a missing verdict, a
  superseded or missing verdict marker, failing, pending, absent, or unreadable CI
  (`MERGE-REFUSED:<reason>`), a branch update that conflicts or a head the host will not confirm
  (an exit-1 `FRESH-REFUSED:<reason>`), an uncomputed mergeability that re-entered already, a pin
  refused twice, and a merge that fails for anything else
  (`MERGE-FAILED:<reason>` — branch protection, a fresh conflict, an outcome the host could not be
  re-read to explain): a findings line beside the recap, the PR parked open for the PM, never a
  retry.

## auto-on-verdict-no-ci

`auto-on-verdict` for a repo that runs **no CI by choice** (PM decision on #78: the CI
requirement stands for code repos; a skills-and-docs repo whose gates the verifier already
re-runs independently may merge on the verdict alone). Identical to `auto-on-verdict` in every
respect but one: the verifier is the only independent witness, and the entry exists so choosing
that is explicit, never a fallback.

- **Trigger:** the verifier this orchestrator dispatched **this iteration** returned `pass` under
  the current verdict marker, AND the checks line is `CHECKS-PASS` **or** `CHECKS-NONE`. A CI state
  that exists but is not green
  still refuses — if this repo ever gains CI, a red or pending check blocks the merge exactly as
  under `auto-on-verdict`.
- **Merge-step action:** as `auto-on-verdict` — the same chained command; the script reads the
  policy name as its third argument and admits `CHECKS-NONE` only under this name.
- **PM fallback:** as `auto-on-verdict`, minus the absent-CI case: `concerns`, `fail`, a missing
  verdict, a missing checks line, failing, pending, or unreadable CI, and a `gh pr merge` that
  itself fails.
