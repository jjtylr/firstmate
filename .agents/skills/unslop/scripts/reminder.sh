#!/usr/bin/env bash
# SessionStart and UserPromptSubmit hook: remind a session that all prose goes
# through the unslop skill. Claude and Codex use different explicit invocation
# syntax, so the caller selects the client-specific line.
#
#   reminder.sh session         Claude SessionStart
#   reminder.sh prompt          Claude UserPromptSubmit
#   reminder.sh codex-session   Codex SessionStart
#   reminder.sh codex-prompt    Codex UserPromptSubmit
#
# Contract: always exit 0. An unknown argument prints nothing. The script does
# not read stdin.
set -uo pipefail

case "${1:-session}" in
  session)
    cat <<'MSG'
[toolkit] You MUST use the toolkit:unslop skill before you write anything.
It governs ALL prose, always: your replies to me, documents, README and comment
text, commit messages, PR and issue text. Every reply, every file, no exceptions.
Run it before you send, not after.
MSG
    ;;
  prompt)
    echo '[toolkit] You MUST use toolkit:unslop on ALL prose. Every reply, every file, no exceptions.'
    ;;
  codex-session)
    cat <<'MSG'
[toolkit] You MUST use $unslop before you write anything.
It governs ALL prose, always: your replies to me, documents, README and comment
text, commit messages, PR and issue text. Every reply, every file, no exceptions.
Run it before you send, not after.
MSG
    ;;
  codex-prompt)
    echo '[toolkit] You MUST use $unslop on ALL prose. Every reply, every file, no exceptions.'
    ;;
esac

exit 0
