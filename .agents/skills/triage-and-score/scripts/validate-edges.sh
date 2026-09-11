#!/bin/bash
# validate-edges.sh [file] — validate proposed relation edges BEFORE any of them
# is posted. Reads from <file>, or stdin when the argument is absent or `-`.
# Prints OK ... and exits 0, or INVALID ... and exits 1 — so
# `validate-edges.sh edges-N.txt && gh api ... dependencies/blocked_by` cannot
# post a bad edge.
#
# One edge per line, `#` optional on a number, `#` alone starts a comment:
#
#     20 blocked-by 14        # 20 waits for 14
#     #18 blocks #20          # same edge, stated the other way
#     20 relates-to 22        # no ordering — existence checked, no cycle meaning
#
# Two rejections, both of which the tracker itself will happily accept:
#   * a dangling reference — an issue number that does not exist;
#   * a cycle — including one closed through edges ALREADY in the tracker, which
#     is the realistic shape when a scorer adds one edge at a time. A cycle
#     deadlocks the drain queue silently: every ticket in it looks blocked
#     forever and nothing else surfaces it.
#
# Fails closed. The tracker is the source of truth for both checks, so an
# unreachable tracker is INVALID, never a pass. Existing edges are read by
# walking blocked-by transitively from every referenced issue — a cycle can only
# be closed by a path that walks back to the ticket being edged.
set -u

src="${1:--}"
if [ "$src" != "-" ] && [ ! -f "$src" ]; then
  echo "INVALID: no such file: $src"
  exit 1
fi

# --- parse -------------------------------------------------------------------
# edges: one "<dependent> <blocker>" pair per line. nodes: every number named.
edges=""
nodes=""
errs=""
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  line="${line%$'\r'}"
  # Drop a trailing comment — a `#` after whitespace and not starting a number,
  # so `20 blocked-by #14  # waits` keeps the reference and loses the note.
  line=$(printf '%s' "$line" | sed -E 's/[[:space:]]+#[^0-9].*$//')
  set -- $line
  [ $# -gt 0 ] || continue
  case "$1" in
    '#'[!0-9]*|'#') continue ;;   # comment line
  esac
  if [ $# -ne 3 ]; then
    errs="$errs
  line $lineno: expected '<issue> blocked-by|blocks|relates-to <issue>', got: $line"
    continue
  fi
  a="${1#\#}"; rel="$2"; b="${3#\#}"
  rel=$(printf '%s' "$rel" | tr 'A-Z' 'a-z')
  rel="${rel%:}"
  case "$a$b" in *[!0-9]*|'')
    errs="$errs
  line $lineno: issue numbers must be digits, got: $line"
    continue ;;
  esac
  case "$rel" in
    blocked-by) edges="$edges$a $b
" ;;
    blocks)     edges="$edges$b $a
" ;;
    relates-to) : ;;
    *) errs="$errs
  line $lineno: unknown relation '$rel' (blocked-by | blocks | relates-to)"
       continue ;;
  esac
  nodes="$nodes$a
$b
"
done < <(if [ "$src" = "-" ]; then cat; else cat "$src"; fi)

if [ -n "$errs" ]; then
  echo "INVALID: unparseable edges:$errs"
  exit 1
fi
nodes=$(printf '%s' "$nodes" | grep . | sort -un)
if [ -z "$nodes" ]; then
  echo "INVALID: no edges given"
  exit 1
fi
proposed=$(printf '%s' "$edges" | grep -c .)
n_nodes=$(printf '%s' "$nodes" | grep -c .)

# --- the tracker must be reachable, or neither check below means anything -----
repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || repo=""
if [ -z "$repo" ]; then
  echo "INVALID: cannot reach the tracker — existence and cycle checks both need it"
  exit 1
fi

# --- dangling references ------------------------------------------------------
missing=""
for n in $nodes; do
  gh issue view "$n" --json number >/dev/null 2>&1 || missing="$missing #$n"
done
if [ -n "$missing" ]; then
  echo "INVALID: no such issue in $repo:$missing"
  exit 1
fi

# --- existing edges, walked transitively from every referenced issue ----------
existing="ok"
seen=""
frontier="$nodes"
while [ -n "$frontier" ]; do
  next=""
  for n in $frontier; do
    case " $seen " in *" $n "*) continue ;; esac
    seen="$seen $n"
    blockers=$(gh api "repos/$repo/issues/$n/dependencies/blocked_by" --jq '.[].number' 2>/dev/null) \
      || { existing="unavailable"; continue; }
    for b in $blockers; do
      edges="$edges$n $b
"
      next="$next $b"
    done
  done
  frontier="$next"
done

# --- cycles -------------------------------------------------------------------
# Kahn, peeling from the far end: a node nothing-depends-on is dropped with the
# edges into it, repeatedly. Whatever will not peel is exactly the cycle set.
left=$(printf '%s' "$edges" | jq -Rrs '
  def peel($nodes; $es):
    ($nodes | map(select(. as $n | ($es | any(.c == $n)) | not))) as $free
    | if ($free | length) == 0 then $nodes
      else peel(($nodes - $free); ($es | map(select(. as $e | ($free | index($e.b)) == null))))
      end;
  [ split("\n")[] | select(test("^[0-9]+ [0-9]+$"))
    | split(" ") | {c: (.[0] | tonumber), b: (.[1] | tonumber)} ] as $E
  | (([$E[].c] + [$E[].b]) | unique) as $N
  | peel($N; $E) | sort | map("#" + tostring) | join(" ")') || {
  echo "INVALID: cycle check failed to run (is jq installed?)"
  exit 1
}

if [ -n "$left" ]; then
  echo "INVALID: blocked-by cycle through $left (existing edges: $existing)"
  exit 1
fi
echo "OK $proposed proposed blocked-by edge(s) over $n_nodes issue(s); acyclic against $(printf '%s' "$edges" | grep -c .) total (existing edges: $existing)"
exit 0
