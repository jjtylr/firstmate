#!/bin/bash
# create-labels.sh [--check] — install this plugin's fixed label vocabulary in
# the current repo's GitHub tracker. Creates what is missing and leaves what is
# already there alone; --check reports drift and changes nothing.
#
# The vocabulary is fixed on purpose (LABELS.md, beside this script's folder). Every repo the
# plugin runs in has the same label strings, so a skill can name one literally
# instead of resolving it through a per-repo mapping — and a queue that
# allowlists `ready-for-agent` means the same thing everywhere.
#
# Creation is deterministic, so it is a script rather than skill prose: the
# `gh label create` calls below have no judgment in them, and a model that
# composes them by hand will eventually mistype a colour or drop a wayfinder
# type. How many there are is counted from the list at run time, never written
# here — a number in this header is a copy that goes stale on the next label.
#
# **Existing labels are never modified.** A repo whose `wontfix` already says
# "This will not be worked on" keeps that description — the string is what the
# skills key on, and rewriting a description that already reads fine would make
# this script destructive for no gain. --check reports the difference so a
# deliberate correction stays possible; it just is not this script's call.
#
# Adding a label to the plugin means editing LABELS.md and the list below
# together. They are canonical only when they agree: this script installs the
# vocabulary, LABELS.md explains it, and a name in one but not the other is a
# label some repo will be missing or some skill will describe and never find.

set -u

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1
if [ $# -gt 0 ] && [ "$CHECK" -eq 0 ]; then
  echo "usage: create-labels.sh [--check]" >&2
  exit 2
fi

command -v gh >/dev/null 2>&1 || {
  echo "create-labels.sh: gh is not installed — the tracker is GitHub Issues" >&2
  exit 1
}
gh repo view --json name >/dev/null 2>&1 || {
  echo "create-labels.sh: not inside a GitHub repo gh can resolve" >&2
  exit 1
}

# name|colour|description. Order is states, then process categories, then kinds
# — the same order LABELS.md presents them in, so a diff between the two files
# reads straight down.
LABELS='needs-triage|e99695|Not yet evaluated
needs-info|fbca04|Blocked until someone answers
ready-for-agent|0e8a16|Fully specified, ready for an unsupervised agent
ready-for-human|1d76db|Real work that needs a human implementer
wontfix|ffffff|Terminal, will not be actioned
spec|9f58af|A published spec. Carries no state label
brief|5319e7|Brainstorming output. Carries no state label
wayfinder:map|006b75|The map issue for one wayfinder effort
wayfinder:research|0e6f7a|Wayfinder ticket, AFK: surface a fact a decision waits on
wayfinder:prototype|0e6f7a|Wayfinder ticket, HITL: build something concrete to react to
wayfinder:grilling|0e6f7a|Wayfinder ticket, HITL: conversation. The default type
wayfinder:task|0e6f7a|Wayfinder ticket: work a decision is blocked on
run-log|c5def5|Log issue for one headless drain run. Carries no state label
claimed|f9d0c4|Display only: the drain holds a lane claim on this ticket
bug|d73a4a|Something is not working
documentation|0075ca|Documentation only
enhancement|a2eeef|A new feature or request'

# Counted from the list, never written as a literal: a label added above and a
# total left at the old number is a report that says the vocabulary is complete
# while naming the wrong size of it.
total=$(printf '%s\n' "$LABELS" | grep -c '[^[:space:]]')

existing=$(gh label list --limit 200 --json name --jq '.[].name') || exit 1

# Membership by exact line match. grep -Fx rather than a case glob because a
# label name contains a colon and may contain characters a glob would eat.
has_label() { printf '%s\n' "$existing" | grep -qFx "$1"; }

missing=0
created=0
while IFS='|' read -r name colour desc; do
  [ -n "$name" ] || continue
  if has_label "$name"; then
    [ "$CHECK" -eq 1 ] && echo "  ok      $name"
    continue
  fi
  missing=$((missing + 1))
  if [ "$CHECK" -eq 1 ]; then
    echo "  MISSING $name"
    continue
  fi
  if gh label create "$name" --color "$colour" --description "$desc" >/dev/null 2>&1; then
    echo "  created $name"
    created=$((created + 1))
  else
    echo "  FAILED  $name" >&2
  fi
done <<EOF
$LABELS
EOF

if [ "$CHECK" -eq 1 ]; then
  if [ "$missing" -eq 0 ]; then
    echo "OK — all $total labels present"
    exit 0
  fi
  echo "DRIFT — $missing label(s) missing; run without --check to create them" >&2
  exit 1
fi

if [ "$missing" -eq 0 ]; then
  echo "OK — all $total labels already present"
elif [ "$created" -eq "$missing" ]; then
  echo "OK — created $created label(s)"
else
  echo "INCOMPLETE — created $created of $missing missing label(s)" >&2
  exit 1
fi
