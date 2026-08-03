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

`dev` is authoritative. The protected `flow` branch is a bounded program-integration base, not a
replacement for `dev`. The exact route is derived from the branch:

| Head branch | Rebase/sync base | Pull-request base | Integration owner |
|---|---|---|---|
| ordinary branch | `origin/dev` | `dev` | human |
| `work/<work>` | merge `origin/dev` with `sync` | `dev` | human |
| `slice/<work>/<slice>` | `origin/work/<work>` | `work/<work>` | verified helper |
| `group/<group>` | merge `origin/flow` with `sync` | `flow` | verified helper after approval |
| `slice/group/<group>/<slice>` | merge `origin/group/<group>` with `sync` | `group/<group>` | verified helper |
| protected `flow` | none | `dev` | human |

`<group>` matches `[gb][0-9]+[a-z]?-[a-z0-9][a-z0-9-]*`; `group` in the group-slice form is
literal. `dev`, `flow`, `master`, and `main` are protected. Do not commit, push, Git-merge, or rebase
them directly. An agent may inspect `flow`, use the verified helper to merge an approved group PR
remotely, and open the final draft `flow` → `dev` PR; only a human merges that final PR.

For each writable branch:

1. Start at its current permitted base and make focused changes.
2. Run applicable behavior, security, and mutation evidence.
3. Fetch and incorporate only the exact base in the table. Use `scripts/dev/workstream sync` for a
   reserved workstream, group, or slice branch.
4. Replay invalidated evidence after a rebase, dependency merge, workflow change, or manifest change.
5. Push only the same-named branch. Use `--force-with-lease` only after an allowed non-program
   rebase; program groups and group slices are merge-preserving and never force-updated.
6. Open only the derived PR route. Agents integrate only verified slice→work, group-slice→group, and
   approved group→`flow` PRs through `scripts/dev/workstream merge`.
7. Preserve merge commits, branches, PR records, and evidence through final review. Humans merge every
   ordinary, workstream, or `flow` final PR into `dev`.

The R0 maintenance PR must land in `dev` before `flow` exists. After all pre-bootstrap closure work
lands, a human freezes `dev` integration and records the exact bootstrap-closure `dev` commit. That
commit must contain immutable R0, and the human creates and protects `flow` at that exact SHA before
another `dev` merge. The human then installs current-head CI, CodeQL, review, retention, and merge
rules before program work begins. See [Agent-managed workstreams and programs](workstreams.md) for
commands and the hosted-rules checklist.

Never inspect or change repository authentication, credentials, tokens, account settings, or Git
attribution configuration.

The rails—`AGENTS.md`, `policy/`, guards, and development-client configuration—require an explicit
maintenance session. Ordinary feature and documentation work does not mutate them.

### Workflow metadata

For ordinary work, prefer a descriptive `<lane>/<lower-kebab-topic>` name. The automated bootstrap
form `agent/<tool>/<slug>` remains valid. Reserved `work/*`, `group/*`, and both slice forms carry the
routing semantics in the table; malformed reserved names are refused. The checker also rejects
protected, generic, invalid, and Git-magic names, but `AGENTS.md` remains authoritative.

Introduced non-merge commits use the exact author
`xormania <127287135+xormania@users.noreply.github.com>`. Subjects are one printable ASCII line,
12–72 characters, and describe one reviewable outcome without a trailing period, draft marker,
merge boilerplate, branch reference, or generic update text. Plain imperative subjects and scoped
Conventional Commit subjects are both valid. Do not add additional attribution trailers.

Pull requests use the branch-derived base and an outcome-focused title under the same subject rules.
The body keeps the template sections `Summary`, `Motivation / Context`, `Changes`, `Testing`, and
`Evidence` in that order. Testing entries name an exact command in backticks and its observed result.
If no command ran, write `Not run — reason`. The evidence section is an append-only sequence of the
template's exact `Cycle` records. Each cycle binds the route, exact 40-hex base and head, behavior and
security assertions, exact RED predecessor, RED/GREEN results, product and CI mutations, runner,
duration, cleanup, artifacts, and uncertainty. Use `N/A — reason` only when a field genuinely does
not apply. Program routes and protected-rail changes use strict validation and cannot waive the RED
predecessor, RED, GREEN, or either mutation. Check or remove every template checklist item before
validation.

Run the local convention checks from the repository root:

```bash
./scripts/dev/workflow-check branch
./scripts/dev/workflow-check commit 'Describe one reviewable outcome'
./scripts/dev/workflow-check commits
./scripts/dev/workflow-check pr-title 'Describe the pull request outcome'
./scripts/dev/workflow-check pr-base dev
./scripts/dev/workflow-check pr-route group/g0-operator-surface flow
./scripts/dev/workflow-check pr-body .cache/dev/pr-body.md BASE_SHA HEAD_SHA HEAD_REF BASE_REF
./scripts/dev/workflow-check evidence-append .cache/dev/old-body.md .cache/dev/pr-body.md
./scripts/dev/workflow-check all
```

`commits` and `all` derive `origin/dev`, `origin/flow`, or the matching remote parent from the current
branch. `pr-body` validates the latest evidence cycle against the supplied current PR base, head, and
route; CI supplies those identities from the event, and the intermediate merge helper rechecks them
before integration. `evidence-append` proves every prior nonblank evidence line remains an exact
prefix. If supplied, an explicit base must resolve to that same derived ref; callers cannot narrow
the range to hide introduced commits. `all` checks only the branch and every introduced non-merge
commit. Run the applicable `pr-*` commands separately; `pr-base` derives the expected base from the
current branch, while `pr-route` can check an explicit head/base pair. The fast gate exercises this
executable contract but cannot inspect hosted PR metadata or GitHub rulesets.

### Shared-checkout coordination

`scripts/dev/coord` provides local cooperative bookkeeping when several workers share one checkout:

```text
./scripts/dev/coord init <coordinator>
./scripts/dev/coord claim <actor> <task> --read-only
./scripts/dev/coord claim <actor> <task> --write <path>...
./scripts/dev/coord handoff <actor> <task> <done|blocked> <summary-file>
./scripts/dev/coord advance <coordinator>
./scripts/dev/coord resolve <coordinator> <task>
./scripts/dev/coord status
./scripts/dev/coord recover <coordinator>
./scripts/dev/coord close <coordinator>
```

One coordinator owns the branch, commits, rebase, publication, and final evidence. A write claim
conflicts with another writer on an exact path, ancestor, or descendant; read-only tasks may
overlap. A `done` or `blocked` handoff retains its claim until the coordinator resolves it. The
coordinator reviews the handoff before resolution.

The session pins its repository, branch, and HEAD. Claims, handoffs, resolution, close, and status
fail on drift. If the coordinator intentionally commits or rebases after every active task has
handed off, `advance` is the controlled exception that records the new HEAD before resolution
continues. After an abrupt process termination, `recover` can clear a stale local mutex but refuses
an owner PID that is still alive.

State and archived sessions remain below ignored `.cache/dev/coord`. Overrides must be absolute and
cannot place state in tracked checkout paths. The harness never changes Git state and does not
authenticate actor labels or grant authority; `AGENTS.md`, the guards, and human review keep those
roles.

## Local evidence

The three local gate entry points corresponding to the required-gates workers are:

```bash
./scripts/dev/ci-fast
./tools/validate.sh --strict
./scripts/dev/docker-gate
```

For agent-managed single- or multi-slice work and `flow` delivery programs, use
[`docs/workstreams.md`](workstreams.md). It preserves reviewed merge ancestry and per-head evidence,
limits agents to verified intermediate integration, and keeps every final merge into `dev`
human-owned.

| Gate | What it establishes | Important prerequisites |
|---|---|---|
| fast | pinned CUE and Cedar provisioning, changed-file guard, shell lint, unit/security contracts, adapter consistency | Network access on first CUE or Cedar provision, Bash toolchain, Python 3.11+, and every tool in `tests/security/fast.manifest`, including `shellcheck` and `jq` |
| strict static | Compose rendering and static configuration/containment invariants | Docker CLI and Compose v2 |
| Docker runtime | deterministic network, mount, secret, image, and runtime-hardening evidence | reachable Docker daemon, Compose v2, build prerequisites |

The pinned CUE and Cedar caches provide reproducibility and corruption detection within the trusted
host development plane. They are not process-isolation boundaries against a hostile same-UID host
process; host control remains outside the workload-containment guarantee in `THREAT_MODEL.md`.

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

Fast suites have a 120-second execution deadline and a shared 600-second subprocess-phase deadline;
Docker suites use 900 and 1800 seconds respectively. The phase clock begins before preflight.
Docker preflight commands have a 30-second deadline. Expiry is infrastructure failure (`125`),
stops new launches, and cleans complete registered process groups with the same bounded escalation
used for cancellation. Fast mode continues completing and queued siblings after an individual suite
timeout; Docker mode launches no later suite because process cleanup cannot establish that external
Docker resources were removed. These fixed production limits are not suite-configurable.

A zero-exit suite passes only when its declared marker appears exactly once as the final non-empty
output line. An early, repeated, prefixed, suffixed, or post-cleanup marker is a failure.

During suite execution, cancellation by `HUP`, `INT`, `QUIT`, or `TERM` emits no partial transcript,
sends `TERM` to every registered process group, and returns `128 + signal`. Cooperative cleanup gets
three seconds in the fast gate and 15 seconds in the Docker gate before escalation to `KILL`; an
active Docker preflight command gets one second. Output remains monitored during cleanup. During
final transcript replay, already-buffered output is streamed, so cancellation can leave a transcript
prefix even though the signal status and diagnostic remain exact. Direct `KILL` of the runner, descendants that
escape the registered session or process group, privileged process-control authority, and processes
the kernel cannot promptly terminate are outside the cleanup guarantee.

CI's workflow-faithful fast replay adds the immutable event base:

```bash
AGENT_LAB_DIFF_BASE=THE_SHA_FROM_CI_SUMMARY ./scripts/dev/ci-fast
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
