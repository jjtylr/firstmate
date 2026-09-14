# Triage checks

The four checks a subagent runs before it recommends anything — three against the codebase, one
against the issue tracker — and what each one's result obliges. This file is the single home for the
check bodies — a caller points at it and does not restate it.

Read this whole file before you start. Each check ends in a **consequence**: a recommendation you
owe the caller. Recommendations only — applying labels, closing issues, grilling the reporter, and
waiting on the maintainer belong to whoever dispatched you, not to you.

## 1. Verify the claim

The filed issue is a lead, not a spec. Re-measure anything it asserts, and be hardest on universals
("none", "all", "only", "there is no…") and on any "verified dead" or "already done".

**Probe precedence — prefer, in this order:**

1. **The live thing.** Run the command, hit the endpoint, reproduce the reporter's steps, check out
   the PR and run the tests it claims to pass.
2. **The code.** Read the call path end to end.
3. **A doc.** Weakest evidence: docs describe intent, and drift from the code silently.

A doc that agrees with a claim does not confirm it; code that contradicts a doc wins.

**A failed grep is not proof.** Absence of a match is absence of *that spelling* — the concept may
live under a different name, be generated, be reached through indirection, or sit in a file your
glob never touched. To claim something does not exist, say what you searched, how, and why that
search would have found it.

**Probe read-only.** Never write to anything shared to test a claim.

**Which copy of a plugin file.** *This applies to a Claude Code plugin install. Installed with
`npx skills` there is one vendored copy of a skill and nothing to choose between, so say that and
read the copy you have.* Under the plugin, a claim naming a path under `skills/`, `agents/`,
`hooks/` or `scripts/` can resolve to two files: the repo's working tree, and the installed plugin
snapshot under `${CLAUDE_PLUGIN_ROOT}`. The snapshot refreshes only on `/plugin update`, so its age
is unbounded, and a difference between the two copies is staleness, never evidence against the
claim. Measure which copy is authoritative instead of picking by habit or by directory name: run
`claim-authority.sh <repo-root>`, which sits beside this file at `./scripts/claim-authority.sh`
**relative to this file** — a shell resolves that against the repo you are checking, so give the
command the absolute path you read this file from — and read the copy its line names. In the
plugin's own source repo that is the working tree; in every other repo it is the snapshot. On
`CLAIM-AUTHORITY-UNKNOWN`, say so in your findings lines and treat the claim as *could-not-check*;
never pick a copy silently. Doctrine files a caller told you to read (this file, the rubric, the
templates) are read from wherever this skill itself was installed, either way; this rule is about
the paths the claim is about.

**Consequence.** Report `VERIFIED: yes | no | n/a`, naming what you probed and what it showed. On
`no`, distinguish:

- **did-not-reproduce** — you ran the probe and the claimed behaviour was not there. The premise is
  wrong; recommend against acting on it.
- **could-not-check** — you could not run the probe (no access, no repro steps, missing detail).
  That is a `needs-info` signal, not a refutation.

A confirmed verification is also what makes an effort estimate real: you cannot honestly separate a
small change from a large one without having read enough of the code to know the premise holds.

## 2. Redundancy

Search the codebase for an existing implementation of the requested behaviour.

**Search by domain concept, not the request's wording.** The reporter's vocabulary is rarely the
codebase's. Take the project's glossary terms for the concept, its synonyms, and the names of the
types and functions that would have to exist, and search for those.

**Report where you looked** — the terms, the paths, the ways in. An unreported search cannot be
trusted or repeated, and "I looked and found nothing" is the exact shape of a false negative (see
the failed-grep rule above).

**Consequence.** A hit means the request is **already implemented**: recommend `wontfix`, and point
to where the behaviour lives — path and entry point — so the reporter can check it themselves.
Already-implemented is *not* a rejection: nothing goes into `.out-of-scope/` for it. A near-miss
(the concept exists but does not do what is asked) is not a hit; say what exists and what is
missing, and let the request stand.

## 3. Prior rejection

Read `.out-of-scope/*.md` — the repo's record of requests that were considered and turned down.
Read the files, do not just list them: one file covers a *concept*, and the request in front of you
may be that concept under another name. See [OUT-OF-SCOPE.md](OUT-OF-SCOPE.md) for the format.

**Consequence.** Report any rejection that resembles this request, quoting the reasoning and
linking the file. Resemblance is a flag, not a verdict — a request can revisit a rejected concept on
new evidence, and it is the maintainer who decides whether the old reasoning still holds. Say which
it looks like: the same request again, or the same concept with something new attached.

## 4. Existing ticket

Search the issue tracker for a ticket already filed on this request. Checks 2 and 3 read the
codebase and the rejection record; this one reads the tracker, and nothing else does.

**Reach the tracker through the repo's `docs/agents/issue-tracker.md`.** It says which tracker this
repo is on and how a ticket there is listed and read. This check names no command of its own,
because it ships to repos that are not on GitHub.

**Read the candidates, do not just list them.** Same failure mode as the prior-rejection check: one
ticket covers a *concept*, and the request in front of you may be that concept under another name.
A title is the reporter's wording, so a scan of titles alone is a false negative waiting to happen.
Search open tickets first, then recently closed ones — a closed ticket is a hit too, whether it was
resolved already or turned down for reasoning that still holds.

**On a large tracker, narrow — and say how you narrowed.** A short open list is the whole search:
read it. Past that, take the domain concept rather than the request's wording, and query the
tracker's text search for its terms, its synonyms, and the identifiers the work would touch — file
paths, command names, symbols. Where the tracker offers only listing and filters, list by the labels
this request would carry, **and** list the most recent tickets whatever they carry. Never narrow on
a field a later stage writes — a label, a score, a milestone. Those arrive at triage or scoring
time, so a freshly captured ticket is both the most likely duplicate and the least likely to carry
one. Such a field is a filter you add to a text search, never the search itself.

**Report where you looked** — the terms, the filters, how many tickets you read. The failed-grep
rule in check 1 binds here: to claim no ticket exists, say what you searched and why that search
would have found one.

**Consequence.** A hit never produces a second ticket, and it is never a licence to drop what you
already measured. Which of the two cases applies is decided by whether a maintainer is in the
session, not by what the hit says:

- **Attended triage — a maintainer is present.** Stop and put the hit to them. File nothing, and
  change no state, until they rule. Name the ticket, and say which it looks like: the same request
  again, or the same concept with something new attached. Once they rule, your measurements go onto
  the existing ticket as a comment.
- **Unattended filing — an operative, a scorer, or any worker filing mid-task with nobody to ask.**
  File nothing. Name the existing ticket in your recap where a new issue number would have gone,
  with what you found, so the PM reads the hit there. You do not block and you do not chase the
  finding: this is the standing do-not-chase rail with the duplicate removed, not a new stop.

Report `none` as plainly as a hit. An unreported search is one the next session has to run again.
