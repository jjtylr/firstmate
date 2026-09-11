#!/bin/bash
# check-lock.sh <path-prefix> [<path-prefix>...] — is a global lock occupied by
# an open loop PR? One `gh pr list` read answers every prefix passed, one line
# per prefix on stdout, in argument order:
#
#   CHECK-LOCK-HELD: <prefix> #<n> (<branch>)[, #<m> (<branch>)]
#   CHECK-LOCK-FREE: <prefix>
#
#   exit 0   every prefix was answered
#   exit 1   the PR list could not be read: one CHECK-LOCK-UNKNOWN line on
#            stderr and no prefix line printed. An unread lock is never a free
#            one — the previous shape printed nothing and exited 0 when `gh`
#            failed (measured 2026-08-26), which the drain read as "free,
#            dispatch", silently disabling every global lock on a network blip.
#            A listing that came back **at** its row limit is unread in the same
#            way and gets the same refusal: `gh` pages silently — measured on gh
#            2.98.0, `--limit` defaults to 30 for `pr list` and it never says it
#            truncated — so a window that comes back exactly full may have been
#            cut short, and a lock held by a PR past the cut would read as free.
#            That is the row-limit path to printing CHECK-LOCK-FREE for a lock
#            that is held. The listing therefore passes an explicit limit, the
#            same 200 `check-holds.sh` reads its two windows at, and refuses
#            rather than clears when the count reaches it. Past 200 open PRs by
#            this author the drain holds every lock instead of reading a partial
#            window as free: the ceiling costs throughput, never safety.
#
#            **A row's own file list truncates on a second axis, and it refuses
#            the whole run.** `gh --json files` returns at most 100 file rows per
#            PR and says nothing when it cuts the rest (measured on gh 2.98.0:
#            kubernetes/kubernetes#141226, 301 changed, 100 returned, exit 0), so
#            a lock held only by a path past the 100th would read as free. Each
#            row therefore carries `changedFiles`, its own true total, and a row
#            whose total does not equal the number of rows returned is unread.
#            One such row refuses every prefix rather than that row alone: the
#            answer for a prefix is derived from every open PR, so one unreadable
#            PR leaves it unestablished. A row carrying no numeric
#            `changedFiles` at all refuses the same way — an uncounted list is
#            never a complete one.
#
# A PR touching several files under one prefix is listed once for that prefix.
set -u

unknown() {
  echo "CHECK-LOCK-UNKNOWN: $1" >&2
  exit 1
}

[ $# -ge 1 ] || unknown "usage: check-lock.sh <path-prefix> [<path-prefix>...]"

# The row limit the listing is read at, and the count at which it is refused.
WINDOW=200

prs="$(gh pr list --state open --author "@me" --limit "$WINDOW" --json number,headRefName,changedFiles,files)" \
  || unknown "gh pr list failed — whether a lock is held cannot be read, and an unread lock is never a free one"
# gh prints `[]` for a match-nothing query, so nothing at all is a gh that said
# nothing, never a repo with no open PRs.
[ -n "$prs" ] \
  || unknown "gh answered nothing for the open PR list, not even an empty list"

# A listing that reached the limit cannot be told from one that stopped just
# short of it, so both refuse. A non-numeric count refuses too: `gh` answering
# an error object rather than an array must never fall through as "few enough".
count="$(printf '%s\n' "$prs" | jq -r 'if type == "array" then length else "" end' 2>/dev/null)"
case "$count" in
  ''|*[!0-9]*) unknown "the open PR list did not answer with a row count — an uncountable listing is never a free lock" ;;
esac
[ "$count" -lt "$WINDOW" ] \
  || unknown "the open PR list came back at its $WINDOW-row limit — gh truncates silently, so whether a lock is held by a PR past the cut cannot be told, and an unread lock is never a free one"

# The second truncation axis: a row's own file list. `changedFiles` is the PR's
# true total in the list shape as well as the single-PR one, so the two are held
# up against each other per row. `set --` is never used to split the result: the
# prefixes to answer are still in "$@".
nocount="$(printf '%s\n' "$prs" | jq -r \
  '[.[] | select((.changedFiles | type) != "number") | .number] | .[0] // ""' 2>/dev/null)"
[ -z "$nocount" ] \
  || unknown "PR #$nocount carries no numeric changedFiles total — whether its file list came back whole cannot be told, and an unread lock is never a free one"

cut_row="$(printf '%s\n' "$prs" | jq -r \
  '[.[] | select(.changedFiles != ([.files[]?] | length))] | .[0]
   | if . == null then "" else "\(.number) \(.changedFiles) \([.files[]?] | length)" end' 2>/dev/null)"
if [ -n "$cut_row" ]; then
  cut_n="${cut_row%% *}"
  cut_rest="${cut_row#* }"
  unknown "PR #$cut_n came back with a truncated file list — ${cut_rest%% *} files changed, ${cut_rest##* } rows returned; gh caps at 100 rows per PR and says nothing, so a lock held by a path past the cut cannot be told from a free one"
fi

for prefix in "$@"; do
  held="$(printf '%s\n' "$prs" | jq -r --arg p "$prefix" \
    '[.[] | select([.files[]?.path | startswith($p)] | any)
      | "#\(.number) (\(.headRefName))"] | join(", ")')" \
    || unknown "the open PR list is not JSON this check can read"
  if [ -n "$held" ]; then
    printf 'CHECK-LOCK-HELD: %s %s\n' "$prefix" "$held"
  else
    printf 'CHECK-LOCK-FREE: %s\n' "$prefix"
  fi
done
