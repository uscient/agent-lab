# Agent configuration — setup & maintenance

How the three coding agents that **develop Agent Lab** (Claude Code, Codex, Grok) are configured to
work autonomously inside the `AGENTS.md` boundary: develop on a writable branch, publish only that
branch, follow its derived PR route, use the verified helper for allowed intermediate merges, leave
every final merge into `dev` to a human, and never weaken containment.

For the normal maintainer workflow and gates, start with
[Development and verification](development.md). This page is the specialist reference for client
policy wiring.

> **Framing.** The `PreToolUse` guard is **defense-in-depth** — it makes the safe path automatic and
> catches mistakes and casual evasion. The **real** boundary is containment (the sandbox,
> no Docker socket, no broad or whole home-directory mounts, internal-only network — see
> `SECURITY.md` / `THREAT_MODEL.md`).
> Read every "hard line" here as "defense-in-depth, backed by containment."

## Architecture — shared core + thin per-tool adapters

One operating policy, shared enforcement, and three generated thin adapters:

| Concern | Single source | Consumed by |
|---|---|---|
| Operating policy | `AGENTS.md` | auto-discovered by all three tools |
| Enforcement logic | `tools/pretooluse-guard.sh` + `tools/session-bootstrap.sh` + `policy/*.patterns` | command, file, secret-read, Serena-mutation, and session hooks |
| Native adapter rule bodies | `policy/allow.commands` + `NATIVE_DENY` in `tools/render-adapters.sh` | `tools/render-adapters.sh` → the three adapters |

```text
AGENTS.md  policy/                       # shared core (instruction + enforcement data)
tools/pretooluse-guard.sh                # PreToolUse: command, read/write, and Serena mutations
tools/session-bootstrap.sh               # SessionStart: dev/master/main -> work branch; flow read-only
tools/render-adapters.sh                 # generates the adapter rule bodies
tools/codex-permission-request.sh        # Codex PermissionRequest approver (mirrors policy)
tools/bin/{git,gh}                        # optional argv-level PATH shims
.claude/settings.json  .codex/{config.toml,hooks.json,rules/}  .grok/{config.toml,hooks/}
```

The tracked client configurations wire the hooks and native rules directly. They do not prepend
`tools/bin` to `PATH`. The Git/GitHub shims are an optional additional layer for a launcher that
chooses to put them first; do not claim shim coverage unless that PATH setup is verified in the
actual session.

## Update a shared rule (the only place to edit)

1. Edit the **policy**, never an adapter:
   - command allow-set → `policy/allow.commands`
   - remote/destructive denials enforced by the guard → `policy/deny.patterns` / `policy/carveout.patterns`
   - read-only "rails" → `policy/protected.paths`
   - human-readable operating policy → `AGENTS.md`
2. Regenerate the adapters (a maintenance action — see below):
   ```bash
   AGENT_LAB_MAINTENANCE=1 tools/render-adapters.sh
   ```
3. Verify: `bash tests/guard/pretooluse-cases.sh` and `bash tests/agent/policy-verify.sh`.

The guard reads `policy/*.patterns` directly, so policy edits take effect immediately for the guard;
the generator re-emits the per-tool belt-and-suspenders rules. **Never hand-edit the generated
regions** in `.claude/settings.json`, `.codex/rules/agent-lab.rules`, or `.grok/config.toml`.

## The `AGENT_LAB_MAINTENANCE=1` convention (and the self-lock)

`policy/protected.paths` is the complete rail inventory. It includes `AGENTS.md`, policy, guards,
shims, adapters, workflows, the workstream and workflow-check helpers, required-gate reducers and
manifests, and their contract tests. The guard blocks Edit/Write and shell mutation of those paths so
an agent can't quietly change its own guardrails. To **deliberately** maintain them, run the session
with `AGENT_LAB_MAINTENANCE=1` **exported in the launching shell** (so the hook subprocess inherits it):

```bash
AGENT_LAB_MAINTENANCE=1 claude        # or codex / grok
```

**Self-lock caution (important).** When you regenerate `.claude/settings.json` *inside* a running
Claude session, Claude may hot-reload it and start enforcing the new hook + denies against you. Two
rules avoid locking yourself out:
1. **Launch maintenance sessions with `AGENT_LAB_MAINTENANCE=1`.**
2. **Wire the Claude adapter last** — generate `.claude/settings.json` as the final maintenance step,
   after all other files are in place.
Note the guard's maintenance flag only relaxes the *guard*; native `deny` rules have no maintenance
bypass. The Claude and Grok adapters therefore keep only unconditional command and secret-read
denials in native `deny`; protected-path enforcement is left to their `Edit|Write` guard hooks
(which honor the flag), so maintenance stays possible.

## Per-tool setup / trust

| Tool | Setup |
|---|---|
| **Claude Code** | No trust step. `.claude/settings.json` is auto-loaded. |
| **Codex** | Trust the project so `.codex/` (config, hooks, rules) loads — Codex ignores an untrusted project's `.codex/`. Verify with a guard-fired check (a deliberately-bad command must print the guard's BLOCKED message). |
| **Grok** | Trust project hooks, or `.grok/hooks/` are **silently skipped** (and a policy check would falsely pass). Use `grok inspect` to confirm hooks/config were discovered, then run the guard-fired check. |

### Codex scoped-network runbook

Codex runs `sandbox_mode = "workspace-write"` with network access enabled for the repository
workflow. `AGENTS.md`, the guard, and protected-branch rules scope that access:

```bash
# Ordinary branch:
git fetch origin dev
git rebase origin/dev
git push -u origin HEAD
gh pr create --base dev ...

# Reserved workstream and program branches:
./scripts/dev/workstream sync
./scripts/dev/workstream pr ...       # matching slice -> parent
./scripts/dev/workstream group-pr ... # group -> flow, draft
./scripts/dev/workstream final ...    # work or flow -> dev, draft
./scripts/dev/workstream merge 123    # approved intermediate only
```

Ordinary branches rebase on `origin/dev`; reusable workstreams, program groups, and group slices use
merge-preserving `workstream sync` with their exact parent. Those integration branches are never
rebased or force-updated. `dev`, `flow`, `master`, and `main` are protected, and a `flow`
checkout stays read-only. Direct protected writes, plain force pushes, direct PR merge/mutation, remote
mutation, GitHub authentication access, and Git attribution changes remain forbidden. The only
agent merge exception is `scripts/dev/workstream merge` for a verified slice→work,
group-slice→group, or approved group→`flow` PR. Humans alone merge final PRs into `dev`.

The repository guards do not configure GitHub. Humans must install the required `CI / Required
gates` and `CodeQL` checks, current-base or merge-queue rule, latest-push approval, merge-only history,
branch retention, and trusted rail ownership described in [Workstreams and programs](workstreams.md).
Runtime credentials are used implicitly by Git/GitHub tooling; agents must never inspect or modify
them.

## Forbidden flags (never use these as the autonomy mechanism)

Autonomy comes from `acceptEdits` (Claude) / `on-request` + `workspace-write` (Codex) /
`always-approve` + denies (Grok) — **never** a global approve-all that would also disarm the denials:

- Codex: `--yolo`, `--dangerously-bypass-approvals-and-sandbox`, `sandbox_mode = "danger-full-access"`, deprecated `codex exec --full-auto`, `--ignore-rules`.
- Grok: `--yolo` **without** deny rules + hook (always pair them).
- Claude: `permissions.defaultMode = "bypassPermissions"`.

## Add a 4th tool

1. Add a thin adapter dir (e.g. `.cursor/`) that wires the tool's `PreToolUse` hook to
   `tools/pretooluse-guard.sh` and its `SessionStart` to `tools/session-bootstrap.sh <tool>`.
2. Add an `emit_<tool>` branch to `tools/render-adapters.sh` that translates `policy/allow.commands`
   + the deny set into the tool's native rule syntax; add the dir to `policy/protected.paths`.
3. Add the tool's rows to `tests/agent/agent-policy-checklist.md` and run the guard-fired + no-prompt
   + scoped-publish checks.
The shared guard/policy/AGENTS.md are reused unchanged — that is the point of the architecture.

## Control plane vs data plane (don't conflate the two "Codex"/"Claude"/"Grok")

This config governs the tools **developing** Agent Lab (control plane). It does **not** govern agents
run **by** Agent Lab as contained workloads via `scripts/agent` / wrapped images (data plane) — those
are bounded by *containment* (internal network, Squid egress, no socket or broad host mounts, guarded
project/secrets mounts) and may be doing unrelated work; the dev git-policy does not apply inside
them.

- **Do not** bake the guard, shims, or git-policy into `scripts/agent` or wrapped images. The shims
  (`tools/bin`) and guard live host-side, in the editing path only.
- The `claude-code` / `codex` **egress-allowlist recipes** (`policies/recipes/*.allowlist`) are
  data-plane (API-host allowlists for a contained agent) — unrelated to the host `.codex/` / `.claude/`
  dev config. Keep them straight.
- *Optional dogfood path:* you may develop Agent Lab "in the box" by pointing
  `AGENT_LAB_PROJECT_DIR` at the repo root (RW) with a coding-agent image — caller configuration,
  not a baked runtime role. Select a secrets directory outside that project tree; the data-plane
  launcher rejects overlapping project/secrets paths. The repo-scoped configs travel with the repo,
  but the coding client must still trust and load them. Verify a guard-fired denial before claiming
  the development policy is active.

### Serena is a contained control-plane helper

The repo-scoped clients also register Serena MCP. Its launcher does not reuse the data-plane
`agent` service because that service deliberately has workload secrets and a configurable image,
home, project, and egress policy. Instead, `scripts/serena-mcp` starts the fixed
`compose.serena.yaml` service with `network_mode: none`, no home/secret/socket mounts, and this
repo as the only content-bearing RW project bind at `/workspace`. Read-only overlays mask Git,
local state, and protected rails, while a private temporary bind isolates `.serena/cache`. This
preserves the control-plane/data-plane distinction while containing the development helper itself.
All binds are private and non-recursive, and the launcher rejects child mounts or nested Git
metadata before startup. Client registrations also remove `BASH_ENV` and `ENV` before invoking a
non-login, no-profile Bash for repository-root discovery.

Do not use Serena's user-global setup commands for this repo and do not add `--project` or
`--project-from-cwd` to the registration. The repository launcher must start recoverably so all
clients can perform the explicit activation sequence in
[Using Serena to develop Agent Lab](serena.md).

Related guides:

- [Documentation map](README.md)
- [Architecture](architecture.md)
- [CI gate mapping](ci.md)
