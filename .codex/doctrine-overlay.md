# Codex — mutation-policy overlay (agent-lab)

Codex reads **AGENTS.md** natively — the containment doctrine is authoritative. This overlay adds the mutation policy agent-lab lacked.

## Posture
- Default `config.toml`: `sandbox_mode = read-only` + `approval_policy = on-request` → inspect & plan only (OS sandbox is the hard stop for "no edits unless told").
- Edit **when told**: `codex --profile edit`. Never `danger-full-access`; never `never` outside the read-only `ci` profile.
- `.git`/`.codex` auto-protected. `.claude / .grok / .devguard`, `.env*`, and `secrets/` are off-limits — discipline + the PreToolUse hook (shell) enforce this; add custom protected paths if your version supports them.

## Discipline (not sandbox-enforced)
- Never commit / push / PR — git authority is the human's (suggest a commit message only).
- Generated docs → `tmp/`, NEW revision per change (`tools/new-revision.sh`).
- Preserve containment invariants (AGENTS.md): no public ports, no socket/home mounts, no privileged, no real secrets, egress only via the proxy.

## Validation
`docker compose config`, `tools/containment-lint.sh`, `tools/validate.sh`. Avoid full `up`/builds unless the task requires it and you're told. Reuse the existing `.codex/prompts/*` for compose security review and egress tests.

## Verify
`/status` — confirm sandbox + approval resolved as configured.
