#!/bin/bash
# merge-decision.sh <verdict> <checks-line> <policy> <verdict-marker> — the
# merge button, under the catalog's auto policies (MERGE-POLICY.md). Prints
# MERGE-ALLOWED and exits 0 only when the verdict word is `pass`, carried under
# the current verdict marker, AND the CI finding corroborates under the policy
# in force; every other input — any other verdict, any other bucket, anything
# missing or unrecognized — prints MERGE-REFUSED:<reason> and exits 1, and the
# PR falls back to the PM.
#
# All four are required of any call that could merge. `<policy>` alone has a
# default (auto-on-verdict, the stricter arm) for a caller that omits the tail
# entirely; such a call then refuses for want of a marker, which is how
# runner-gate.sh probes a policy name without holding a verdict.
#
# The orchestrator merges only chained behind this script — this, then
# merge-freshness.sh, then merge-pinned.sh, which is the serialized merge
# pipeline's step 4 into its step 5 (MERGE-PIPELINE.md). That mirrors how
# validate-verdict.sh gates verdict posting: the highest-stakes act in the
# pipeline must not depend on model judgment, so this exit code, not a
# paragraph asking for care, is what holds the button. This script answers the
# verdict-and-CI half only; whether the PR is still the tree that verdict was
# about is merge-freshness.sh's, and the pin is merge-pinned.sh's.
#
# <verdict> is the word the orchestrator's own verifier dispatch returned this
# iteration (pass | concerns | fail | refused) — never a block re-read from PR
# comments.
# <checks-line> is pr-checks.sh output; the bucket is the part before the
# first colon, so CHECKS-PASS:12 reads as CHECKS-PASS.
# <policy> is the repo's merge_policy name from docs/agents/loop.md; omitted,
# it reads as auto-on-verdict, the stricter arm.
# <verdict-marker> is the marker line the verifier reported posting under, read
# back off its own comment — the whole line, e.g. "<!-- verifier-verdict vN -->".
#
# **The verdict word is where a concern's scope reaches this script, and the only
# place it does.** Each concern in the block carries a scope tag: `[diff]` for the
# examined tree, `[adjacent #<n>]` for a finding beside it that went to its own
# issue (VERDICT.md). `validate-verdict.sh` refuses a `concerns` with no `[diff]`
# element and refuses a `pass` that carries one, so a word that arrives here
# already means the tag — `concerns` is a diff concern, and a block whose only
# concerns are adjacent is a `pass`. Reading the tag a second time here would give
# one decision two homes, and they would drift. `concerns` still parks the PR
# whatever the tag says: ship-only-on-pass is not a thing an adjacent finding can
# talk its way past.
#
# **A verdict under a superseded marker is no verdict.** The marker version is
# what says the verdict is a claim about an identified commit (VERDICT.md); a
# block written before that meaning change asserted nothing about any tree, so
# there is nothing here to read it as. It refuses with the no-verdict reason,
# and so does a call that carries no marker at all — a stale verifier, or a
# caller that has not been updated, must not merge by default. The canonical
# version is read at run time from validate-verdict.sh, the marker's
# machine-owned home (scripts/check-markers.sh), so no digit lives in this file
# to go stale.
#
# Which buckets corroborate is the policy's catalog entry, executed here:
#   auto-on-verdict        — CHECKS-PASS only. CHECKS-NONE refuses (PM
#                            decision, spec #73 sign-off): one witness is not
#                            two, so a repo without CI cannot run this policy.
#   auto-on-verdict-no-ci  — CHECKS-PASS or CHECKS-NONE (PM decision, #78):
#                            for a repo with no CI by choice, the verifier is
#                            the one independent witness. A CI state that
#                            exists but is not green still refuses.
#
# The policy refusal is checked **first**, and its wording is a contract:
# runner-gate.sh asks this script whether a name is an auto policy and reads
# that line rather than the exit code, because every other refusal here exits 1
# too — a marker check alone would otherwise read every auto policy as
# pm-merge.
set -u

verdict="${1-}"
checks="${2-}"
policy="${3-auto-on-verdict}"
marker="${4-}"
bucket="${checks%%:*}"

here=$(cd "$(dirname "$0")" && pwd)
home="$here/validate-verdict.sh"
canon=$(grep -oE '<!-- verifier-verdict v[0-9]+ -->' "$home" 2>/dev/null | head -n1)
marker=$(printf '%s' "$marker" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

if [ -z "$verdict" ] && [ -z "$checks" ]; then
  echo "MERGE-REFUSED:no verdict and no checks line — nothing to decide on"
  exit 1
fi

case "$policy" in
  auto-on-verdict|auto-on-verdict-no-ci) ;;
  *)
    echo "MERGE-REFUSED:policy '$policy' is not an auto policy the catalog carries — the PM merges"
    exit 1 ;;
esac

if [ -z "$canon" ]; then
  echo "MERGE-REFUSED:cannot read the canonical verdict marker from $home — refusing rather than guessing it"
  exit 1
fi
if [ -z "$marker" ]; then
  echo "MERGE-REFUSED:no verdict — no verdict marker was carried, so nothing says which tree the verdict claims"
  exit 1
fi
if [ "$marker" != "$canon" ]; then
  echo "MERGE-REFUSED:no verdict — the block is under '$marker', not $canon; a verdict under a superseded marker is not a claim about any tree"
  exit 1
fi

case "$verdict" in
  pass) ;;
  '')
    echo "MERGE-REFUSED:no verdict — an unverified PR never auto-merges"
    exit 1 ;;
  refused)
    echo "MERGE-REFUSED:verdict is refused — the verifier did not have the commit it was briefed to examine; re-verify at the current head"
    exit 1 ;;
  concerns)
    echo "MERGE-REFUSED:verdict is concerns — a diff-scoped concern parks the PR; the PM decides this one"
    exit 1 ;;
  fail)
    echo "MERGE-REFUSED:verdict is fail — the PM decides this PR"
    exit 1 ;;
  *)
    echo "MERGE-REFUSED:unrecognized verdict '$verdict'"
    exit 1 ;;
esac

case "$bucket" in
  CHECKS-PASS)
    echo "MERGE-ALLOWED"
    exit 0 ;;
  CHECKS-NONE)
    if [ "$policy" = "auto-on-verdict-no-ci" ]; then
      echo "MERGE-ALLOWED"
      exit 0
    fi
    echo "MERGE-REFUSED:no CI configured — a repo without checks cannot auto-merge under auto-on-verdict"
    exit 1 ;;
  CHECKS-FAIL)
    echo "MERGE-REFUSED:CI is failing"
    exit 1 ;;
  CHECKS-PENDING)
    echo "MERGE-REFUSED:CI is still running"
    exit 1 ;;
  CHECKS-UNKNOWN)
    echo "MERGE-REFUSED:CI state unreadable"
    exit 1 ;;
  '')
    echo "MERGE-REFUSED:no checks line — a checks reading must exist before a merge"
    exit 1 ;;
  *)
    echo "MERGE-REFUSED:unrecognized checks line '$checks'"
    exit 1 ;;
esac
