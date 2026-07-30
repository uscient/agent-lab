# Developing Agent Lab

This guide is for maintainers changing the repository. It covers orientation, branch workflow,
local evidence, and the separation between development tools and contained workloads.

`AGENTS.md` is the operating-policy source for coding agents. [Operations](operations.md) is the
separate guide for running workloads.

## Orient first

From the repository root:

```bash
./scripts/dev/brief
./scripts/dev/changed
./scripts/dev/doctor
```

- `brief` writes an ignored snapshot to `.cache/dev/brief.md`.
- `changed` reports tracked and untracked working-tree changes.
- `scripts/dev/doctor` inventories the developer environment; it does not certify that every gate
  prerequisite is installed.

The similarly named `./scripts/doctor` is an operator check for Docker, local runtime
configuration, secret patterns, and the rendered lab topology. Use the command that matches the
plane you are working on.

## Branch and integration workflow

The integration branch is `dev`.

1. Create a work branch from current `dev`.
2. Make and verify focused changes on that branch.
3. Fetch remote state.
4. Rebase only on `origin/dev`.
5. Push the same-named work branch. After a rebase, use `--force-with-lease`, never plain force.
6. Open a pull request with base `dev`.
7. A human reviews and merges it.

Do not commit on or push directly to `dev`, `master`, or `main`. Do not merge your own pull request.
Never inspect or change repository authentication, credentials, tokens, account settings, or Git
attribution configuration.

The rails—`AGENTS.md`, `policy/`, guards, and development-client configuration—require an explicit
maintenance session. Ordinary feature and documentation work does not mutate them.

## Local evidence

The three local gate entry points corresponding to the required-gates workers are:

```bash
./scripts/dev/check default quick
./tools/validate.sh --strict
./scripts/dev/docker-gate
```

| Gate | What it establishes | Important prerequisites |
|---|---|---|
| fast | changed-file guard, shell lint, unit/security contracts, adapter consistency | Bash toolchain plus every tool in `tests/security/fast.manifest`, including `shellcheck` and `jq` |
| strict static | Compose rendering and static configuration/containment invariants | Docker CLI and Compose v2 |
| Docker runtime | deterministic network, mount, secret, image, and runtime-hardening evidence | reachable Docker daemon, Compose v2, build prerequisites |

`./scripts/dev/check default full` adds strict static validation to the fast gate. It still does not
run the Docker runtime gate.

CI's workflow-faithful fast replay adds the immutable event base:

```bash
AGENT_LAB_DIFF_BASE=THE_SHA_FROM_CI_SUMMARY ./scripts/dev/check default quick
```

See [CI as an agent-facing gate](ci.md) for the required worker names, aggregate contract, artifacts,
and trust boundary. CodeQL is a separate GitHub workflow and is not reproduced by these three local
commands.

## Result classification

The gate framework distinguishes assertions from absent infrastructure:

| Exit | Meaning |
|---|---|
| `0` | every required assertion ran and passed |
| `1` | an assertion failed or a forbidden skip/ambiguous status occurred |
| `125` | prerequisite or infrastructure failure; no pass/fail conclusion |

A suite-level exit 77 is a skip, and the aggregate gate treats it as failure rather than green.
Outputs beginning with `SKIP`, `NOT_IMPLEMENTED`, or `WARN` are forbidden in required suites.

Do not repair a failed gate by weakening assertions, adding blanket retries, converting failures to
skips, or treating an external error as denial evidence. Fix the source or report the precise
infrastructure requirement.

## Development planes

### Repository agents

Claude Code, Codex, and Grok share:

- `AGENTS.md`;
- the `PreToolUse` guard and session bootstrap;
- generated native adapter rules;
- the same branch and publication boundary.

Their configuration is development control-plane policy. It is not baked into `scripts/agent` or
third-party workload images. See [Development-agent configuration](agent-config.md).

### Serena

Serena provides semantic Bash navigation, bounded edits, references, and diagnostics for maintainers.
It runs in a dedicated no-network container with this repository at `/workspace`; it is not a
workload dependency.

Use [the Serena guide](serena.md) for one-time setup, explicit project activation, real examples,
health evidence, limitations, and troubleshooting.

### Contained workloads

Agents launched by `scripts/agent` are the data plane. They can be unrelated to repository
development and are bounded by Docker topology, mounts, secrets, egress policy, and runtime
hardening—not the host development Git policy.

See [Architecture](architecture.md) for the full split.

## Repository map

| Path | Purpose |
|---|---|
| `compose*.yaml` | network, service, workload, HOME, and Serena topology |
| `scripts/agent` | supported workload launcher |
| `scripts/lib/` | configuration, guard, egress, image, and policy libraries |
| `scripts/dev/` | maintainer orientation and gate commands |
| `tools/` | validation, client guard, entrypoint, and adapter helpers |
| `policy/` | protected development-agent policy data |
| `policies/` | runtime Squid denies and egress recipes |
| `tests/security/*.manifest` | versioned required-suite contracts |
| `tests/docker/` | deterministic runtime containment suites |
| `docs/` | operator, architecture, development, CI, and Serena guides |

## Documentation changes

Security and architecture prose must be verified against current source and executable evidence.
A matching reproduction establishes the mechanism it exercised; it does not prove every historical
cause or every runtime environment.

When behavior changes:

1. update the canonical implementation and its regression evidence;
2. update the owning guide from [the documentation map](README.md);
3. remove or redirect duplicated guidance;
4. run the same gates that support the documented claim;
5. keep remaining limitations explicit.

For component-local behavior, update the README beside CoreDNS, Squid, OpenClaw scaffolding, or the
egress acceptance tests as applicable.
