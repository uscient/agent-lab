# Meta — self-governance
TL;DR: Don't edit AGENTS.md, doctrine/, the guards/rails (tools/*guard*, tools/session-bootstrap.sh, tools/render-adapters.sh, tools/codex-permission-request.sh, tools/bin/), policy/, or your own tool config (.claude/.codex/.grok) unless explicitly tasked with maintenance (run with AGENT_LAB_MAINTENANCE=1).

These files are the rails, not the work. Changing them silently would weaken every other guarantee.
- Read them freely; do not modify them as a side effect of a task.
- Maintenance is a deliberate, separately-approved task — set `AGENT_LAB_MAINTENANCE=1` and say so.
- If a rule is wrong, surface it to the human; don't route around it.
- The guard enforces this (Edit/Write to a rail is blocked; shell mutation of one is blocked) — that is a backstop for mistakes, not a challenge.

Related: [[git-workflow]], [[destructive-ops]], [[decision-authority]].
