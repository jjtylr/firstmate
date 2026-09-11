#!/bin/bash
# run-issue-post.sh <issue> <body-file> — post one report to the run issue and
# prove it landed.
#
#   stdout   the new comment's id, alone. Findings go to stderr.
#   exit 0   the comment was posted and read back byte-for-byte
#            RUNNER-POSTED on stderr
#   exit 1   nothing was posted, or what came back is not what went out
#            RUNNER-REFUSED       the call is malformed; nothing was sent
#            RUNNER-FAILED        gh could not post, or answered unreadably
#            RUNNER-POST-UNVERIFIED  posted, but the read-back did not match
#
# **The read-back is the point.** A headless run reports to nobody who is
# watching, so "gh exited 0" is the whole evidence that an iteration's report
# survived — and it is not enough: a truncated or rewritten body would be
# silently lost, and the run's only record is this issue. The comment is read
# back **by its own id**, not as "the issue's last comment", so a comment posted
# in between can neither pass this check nor fail it.
#
# The comparison ignores carriage returns and trailing whitespace, and nothing
# else: the API round-trips a body verbatim apart from line endings, so any
# other difference is a real one.
set -u

refuse() { echo "RUNNER-REFUSED: $1" >&2; exit 1; }

[ $# -eq 2 ] || refuse "usage: run-issue-post.sh <issue> <body-file>"

issue="${1#\#}"
file="$2"

case "$issue" in ''|*[!0-9]*) refuse "issue must be a number, got: $1" ;; esac
[ -f "$file" ] || refuse "no such body file: $file"
[ -s "$file" ] || refuse "the body file is empty: $file"

url=$(gh issue comment "$issue" --body-file "$file") || {
  echo "RUNNER-FAILED: gh could not comment on #$issue" >&2
  exit 1
}

# `gh issue comment` answers with the comment's URL, whose fragment is
# `#issuecomment-<id>`. Without an id there is nothing to read back, and an
# unproven post is a failed post.
case "$url" in
  *issuecomment-*) id="${url##*issuecomment-}" ;;
  *) id="" ;;
esac
case "$id" in
  ''|*[!0-9]*)
    echo "RUNNER-FAILED: no comment id in what gh answered: $url" >&2
    exit 1
    ;;
esac

back=$(gh api "repos/{owner}/{repo}/issues/comments/$id" --jq '.body') || {
  echo "RUNNER-POST-UNVERIFIED: #$issue comment $id could not be read back" >&2
  exit 1
}

norm() {
  local s
  s=$(tr -d '\r' | sed 's/[[:space:]]*$//')
  printf '%s' "$s"
}
sent=$(norm < "$file")
got=$(printf '%s\n' "$back" | norm)

if [ "$sent" != "$got" ]; then
  echo "RUNNER-POST-UNVERIFIED: #$issue comment $id read back different from what was sent" >&2
  exit 1
fi

echo "RUNNER-POSTED: #$issue comment $id" >&2
printf '%s\n' "$id"
exit 0
