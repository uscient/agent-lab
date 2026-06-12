---
description: Read-only investigation of agent-lab → tmp/
---
READ-ONLY recon — no edits, no container starts, no network. Read ../AGENTS.md first.

Target: $ARGUMENTS

Inspect tracked source and the Compose topology. Flag any boundary risk: public ports, host/socket/home mounts, privileged, unpinned images, secrets in tracked files, egress that bypasses the proxy. Ground in `path:line`. Run `tools/containment-lint.sh` and fold in results. Write a NEW `tmp/` revision via `tools/new-revision.sh`. Never print secret values.
