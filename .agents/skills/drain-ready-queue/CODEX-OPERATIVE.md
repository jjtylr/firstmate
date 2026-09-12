# Codex operative runner (Firstmate adaptation)

Firstmate owns worker dispatch, isolation, harness selection, trust handling, and merge authority.
The upstream toolkit runner's private `codex exec` path is not used after installation here.

1. Create the task brief with Firstmate's `bin/fm-brief.sh`.
2. Spawn it with `bin/fm-spawn.sh <task-id> <project-dir> --mode <mode> --yolo <on|off> --harness codex`.
3. Supervise the task through Firstmate's normal durable records and merge owner.

For callers that still use the upstream three-argument interface, the adapted
`run-codex-operative.sh` verifies `FM_HOME`, `FM_TASK_ID`, and that the supplied brief matches
`$FM_HOME/data/$FM_TASK_ID/brief.md`, then delegates to `bin/fm-spawn.sh`. It prints
`CODEX-OPERATIVE-DISPATCHED` when that handoff succeeds and `CODEX-OPERATIVE-REFUSED` otherwise.
It never falls back to a direct Codex process or to the parent checkout.
