# Claude Code — mutation-policy overlay (agent-lab)

**Security doctrine is `../AGENTS.md`** (containment invariants, threat model, hard stops, ask-before list). This overlay only adds the *mutation-policy enforcement* agent-lab's committed config was missing — it does not replace AGENTS.md.

## What this overlay enforces (same policy as the workspace top level)
- **Plan mode is the default** (`settings.json` → `defaultMode: plan`): read-only until you exit plan mode for a specific, instructed change. Stricter than AGENTS.md's "allowed work without approval" — the stricter rule wins.
- **Never commit / push / PR.** Deny rules + the PreToolUse hook block git add/commit/push/merge/tag and `gh pr`. Suggest a commit message in your report; the human commits.
- **`ask` on every Edit/Write**; `allow` read + `docker compose config` + read-only scripts + `tmp/` writes; control planes, `.env`, and `secrets/` are deny.
- **PreToolUse hook** (`tools/pretooluse-guard.sh`) is the real stop: git mutation, `gh pr`, `sed -i`, `rm -rf`, `sudo`, control-plane writes, **and agent-lab boundary breaks** — docker.sock mounts, `--privileged`, host networking, shell writes to `.env`/secrets.

## Validation (not cargo — this is a containment lab)
`tools/validate.sh` = `docker compose config` + `tools/containment-lint.sh`. Never `docker compose up` a full stack to "check"; use `config`. The sanctioned acceptance test is `./scripts/egress-test` (ask first — it starts the disposable test container).

## Output & style
All generated docs → `tmp/` as NEW revisions (`tools/new-revision.sh`). Smallest useful patch (AGENTS.md implementation style). Read selectively; cite `path:line`; never print secret values.

## Verify
`/permissions` confirms plan mode + denies + hook. This committed `settings.json` supersedes the conservative `settings.local.example.json`; keep your personal `settings.local.json` for machine-specific overrides only.
