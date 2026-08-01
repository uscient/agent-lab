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
| fast | changed-file guard, shell lint, unit/security contracts, adapter consistency | Bash toolchain, Python 3.11+, and every tool in `tests/security/fast.manifest`, including `shellcheck` and `jq` |
| strict static | Compose rendering and static configuration/containment invariants | Docker CLI and Compose v2 |
| Docker runtime | deterministic network, mount, secret, image, and runtime-hardening evidence | reachable Docker daemon, Compose v2, build prerequisites |

`./scripts/dev/check default full` adds strict static validation to the fast gate. It still does not
run the Docker runtime gate.

The stable `scripts/dev/security-gate` Bash entrypoint uses a standard-library-only Python 3.11+
helper to run at most four fast suites concurrently. Each suite receives only its private socket
transmit endpoint; the parent retains the receive endpoints and emits results in manifest order, so
completion timing cannot reorder the evidence. On Linux the parent sets and verifies
`PR_SET_DUMPABLE=0`; inability to establish that boundary fails as infrastructure. Cross-suite
descriptor protection still depends on host ptrace and procfs policy. This is evidence separation
for unprivileged repository tests, not containment against permissive same-UID ptrace, root,
`CAP_SYS_PTRACE`, equivalent process-inspection authority, or a non-Linux platform without an
equivalent boundary.

The runner rejects a suite once captured payload exceeds 8 MiB, or retained plus currently captured
payload exceeds 32 MiB. Overflow is an infrastructure failure (`125`), stops registered groups
immediately, and emits no transcript. These are logical payload thresholds, not hard memory
ceilings. A receive can overshoot by one 64 KiB chunk, kernel socket buffers are outside the
counters, and allocation, conversion, decoding, optional persistence, interpreter state, and
temporary copies can raise RSS above 32 MiB. No `RLIMIT`, cgroup, or hard RSS cap is installed. The
Docker security gate is always serial. For differential diagnosis, a maintainer can set
`AGENT_LAB_SECURITY_GATE_JOBS=1` through `4` on the fast gate; values outside that bound fail as
infrastructure, and Docker remains fixed at one worker.

Result precedence is explicit: (1) a handled cancellation returns `128 + signal`, including when
capture fails during cleanup; (2) a runner capture, persistence-integrity, or output-limit failure
returns `125` before suite classification and emits no transcript; (3) after successful collection,
a suite assertion or skip returns `1` and outranks suite-reported infrastructure; (4) otherwise a
pure suite-infrastructure result returns `125`. Only an all-pass result returns `0`. A suite that
exits zero while leaving a process-group member is recorded as infrastructure even if that member
prints the expected marker during cleanup.

Set `AGENT_LAB_SECURITY_GATE_EVIDENCE_DIR` to preserve per-suite `.out` and `.status` files for
diagnosis. The directory must be empty so stale files cannot be mistaken for current results.
Evidence directory identity, exclusive file creation, writes, sync, and readback fail closed as
infrastructure errors. Preserved evidence is diagnostic: it is not immutable or an integrity
guarantee after the runner exits, and platforms that reject directory `fsync` rely on file `fsync`
plus exact readback. Cancellation during persistence may leave a prefix of those diagnostic files.

During suite execution, cancellation by `HUP`, `INT`, `QUIT`, or `TERM` emits no partial transcript,
sends `TERM` to every registered process group, and returns `128 + signal`. Cooperative cleanup gets
three seconds in the fast gate and 15 seconds in the Docker gate before escalation to `KILL`; an
active Docker preflight command gets one second. Output remains monitored during cleanup. During
final transcript replay, already-buffered output is streamed, so cancellation can leave a transcript
prefix even though the signal status and diagnostic remain exact. There is no automatic per-suite
deadline; a silent hung suite requires cancellation. Direct `KILL` of the runner, descendants that
escape the registered session or process group, privileged process-control authority, and processes
the kernel cannot promptly terminate are outside the cleanup guarantee.

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
