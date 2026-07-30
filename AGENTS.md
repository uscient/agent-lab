# AGENTS.md — Agent Lab operating rules

Agent Lab is a Docker-containment lab (bash + docker-compose). You are an agent **developing this
repo**. Work autonomously inside the boundary below; a `PreToolUse` guard enforces the edges so you
don't have to think about them. The guard is defense-in-depth — the **real** safety boundary is
containment (the network-off sandbox), not these rules. See `doctrine/containment.md`.

Repo: `https://github.com/uscient/agent-lab` · base branch: `dev`

## Prime directives
- **Work on a branch created from `dev`** — any name. SessionStart puts you on a working branch; if not, create one before committing. Commit freely on it; never commit on `dev`/`master`/`main`.
- **Integrate remote state one way: rebase your branch on `origin/dev`** (`fetch`, then rebase; `git push --force-with-lease` to update your pushed branch afterward).
- **Push your branch and open a PR to `dev`** when the work is done. Integration into `dev` happens only via PR; the human reviews and merges. Never push to `dev`/`master`/`main` directly.
- **Don't edit the rails** (`AGENTS.md`, `doctrine/`, `policy/`, the guards, your tool config) unless explicitly doing maintenance (`AGENT_LAB_MAINTENANCE=1`).
- On a judgment call, read the cited `doctrine/` file and decide; prefer the reversible action.

## Autonomy boundary (act without prompts inside the left column)
| Auto — no prompt | Denied — guard blocks (exit 2) |
|---|---|
| read · edit · tests/build/lint · `git add`/`commit` · local `merge`/`rebase` · branch/switch · `git fetch`¹ · `git stash` · rebase on `origin/dev` · `git push` (your branch; `--force-with-lease` after rebase)¹ · `gh pr create` (base `dev`)¹ | push to `dev`/`master`/`main` · `pull` · `merge`/`rebase` from `origin/*` other than the `origin/dev` rebase · PR merge & other `gh` remote-writes · `git remote` mutation |
| | destructive: `rm -rf` · `reset --hard` · `clean -fdx` · history rewrite (outside your branch's rebase) · broad `chmod`/`chown` · `sudo` · `sed -i` |
| | containment: `docker.sock` · `--privileged` · host-net · secret/`.env` writes |

¹ Remote operations (`fetch`/`push`/`gh pr`) are unavailable inside a **Codex** session (network-off by design); they happen outside it.

## Commands — the real stack
| Do | Run |
|---|---|
| lint | `./scripts/dev/lint-scripts` |
| test | `./scripts/dev/test quick` (or `full`) |
| check (umbrella) | `./scripts/dev/check default quick` |
| containment validate | `./tools/validate.sh` · `./tools/containment-lint.sh` |
| unit tests | `bash tests/guard/pretooluse-cases.sh` · `bash tests/guard/cases.sh` · `bash tests/agent/*.sh` |
| orient | `./scripts/dev/brief` · `./scripts/dev/changed` · `./scripts/doctor` |
| stack | `./scripts/up [core\|egress\|devtools]` · `./scripts/down` · `./scripts/agent` |

No MCP / external integrations. No secret access. Stay inside containment (`SECURITY.md`, `THREAT_MODEL.md`).

## Doctrine — read on demand (guard denials cite the file)
- `doctrine/meta.md` — don't edit the rails unless tasked with maintenance.
- `doctrine/git-workflow.md` — branch from `dev`; rebase on `origin/dev` to stay current; push your branch; PR to `dev`; the human reviews and merges.
- `doctrine/containment.md` — the sandbox, not the guard, is the real boundary; never weaken it.
- `doctrine/destructive-ops.md` — irreversible ops are denied under autonomy; ask first.
- `doctrine/decision-authority.md` — GitHub is source of truth; what the human owns; reversible-first.

Done = your branch pushed + a PR open to `dev` + a short handoff. The human reviews and merges.

---
_Updated 2026-07-30_