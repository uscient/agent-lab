# AGENTS.md — Agent Lab operating rules

Agent Lab is a Docker-containment lab (bash + docker-compose). You are an agent **developing this
repo**. Work autonomously inside the boundary below; a `PreToolUse` guard enforces the edges so you
don't have to think about them. The guard is defense-in-depth — the **real** safety boundary is
containment (the network-off sandbox), not these rules. See `doctrine/containment.md`.

## Prime directives
- **Never** `git push`/`pull`, integrate remote state (`merge`/`rebase` from `origin/*`), or open a PR. The human owns the remote and the merge gate.
- **Commit freely** — but never on `master`/`main`. SessionStart puts you on `agent/<tool>/<slug>`; if not, create one before committing.
- **Don't edit the rails** (`AGENTS.md`, `doctrine/`, `policy/`, the guards, your tool config) unless explicitly doing maintenance (`AGENT_LAB_MAINTENANCE=1`).
- On a judgment call, read the cited `doctrine/` file and decide; prefer the reversible action.

## Autonomy boundary (act without prompts inside the left column)
| Auto — no prompt | Denied — guard blocks (exit 2) |
|---|---|
| read · edit · tests/build/lint · `git add`/`commit` · local `merge`/`rebase` · branch/switch · `git fetch`¹ · `git stash` | `push` · `pull` · remote `merge`/`rebase` · `gh pr`/remote-write · `git remote` mutation |
| | destructive: `rm -rf` · `reset --hard` · `clean -fdx` · history rewrite · broad `chmod`/`chown` · `sudo` · `sed -i` |
| | containment: `docker.sock` · `--privileged` · host-net · secret/`.env` writes |

¹ `fetch` is unavailable inside a **Codex** session (network-off by design); remote is refreshed outside it.

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
- `doctrine/git-workflow.md` — commit local; never push/pull/remote-integrate/PR; human owns the gate.
- `doctrine/containment.md` — the sandbox, not the guard, is the real boundary; never weaken it.
- `doctrine/destructive-ops.md` — irreversible ops are denied under autonomy; ask first.
- `doctrine/decision-authority.md` — GitHub is source of truth; what the human owns; reversible-first.

Done = a clean local commit on your branch + a short handoff. The human reviews and opens the PR.
