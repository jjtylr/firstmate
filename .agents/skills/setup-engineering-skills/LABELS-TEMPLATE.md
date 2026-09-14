# Labels

This repo's label vocabulary is **not defined here.** It belongs to the toolkit plugin and is
identical in every repo the skills run in — which is what lets a skill name a label literally
instead of resolving it through a per-repo mapping. Nothing in this file is a local decision, and
editing it changes nothing.

## Where the canon is

`LABELS.md`, in the toolkit's `setup-engineering-skills` skill directory — states, categories, and
what each label asserts. A skill reads it as `../setup-engineering-skills/LABELS.md`, a path
resolved against the skill file doing the reading. That path means nothing from this repo's root,
so from a shell here — the first line finds the `npx skills` copy, the second the Claude Code
plugin's:

```sh
find .agents/skills -path '*setup-engineering-skills/LABELS.md' -print -quit
find ~/.claude/plugins/cache -path '*setup-engineering-skills/LABELS.md' -print -quit
```

## The strings

Convenience copy, current as of the install stamped at the bottom. The plugin is what counts.

**States** — an issue carries exactly one, or none. No state means it is not in the pipeline, which
is how specs, briefs, and wayfinder maps stay out of every queue:

`needs-triage` · `needs-info` · `ready-for-agent` · `ready-for-human` · `wontfix`

**Categories** — any number, invisible to queue selection:

`spec` · `brief` · `wayfinder:map` · `wayfinder:research` · `wayfinder:prototype` ·
`wayfinder:grilling` · `wayfinder:task` · `run-log` · `claimed` · `bug` · `documentation` ·
`enhancement`

`claimed` is display only. It mirrors the drain's lane claim so the tracker shows what is in
flight; the claim comment on the ticket is what every script reads.

## Checking this repo against the canon

Reports what the tracker is missing and changes nothing:

```sh
find .agents/skills ~/.claude/plugins/cache \
  -path '*setup-engineering-skills/scripts/create-labels.sh' -print -quit \
  | xargs -I{} bash {} --check
```

Drop `--check` to create what is missing. It never modifies a label that already exists.

---

Installed by `/setup-engineering-skills` on `<date>`.
