# AGENTS.md — Agent Lab operating rules

Agent Lab is a Bash/Docker Compose containment lab. You are **developing this repo**.
Work inside this boundary; `PreToolUse` is defense-in-depth—the **real** safety boundary is
containment. See `SECURITY.md` and `THREAT_MODEL.md`.

Repo: `https://github.com/uscient/agent-lab` · authoritative branch: `dev`

## Prime directives

- **Use the branch-derived route.** `dev`, `flow`, `master`, and `main` are protected. Ordinary and
  `work/*` branches PR to `dev` — the route for all new work. The `group/<group>`→`flow` program
  topology is **dormant**: still guard-enforced, but do not open new Group work. A Group branch
  receives changes only through matching group-slice PRs; `<group>` is at most 48 chars matching
  `[gb][0-9]+[a-z]?-[a-z0-9][a-z0-9-]*`; `slice/<work>/<slice>` and `slice/group/<group>/<slice>`
  target only their matching parent.
- **Integrate through PRs; retain history.** Local merge/rebase is allowed on ordinary work branches.
  `scripts/dev/workstream merge` is the sole agent merge into a reserved parent: verified
  slice→work, group-slice→group, or accepted group→`flow`. It requires current-base successful checks
  and a merge commit. Humans alone merge final PRs into `dev`. Never push, commit, Git-merge, or
  rebase a protected branch.
- **Sync without erasing accepted merges.** Use `scripts/dev/workstream sync` on workstreams and
  slices; `group-sync` prepares the PR-only Group merge while that topology stays dormant. Never
  rebase or force-update program groups or group slices; legacy slices rebase only on their matching
  parent. Replay evidence after every sync. Never squash accepted history or delete integration
  branches/PR evidence.
- **Don't edit the rails** (`AGENTS.md`, `policy/`, guards, protected workflow/helper/check paths, or
  tool configuration) unless explicitly doing maintenance (`AGENT_LAB_MAINTENANCE=1`).
- **Never inspect or change GitHub authentication, credentials, tokens, account settings, or Git
  attribution configuration.** Prefer reversible actions.

## Autonomy boundary (act without prompts inside the left column)

| Auto — no prompt | Denied — guard blocks (exit 2) |
|---|---|
| read · edit · tests/build/lint · `git add` · commit on non-reserved branches and slices · branch/switch · `git fetch`¹ · `git stash` · allowed local merge/rebase, workstream sync, or PR-only Group sync preparation · push the current non-Group writable branch to same-named `origin` (`--force-with-lease` only after an allowed non-program rebase)¹ · repository-scoped read-only `gh pr`/`gh run`/GET-only `gh api` · exact branch-derived PR creation¹ · verified `scripts/dev/workstream` intermediate integration¹ | write/integrate `dev`/`flow`/`master`/`main` directly · `pull` · integration from an unrelated remote base · direct commit/push/update of `group/*` · program-branch force/rebase · plain `--force`, remote/forced branch deletion, mirror push · direct PR merge or other unscoped `gh` remote write · `git remote` mutation · `gh auth` · Git identity/attribution mutation |
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

- Serena is a no-network development container, never runtime or authority. Bash LSP uses
  `agent-lab-dev` at `/workspace`.
- Before semantic work, call `get_current_config`; if inactive, `activate_project` on `/workspace`.
  Then prove readiness with a symbol operation. Start with an overview or targeted symbol;
  inspect declarations/references before bounded semantic edits.
- Ignored `proj/` is writable state without links or IPC. Use ordinary tools for prose, config,
  extensionless Bash and Python smoke. Report Serena failures.
- After edits, inspect symbols, diagnostics, and gates. Activation plus `list_memories` checks
  onboarding. Never store secrets, transient IDs, or host paths. See `docs/serena.md`.

## Authority

- `AGENTS.md` is the sole operating-policy source for agents developing this repository.
- GitHub governs integration. Humans own `dev` merges, releases, settings, auth, and policy, and
  create/protect `flow` only at the exact closure commit containing R0 — still CI-enforced, though
  the program topology it serves is dormant.
- Agents may publish their current branch, open only its derived PR route, and perform only the
  verified intermediate merges above. Explicit rail maintenance requires `AGENT_LAB_MAINTENANCE=1`.

Done = the scoped verified change is merged, or its PR to `dev` is open, plus a short handoff.
Humans merge every final PR into `dev`.

---
_Updated 2026-08-07_
