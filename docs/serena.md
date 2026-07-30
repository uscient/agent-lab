# Serena development integration

Serena is a repository-scoped semantic development tool for Agent Lab. It is not a workload
dependency, an authority system, or canonical project state. `AGENTS.md`, source, and the normal
repository checks remain authoritative.

## Placement and pinned toolchain

`scripts/serena-mcp` starts a one-shot `compose.serena.yaml` service rather than running the host
Serena installation or reusing the general `agent` service. The dedicated placement is necessary:
the general service mounts workload secrets and configurable home state, while Serena needs only
the current source tree and language-server processes.

The runtime has:

- logical project `agent-lab-dev`;
- project root `/workspace`, bound RW from this repository;
- private temporary RW storage over `/workspace/.serena/cache`;
- empty or read-only overlays for Git metadata, local environment/state paths, and protected rails;
- private, non-recursive binds plus a fail-closed child-mount and nested-`.git` preflight;
- `network_mode: none`;
- read-only root filesystem and tmpfs-only global Serena state;
- no host home, secret, credential, token, Docker socket, proxy, or port;
- non-root UID/GID, all capabilities dropped, no-new-privileges, and resource limits.

The image installs the clean tree at Serena commit
`6c1c9653700cbe644cb5a5b026b77db2f4071c36` (`1.6.2.dev0`). It prewarms
`bash-language-server` 5.6.0 and ShellCheck 0.10.0 in Serena's exact managed layout during the
image build. Build-time package/source access is therefore separate from the no-network runtime.
`SERENA_USAGE_REPORTING=false` and disabled dashboard/GUI flags prevent optional outbound features
from being attempted.

The Serena source commit and direct Bash-language-server/ShellCheck versions are exact pins.
ShellCheck is additionally checksum-verified by Serena. The npm installation is version-pinned but
does not use an Agent Lab lockfile for its transitive dependency resolution, so the complete image
dependency graph must not be described as content-pinned.

The Serena project was created with the supported workflow:

```bash
SERENA_HOME="$(mktemp -d)" serena project create . \
  --name agent-lab-dev \
  --ls bash
```

The tracked `.serena/project.yml` selects Bash, UTF-8, the LSP backend, and the single workspace
root `.`. It respects Git ignores and adds no external workspace folders. At runtime a private
ephemeral mount covers `.serena/cache`, so symbol caches do not persist into the host checkout; the
machine-local override is also ignored. Source and tests are not over-ignored.

The stdlib-only `tests/serena/mcp-smoke.py` program is host-side test orchestration, not an Agent Lab
runtime or workload language. It is deliberately outside the Bash-only Serena semantic scope rather
than adding a second language server solely for the integration harness. Serena therefore does not
semantically analyze that Python file; use ordinary editing plus its AST/static checks. This and the
extensionless Bash limitation below are explicit remaining limitations.

## Setup and client registration

Build the image explicitly before starting a client:

```bash
./scripts/dev/serena-build
```

The launcher never builds or pulls during MCP startup. If the image is absent or does not carry the
pinned source label, it fails with an actionable message. Project registrations are:

| Client | Repository config | Context |
|---|---|---|
| Claude Code | `.mcp.json` | `claude-code` |
| Codex | `.codex/config.toml` | `codex` |
| Grok | generated `.grok/config.toml` | `grok` |

Every registration calls `scripts/serena-mcp` without `--project` and without
`--project-from-cwd`. That distinction is deliberate: preselecting a project removes recovery tools
from single-project client contexts in the pinned Serena version. Registrations remove ambient
`BASH_ENV` and `ENV` before invoking a non-login, no-profile Bash, so host startup files cannot run
ahead of the contained launcher.

## Normal agent workflow

Before substantial semantic work:

1. Call `get_current_config`.
2. On a fresh session in the pinned version, expect an `isError` result containing
   `No active project`; this is the recoverable pre-activation state, not configuration evidence.
3. If no project is active, call `activate_project` with `/workspace`.
4. Call `get_current_config` again and confirm project `agent-lab-dev`, context, and LSP backend.
5. Treat the activation response as evidence for root `/workspace`, language Bash, and UTF-8.
6. Run a live, uncached `get_symbols_overview`, `find_declaration`, or similar operation before
   claiming language-server
   readiness.

For code exploration and change impact:

1. Start with `get_symbols_overview` or a targeted `find_symbol`.
2. Retrieve only the bodies needed for the task.
3. Use `find_declaration` and `find_referencing_symbols` to traverse relationships.
4. Prefer the usable bounded semantic editors: `replace_symbol_body`, `insert_before_symbol`, or
   `insert_after_symbol` when the requested change matches a reliable symbol boundary. Broad
   content replacement, rename, and safe-delete tools are deliberately made inactive by project
   policy after activation. Because recoverable startup exposes the MCP schema before a project is
   active, clients may still list those names; calls are rejected as inactive once `/workspace` is
   active.
5. Use ordinary text search and file editing for prose, configuration, generated data, partial
   textual changes, or files without a reliable symbol boundary.
6. Reinspect affected symbols and call `get_diagnostics_for_file` after edits.
7. Run normal tests, lint, build, and containment checks independently.

Serena's Bash matcher recognizes `.sh` and `.bash`, not this repository's extensionless Bash
entrypoints. Use ordinary tools for those files and say why. An empty symbol/reference result is
not proof of absence: first verify activation, `/workspace`, Bash selection, ignore handling,
language-server readiness, and logs. Do not conceal a Serena failure by silently falling back or
claim semantic verification after only text search.

The pinned version has no `check_onboarding_performed` tool. Inspect the activation response and
call `list_memories`. No project memories are currently persisted because the repository guidance
already supplies canonical architecture and commands. If future onboarding is useful, activate
`/workspace` first and keep memories factual, project-specific, and free of secrets, tokens,
container IDs, and host-only paths.

## Distinct health states

| State | Required evidence |
|---|---|
| MCP connected | `initialize` and `tools/list` succeed through `scripts/serena-mcp` |
| Project visible | `activate_project("/workspace")` resolves the tracked project |
| Project active | activation names `agent-lab-dev`; follow-up configuration confirms it |
| Language server launched | runtime process evidence shows `bash-language-server` |
| Language server ready | an uncached per-run fixture overview and live declaration request succeed |
| Semantic extraction working | `agent_lab_validate_config` is returned from `scripts/lib/config.sh` |
| Relationships working | `agent_lab_validate_boolean` resolves to referencing symbol `agent_lab_validate_config` |
| Semantic editing working | a disposable fixture symbol is replaced, retrieved, and remains free of Error diagnostics |
| Diagnostics working | a controlled invalid `.sh` fixture returns Error codes `SC1072` and `SC1073` |
| Repository verification working | an existing Agent Lab test runs independently |

These states must not be collapsed into “Serena works.” MCP startup and project configuration do
not prove language-server readiness.

## Deterministic smoke

Run:

```bash
./scripts/dev/serena-build
./scripts/dev/serena-smoke
```

The smoke parses and executes the exact command and arguments from each repository client
registration while its process working directory is nested at `tests/serena`; this prevents a
repo-root working directory from masking registration path errors. It then speaks newline-delimited
MCP JSON-RPC for Codex, Claude, and Grok contexts, initializes MCP, lists required tools, and performs
`get_current_config` (expected pre-activation `isError`) → `activate_project("/workspace")` →
`get_current_config`. Each context calls `list_memories`, creates a unique valid Bash fixture, and
requires an uncached symbol overview plus a live definition traversal before inspecting real Agent
Lab source. The Codex pass additionally:

- replaces one complete symbol in the disposable fixture, retrieves the edited body, and checks it
  for Error diagnostics;
- extracts `agent_lab_validate_config`;
- resolves the declaration of `agent_lab_validate_boolean`;
- finds `agent_lab_validate_config` as its same-file referencing symbol;
- creates and removes a controlled invalid Bash fixture and requires parsed `Error` diagnostics
  `SC1072` and `SC1073`;
- verifies the live `bash-language-server` process and container hardening;
- records current memory/onboarding state for every context.

It then runs `tests/agent/config-guard.sh` independently of Serena. Any missing stage exits nonzero
and prints the failed RPC result plus recent Serena/container logs. A successful handshake followed
by a failed semantic operation is a failed smoke. Disposable fixtures are removed only after their
MCP server has stopped.

Run the full repository gates separately:

```bash
./scripts/dev/check default quick
./tools/validate.sh --strict
./scripts/dev/docker-gate
```

## Troubleshooting order

If a semantic query is unexpectedly empty or fails:

1. Run `get_current_config`; on a fresh session, recognize the expected `No active project`
   `isError` state.
2. Activate `/workspace`, then inspect configuration again.
3. Confirm the activation response names `/workspace`, Bash, and UTF-8.
4. Confirm the file is a non-ignored `.sh` or `.bash` file inside `/workspace`.
5. Run `./scripts/dev/serena-build` and verify the pinned image check succeeds.
6. Run `./scripts/dev/serena-smoke`; do not add arbitrary sleeps.
7. Inspect the reported Serena and Bash language-server logs.
8. Only after these checks decide that no symbol/reference/diagnostic exists.

No runtime network exception is an acceptable fix. A missing executable or preseeded asset is an
image-build failure; a wrong root or inactive project is an activation/configuration failure; an
unsupported extension or relationship is a Serena/Bash-language-server limitation.
