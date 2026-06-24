# Agent configuration — setup & maintenance

How the three coding agents that **develop Agent Lab** (Claude Code, Codex, Grok) are configured to
work autonomously inside a hard boundary: commit locally, never push/PR, never weaken containment.

> **Framing.** The `PreToolUse` guard is **defense-in-depth** — it makes the safe path automatic and
> catches mistakes and casual evasion. The **real** boundary is containment (the network-off sandbox,
> no Docker socket, no host mounts, internal-only network — see `SECURITY.md` / `THREAT_MODEL.md`).
> Read every "hard line" here as "defense-in-depth, backed by containment."

## Architecture — shared core + thin per-tool adapters

One policy, three thin adapters. Three single-sources-of-truth, zero hand-duplication:

| Concern | Single source | Consumed by |
|---|---|---|
| Instruction / doctrine | `AGENTS.md` + `doctrine/*.md` | auto-discovered by all three tools; doctrine read on demand |
| Enforcement logic | `tools/pretooluse-guard.sh` + `tools/session-bootstrap.sh` + `policy/*.patterns` | each tool's `PreToolUse` / `SessionStart` hook |
| Allow/deny rule bodies | `policy/allow.commands` + `policy/protected.paths` (+ guard's `deny.patterns`) | `tools/render-adapters.sh` → the three adapters |

```text
AGENTS.md  doctrine/  policy/            # shared core (instruction + enforcement data)
tools/pretooluse-guard.sh                # the one enforcement brain (PreToolUse: Bash + Edit/Write)
tools/session-bootstrap.sh               # SessionStart: never-on-master -> agent/<tool>/<slug>
tools/render-adapters.sh                 # generates the adapter rule bodies
tools/codex-permission-request.sh        # Codex PermissionRequest approver (mirrors policy)
tools/bin/{git,gh}                        # argv-level PATH shims (deep defense)
.claude/settings.json  .codex/{config.toml,hooks.json,rules/}  .grok/{config.toml,hooks/}
```

## Update a shared rule (the only place to edit)

1. Edit the **policy**, never an adapter:
   - command allow-set → `policy/allow.commands`
   - remote/destructive denials enforced by the guard → `policy/deny.patterns` / `policy/carveout.patterns`
   - read-only "rails" → `policy/protected.paths`
   - human-readable doctrine → `AGENTS.md` / `doctrine/*.md`
2. Regenerate the adapters (a maintenance action — see below):
   ```bash
   AGENT_LAB_MAINTENANCE=1 tools/render-adapters.sh
   ```
3. Verify: `bash tests/guard/pretooluse-cases.sh` and `bash tests/agent/policy-verify.sh`.

The guard reads `policy/*.patterns` directly, so policy edits take effect immediately for the guard;
the generator re-emits the per-tool belt-and-suspenders rules. **Never hand-edit the generated
regions** in `.claude/settings.json`, `.codex/rules/agent-lab.rules`, or `.grok/config.toml`.

## The `AGENT_LAB_MAINTENANCE=1` convention (and the self-lock)

The rails (`AGENTS.md`, `doctrine/`, `policy/`, the guard scripts, `tools/bin/`, the adapter dirs)
are in `policy/protected.paths`: the guard blocks Edit/Write and shell-mutation of them so an agent
can't quietly change its own guardrails. To **deliberately** maintain them, run the session with
`AGENT_LAB_MAINTENANCE=1` **exported in the launching shell** (so the hook subprocess inherits it):

```bash
AGENT_LAB_MAINTENANCE=1 claude        # or codex / grok
```

**Self-lock caution (important).** When you regenerate `.claude/settings.json` *inside* a running
Claude session, Claude may hot-reload it and start enforcing the new hook + denies against you. Two
rules avoid locking yourself out:
1. **Launch maintenance sessions with `AGENT_LAB_MAINTENANCE=1`.**
2. **Wire the Claude adapter last** — generate `.claude/settings.json` as the final maintenance step,
   after all other files are in place.
Note the guard's maintenance flag only relaxes the *guard*; Claude's *native* `permissions.deny`
rules have no maintenance bypass. The Claude adapter therefore keeps only the git/remote denies in
native `deny`; protected-path read-only enforcement is left to the guard's `Edit|Write` matcher
(which honors the flag), so maintenance stays possible.

## Per-tool setup / trust

| Tool | Setup |
|---|---|
| **Claude Code** | No trust step. `.claude/settings.json` is auto-loaded. |
| **Codex** | Trust the project so `.codex/` (config, hooks, rules) loads — Codex ignores an untrusted project's `.codex/`. Verify with a guard-fired check (a deliberately-bad command must print the guard's BLOCKED message). |
| **Grok** | Trust project hooks, or `.grok/hooks/` are **silently skipped** (and a policy check would falsely pass). Use `grok inspect` to confirm hooks/config were discovered, then run the guard-fired check. |

### Codex network-off runbook (intentional design decision)

Codex runs `sandbox_mode = "workspace-write"` with `network_access = false`. That blocks push
(good) **and** `git fetch`. So **`git fetch` is not available inside a Codex session — by design.**
Refresh remote state *outside* Codex **before** the session starts:

```bash
git fetch origin          # human / CI / wrapper, before launching codex
codex …                   # works against the freshly-fetched local refs
```

Do **not** add a network-on Codex profile to "fix" fetch — enabling network would remove the
sandbox layer from the push denial. Keeping fetch outside the session is the deliberate trade-off.

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
   + push-after-autonomy checks.
The shared guard/policy/AGENTS.md/doctrine are reused unchanged — that is the point of the architecture.

## Control plane vs data plane (don't conflate the two "Codex"/"Claude"/"Grok")

This config governs the tools **developing** Agent Lab (control plane). It does **not** govern agents
run **by** Agent Lab as contained workloads via `scripts/agent` / wrapped images (data plane) — those
are bounded by *containment* (internal network, Squid egress, no socket/host mounts, mount guards) and
may be doing unrelated work; the dev git-policy does not apply inside them.

- **Do not** bake the guard, shims, or git-policy into `scripts/agent` or wrapped images. The shims
  (`tools/bin`) and guard live host-side, in the editing path only.
- The `claude-code` / `codex` **egress-allowlist recipes** (`policies/recipes/*.allowlist`) are
  data-plane (API-host allowlists for a contained agent) — unrelated to the host `.codex/` / `.claude/`
  dev config. Keep them straight.
- *Optional dogfood path:* you may develop Agent Lab "in the box" by pointing
  `AGENT_LAB_PROJECT_DIR` at the repo root (RW) with a coding-agent image — caller configuration,
  not a baked runtime role. The repo-scoped configs travel with the repo, so an agent editing Agent
  Lab inherits the dev policy wherever it runs.
