# Codex operative runner (Firstmate adaptation)

Firstmate owns worker dispatch, isolation, harness selection, trust handling, and merge authority.
The upstream toolkit runner's private `codex exec` path is not used after installation here.
Use one stable Firstmate task id for each ticket from dispatch through cleanup.

1. Create the task brief with Firstmate's `bin/fm-brief.sh`.
2. Run `FM_TASK_ID=<task-id> FM_TOOLKIT_PROJECT=<project> FM_TOOLKIT_MODE=<mode> FM_TOOLKIT_YOLO=<on|off> bash "$SKILL/scripts/run-codex-operative.sh" <N> <SLUG> <absolute-brief-file>` from the repo root.
3. Supervise the task through Firstmate's durable records, and send requested fixes through `bin/fm-send.sh <task-id> <message>`.
4. Pass the same `<task-id>` as the fifth argument to `merge-pinned.sh`.
5. After the pull request lands, or after a terminal no-change result, run `bin/fm-teardown.sh <task-id>`.

The adapted `run-codex-operative.sh` verifies `FM_HOME`, `FM_TASK_ID`, the explicit project, mode, and yolo inputs, and that the supplied brief matches `$FM_HOME/data/$FM_TASK_ID/brief.md`.
It then delegates to `bin/fm-spawn.sh` and prints `CODEX-OPERATIVE-DISPATCHED` when that handoff succeeds and `CODEX-OPERATIVE-REFUSED` otherwise.
It never falls back to a direct Codex process or to the parent checkout.
The upstream `reap.sh` and `cleanup-stopped.sh` scripts own Claude worktrees only and must not run for a Firstmate-dispatched Codex task.
If `fm-teardown.sh` refuses cleanup, leave the task record, worktree, branch, and lane claim intact and report the refusal.
