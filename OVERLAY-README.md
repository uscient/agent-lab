# agent-lab — mutation-policy overlay

Unzip these files **into your existing `agent-lab/` project root.** They ADD the mutation-policy enforcement and helper tools that agent-lab's committed config didn't include — and they overwrite nothing (every filename is new). Run `unzip -l` first to confirm.

## Source of truth is unchanged
**`agent-lab/AGENTS.md` remains authoritative** for the security/containment doctrine (network, filesystem, privilege, secret, and supply-chain invariants; threat model; hard stops; ask-before list). This overlay does not touch it. It only layers the same *mutation policy* used at the workspace top level, expressed in each tool's enforcement primitives.

## What it adds
| Path | Purpose |
|------|---------|
| `.claude/settings.json` | Committed enforcement: `defaultMode: plan`, deny git mutation/PR + secrets/control-plane, `ask` on edits, PreToolUse hook. Extends the existing `settings.local.example.json`. |
| `.claude/commands/{plan,recon,revise}.md` | `tmp/`-writing, security-aware slash commands (alongside agent-lab's existing review commands). |
| `.claude/doctrine-overlay.md` | How the mutation policy maps onto Claude Code. |
| `.codex/config.toml` | Read-only sandbox by default; opt-in `--profile edit`. (agent-lab had only `.codex/prompts/`.) |
| `.codex/doctrine-overlay.md` | Codex mapping. |
| `.grok/{config.toml,settings.json,doctrine-overlay.md}` | Grok Build / grok-cli config (agent-lab had none). |
| `tools/pretooluse-guard.sh` | Hard stop: git mutation, `gh pr`, `sed -i`, `rm -rf`, sudo, control-plane writes — **plus** docker.sock / `--privileged` / host-net / secret writes. |
| `tools/containment-lint.sh` | Content scan for boundary breaks + real secrets (complements `scripts/dev/guard-diff`). |
| `tools/validate.sh` | `docker compose config` + containment-lint. Never `up`. |
| `tools/new-revision.sh` | New lineage-named `tmp/` revision (never overwrite). |
| `tmp/.gitkeep` | Agent working docs land here as revisions. |

## Same mutation policies as the top level
- No commit / push / PR — git authority is the human's (suggest a commit message only).
- No edits unless told — plan mode is the default; editing is opt-in per task.
- All agent docs → `tmp/` as NEW revisions.
- Smallest useful patch; strict, docker-aware bash; read selectively / cite `path:line`.

## Note
This overlay's `settings.json` is intentionally stricter than agent-lab's "allowed work without approval" list (the stricter rule wins): it tightens those into "plan + explicit edit, never commit," while `AGENTS.md` continues to carry the real security boundary. `tmp/` isn't in agent-lab's `.gitignore` — add it, or route handoffs to your Drive convention, if you don't want working docs tracked.
