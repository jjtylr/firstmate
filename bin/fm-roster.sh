#!/usr/bin/env bash
# fm-roster.sh - read-only roster of this fleet's first mate and second mates.
#
# Prints who is in the fleet, which computer each mate runs on, and which
# projects each mate is in charge of, rebuilt from the routing records on every
# run so a move between computers or a project changing hands shows up on the
# next run with no hand-kept list. It is meant to be run from anywhere by its
# absolute path, for example by an external board tool:
#   ~/code/jeeves/bin/fm-roster.sh --json
#
# Usage: fm-roster.sh [--json]
#   (no flag)  a short human table, one row per mate
#   --json     one JSON object (schema below)
#
# Home resolution matches the other read-only fleet commands: FM_HOME when set,
# otherwise the code root's own home. Nothing else from the environment is needed.
#
# Sources, each read through its single owner:
#   data/projects.md    the main project registry, enumerated with
#                       bin/fm-project-mode.sh --list
#   data/secondmates.md the secondmate routes, parsed with
#                       bin/fm-secondmate-registry-lib.sh; an absent file means
#                       no second mates
#
# Who is in charge of a project:
#   - A second mate is in charge of every project in its registry `projects:` list.
#   - The first mate is in charge of every project in the main registry that no
#     second mate lists.
#   - A project listed by more than one mate appears under each of them with
#     "shared": true and the ids of every mate holding it.
#
# Computer and placement:
#   - The first mate and every local second mate report the short hostname of the
#     machine this command runs on (the main home's machine), placement "local".
#   - A remote second mate reports its registry `host:` alias, placement "remote".
#   No host is ever probed.
#
# A project's "repo" is its GitHub "owner/name", read from the origin of a local
# clone at <home>/projects/<name> (the mate's own home when local, then the main
# home), and null when no clone records a GitHub origin.
#
# JSON schema (fm-roster.v1):
#   {
#     "schema": "fm-roster.v1",
#     "mates": [
#       { "id": "main" | <secondmate id>,
#         "role": "firstmate" | "secondmate",
#         "computer": <short hostname or host alias>,
#         "placement": "local" | "remote",
#         "home": <absolute home path on that computer>,
#         "summary": <registered summary> | null,   (null for the first mate)
#         "scope": <registered scope> | null,       (null for the first mate)
#         "projects": [ { "name": <name>, "repo": <owner/name> | null,
#                         "shared": <bool>, "mates": [<mate id>, ...] } ] } ] }
#
# Read-only: it takes no session lock, drains nothing, arms nothing, writes no
# file, and contacts no remote host. A malformed secondmate registry entry is an
# error (exit 1) rather than a silently dropped mate.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SM_REG="$DATA/secondmates.md"

# shellcheck source=bin/fm-secondmate-registry-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

usage() { echo "usage: fm-roster.sh [--json]"; }

JSON=0
case "${1:-}" in
  '') ;;
  --json) JSON=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 2; }
if [ "$JSON" -eq 1 ]; then
  command -v jq >/dev/null 2>&1 || { echo "fm-roster: jq not found" >&2; exit 1; }
fi

MAIN_HOME=$(cd "$FM_HOME" 2>/dev/null && pwd) || { echo "fm-roster: home not found: $FM_HOME" >&2; exit 1; }
HOST=$(hostname -s 2>/dev/null || uname -n)
HOST=${HOST%%.*}

# Parallel arrays, one entry per mate; PROJ_<i> lines hold that mate's projects.
M_ID=() M_ROLE=() M_COMPUTER=() M_PLACEMENT=() M_HOME=() M_SUMMARY=() M_SCOPE=() M_PROJECTS=()

trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

split_projects() {  # <comma list> -> unique trimmed names, one per line
  local IFS=, item name out=""
  for item in $1; do
    name=$(trim "$item")
    [ -n "$name" ] || continue
    printf '%s\n' "$out" | grep -Fxq -- "$name" && continue
    out="${out}${out:+$'\n'}$name"
  done
  [ -z "$out" ] || printf '%s\n' "$out"
}

if [ -e "$SM_REG" ] || [ -L "$SM_REG" ]; then
  [ -f "$SM_REG" ] && [ ! -L "$SM_REG" ] || { echo "fm-roster: secondmate registry is unsafe: $SM_REG" >&2; exit 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "- "*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || { echo "fm-roster: malformed secondmate registry entry: $line" >&2; exit 1; }
    [ "$SECONDMATE_REGISTRY_ID" != main ] || { echo "fm-roster: secondmate ID conflicts with firstmate: main" >&2; exit 1; }
    M_ID+=("$SECONDMATE_REGISTRY_ID")
    M_ROLE+=(secondmate)
    if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
      M_COMPUTER+=("$SECONDMATE_REGISTRY_HOST")
      M_PLACEMENT+=(remote)
    else
      M_COMPUTER+=("$HOST")
      M_PLACEMENT+=(local)
    fi
    M_HOME+=("$SECONDMATE_REGISTRY_HOME")
    M_SUMMARY+=("$SECONDMATE_REGISTRY_SUMMARY")
    M_SCOPE+=("$SECONDMATE_REGISTRY_SCOPE")
    M_PROJECTS+=("$(split_projects "$SECONDMATE_REGISTRY_PROJECTS")")
  done < "$SM_REG"
fi

claimed=""
for projects in "${M_PROJECTS[@]}"; do
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    claimed="${claimed}${claimed:+$'\n'}$p"
  done <<EOF
$projects
EOF
done
main_projects=""
while IFS= read -r name; do
  [ -n "$name" ] || continue
  printf '%s\n' "$claimed" | grep -Fxq -- "$name" && continue
  printf '%s\n' "$main_projects" | grep -Fxq -- "$name" && continue
  main_projects="${main_projects}${main_projects:+$'\n'}$name"
done <<EOF
$(FM_HOME="$MAIN_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-project-mode.sh" --list)
EOF

M_ID=(main ${M_ID[@]+"${M_ID[@]}"})
M_ROLE=(firstmate ${M_ROLE[@]+"${M_ROLE[@]}"})
M_COMPUTER=("$HOST" ${M_COMPUTER[@]+"${M_COMPUTER[@]}"})
M_PLACEMENT=(local ${M_PLACEMENT[@]+"${M_PLACEMENT[@]}"})
M_HOME=("$MAIN_HOME" ${M_HOME[@]+"${M_HOME[@]}"})
M_SUMMARY=("" ${M_SUMMARY[@]+"${M_SUMMARY[@]}"})
M_SCOPE=("" ${M_SCOPE[@]+"${M_SCOPE[@]}"})
M_PROJECTS=("$main_projects" ${M_PROJECTS[@]+"${M_PROJECTS[@]}"})

holders() {  # <project> -> ids of every mate listing it, one per line
  local i
  for i in "${!M_ID[@]}"; do
    printf '%s\n' "${M_PROJECTS[$i]}" | grep -Fxq -- "$1" && printf '%s\n' "${M_ID[$i]}"
  done
  return 0
}

github_repo() {  # <project> <mate index> -> owner/name or nothing
  local name=$1 i=$2 dir url dirs=()
  [ "${M_PLACEMENT[$i]}" = remote ] || dirs+=("${M_HOME[$i]}/projects/$name")
  dirs+=("$MAIN_HOME/projects/$name")
  for dir in "${dirs[@]}"; do
    [ -d "$dir" ] || continue
    url=$(git -C "$dir" config --get remote.origin.url 2>/dev/null) || continue
    case "$url" in
      git@github.com:*) url=${url#git@github.com:} ;;
      ssh://git@github.com/*) url=${url#ssh://git@github.com/} ;;
      https://github.com/*) url=${url#https://github.com/} ;;
      *) continue ;;
    esac
    url=${url%/}; url=${url%.git}
    case "$url" in */*/*|/*|*/) continue ;; */*) printf '%s\n' "$url"; return 0 ;; esac
  done
  return 0
}

if [ "$JSON" -eq 0 ]; then
  printf '%-14s %-10s %-14s %-9s %s\n' MATE ROLE COMPUTER PLACEMENT PROJECTS
  shared_seen=0
  for i in "${!M_ID[@]}"; do
    list=""
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      mark=""
      [ "$(holders "$p" | wc -l | tr -d ' ')" -gt 1 ] && { mark="*"; shared_seen=1; }
      list="${list}${list:+, }$p$mark"
    done <<EOF
${M_PROJECTS[$i]}
EOF
    printf '%-14s %-10s %-14s %-9s %s\n' "${M_ID[$i]}" "${M_ROLE[$i]}" "${M_COMPUTER[$i]}" "${M_PLACEMENT[$i]}" "${list:--}"
  done
  [ "$shared_seen" -eq 0 ] || echo "* listed by more than one mate"
  exit 0
fi

mates_json=""
for i in "${!M_ID[@]}"; do
  projects_json=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    owners=$(holders "$p")
    projects_json+=$(jq -cn --arg name "$p" --arg repo "$(github_repo "$p" "$i")" --arg owners "$owners" '
      ($owners | split("\n") | map(select(. != ""))) as $m
      | {name: $name, repo: (if $repo == "" then null else $repo end), shared: ($m | length > 1), mates: $m}')$'\n'
  done <<EOF
${M_PROJECTS[$i]}
EOF
  mates_json+=$(jq -cn \
    --arg id "${M_ID[$i]}" --arg role "${M_ROLE[$i]}" --arg computer "${M_COMPUTER[$i]}" \
    --arg placement "${M_PLACEMENT[$i]}" --arg home "${M_HOME[$i]}" \
    --arg summary "${M_SUMMARY[$i]}" --arg scope "${M_SCOPE[$i]}" --arg projects "$projects_json" '
    {id: $id, role: $role, computer: $computer, placement: $placement, home: $home,
     summary: (if $role == "firstmate" then null else $summary end),
     scope: (if $role == "firstmate" then null else $scope end),
     projects: ($projects | split("\n") | map(select(. != "") | fromjson))}')$'\n'
done
printf '%s' "$mates_json" | jq -s '{schema: "fm-roster.v1", mates: .}'
