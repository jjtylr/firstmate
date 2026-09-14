<!-- loop-config v2 -->

# Agentic loop: per-repo parameters

Read by `drain-ready-queue`, `triage-and-score`, and `to-tickets`. **Logic lives in those skills;
this file holds only this repo's parameters** — a rule that isn't a number, path, or short command
here belongs in the plugin, not in this file. Generated and reconciled by
`/setup-engineering-skills` (Section D); edit it directly as the repo's measurements change.

This file is **complete on its own**: every key a loop consumer needs is present here, with no
runtime fallback to plugin defaults. Keys marked **fleet default** start from the plugin's
declarations (`LOOP-DEFAULTS.md`, in the setup skill's folder — setup-time input only). A repo
that deliberately deviates from a fleet default writes a one-line justification beside its value,
so deviations are grep-able; there is no separate overrides section.

## gates

**What:** the commands the operative runs after its final edit, in order; a conditional gate names
the paths that arm it. Deterministic and exit-coded only — behavioural checks are verification
activities, not gates.
**Read by:** `drain-ready-queue` — copied into every dispatch brief (and, once the verifier
exists, re-run independently by it).
**Required:** yes. A deliberately row-less table means operatives run nothing and every PR rests
on review alone — write that only on purpose, and say why beside the table.

| Gate | When |
|---|---|
| `<test command>` | always |
| `<conditional command>` | paths matching `<glob>` touched |

## merge_policy

**What:** who presses the merge button — a policy **name** from the plugin's catalog, plus one
line of why this repo runs it. The catalog defining each policy's behavior is `MERGE-POLICY.md`,
beside the drain skill's doctrine in the plugin — never this file; it currently carries `pm-merge`,
`auto-on-verdict`, and `auto-on-verdict-no-ci`.
**Read by:** `drain-ready-queue`, at the merge step.
**Required:** yes. A missing name, or one the catalog does not carry, reads as `pm-merge` — the
safe direction is "don't merge".

`pm-merge` — the PM merges every PR.

## merge_method

**What:** the `gh pr merge` method used when a PR from this loop merges. **Fleet default:**
`squash` (declared in `LOOP-DEFAULTS.md`).
**Read by:** whoever executes the merge step — the PM under `pm-merge`, the drain's script-gated
merge under an auto policy; recorded here so a scripted merge step reads a value instead of
guessing one.
**Required:** yes.

`squash`

## auto_merge_checkin

**What:** under an auto merge policy, the number of auto-merged PRs after which the run
pauses for a PM check-in — the unattended brake, replacing the ~4-unreviewed-PRs stop that applies
under `pm-merge`. **Fleet default:** `5` (declared in `LOOP-DEFAULTS.md`).
**Read by:** `drain-ready-queue`, at its stop conditions; ignored under `pm-merge`.
**Required:** only under an auto policy.

`5`

## effort_threshold

**What:** the maximum `AGENT-EFFORT` score the drain loop dispatches; a candidate scored above it
is bounced to `needs-info` with a comment asking for a split. **Fleet default:** `3` (declared in
`LOOP-DEFAULTS.md`).
**Read by:** `drain-ready-queue`; `triage-and-score` cites it when scoring against the bands.
**Required:** no. Deliberately empty means no effort gate — the drain dispatches any ready
candidate regardless of score.

`3`

## max_lanes

**What:** the drain's concurrent capacity — how many tickets it may hold in flight at once. Legal
vocabulary `{1, 2, 3}`. **Fleet default:** `1` (declared in `LOOP-DEFAULTS.md`).
**Read by:** `drain-ready-queue`, through `scripts/resolve-lanes.sh` — the script that prints the
count in force and owns every reading below.
**Required:** yes. Any other reading — absent key, `0`, above `3`, non-integer — resolves to `1`
with a findings line, and so does any value above `1` under a `merge_policy` that is not an auto
policy: parallel lanes need the serialized merge pipeline an auto policy runs. A typo degrades to
the serial drain, never to uncontrolled parallelism.

`1`

## global_locks

**What:** path globs that serialize across **all** lanes — a candidate whose ticket declares the
lock (`Locks: <name>`), or whose PR matches the glob, waits while any open loop PR touches it.
**Read by:** `drain-ready-queue`.
**Required:** no. Often empty — a row-less table registers no lock, so no candidate is held for one.

| Lock | Glob |
|---|---|
| `<name>` | `<glob>` |

## workspace_setup (optional)

**What:** command run inside the fresh ephemeral worktree before the gates — only for a repo whose
gates need provisioning a bare checkout lacks.
**Read by:** `drain-ready-queue` — injected into every dispatch brief.
**Required:** no. Empty means a bare worktree suffices; verify by running the gates in one before
writing anything here.

```
(empty)
```

## brief_addendum

**What:** freeform rails injected **verbatim** into every dispatch brief (and later every verifier
brief). This is where a repo's non-negotiables travel — nothing load-bearing may live only in repo
docs the skill would have to know to cite. Fleet rails declared in `LOOP-DEFAULTS.md` land here at
setup, above the repo's own (the fleet currently declares none).
**Read by:** `drain-ready-queue`.
**Required:** no. "(none)" means briefs carry no extra rails.

> (none)

## scoring

**What:** the numbers for `triage-and-score`'s rubric. The rubric's **structure** — axes, gates,
block format, defensive queries — lives in the plugin (`skills/triage-and-score/SCORING.md`);
these are this repo's **measurements**, and they are meaningless in any other repo (cross-repo
score comparability is a non-goal).
**Read by:** `triage-and-score`.
**Required:** no. An unmeasured repo keeps the tables row-less under a dated "not measured yet —
run the command below" note — never angle-bracket placeholders in a written file — and the scorer
falls back to the plugin's repo-neutral exemplars until local anchors exist.

### Effort quintiles (added lines per merged PR)

Measured `<date>` with:
`gh pr list --state merged --limit 120 --json number,changedFiles,additions,deletions`

| E | Added lines | Anchor (issue → PR) |
|---|---|---|
| 1 | ≤ `<p20>` | `<#issue → PR #n, +a/-d>` |
| 2 | `<p20+1>`–`<p40>` | |
| 3 | `<p40+1>`–`<p60>` | |
| 4 | `<p60+1>`–`<p80>` | |
| 5 | > `<p80>` | |

### Value anchors

One named issue per band, following the plugin ladder (silent wrongness > recurring cost >
fictional guard > handled friction > hygiene).

| V | Anchor |
|---|---|
| 5 | `<#issue — one line>` |
| 4 | |
| 3 | |
| 2 | |
| 1 | |

### PM-cost anchors

| P | Anchor |
|---|---|
| 0 | `<#issue — fully specified>` |
| 1 | |
| 2 | `<#issue — the unanswered scope question>` |
| 3 | |
