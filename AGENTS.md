# AGENTS.md — Agent Lab operating rules

Agent Lab is a Docker-containment lab (Bash + Docker Compose). You are an agent **developing this
repo**. Work autonomously inside the boundary below; a `PreToolUse` guard enforces the edges. The
guard is defense-in-depth—the **real** safety boundary is containment. See `SECURITY.md` and
`THREAT_MODEL.md`.

Repo: `https://github.com/uscient/agent-lab` · authoritative branch: `dev`

## Prime directives

- **Use the branch-derived route.** `dev`, `flow`, `master`, and `main` are protected. Ordinary and
  `work/*` branches PR to `dev`. A `group/<group>` branch tracks `origin/flow`
  and PRs to `flow`; `<group>` is at most 48 characters and matches
  `[gb][0-9]+[a-z]?-[a-z0-9][a-z0-9-]*`. Legacy
  `slice/<work>/<slice>` and literal group `slice/group/<group>/<slice>` branches target only their
  matching parent.
- **Integrate through PRs and retain history.** `scripts/dev/workstream merge` is the only agent
  merge path: verified slice→work, group-slice→group, and approved group→`flow`. It requires the
  current base and successful checks and uses a merge commit. Humans alone merge final ordinary,
  workstream, or `flow` PRs into `dev`. Never directly push, commit, Git-merge, or rebase a protected
  branch.
- **Sync without erasing accepted merges.** Use `scripts/dev/workstream sync` on reserved branches.
  Workstreams, program groups, and group slices merge their moving parent and may never be rebased or
  force-updated; legacy slices may rebase only on their matching parent. Replay evidence after every
  sync. Never squash accepted history or delete integration branches/PR evidence.
- **Don't edit the rails** (`AGENTS.md`, `policy/`, guards, protected workflow/helper/check paths, or
  tool configuration) unless explicitly doing maintenance (`AGENT_LAB_MAINTENANCE=1`).
- **Never inspect or change GitHub authentication, credentials, tokens, account settings, or Git
  attribution configuration.** On a judgment call, prefer the reversible action.

## Autonomy boundary (act without prompts inside the left column)

| Auto — no prompt | Denied — guard blocks (exit 2) |
|---|---|
| read · edit · tests/build/lint · `git add`/`commit` · branch/switch · `git fetch`¹ · `git stash` · exact allowed rebase or workstream sync · push the current branch to its same-named `origin` branch (`--force-with-lease` only after an allowed non-program rebase)¹ · read-only `gh pr`/`gh run` · exact branch-derived PR creation¹ · verified `scripts/dev/workstream` intermediate integration¹ | write/integrate `dev`/`flow`/`master`/`main` directly · `pull` · integration from an unrelated remote base · program-branch force/rebase · plain `--force`, branch deletion, mirror push · direct PR merge or other unscoped `gh` remote write · `git remote` mutation · `gh auth` · Git identity/attribution mutation |
| | destructive: `rm -rf` · `reset --hard` · `clean -fdx` · unapproved history rewrite · broad `chmod`/`chown` · `sudo` · `sed -i` |
| | containment: `docker.sock` · `--privileged` · host-net · secret/`.env` writes |

¹ Remote operations depend on the active runtime having network access. If unavailable, finish local
work and report the publication blocker accurately.

## Commands — the real stack

| Do | Run |
|---|---|
| lint | `./scripts/dev/lint-scripts` |
| test | `./scripts/dev/test quick` (or `full`) |
| check (umbrella) | `./scripts/dev/check default quick` |
| containment validate | `./tools/validate.sh` · `./tools/containment-lint.sh` |
| unit tests | `bash tests/guard/pretooluse-cases.sh` · `bash tests/guard/cases.sh` · `bash tests/agent/*.sh` |
| orient | `./scripts/dev/brief` · `./scripts/dev/changed` · `./scripts/doctor` |
| workstream/program | `./scripts/dev/workstream` · see `docs/workstreams.md` |
| stack | `./scripts/up [core\|egress\|devtools]` · `./scripts/down` · `./scripts/agent` |
| Serena | `./scripts/dev/serena-build` · `./scripts/dev/serena-smoke` |

Use integrations only for the scoped repository/GitHub workflow. No secret access. Never weaken
containment (`SECURITY.md`, `THREAT_MODEL.md`).

## Serena — semantic development tooling

- Serena runs in its dedicated no-network container; it is not a workload, runtime dependency,
  authority system, or source of truth. Its project is `agent-lab-dev` at `/workspace`, using Bash LSP.
- Before substantial semantic work, call `get_current_config`. A fresh pinned session may return
  `No active project`; call `activate_project` on `/workspace`, then `get_current_config` again.
  Activation is not readiness—complete a live symbol operation.
- Start with `get_symbols_overview` or targeted `find_symbol`; use `find_declaration` and
  `find_referencing_symbols` for impact. Prefer bounded semantic editors when boundaries are reliable.
- Shared ignored `proj/` is writable ordinary-file state; no links or IPC. Use ordinary tools for
  it, prose, config, partial text, extensionless Bash, and Python smoke. Report Serena failures.
- After edits, inspect affected symbols, call `get_diagnostics_for_file`, and run normal gates.
  Activation plus `list_memories` is the onboarding check. Never store secrets, transient IDs, or
  host-only paths. See `docs/serena.md`.

## Authority

- `AGENTS.md` is the sole operating-policy source for agents developing this repository.
- GitHub is the integration source of truth. Humans create and protect initial `flow` at the exact R0
  `dev` SHA, own final merges into `dev`, releases, protected settings, authentication, and policy.
- Agents may publish their current branch, open only its derived PR route, and perform only the
  verified intermediate merges above. Explicit rail maintenance requires `AGENT_LAB_MAINTENANCE=1`.

Done = the scoped verified slice/group integration is complete, or the final draft PR to `dev` is
open, plus a short handoff. Humans merge every final PR into `dev`.

---
_Updated 2026-08-03_
