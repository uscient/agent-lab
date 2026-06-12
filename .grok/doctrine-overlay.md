# Grok — mutation-policy overlay (agent-lab)

Grok Build (official `grok`) reads AGENTS.md + CLAUDE.md natively; community grok-cli reads AGENTS.md. The containment doctrine in AGENTS.md is authoritative; this overlay adds the mutation policy.

## Posture
- **Default to Plan mode** (`/plan`) — blocks write tools = "no edits unless told". Leave it only for a specific instructed change.
- Approvals **manual** — never `--always-approve` / `permission_mode = "always-approve"`.
- `grok inspect` confirms the loaded config + instructions.

## Discipline (not tool-enforced)
- Never commit / push / PR (suggest a commit message only).
- Generated docs → `tmp/`, NEW revision per change (`tools/new-revision.sh`).
- Preserve AGENTS.md containment invariants (ports / mounts / privileges / secrets / egress).

## Validation
`docker compose config` + `tools/containment-lint.sh` (`tools/validate.sh`). No full `up` to "check".

## Caveat
Grok Build is early beta; keys evolve. Verify with `grok inspect` and adjust. Behaviour is the contract: read-only/plan default, manual approval, `tmp/`-only writes, containment preserved. Set your real model in `settings.json`.
