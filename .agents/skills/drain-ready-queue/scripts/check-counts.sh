#!/bin/bash
# check-counts.sh <pr> | --body-file <file> — does a number this PR's prose
# claims still agree with the tree?
#
# A count written into a PR body or a recap is a self-report, and nothing
# measured it. `agents/operative.md` already tells the operative to count a
# second, independent way before publishing a number, and that authoring-time
# rail lost five times across two runs (#150 holds the instances). It lost in
# two distinct ways, and only one of them a rail can reach:
#
#   - **Never derived.** PR #182's "three inline refusals", written from reading
#     the diff. A rail is the right shape for this one, and it still lost.
#   - **Derived once, then the tree moved.** PR #181's "8 cases" was true when
#     the operative wrote it and false two commits later, after a more-fixes
#     round added two cases. Nothing written at authoring time can catch this,
#     because the number goes stale after the sentence is finished.
#
# The second mode is why this is a check and not another rail. Only a
# re-derivation at verify time sees it.
#
#   stdout  zero or more COUNTS-UNMARKED lines, then zero or more COUNTS-WRONG
#           lines, then exactly one verdict line — COUNTS-MATCH or
#           COUNTS-MISMATCH — last.
#   stderr  exactly one COUNTS-UNKNOWN line when the answer cannot be measured,
#           and then no verdict line at all.
#   exit 0  no marked claim disagrees with the tree.
#   exit 1  a marked claim disagrees, or the answer could not be measured. Both
#           exit alike: a comparison that did not run has not shown the claim
#           true, the reading `check-declared-locks.sh` already takes.
#
# **A marked claim.** A number carries its derivation inline, in parentheses:
#
#   the four (count: matches 'unknown "' skills/drain-ready-queue/scripts/check-lock.sh) inline refusals
#   `pick.test.sh` holds 10 (count: cases scripts/tests/pick.test.sh) cases
#
# The claim's number is the **nearest number to the left of the mark**, digits
# or a number word from zero through twenty. Both written orders above work, and
# a claim whose author wrapped it across lines works too: the body is read as one
# stream, so a line break is only whitespace.
#
# **The closed vocabulary of kinds.** Each kind is one fixed command,
# parameterised by its target and nothing else. This is `check-markers.sh`'s
# rule — consistency, not prohibition: a number whose kind is not in this table
# is not checked, and that is not an error.
#
#   cases    <path>            grep -c '^test_case ' <path>
#   matches  <pattern> <path>  grep -c -F -- <pattern> <path>
#   files    <base>..<head>    git diff --name-only <base> <head>, counted
#
# Each derivation counts **lines**, never records, because that is what `grep -c`
# counts. Two call sites on one line are one `matches` hit, and a heredoc fixture
# whose lines begin `test_case ` is three more `cases` hits in the file quoting
# it — measured here, on this check's own test file, which over-counted by
# exactly its fixture until the fixture moved to `printf`. So a claim needs a
# derivation that lands once per record; where none does, leave the number
# unmarked and say what you counted instead.
#
# **Never build a command from the body's text.** The kind selects a fixed
# command and the target is passed as a literal argument, never through a shell
# and never through `eval`. A PR body is input, and input that reaches a shell is
# a hole. A target that is not a tracked path, or a range that is not two
# resolvable commits, is COUNTS-UNKNOWN.
#
# **An unmarked count warns; it never fails.** A number sitting beside one of the
# countable nouns with no derivation gets a COUNTS-UNMARKED line and leaves the
# exit code alone. Prose says "one line for the PM" and means nothing countable,
# so only a marked claim that disagrees with the tree fails.
#
# **Quoted syntax is not a claim.** Fenced blocks are skipped whole, because a
# pasted gate output line is the tool's own count and not a sentence about it,
# and an inline code span is dropped too — a body explaining the mark must not
# park itself, which this one did until the span rule landed.
#
# The findings lines, all of them:
#
#   COUNTS-MATCH: <n> marked claim(s) re-derived, all agree
#   COUNTS-MISMATCH: <n> marked claim(s), <w> disagree with the tree
#   COUNTS-WRONG: '<claim>' says <stated>, the tree says <measured> — <derivation>
#   COUNTS-UNMARKED: '<number> <noun>' carries no derivation
#   COUNTS-UNKNOWN: ...    (stderr, exit 1)
#
# **The input mode is invisible in the output.** `<pr>` and `--body-file` print
# the same lines for the same text, so an operative can run the check on a body
# it has not posted yet and read exactly what the verifier will read after.
#
# The tree it measures is the working tree it runs in — for the verifier, its
# throwaway clone at the commit under examination.
#
# `-f` is load-bearing, not tidiness: the body is split into words unquoted, so
# without it a sentence mentioning `*.md` would be expanded against the working
# directory and one word would become however many files sit there.
set -uf

unknown() {
  echo "COUNTS-UNKNOWN: $1" >&2
  exit 1
}

# --- the body -----------------------------------------------------------------
case "${1:-}" in
  --body-file)
    [ $# -eq 2 ] || unknown "usage: check-counts.sh --body-file <file>"
    [ -f "$2" ] || unknown "no such body file: $2"
    body="$(cat "$2")" || unknown "the body file could not be read: $2"
    ;;
  '' )
    unknown "usage: check-counts.sh <pr> | check-counts.sh --body-file <file>"
    ;;
  *)
    [ $# -eq 1 ] || unknown "usage: check-counts.sh <pr> | check-counts.sh --body-file <file>"
    p="${1#\#}"
    case "$p" in
      ''|*[!0-9]*) unknown "usage: check-counts.sh <pr>, got: $1" ;;
    esac
    body="$(gh pr view "$p" --json body -q .body 2>/dev/null)" \
      || unknown "PR #$p — its body could not be read, and an unread body shows no claim true"
    ;;
esac

# Fenced code is the tool's own output, not prose about it. Everything else
# joins into one stream, so a claim wrapped across lines still finds its number.
stream=""
fenced=0
while IFS= read -r line; do
  case "$line" in
    '```'*|'   ```'*|'  ```'*|' ```'*)
      fenced=$((1 - fenced))
      continue
      ;;
  esac
  [ "$fenced" = 0 ] || continue
  stream="$stream $line"
done <<EOF
$body
EOF

# An inline code span is a quotation of the syntax, not a claim written in it —
# measured on this check's own PR body, where a sentence explaining the mark
# parked the PR with an unreadable target. Balanced spans become a space; an
# unmatched backtick keeps its tail, so a stray one cannot swallow the body.
cleaned=""
s="$stream"
while :; do
  case "$s" in
    *'`'*) ;;
    *) cleaned="$cleaned$s"; break ;;
  esac
  cleaned="$cleaned${s%%\`*} "
  s="${s#*\`}"
  case "$s" in
    *'`'*) s="${s#*\`}" ;;
    *) cleaned="$cleaned$s"; break ;;
  esac
done
stream="$cleaned"

# --- reading a number ---------------------------------------------------------
NUMWORDS='zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty'

# Markdown punctuation is not part of a number: `4`, (4), 4. and **4** all read
# as 4. Everything that is not a letter or a digit comes off, so `v2` stays a
# word and never a count. Done in the shell rather than through `tr`, because
# this runs once per word of the body and a fork per word is the slow way.
to_number() { # <word> → the number on stdout, or non-zero
  local s="$1" t="" c i=0 w
  while [ -n "$s" ]; do
    c="${s%"${s#?}"}"
    case "$c" in [A-Za-z0-9]) t="$t$c" ;; esac
    s="${s#?}"
  done
  case "$t" in
    '') return 1 ;;
    *[!0-9]*) ;;
    *) printf '%s' "$((10#$t))"; return 0 ;;
  esac
  t="$(printf '%s' "$t" | tr 'A-Z' 'a-z')"
  for w in $NUMWORDS; do
    [ "$w" = "$t" ] && { printf '%s' "$i"; return 0; }
    i=$((i + 1))
  done
  return 1
}

# The last few words of a run, so a findings line names the sentence a human has
# to find rather than the bare digit.
tail_words() { # <string> <n>
  local s="$1" n="$2" out="" w
  for w in $s; do
    out="$out $w"
    set -- $out
    while [ $# -gt "$n" ]; do shift; done
    out="$*"
  done
  printf '%s' "$out"
}

TAB="$(printf '\t')"

trim() { # <string> — leading and trailing whitespace off
  local s="$1"
  while [ "${s#[ $TAB]}" != "$s" ]; do s="${s#[ $TAB]}"; done
  while [ "${s%[ $TAB]}" != "$s" ]; do s="${s%[ $TAB]}"; done
  printf '%s' "$s"
}

# --- deriving a count ---------------------------------------------------------
# One fixed command per kind. The target is an argument, never a fragment of a
# command line, so a body carrying $(…) or a semicolon buys nothing.
tracked() { # <path>
  git ls-files --error-unmatch -- "$1" >/dev/null 2>&1
}

# Sets DERIVED, never echoes it: `unknown` exits, and an `exit` inside a command
# substitution leaves only the subshell, so a caller reading this through `$( )`
# would print a verdict after refusing to measure.
DERIVED=""
derive() { # <kind> <arg1> [arg2] → DERIVED, or unknown() and exit
  local kind="$1" n base head
  case "$kind" in
    cases)
      tracked "$2" || unknown "'cases $2' — not a tracked path in this tree, so its count cannot be measured"
      n="$(grep -c '^test_case ' -- "$2" 2>/dev/null)"
      ;;
    matches)
      tracked "$3" || unknown "'matches $3' — not a tracked path in this tree, so its count cannot be measured"
      n="$(grep -c -F -- "$2" "$3" 2>/dev/null)"
      ;;
    files)
      case "$2" in
        *..*) ;;
        *) unknown "'files $2' — not a <base>..<head> range, so its file count cannot be measured" ;;
      esac
      base="${2%%..*}"
      head="${2#*..}"
      git rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1 \
        || unknown "'files $2' — '$base' does not resolve to a commit in this tree"
      git rev-parse --verify --quiet "$head^{commit}" >/dev/null 2>&1 \
        || unknown "'files $2' — '$head' does not resolve to a commit in this tree"
      n="$(git diff --name-only "$base" "$head" 2>/dev/null | grep -c .)"
      ;;
  esac
  # grep -c exits 1 on a count of zero and still prints it; an empty capture is
  # the only real failure.
  [ -n "$n" ] || unknown "'$kind $2' — the derivation printed nothing"
  DERIVED="$n"
}

# --- walking the marks --------------------------------------------------------
# Each pass eats one `(count: …)`. `pre` is the prose before it, whose last
# number is the claim; `rest` carries on after the mark's closing paren.
rest="$stream"
residue=""
unmarked=""
wrong=""
marked=0
disagree=0

while :; do
  case "$rest" in
    *'(count:'*) ;;
    *) residue="$residue$rest"; break ;;
  esac

  pre="${rest%%'(count:'*}"
  rest="${rest#*'(count:'}"

  # The claim is the last number in `pre`, plus whatever trails it up to the
  # mark. Everything before that number stays in the residue, where the unmarked
  # scan can still see it.
  keep=""
  claim=""
  stated=""
  for w in $pre; do
    if v="$(to_number "$w")"; then
      keep="$keep $claim"
      claim="$w"
      stated="$v"
    else
      claim="$claim $w"
    fi
  done
  [ -n "$stated" ] || unknown "a (count: …) mark carries no number to its left"
  residue="$residue $keep"
  claim="$(trim "$(tail_words "$keep" 3) $claim")"

  # The kind, then its target, read as literal fields — nothing here becomes a
  # command.
  rest="$(trim "$rest")"
  kind="${rest%%[ $TAB)]*}"
  after="${rest:${#kind}}"
  arg1=""
  arg2=""
  deriv=""
  case "$kind" in
    cases|files)
      case "$after" in
        *')'*) ;;
        *) unknown "a (count: $kind …) mark never closes its parenthesis" ;;
      esac
      arg1="$(trim "${after%%')'*}")"
      rest="${after#*')'}"
      [ -n "$arg1" ] || unknown "a (count: $kind …) mark names no target"
      deriv="$kind $arg1"
      ;;
    matches)
      s="$(trim "$after")"
      case "$s" in
        "'"*)
          s="${s#\'}"
          case "$s" in
            *"'"*) ;;
            *) unknown "a (count: matches …) mark never closes its quoted pattern" ;;
          esac
          arg1="${s%%\'*}"
          s="${s#*\'}"
          ;;
        *)
          arg1="${s%%[ $TAB)]*}"
          s="${s:${#arg1}}"
          ;;
      esac
      case "$s" in
        *')'*) ;;
        *) unknown "a (count: matches …) mark never closes its parenthesis" ;;
      esac
      arg2="$(trim "${s%%')'*}")"
      rest="${s#*')'}"
      [ -n "$arg1" ] && [ -n "$arg2" ] \
        || unknown "a (count: matches …) mark needs a pattern and a path"
      deriv="matches '$arg1' $arg2"
      ;;
    *)
      # Not in the vocabulary. Not checked, and not an error — the anchor is
      # still eaten, so the claim is not then reported as unmarked either.
      case "$after" in
        *')'*) rest="${after#*')'}" ;;
        *) rest="" ;;
      esac
      continue
      ;;
  esac

  marked=$((marked + 1))
  derive "$kind" "$arg1" "$arg2"
  measured="$DERIVED"
  if [ "$stated" -ne "$measured" ]; then
    disagree=$((disagree + 1))
    wrong="${wrong}COUNTS-WRONG: '$claim' says $stated, the tree says $measured — $deriv
"
  fi
done

# --- the numbers nobody marked ------------------------------------------------
# A number adjacent to a countable noun and nothing else. Advisory: it names a
# claim this check could have re-derived and cannot, and it never moves the exit
# code, because a sentence must not become a new way to park a PR.
NOUNS='cases|refusals|call sites|warns|files|skills|lines'
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  unmarked="${unmarked}COUNTS-UNMARKED: '$hit' carries no derivation
"
done <<EOF
$(printf '%s\n' "$residue" \
  | grep -oiE "(\<(${NUMWORDS// /|})\>|\<[0-9]+) (${NOUNS})\>" 2>/dev/null)
EOF

[ -z "$unmarked" ] || printf '%s' "$unmarked"
[ -z "$wrong" ] || printf '%s' "$wrong"

if [ "$disagree" = 0 ]; then
  printf 'COUNTS-MATCH: %s marked claim(s) re-derived, all agree\n' "$marked"
  exit 0
fi

printf 'COUNTS-MISMATCH: %s marked claim(s), %s disagree with the tree\n' \
  "$marked" "$disagree"
exit 1
