# Codex operative runner

Codex 0.154 project roles do not solve operative isolation. `spawn_agent` accepts an agent type but
inherits the parent's working directory. An operative edits, commits and pushes, so dispatching it
there can change the orchestrator's checkout and two lanes can cross-write.

Use the bounded runner from the repository root:

```bash
bash "$SKILL/scripts/run-codex-operative.sh" <N> <SLUG> <absolute-brief-file>
```

The call blocks until that one operative returns, times out, or is interrupted. Start cleared lanes
as parallel shell tool calls, one runner invocation per lane, and take whichever call returns first.
Each process creates or acquires one owned worktree under the main checkout. It proves the posted
lane claim's ticket and branch. It then uses the worktree as both the `codex exec` process directory
and explicit `-C` root. The command uses Codex's `workspace-write` sandbox with automatic approval.
It does not bypass project trust or hook trust.

The project-local `operative` agent role is a guard. If someone uses `spawn_agent` with that role,
it tells the parent to use this runner and stops. The real operative starts as a fresh `codex exec`
and reads [the operative role](./agent-roles/operative.md) from its isolated checkout.

## Outcomes

The runner prints the operative's final message between `CODEX-OPERATIVE-RECAP-BEGIN` and
`CODEX-OPERATIVE-RECAP-END`. It then prints exactly one outcome.

- `CODEX-OPERATIVE-PR` means an open PR points at the clean local branch head. Relay the recap and
  continue with independent verification.
- `CODEX-OPERATIVE-STOPPED` means no unlanded work remains. Apply the normal STOPPED procedure when
  the recap says the ticket stopped.
- `CODEX-OPERATIVE-FAILED-STARTUP` means Codex failed before it produced work. Clear the dead
  dispatch through the existing `died` path.
- `CODEX-OPERATIVE-UNLANDED`, `CODEX-OPERATIVE-TIMEOUT`, and `CODEX-OPERATIVE-INTERRUPTED` preserve
  any worktree and branch. Relay the path and stop filling that lane. The PM decides whether to
  resume, salvage, or discard it.
- `CODEX-OPERATIVE-REFUSED` means isolation, ownership, the committed bootstrap, or claim binding
  could not be proved. Stop. Never replace the refusal with a direct `codex exec` call.

The normal reap recognizes the runner's Git worktree lock. A live process stays untouched. A dead
process with no PR produces `REAP-HELD-DEAD`. Cleanup removes only empty stopped work or a clean
merged branch. Closed PRs, dirty trees, unpushed commits, mismatched PR heads, and unreadable host
state all stay in place.
