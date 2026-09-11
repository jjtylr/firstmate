# Fleet defaults

The fleet's current values for the loop keys every repo shares. Same ownership pattern as
[LABELS.md](./LABELS.md): the plugin declares, the setup skill installs.

**Setup-time input only.** This file is read by `setup-engineering-skills` — on first run and on
reconciling reruns — and by nothing else. Loop consumers read one complete per-repo
`docs/agents/loop.md`; there is no runtime fallback to this file and no absent-key semantics,
because every key a consumer needs is present in the repo file it reads.

## Declarations

| Key | Fleet value |
|---|---|
| `effort_threshold` | `3` |
| `merge_method` | `squash` |
| `auto_merge_checkin` | `5` |
| `max_lanes` | `1` |
| `fleet_rails` | (none) |

- **`effort_threshold`** — the maximum `AGENT-EFFORT` score the drain loop dispatches before
  bouncing a candidate to `needs-info` for a split.
- **`merge_method`** — the `gh pr merge` method used when a loop PR merges.
- **`auto_merge_checkin`** — under an auto merge policy, the number of auto-merged PRs
  after which an unattended run pauses for a PM check-in; ignored under `pm-merge`.
- **`max_lanes`** — the drain's concurrent capacity, `{1, 2, 3}`. `1` is the fleet value: a repo
  raises it only after its own prerequisites and against captured ledger evidence, and a value
  above `1` is legal only under an auto merge policy.
- **`fleet_rails`** — brief-addendum lines every repo's dispatch briefs should carry, written into
  the repo's `brief_addendum` at setup above its own rails. Currently none: an empty declaration
  writes nothing.

## Changing a fleet value

Edit the declaration here, then rerun `/toolkit:setup-engineering-skills` in each repo where the
change should land. The reconciler presents the delta with its source ("fleet default changed")
and writes it per-section; propagation latency is one rerun per repo, accepted by design.

## Deviating in one repo

A repo may deviate: its `loop.md` carries the deviating value with a one-line justification beside
it, so deviations are grep-able — there is no separate overrides section. On rerun, a justified
deviation is recorded intent, not a delta to present; a difference carrying no justification is
presented as a delta.
