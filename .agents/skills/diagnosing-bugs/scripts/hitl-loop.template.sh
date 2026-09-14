#!/usr/bin/env bash
# Human-in-the-loop reproduction loop.
# Copy this file, edit the steps below, and have the USER run it. It reads
# answers from a terminal, and a Bash tool call has none: stdin is closed, the
# first `read` fails, and under `set -e` the script ends with nothing captured.
#
# Usage, in Claude Code, typed by the user so the prompts reach their terminal
# and the KEY=VALUE lines land in the conversation:
#   ! bash hitl-loop.template.sh
# Or in their own shell, pasting the KEY=VALUE lines back.
#
# Two helpers:
#   step "<instruction>"          → show instruction, wait for Enter
#   capture VAR "<question>"      → show question, read response into VAR
#
# At the end, captured values are printed as KEY=VALUE for the agent to parse.
#
# `capture` prints its value back to the terminal, where the agent reads it — so
# capture observations, and leave signing in to the user as a `step`.

set -euo pipefail

# `read` fails at end of input, which is what a Bash tool call hands this
# script: no terminal, so no human. Say so, instead of letting `set -e` end the
# run on a bare read with nothing captured and nothing explained.
no_input() { # <the prompt that was waiting>
  printf '\nHITL-NO-INPUT: stdin ended at "%s". This script needs a human at a terminal. Run it with `! bash <path>` in Claude Code, or in your own shell, and paste the KEY=VALUE lines back.\n' "$1" >&2
  exit 1
}

step() {
  printf '\n>>> %s\n' "$1"
  read -r -p "    [Enter when done] " _ || no_input "$1"
}

capture() {
  local var="$1" question="$2" answer
  printf '\n>>> %s\n' "$question"
  read -r -p "    > " answer || no_input "$question"
  printf -v "$var" '%s' "$answer"
}

# --- edit below ---------------------------------------------------------

step "Open the app at http://localhost:3000 and sign in."

capture ERRORED "Click the 'Export' button. Did it throw an error? (y/n)"

capture ERROR_MSG "Paste the error message (or 'none'):"

# --- edit above ---------------------------------------------------------

printf '\n--- Captured ---\n'
printf 'ERRORED=%s\n' "$ERRORED"
printf 'ERROR_MSG=%s\n' "$ERROR_MSG"
