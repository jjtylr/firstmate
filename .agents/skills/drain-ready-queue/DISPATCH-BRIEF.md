# The dispatch brief

Read by the orchestrator at step 4 of `drain-ready-queue` and sent to the `operative` subagent
**verbatim after substitution**. It carries ticket specifics and repo config only. Every rail lives
in [the operative role](./agent-roles/operative.md), which resolves its own reference files. A rail
restated here will drift from the one the operative actually runs on.

Substitute `<N>`, `<TITLE>` and `<SLUG>`; fill the config's `gates` (each conditional gate with the
paths that arm it) and `<workspace_setup>` if the config sets one; append `brief_addendum` verbatim.
Everything between the rules is the brief.

The `Area:` line is step 2's `area` field, copied through **as it resolved** — omit the line entirely
when that field is `null`, and never infer an area the ticket did not name. What the operative then
does with it is a rail, not a brief line.

---

Work backlog issue **#\<N\> — \<TITLE\>** to an open PR. You own this ticket end to end.

Branch: `agent/<SLUG>-<N>`. The PR body carries `Closes #<N>`.

<If step 2's `area` is non-null: `Area: <area>`>

<If `workspace_setup` is non-empty: run `<workspace_setup>` in your worktree before anything else.>

**This repo's gates**, in order, after your final edit:

<gates, one per line, each conditional gate with its trigger>

<brief_addendum, verbatim>
