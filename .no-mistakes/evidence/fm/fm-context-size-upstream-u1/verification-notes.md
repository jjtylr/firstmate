# Conversation-size live verification

## Product evidence

- `live-verification.py` launched the installed, real Claude Code and Pi CLIs in disposable workspace homes against an explicitly synthetic localhost API. No production login or model was used. The CLIs, not fixtures, wrote the retained `claude-vendor-session-0.jsonl` and `pi-vendor-session-0.jsonl` files.
- The actual `fm-context-size.sh`, `fm-fleet-snapshot.sh --json`, and `fm-fleet-view.sh` read those sessions: Claude reported 250100 input/cache tokens in a 1000000-token window; Pi reported 130000 tokens in a 500000-token window. Output tokens were not included. The Pi catalog was disposable host model-store data; offline Pi initially had no refreshed model store, which correctly retained tokens with an unknown window.
- Additional disposable input records exercised exactly 20%, one token above/below, assistant-call timestamp versus newer file mtime, unknown model/timestamp, unsupported harness, missing log, newest-file selection, later user/malformed records, and assistant usage outside the 4 MB tail. These are synthetic data inputs to the real CLI, not replacement implementations.
- A real OpenSSH client connected to a localhost TCP peer which withheld its SSH banner. The observation became unknown after 3.139 seconds. The full snapshot and view retained the other measured rows.
- Hash and mtime comparisons before/after snapshot and rendering found no changes to fixture session, metadata, or fleet files; no agent lifecycle calls were made.
- `remote-live-verification.py` exercised successful authenticated OpenSSH, the actual `fm-on.sh` argv transport, remote entrypoint, remote job worker, `--remote-self`, and parent snapshot against a disposable Linux container. Its separate home held synthetic Pi input records and its own model store: 324 tokens / 1000 context, 32.4%, OVER. The local host had no such model catalog entry. Source was mounted read-only; a disposable Git index avoided accessing the gate bare repository. SSH keys, user home, package root and other fixture files were workspace-local. The container and imported verification image were removed in the driver's finally block.
- The remote doctor's broader secondmate readiness report still names missing optional-to-this-read tools (Herdr, tasks-axi, treehouse, harness); the actual remote job worker and conversation read nevertheless ran successfully. No Herdr or agent lifecycle was exercised.

## Visual evidence

`fleet-view.md` is the actual CLI output. `fleet-view.html` renders its Markdown table without changing its values, using a simple GitHub-style Markdown presentation. `fleet-view.png` is a full-page Chrome screenshot of that rendering, captured through an isolated browser profile. This is a CLI/Markdown surface, not a proposed GUI.

## Targeted checks and resolved setup problems

Only the four author-proposed subjects and focused comparisons were run; no complete suite or lint/static-analysis phase was run.

1. The first invocation placed TMPDIR inside the repository. The home-summary check correctly refused nested secondmate-home fixtures. Re-running with the toolchain's normal incidental temporary directory removed that setup failure.
2. The default PATH selects Homebrew Bash 5.3.20. Fleet-view and bearings checks produced nondeterministic endpoint/projection failures. The same focused suites from the base commit also failed, and diagnostic inventory observations sometimes retained valid fake tmux output with a nonzero command status. This is not demonstrated as a regression from this change.
3. Re-running the complete targeted command with stock macOS Bash selected for both the runner and child shebangs passed every subject, without skips:

```sh
PATH="/bin:/usr/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:$PATH" /bin/bash bin/fm-test-run.sh tests/fm-context-size.test.sh tests/fm-fleet-snapshot-view.test.sh tests/fm-bearings-snapshot.test.sh tests/fm-home-summary-refresh.test.sh
```

4. The first offline Pi check correctly returned an unknown context window because the fresh agent home had no model store. Supplying the isolated catalog then proved window lookup. No source change was needed.
5. Initial disposable SSH-server provisioning lacked root-owned image metadata, /tmp and full ps support. Rebuilding the workspace-local fixture with root archive ownership, /tmp, and procps fixed setup. The final real SSH scenario and parent snapshot passed.

No permanent source or test changes were made. The only remaining caveat is the pre-existing default-shell fixture nondeterminism; stock-Bash compatibility and all named live conversation-size scenarios passed. Publication/PR/CI are owned by the outer executor and were not run here.
