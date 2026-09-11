---
name: setup-engineering-skills
metadata:
  internal: true
description: Configure this repo for the engineering skills — record its issue tracker, install the plugin's label vocabulary, and set up its domain doc and agentic-loop config. Run once before first use of the other engineering skills; rerun any time to reconcile the generated files against the current plugin.
disable-model-invocation: true
---

# Setup Engineering Skills

Scaffold the per-repo configuration that the engineering skills assume:

- **Issue tracker** — the repo's GitHub Issues, and how the skills address them
- **Labels** — the plugin's fixed label vocabulary, installed into the tracker
- **Domain docs** — where `CONTEXT.md` and ADRs live, and the consumer rules for reading them

**Where the paths below point.** A `../<skill>/FILE.md` path resolves against **this file**: both install shapes — the Claude Code plugin's `skills/` and the `npx skills` vendored `.agents/skills/` — put every skill directory side by side. If a named sibling skill is not installed its files are simply absent: say which one you could not read and take the stated fallback, never recite it from memory.

This is a prompt-driven skill, not a deterministic script. Explore, present what you found, confirm with the user, then write.

## Process

### 1. Explore

Look at the current repo to understand its starting state. Read whatever exists; don't assume:

- `git remote -v` and `.git/config` — is this a GitHub repo? Which one?
- `AGENTS.md` and `CLAUDE.md` at the repo root — does either exist? Is there already an `## Agent skills` section in either?
- `CONTEXT.md` and `CONTEXT-MAP.md` at the repo root
- `docs/adr/` and any `src/*/docs/adr/` directories
- `docs/agents/` — does this skill's prior output already exist?
- Which of the plugin's labels the tracker already has — run `./scripts/create-labels.sh --check` from this skill's folder, which reports and changes nothing.
- Are the loop skills installed? (`drain-ready-queue` or `triage-and-score` alongside this one, or in your available skills.) This decides whether Section D runs at all. Also check whether `docs/agents/loop.md` already exists — prior output to update, not overwrite.
- Monorepo signals — a `pnpm-workspace.yaml`, a `workspaces` field in `package.json`, or a populated `packages/*` with its own `src/`. Present only in a genuinely large multi-package repo; their absence means single-context, which is almost every repo.

### 2. Present findings and ask

Summarise what's present and what's missing. Then take the sections in order — one section, one answer, then the next.

Lead each section with the recommended answer so the user can accept it in a word. Give a one-line explainer only when the choice genuinely branches; skip the section entirely when exploration already settled it (Section B when `triage` isn't installed, Section C when there's no monorepo).

**Section A — Issue tracker.**

> Explainer: The "issue tracker" is where issues live for this repo. Skills like `to-tickets`, `triage`, and `to-spec` read from and write to it — they need the concrete commands, which is what `docs/agents/issue-tracker.md` records. These skills are built for GitHub Issues; that is what this section writes unless you tell it otherwise.

**GitHub is the only tracker this skill ships a template for.** If a `git remote` points at GitHub, confirm it in one line and move on — this is a confirmation, not a menu.

If there is no GitHub remote, say so and ask before writing anything: the skills' tracker calls are `gh` invocations, so a repo without GitHub Issues needs an **Other** — Jira, Linear, GitLab, a directory of markdown files, whatever the user actually uses. Ask them to describe the workflow in one paragraph and record it as freeform prose. Say plainly that the skills have not been exercised against it and the prose is what they will follow.

Record the choice in `docs/agents/issue-tracker.md`. The GitHub template carries a "PRs as a request surface" flag, defaulted **off** — leave it off and don't raise it; a user who wants external PRs in the triage queue can flip the flag in the file later.

**Section B — Labels.**

> Explainer: the label vocabulary is the plugin's, not this repo's — 15 strings that mean the same thing in every repo the skills run in, which is what lets a skill name one literally instead of looking up a mapping. It is defined in [LABELS.md](./LABELS.md) and there is nothing to choose here. This section only installs what the tracker is missing.

Show the user the `--check` output from exploration — the missing labels, named — and ask for a go-ahead, because this writes to their tracker. On yes:

```sh
./scripts/create-labels.sh
```

It creates only what is absent and never modifies a label that already exists, so a repo whose `wontfix` carries GitHub's stock description keeps it. Report what it created. If the user declines, say plainly which skills will not work: the loops select on `ready-for-agent` and `needs-info`, `to-spec` stamps `spec`, and `wayfinder` needs all five `wayfinder:*` labels.

Then write `docs/agents/labels.md` from [LABELS-TEMPLATE.md](./LABELS-TEMPLATE.md), stamping today's date at the bottom. It is a **pointer, not a definition** — it names where the canon lives, carries the label strings as a convenience copy, and gives the shell commands to resolve the plugin file and re-check the tracker. Neither `${CLAUDE_PLUGIN_ROOT}` nor a skill-relative `../setup-engineering-skills/LABELS.md` resolves from a repo root, so a file in the user's repo must not lean on either; the `find` commands in the template are what make the path reachable, and they cover both install shapes.

**Section C — Domain docs.** Default to **single-context** — one `CONTEXT.md` + `docs/adr/` at the repo root. This fits almost every repo; write it without asking.

Offer **multi-context** — a root `CONTEXT-MAP.md` pointing to per-context `CONTEXT.md` files — only when exploration found monorepo signals. Then confirm which layout they want.

**Section D — Agentic loop parameters.** Skip this section entirely if neither loop skill is installed (exploration told you).

> Explainer: `drain-ready-queue` and `triage-and-score` keep all their logic in the plugin and read this repo's parameters from one generated file, `docs/agents/loop.md` — the gates to run, the max effort to dispatch, the module taxonomy for parallel-dispatch collision checks, and the scoring measurements. Nothing load-bearing may live only in repo docs the skills would have to know to cite; anything of that kind goes in the file's `brief_addendum`, which travels verbatim into every dispatch brief.

The template's first line is the version marker `<!-- loop-config v2 -->`, and it stays the first
line of the file you write — a generated config is born versioned so a consumer can tell which
shape it is reading. Updating a `docs/agents/loop.md` that already exists: keep the marker line it
already carries, verbatim, with one exception — a `v1` marker is rewritten to `v2` during the
migration described under **Rerun** below, the one sanctioned marker change. If the file has no
marker, add the template's. Never drop it, and don't invent a new version number here.

Fleet-standard values come from [LOOP-DEFAULTS.md](./LOOP-DEFAULTS.md) — the plugin's declaration,
setup-time input only. Propose each fleet value as found there; a repo that deliberately deviates
writes a one-line justification beside its value in `loop.md`, so the deviation is grep-able and
survives reconciliation.

Walk the [LOOP-TEMPLATE.md](./LOOP-TEMPLATE.md) keys with the user, in order, proposing what exploration found:

- **`gates`** — propose from what exists: a `Makefile` test target, `package.json` scripts, CI workflow steps. Include conditional gates with their trigger globs (e.g. a migration check when migration paths are touched).
- **`merge_policy`** — the menu is **generated from the plugin's catalog**,
  [MERGE-POLICY.md](../drain-ready-queue/MERGE-POLICY.md) in the drain
  skill's folder: read it and present each entry by name with one plain line on who presses the
  merge button (`pm-merge` — the PM merges every PR; `auto-on-verdict` — the drain orchestrator
  merges when its own verifier passed AND CI corroborates; `auto-on-verdict-no-ci` — the
  orchestrator merges on its verifier's pass alone, for a repo that runs no CI by choice), never a
  freeform policy. **Recommend `pm-merge` for a repo new to the loop**, and state plainly what an
  auto policy gives up: review happens after landing, disagreement means a revert, and the
  verifier's quality becomes load-bearing. **A repo with no CI cannot run `auto-on-verdict`** —
  the drain's decision script refuses `CHECKS-NONE` there, so choosing it behaves as `pm-merge`
  until CI exists; `auto-on-verdict-no-ci` is the explicit single-witness choice for such a repo,
  and picking it means the verifier is the only independent witness — say both plainly before the
  user picks. Write the chosen name plus one line of why. **When an auto policy is chosen, tell the
  user to turn on the host's "require branches to be up to date before merging" protection on the
  base branch** where the host offers it (GitHub: branch protection, or a ruleset's *Require
  branches to be up to date before merging*). The drain's serialized merge pipeline already updates
  and re-verifies before it merges
  ([MERGE-PIPELINE.md](../drain-ready-queue/MERGE-PIPELINE.md)); this
  setting makes the server enforce the same thing independently, so a merge that ever slipped past
  the pipeline still could not land a stale tree. It is a belt to those braces, not a replacement —
  and it is the PM's switch to flip, never the loop's.
- **`merge_method`** — write the fleet default from `LOOP-DEFAULTS.md` (`squash`); a deviating
  repo records its reason beside the value.
- **`auto_merge_checkin`** — write the fleet default from `LOOP-DEFAULTS.md` (`5`); it is read
  only under an auto policy, where it is the unattended run's PM check-in bound.
- **`effort_threshold`** — recommend the fleet default from `LOOP-DEFAULTS.md` (`3`).
- **`max_lanes`** — write the fleet default from `LOOP-DEFAULTS.md` (`1`). A repo raises it only
  after its merge policy has graduated to an auto one, and against its own ledger evidence; above
  `1` under `pm-merge` reads as `1`, as does any value outside `{1, 2, 3}`. Don't offer a higher
  number at setup.
- **`global_locks`** — anything where two open PRs are structurally unsafe even when files differ (schema migrations are the canonical case). Often empty.
- **`workspace_setup`** — leave empty unless the user knows the gates need provisioning a bare checkout lacks. Recommend verifying by running the gates in a bare worktree before filling it.
- **`brief_addendum`** — write any `fleet_rails` from `LOOP-DEFAULTS.md` first (currently none),
  then ask for the repo's own non-negotiable rails, if any.
- **`scoring`** — if the repo has merged-PR history, offer to run the quintile measurement command and fill the effort bands now (stamp date + command); otherwise write the tables row-less under a dated "not measured yet" note — no unfilled `<placeholder>` survives into a written file — and note the ported `triage-and-score` falls back to the plugin's repo-neutral exemplars until local anchors exist.

Beside `loop.md`, create `docs/agents/rulings.md` when it does not exist — **empty**. It is the
standing-rulings file the drain's verifier reads before raising a question the PM has already ruled
on. The PM is its only author: agents never add or edit an entry, and setup never seeds one.

### 3. Confirm and edit

Show the user a draft of:

- The `## Agent skills` block to add to whichever of `CLAUDE.md` / `AGENTS.md` is being edited (see step 4 for selection rules)
- The contents of `docs/agents/issue-tracker.md`, `docs/agents/labels.md`, `docs/agents/domain.md`, and `docs/agents/loop.md` (only when a loop skill is installed and Section D ran)

Let them edit before writing.

### 4. Write

**Pick the file to edit:**

- If `AGENTS.md` exists and `CLAUDE.md` points to it with `@AGENTS.md`, edit `AGENTS.md`.
- Else if `CLAUDE.md` exists, edit it.
- Else if `AGENTS.md` exists, edit it.
- If neither exists, ask the user which one to create — don't pick for them.

Never create `AGENTS.md` when `CLAUDE.md` already exists (or vice versa) — always edit the one that's already there.

If an `## Agent skills` block already exists in the chosen file, update its contents in-place rather than appending a duplicate. Don't overwrite user edits to the surrounding sections.

The block:

```markdown
## Agent skills

### Issue tracker

[one-line summary of where issues are tracked]. See `docs/agents/issue-tracker.md`.

### Labels

The toolkit plugin's fixed vocabulary — 17 labels, five of them pipeline states and the rest categories the queues ignore. Not per-repo, not remapped. See `docs/agents/labels.md`.

### Domain docs

[one-line summary of layout — "single-context" or "multi-context"]. See `docs/agents/domain.md`.

### Agentic loop

[one-line summary — gates and effort threshold]. See `docs/agents/loop.md`.
```

The `### Labels` sub-block and `docs/agents/labels.md` are always written — the vocabulary applies to every repo. Include `### Agentic loop`, and write `docs/agents/loop.md`, only when a loop skill is installed and Section D ran. When they aren't, the blocks are omitted.

Then write the docs files using the templates in this skill folder as a starting point:

- [ISSUE-TRACKER-GITHUB-TEMPLATE.md](./ISSUE-TRACKER-GITHUB-TEMPLATE.md) — GitHub issue tracker
- [LABELS-TEMPLATE.md](./LABELS-TEMPLATE.md) — the `docs/agents/labels.md` pointer (always)
- [DOMAIN-TEMPLATE.md](./DOMAIN-TEMPLATE.md) — domain doc consumer rules + layout
- [LOOP-TEMPLATE.md](./LOOP-TEMPLATE.md) — agentic-loop parameters (only if a loop skill is installed)

For "other" issue trackers, write `docs/agents/issue-tracker.md` from scratch using the user's description.

### 5. Done

Tell the user the setup is complete and which engineering skills will now read from these files. Mention they can edit `docs/agents/*.md` directly later, and that rerunning this skill at any time reconciles the generated files against the current plugin — it presents only what changed and never touches their prose.

## Rerun: the reconciler

Rerunning this skill is idempotent and is how plugin changes — a new template key, a changed fleet
default, a renamed pointer path — reach an already-configured repo. Explore as on a first run;
where step 1 finds prior output, reconcile it instead of re-interviewing. Five rules:

1. **Present only deltas.** Compare each generated file's machine-read content — markers, key
   values, table rows, embedded pointer paths — against the current templates and declarations
   ([LOOP-DEFAULTS.md](./LOOP-DEFAULTS.md), [LABELS.md](./LABELS.md)). Show every delta with its
   source ("fleet default changed", "template gained a key", "pointer path stale") and confirm
   before writing. A fleet-key deviation carrying its one-line justification is recorded intent,
   not a delta.
2. **Edit per-section; PM prose is never rewritten or flagged.** Machine-read content is what the
   skills parse — markers, key values, tables, pointer paths, and the template's What / Read by /
   Required scaffolding. Sentences the user wrote into a generated file are prose and survive
   verbatim, even inside a section being edited.
3. **From-scratch files are checked for stale pointer paths only.** A file written from the user's
   own description (an "Other"-tracker `issue-tracker.md`) has no template to diff against; touch
   nothing in it beyond a pointer path that no longer resolves.
4. **v1 → v2 migration of `loop.md`.** A file whose marker reads `v1` migrates on rerun: every
   repo value carries over (the v1 template always wrote `merge_policy` as `pm-merge`, so that
   value carries), keys the template gained arrive from the current template and declarations, the
   What / Read by / Required scaffolding is added per section, and the marker is rewritten to
   `<!-- loop-config v2 -->` — the one sanctioned marker change.
5. **Renamed plugin files are repaired at every marker version.** A generated file links plugin
   doctrine by path, and the plugin renames those files. Rewrite every link below to its current
   name wherever it appears in a generated file, whatever marker that file carries. This is rule
   1's "pointer path stale" delta with the map written down, so a rerun repairs it rather than
   rediscovering it.

   | Old path | Current path |
   |---|---|
   | `skills/triage/AGENT-BRIEF.md` | `skills/triage/TICKET-BRIEF.md` |

   Only a path a template actually emits can go stale in a repo, so only those get rows. Today the
   templates emit four:

   | Emitted path | Emitted by |
   |---|---|
   | `skills/triage/TICKET-BRIEF.md` | [LOOP-TEMPLATE.md](./LOOP-TEMPLATE.md) |
   | `skills/triage-and-score/SCORING.md` | [LOOP-TEMPLATE.md](./LOOP-TEMPLATE.md) |
   | `skills/setup-engineering-skills/LABELS.md` | [LABELS-TEMPLATE.md](./LABELS-TEMPLATE.md) |
   | `skills/setup-engineering-skills/scripts/create-labels.sh` | [LABELS-TEMPLATE.md](./LABELS-TEMPLATE.md) |

   Rename one of those and add its row above. The last one is a script inside a `find` command a
   human is told to run, not a markdown link, so a missed rename there fails with no output rather
   than an error. Re-derive this list from the templates rather than trusting it. A plugin file no
   template emits needs no row, however widely the plugin links it internally.

   The marker does not move for a rename. It records the config's **shape**, which keys and
   sections a consumer will find, and a renamed link changes neither. Bumping it would push every
   repo through a migration for a link repair this rule already makes, and would leave two
   migration paths to chain.
