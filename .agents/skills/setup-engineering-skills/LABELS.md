# Labels

The label vocabulary every repo using this plugin runs on. It is **fixed** — the plugin decides it,
`create-labels.sh` installs it, and no repo remaps it. A skill that needs a label string uses the
one written here.

Two kinds, and the difference is what makes queue selection safe.

A **state** is where an issue sits in the pipeline. An issue carries **exactly one, or none**, and
every loop stage selects its queue by allowlisting the states it consumes — never by blocklisting
categories. A **category** says what an issue *is*; categories are invisible to selection.

**No state label means the issue is not in the pipeline.** That is how specs, briefs, and wayfinder
maps stay out of every queue without any exclusion list having to learn their names. An issue whose
state someone forgot is invisible to the loops, and that is intended.

## States

| Label | Meaning |
| ----- | ------- |
| `needs-triage` | Not yet evaluated. The entry state for anything arriving raw; an untriaged issue normally lands here first, and `triage` full mode consumes it. |
| `needs-info` | Cannot proceed until someone answers. Triage applies it when the reporter owes an answer; the drain applies it when a candidate scores above `effort_threshold` and needs splitting, or when a dispatch stopped. |
| `ready-for-agent` | Fully specified, safe to hand an unsupervised agent. The only state the drain loop dispatches from. |
| `ready-for-human` | Real work that needs a human implementer. The loops never dispatch it. |
| `wontfix` | Terminal — will not be actioned. Applied when **closing** an out-of-scope issue, not while one is open. |

## Process categories

Artefacts the skills produce. Each is stateless by design — giving one a state puts a document into
a work queue.

| Label | Meaning |
| ----- | ------- |
| `spec` | A spec published by `to-spec`. **Never carries a state label** — a spec is a category, not pipeline work. |
| `brief` | The output of a brainstorming session; ground for a future grill. Also stateless. |
| `wayfinder:map` | The single map issue for one wayfinder effort — the canonical artefact. Its decision tickets are child issues of it. |
| `wayfinder:research` | A wayfinder decision ticket, AFK: reading docs or APIs to surface a fact a decision waits on. Resolved by a `/research` subagent. |
| `wayfinder:prototype` | A wayfinder decision ticket, HITL: build something cheap and concrete to react to when "how should it look or behave" is the question. |
| `wayfinder:grilling` | A wayfinder decision ticket, HITL: conversation. The default type. |
| `wayfinder:task` | A wayfinder ticket that *does* rather than decides — manual work a decision is blocked on. |
| `run-log` | The log issue for one headless drain run. **Never carries a state label**, so every queue ignores it, and the label is the selector its scripts query. One open at a time: the runner opens it, the loop posts each iteration's report to it, and the PM **closing** it is the ack that lets the next run start. |

## Display categories

Labels that mirror something the blackboard already says, so a human scanning the tracker sees it
without opening the issue. **No script decision reads one**, which is what keeps them safe to be
wrong.

| Label | Meaning |
| ----- | ------- |
| `claimed` | The drain has posted a lane claim on this ticket and is working it. Added when the claim posts, removed when the claim is released — by the ticket's ledger row, or by the PM. It sits *beside* the ticket's state, never instead of it: a claimed ticket is still `ready-for-agent`. Display-only — the claim comment is the authority the pick and the collision check read, and where label and claim disagree the claim wins. |

## Kind categories

What an issue is about. Free to combine with any state.

| Label | Meaning |
| ----- | ------- |
| `bug` | Something isn't working. |
| `documentation` | Documentation only. |
| `enhancement` | A new feature or request. |

## Installing them

```sh
./scripts/create-labels.sh          # create what's missing
./scripts/create-labels.sh --check  # report drift, change nothing
```

`create-labels.sh` carries the same names with their colours and one-line descriptions. **Adding a
label means editing this file and that script together** — the script installs, this file explains,
and they are canonical only when they agree.

## Rules the skills rely on

1. **One state at a time.** Two state labels on one issue is a bug: the blackboard stops saying which stage owns the item.
2. **No state means invisible.** Not a gap — it is how process artefacts stay out of the queues.
3. **Categories never gate selection.** A queue that must be taught each new category label is built wrong; allowlist the states you consume instead. A display label is the sharpest case: `claimed` mirrors a fact the tracker already carries, and a mirror that gated anything would be a second, weaker copy of the record it mirrors.
4. **The vocabulary is not per-repo.** `pick.sh` and `queue.sh` accept `READY_LABEL` / `TRIAGE_LABEL` as a test seam, not as a remapping feature — a repo that sets them in earnest has left the vocabulary the rest of the plugin assumes.
