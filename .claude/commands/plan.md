---
description: Security-aware plan for an agent-lab change → tmp/ (no edits)
---
PLAN ONLY — do not modify files. Read ../AGENTS.md and ../CLAUDE.md first; the containment doctrine and security invariants are binding.

Task: $ARGUMENTS

Read selectively (rg → targeted reads); ground findings in real `path:line`. For every proposed change, state its **security-boundary impact** (network, filesystem, privileges, secrets, supply chain) and whether it preserves default-deny. Emit a NEW `tmp/` revision via `tools/new-revision.sh`. Structure: Objective; Current state (refs); Design; Boundary impact & fail-open risks; Phased tasks; Validation (`docker compose config` / `containment-lint` / `egress-test`); Open questions.
