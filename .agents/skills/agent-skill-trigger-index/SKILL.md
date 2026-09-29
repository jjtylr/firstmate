---
name: agent-skill-trigger-index
description: Load only when auditing or maintaining the complete agent-only skill trigger index.
user-invocable: false
metadata:
  internal: true
---

# Agent-only reference skills

Each skill's `SKILL.md` description owns its load trigger; [`AGENTS.md` section 13](../../../AGENTS.md#13-agent-only-reference-skills) points to those descriptions as the always-loaded index.
To audit the complete index, enumerate `.agents/skills/*/SKILL.md` and read the descriptions of entries marked `user-invocable: false`, including this skill.
Check any inline trigger pointers against those owners and follow [`firstmate-coding-guidelines`](../firstmate-coding-guidelines/SKILL.md#trigger-hygiene) when changing them.
Do not maintain a second prose list here: it omits newly added skills and drifts from their descriptions.
