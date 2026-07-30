# AGENTS.md — Agent Lab operating rules

Agent Lab is a Docker-containment lab (bash + docker-compose). You are an agent **developing this
repo**. Work autonomously inside the boundary below; a `PreToolUse` guard enforces the edges so you
don't have to think about them. The guard is defense-in-depth — the **real** safety boundary is
containment, not these rules. See `SECURITY.md` and `THREAT_MODEL.md`.

Repo: `https://github.com/uscient/agent-lab` · base branch: `dev`

## Prime directives
- **Work on a branch created from `dev`** — any name. SessionStart puts you on a working branch; if not, create one before committing. Commit freely on it; never commit on `dev`/`master`/`main`.
- **Integrate remote state one way: rebase your branch on `origin/dev`** (`fetch`, then rebase; `git push --force-with-lease` to update your pushed branch afterward).
- **Push your branch and open a PR to `dev`** when the work is done. Integration into `dev` happens only via PR; the human reviews and merges. Never push to `dev`/`master`/`main` directly.
- **Don't edit the rails** (`AGENTS.md`, `policy/`, the guards, your tool config) unless explicitly doing maintenance (`AGENT_LAB_MAINTENANCE=1`).
- **Never inspect or change GitHub authentication, credentials, tokens, account settings, or Git attribution configuration.**
- On a judgment call, prefer the reversible action.

## Autonomy boundary (act without prompts inside the left column)
| Auto — no prompt | Denied — guard blocks (exit 2) |
|---|---|
| read · edit · tests/build/lint · `git add`/`commit` · local `merge`/`rebase` · branch/switch · `git fetch`¹ · `git stash` · rebase on `origin/dev` · push the current branch to its same-named `origin` branch (`--force-with-lease` after rebase)¹ · read-only `gh pr` · `gh pr create --base dev`¹ | push to `dev`/`master`/`main` · `pull` · `merge`/`rebase` from `origin/*` other than the `origin/dev` rebase · plain `--force`, branch deletion, mirror push · PR merge & other `gh` remote-writes · `git remote` mutation · `gh auth` · Git identity/attribution mutation |
| | destructive: `rm -rf` · `reset --hard` · `clean -fdx` · history rewrite (outside your branch's rebase) · broad `chmod`/`chown` · `sudo` · `sed -i` |
| | containment: `docker.sock` · `--privileged` · host-net · secret/`.env` writes |

¹ Remote operations depend on the active runtime having network access. If it does not, finish the local work and report the publication blocker accurately.

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
| Serena | `./scripts/dev/serena-build` · `./scripts/dev/serena-smoke` |

Use integrations only for the scoped repository/GitHub workflow. No secret access. Never weaken containment (`SECURITY.md`, `THREAT_MODEL.md`).

## Serena — semantic development tooling
- Serena runs in its dedicated no-network container; it is not an Agent Lab workload, runtime dependency, authority system, or source of truth. Its logical project is `agent-lab-dev` at container path `/workspace`, using the Bash LSP backend.
- Before substantial semantic work, call `get_current_config`. In the pinned Serena version, a fresh session returns the expected `isError` state `No active project`; recover with `activate_project` on `/workspace`, then call `get_current_config` again. Activation alone is not readiness—complete a live symbol operation.
- Start with `get_symbols_overview` or targeted `find_symbol`, retrieve only needed bodies, and use `find_declaration` / `find_referencing_symbols` to assess impact. Prefer the usable bounded semantic editors—`replace_symbol_body`, `insert_before_symbol`, and `insert_after_symbol`—when the change matches a reliable symbol boundary.
- Use ordinary search/edit tools for prose, configuration, generated data, partial text changes, extensionless Bash entrypoints, and the stdlib-only Python smoke harness, which are outside the configured Bash semantic scope. If this follows a Serena failure, state the failure instead of claiming semantic verification.
- After edits, inspect the affected symbols and call `get_diagnostics_for_file`; then run the normal tests/lint/build separately. Serena never replaces repository gates.
- The activation response plus `list_memories` is the current onboarding check. Keep any future memory factual and project-specific; never store secrets, tokens, transient container IDs, or host-only paths. See `docs/serena.md` for failure-state diagnosis and smoke evidence.

## Authority
- `AGENTS.md` is the sole operating-policy source for agents developing this repository.
- GitHub is the integration source of truth. Agents may fetch, publish their own work branch, and open a PR to `dev`.
- Humans own review, merge, releases, protected branches, credentials/authentication, and policy approval.
- Explicit rail maintenance requires `AGENT_LAB_MAINTENANCE=1`; ordinary tasks must not mutate the rails.

Done = your branch pushed + a PR open to `dev` + a short handoff. The human reviews and merges.

---
_Updated 2026-07-30_
