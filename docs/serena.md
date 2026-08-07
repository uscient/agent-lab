# Using Serena to develop Agent Lab

Serena gives coding agents symbol-aware navigation, bounded semantic editing, and Bash
language-server diagnostics while they develop this repository. It is a contained control-plane
helper, not a service used by workloads launched through `scripts/agent`.

## The 30-second version

Remember these facts:

- the Serena project is `agent-lab-dev`;
- Serena sees this repository at `/workspace`;
- semantic analysis covers `.sh` and `.bash` files;
- Git and GitHub branch state come from host-side repository commands, not Serena;
- build the contained toolchain once with `./scripts/dev/serena-build`;
- at the start of a coding session, activate `/workspace` explicitly and prove readiness with a
  live symbol query.

One-time setup:

```bash
./scripts/dev/serena-build
./scripts/dev/serena-smoke
```

At the start of each agent session, use Serena tools in this order:

```text
get_current_config
activate_project(project="/workspace")       # when the project is absent or wrong
get_current_config
get_symbols_overview(relative_path="scripts/lib/config.sh")
```

The final operation matters. A connected MCP server and an active project do not prove that the
Bash language server is ready.

## Mental model

```text
Claude / Codex / Grok
        │ repository MCP registration
        ▼
scripts/serena-mcp
        │ one-shot Docker Compose service
        ▼
no-network Serena container ── Bash language server
        │
        └── /workspace = this Agent Lab checkout

scripts/agent ── contained experimental workload (a separate path)
```

Serena can read and edit the project source at `/workspace`. Git metadata, local environment and
agent-state paths, and protected rails are hidden or overlaid read-only. Its project cache is a
private temporary mount, and its global state is tmpfs-only. It receives no host home directory,
credentials, secrets, Docker socket, proxy configuration, port, or network access.

The Git-ignored `proj/` tree is shared planning state: it stays on the writable `/workspace` bind,
so agents using the same checkout see and can edit the same files. Because Serena honors
`.gitignore`, use ordinary file tools rather than semantic tools for `proj/` prose. Sharing does not
make it repository authority or a secret store; startup still rejects sensitive credential, key,
and environment path names nested inside it. `proj/` must be a real directory containing only
ordinary directories and singly linked regular files; symlinks, hardlinks, and host IPC objects
fail closed before container startup.

That preflight is a startup snapshot, not a continuous monitor. Concurrent host-side agents are
trusted to keep `proj/` within the ordinary-file contract while Serena runs. Treat an untrusted
concurrent writer as outside this practical shared-directory design; containing one would require a
brokered storage service rather than a direct writable bind.

That separation is deliberate. Serena helps an agent develop Agent Lab without becoming an Agent
Lab runtime dependency, authority system, or source of truth. Repository files, `AGENTS.md`, and
the normal checks remain authoritative.

## One-time setup

From the repository root, build the pinned development image:

```bash
./scripts/dev/serena-build
```

The launcher never builds or pulls at MCP startup. If the image is absent or stale, it exits with a
message directing you back to this command. Once the image exists, start or reload a supported
client from this checkout so it reads the repository-scoped registration. See
[Development-client configuration](agent-config.md) for client discovery and Codex project-trust
details.

| Client | Registration | Serena context |
|---|---|---|
| Claude Code | `.mcp.json` | `claude-code` |
| Codex | `.codex/config.toml` | `codex` |
| Grok | generated `.grok/config.toml` | `grok` |

Then verify the complete integration:

```bash
./scripts/dev/serena-smoke
```

The smoke is required after setup, after changing the integration, and when troubleshooting. It is
not a command that must run before every ordinary coding session.

Do not use Serena's user-global setup commands for this repository. Do not add `--project` or
`--project-from-cwd` to a registration: the clients intentionally start without a fixed project so
the explicit activation recovery path remains available.

## Start every coding session

1. Call `get_current_config`.
2. A fresh session may return an `isError` result containing `No active project`. This is an
   expected, recoverable state.
3. If no project is active, or the active project/root is wrong, call `activate_project` with
   `/workspace`.
4. Call `get_current_config` again. Confirm project `agent-lab-dev`, the client context, and the LSP
   backend.
5. Confirm that activation reports root `/workspace`, language Bash, and UTF-8.
6. Run an uncached, live semantic operation on a relevant `.sh` or `.bash` file before relying on
   symbol or diagnostic results.

Here is a reusable instruction for an agent:

> Use Serena for semantic work in Agent Lab. First inspect the current configuration, activate
> `/workspace` if needed, and confirm `agent-lab-dev`. Prove language-server readiness with a live
> symbol operation. Traverse definitions and references before editing, reinspect and run
> diagnostics afterward, then run the normal repository checks separately. If Serena fails, report
> the failure before falling back to ordinary tools.

## A real Agent Lab example

Suppose a task may affect configuration validation in `scripts/lib/config.sh`.

1. Get a symbol overview of `scripts/lib/config.sh`.
2. Find `agent_lab_validate_boolean` and retrieve its body only if needed.
3. Find symbols that reference `agent_lab_validate_boolean`.
4. Confirm that `agent_lab_validate_config` contains the call before changing behavior.
5. If the change matches a complete function boundary, use a bounded semantic edit.
6. Retrieve the edited symbol again and request diagnostics for `scripts/lib/config.sh`.
7. Run the relevant tests and repository gates independently.

The representative Serena calls are:

```text
get_symbols_overview(relative_path="scripts/lib/config.sh")
find_symbol(
  name_path_pattern="agent_lab_validate_boolean",
  relative_path="scripts/lib/config.sh"
)
find_referencing_symbols(
  name_path="agent_lab_validate_boolean",
  relative_path="scripts/lib/config.sh"
)
get_diagnostics_for_file(relative_path="scripts/lib/config.sh")
```

In the current source, the reference query should identify
`agent_lab_validate_config`. That stable relationship is also exercised by the smoke test.

## When to use Serena

| Task | Preferred tool |
|---|---|
| Survey symbols in a `.sh` or `.bash` file | Serena symbol overview |
| Find a known function or retrieve its body | Serena symbol lookup |
| Follow a call to its definition or find callers | Serena declaration/reference tools |
| Replace or insert at a reliable function boundary | Serena bounded semantic editors |
| Check Bash language-server findings after an edit | Serena file diagnostics |
| Search prose, YAML, TOML, Compose, or generated data | ordinary text search |
| Edit documentation, configuration, or part of a line | ordinary file editing |
| Work on an extensionless Bash entrypoint | ordinary search and editing |
| Verify behavior | repository tests, lint, build, and containment gates |

Start with a symbol overview or targeted lookup rather than reading the whole repository. Retrieve
only the bodies needed for the task, and inspect references before changing shared behavior.

Use `replace_symbol_body`, `insert_before_symbol`, and `insert_after_symbol` only when the requested
change aligns with a reliable symbol boundary. Project policy deliberately makes broad content
replacement, rename, and safe-delete inactive after activation. A client may list those tools before
activation because the recoverable startup schema is broader; calls are rejected once `/workspace`
is active.

Serena supplements ordinary search and the repository checks. It replaces neither.

### Branch-workflow orientation

Serena's project prompt tells agents to establish branch and worktree state with the host-side
`./scripts/dev/brief` and `./scripts/dev/changed` commands before editing. For `flow`, group, or
slice work, [the workstream contract](workstreams.md) and `scripts/dev/workstream` remain the
integration authority. Serena cannot establish the current GitHub PR state, required-check state,
or permission to mutate a protected branch.

Keep workflow prose, YAML, and extensionless Bash rails on the ordinary search/edit path. Serena is
still useful for supported `.sh` and `.bash` helpers reached from those rails, but its result is
semantic evidence only; the repository gates supply behavioral and security evidence.

## What a healthy integration proves

Keep these states separate:

| State | Required evidence |
|---|---|
| MCP connected | initialization and tool listing succeed through `scripts/serena-mcp` |
| Project visible | `activate_project("/workspace")` resolves the tracked project |
| Project active | activation names `agent-lab-dev`; follow-up configuration confirms it |
| Language server launched | runtime evidence shows `bash-language-server` |
| Language server ready | an uncached per-run fixture overview and a live declaration request complete |
| Symbols working | `agent_lab_validate_config` is extracted from `scripts/lib/config.sh` |
| Relationships working | `agent_lab_validate_boolean` has referencing symbol `agent_lab_validate_config` |
| Semantic editing working | a disposable fixture symbol is edited, retrieved, and has no Error diagnostics |
| Diagnostics working | a controlled invalid fixture produces Error-level `SC1072` and `SC1073` |
| Repository verification working | an existing Agent Lab test passes independently of Serena |

“The Serena server started” proves only the first row.

## Verification commands

Run the deterministic end-to-end smoke with Docker available:

```bash
./scripts/dev/serena-build
./scripts/dev/serena-smoke
```

For each registered client, the smoke starts from a nested working directory, checks the expected
pre-activation state, activates `/workspace`, confirms the project, performs an uncached symbol
operation, and traverses a live declaration. The Codex pass also checks the real
`agent_lab_validate_boolean` relationship, a bounded edit on a disposable fixture, controlled
ShellCheck diagnostics, the live language-server process, and container hardening. It finishes by
running `tests/agent/config-guard.sh` outside Serena.

MCP-stage failures exit nonzero with the failed response and recent Serena/container logs. Docker,
image, or containment preflight failures can occur before MCP starts; exit 125 identifies
infrastructure or preflight failure, not a semantic result. A successful handshake followed by a
failed semantic operation is a failed smoke.

Run the normal repository gates separately:

```bash
./scripts/dev/check default quick
./tools/validate.sh --strict
./scripts/dev/docker-gate
```

## If it fails

| Symptom | Check and recovery |
|---|---|
| Serena tools are absent | Confirm the tracked client registration, then reload or restart the client from this checkout. |
| Image missing or stale | Run `./scripts/dev/serena-build`; startup never downloads or builds. |
| `No active project` | Call `activate_project("/workspace")`, then inspect configuration again. |
| Wrong project or root | Activate `/workspace`; require `agent-lab-dev` before semantic work. |
| Active project but empty symbol result | Confirm the file is a non-ignored `.sh` or `.bash` under `/workspace`, then prove language-server readiness with another live operation. |
| Extensionless Bash, Python, prose, or configuration file | This is outside the configured semantic scope; use ordinary tools and say why. |
| `proj/` is absent or read-only | Reload or restart the client/MCP so it creates a new Serena container. Activation alone does not recreate container mounts. |
| Containment preflight failure | Remove the reported child mount, nested `.git`, sensitive symlink, or nested credential/key/environment path. Use a non-root canonical UID/GID. Do not weaken the preflight. |
| Semantic or diagnostic operation fails | Run `./scripts/dev/serena-smoke` and use its reported MCP, Serena, and language-server output. |

For an unexplained empty or failed query, use this order:

1. inspect the active project and root;
2. verify that the file is inside `/workspace`;
3. verify the `.sh` or `.bash` language match;
4. verify ignore and workspace-folder handling;
5. verify the pinned image and language-server availability;
6. wait for a real semantic operation rather than adding an arbitrary sleep;
7. inspect Serena and Bash language-server logs;
8. only then conclude that a symbol, relationship, or diagnostic is absent.

Do not add a runtime network exception to fix development tooling. A missing executable or asset is
an image-build problem; a wrong root is an activation problem; an unsupported file is a documented
scope limitation.

## Known limitations

- Only Bash is configured. Serena recognizes `.sh` and `.bash`, not Agent Lab's extensionless Bash
  entrypoints.
- `tests/serena/mcp-smoke.py` is host-side orchestration, not an Agent Lab runtime language. It stays
  outside the semantic project rather than adding Python solely for the test harness.
- Broad content replacement, rename, and safe-delete tools are inactive by project policy.
- Project symbol caches are ephemeral and do not persist into the host checkout.
- The direct Serena, Bash-language-server, and ShellCheck versions are pinned. The npm installation
  is version-pinned but does not use an Agent Lab lockfile for its transitive dependency graph.

An empty result on a supported file is not proof that the symbol does not exist. Follow the recovery
order above, and never claim semantic verification when only text search was performed.

## Technical reference

The project was created using Serena's supported workflow:

```bash
SERENA_HOME="$(mktemp -d)" serena project create . \
  --name agent-lab-dev \
  --ls bash
```

The tracked `.serena/project.yml` selects Bash, UTF-8, the LSP backend, Git-ignore handling, the
preseeded Bash-language-server version, and the single workspace root `.`. It adds no external
workspace folders and does not over-ignore source or tests. No project memories are currently
persisted; repository guidance is sufficient and remains canonical.

`scripts/serena-mcp` starts the one-shot `compose.serena.yaml` service. Every bind is private and
non-recursive. The ignored `proj/` tree is inherited from the writable project bind; runtime-state
roots, local environment files, Git metadata, and secrets remain masked. Startup fails closed on
child mounts, visible nested `.git` objects, nested credential/key/environment paths, sensitive
symlinks, unsafe shared-`proj/` objects, and root or noncanonical UID/GID values.
Client registrations remove `BASH_ENV` and `ENV` before invoking a non-login, no-profile Bash so
ambient host startup files cannot run before the contained launcher.

The image contains:

- Serena commit `6c1c9653700cbe644cb5a5b026b77db2f4071c36`
  (`1.6.2.dev0`);
- `bash-language-server` 5.6.0;
- ShellCheck 0.10.0 in Serena's expected managed layout.

Build-time dependency access is separate from the no-network runtime.
`SERENA_USAGE_REPORTING=false` and disabled dashboard/GUI flags prevent optional outbound features
from being attempted.

The pinned version has no `check_onboarding_performed` tool. Use the activation response plus
`list_memories` as the onboarding check. No project memories are tracked or currently present
because repository guidance is sufficient. If memories are added later, activate `/workspace`
first, keep them factual and specific to Agent Lab, and never store secrets, tokens, transient
container IDs, or host-only paths in them.

Related repository guidance:

- [Documentation map](README.md)
- [Development and verification](development.md)
- [Architecture](architecture.md)
- [Agent development rules](../AGENTS.md)
- [Development-client configuration](agent-config.md)
- [CI gate mapping](ci.md)
- [Security policy](../SECURITY.md)
- [Threat model](../THREAT_MODEL.md)
