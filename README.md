# Agent Lab

Agent Lab is a Docker Compose containment lab for running untrusted or failure-prone agent workloads
against a deliberately narrow set of host resources and network destinations.

It provides the containment substrate—an internal agent network, lab-local DNS, a deny-by-default
egress proxy, guarded filesystem mounts, file-backed secrets, and executable security checks. It is
not a general AI application stack, hosted service, or VM-grade sandbox.

> **Repository status: public mirror**
>
> This code is published under the Apache 2.0 license for transparency, reference, and local
> use/forking. Contributions from outside the organization are not accepted. See
> [CONTRIBUTING.md](.github/CONTRIBUTING.md).

## What Agent Lab gives you

- Agent containers join only an internal Docker network with no direct route to the host, LAN, or
  internet.
- CoreDNS answers lab-local names and refuses arbitrary external recursion.
- Squid is the only dual-homed service and permits only explicitly selected destination domains.
- Agent root filesystems are read-only, capabilities are dropped, privilege escalation is disabled,
  and CPU, memory, and process limits are set.
- Projects and secrets enter through separate, guarded mounts. Whole or broad host-home mounts,
  credential stores, the Docker socket, privileged mode, host networking, and public ports are
  refused. A narrow project below a home directory is allowed.
- Runtime configuration is parsed as data, validated before side effects, and rechecked before
  Docker consumes host paths.
- Security claims are mapped to fast, static, and deterministic Docker runtime gates.

## Quick start

Prerequisites are Bash, Docker with a reachable daemon, and Docker Compose v2. A non-root host user
is the supported posture, especially when matching a bind-mounted project's ownership.

Prepare the operator-local configuration, check the host, and run a read-only Agent Lab preflight:

```bash
cp .env.example .env.local
./scripts/doctor
AGENT_LAB_EPHEMERAL_HOME=1 ./scripts/agent --check
```

Start the default contained shell with the same ephemeral agent home:

```bash
AGENT_LAB_EPHEMERAL_HOME=1 ./scripts/agent -- bash
```

The default image is built locally on first use. The one-off agent container is removed when it
exits, but CoreDNS and Squid remain running. The default workspace and audit logs are named volumes
and can persist even when the agent home is ephemeral.

The default `base` egress recipe permits no destination, including an agent API. A network failure
in this first shell is expected until you deliberately select a narrow recipe.

Stop the services while retaining named volumes:

```bash
./scripts/agent down
```

Remove the services and Agent Lab's named workspace, home, and audit volumes:

```bash
./scripts/agent --clean
```

`--clean` does not delete a host project, host secret files, or ignored host cache files.

To work on a host project, export the path, non-root host identity, and HOME mode for one preview
and run:

```bash
export AGENT_LAB_PROJECT_DIR=/absolute/path/to/project
export AGENT_LAB_AGENT_UID="$(id -u)"
export AGENT_LAB_AGENT_GID="$(id -g)"
export AGENT_LAB_EPHEMERAL_HOME=1
./scripts/agent --check
./scripts/agent -- bash
unset AGENT_LAB_PROJECT_DIR AGENT_LAB_AGENT_UID AGENT_LAB_AGENT_GID AGENT_LAB_EPHEMERAL_HOME
```

The project is mounted read-write at `/workspace`. Agent Lab rejects broad, sensitive,
credential-bearing, overlapping, or unstable project/secret paths before Docker starts.

Read the [operator guide](docs/operations.md) before adding secrets, enabling egress, or bringing a
third-party image.

## How it works

```text
host operator
     │
     │ scripts/agent: parse → validate → guard → verify
     ▼
agent container ─────── internal `agents` network ─────── CoreDNS
     │
     │ HTTP(S) proxy only
     ▼
Squid egress proxy ─── internet-capable `egress` network ─── allowlisted destinations
```

The internal network—not proxy environment variables—is the default-deny boundary. The agent never
joins the internet-capable network. Proxy variables direct cooperating tools to Squid, while the
network topology prevents a raw direct route.

The repository also contains a separate development control plane: agent operating rules, client
hooks, CI gates, and specialist development helpers. Those tools develop Agent Lab; they are not
injected into workloads run by Agent Lab.

See [Architecture](docs/architecture.md) for the complete data flow, state model, configuration
authority, and control-plane/data-plane split.

## Experiments

Agent Lab also has a separate v0alpha1 onboarding path for Experiments. An Experiment is authored as
one declarative `experiment.cue` file and can enter from a closed directory, a bounded ZIP archive,
or an exact commit in a supported public GitHub repository. Agent Lab snapshots the source,
validates it with the pinned CUE contract, resolves every image selector to an immutable subject,
freshly evaluates the install policy with Cedar, and, only on a permit, can retain the resulting
evidence in a private local Agent Lab home.

This path stops at onboarding evidence. It does not run Experiment content, invoke Docker, acquire
image bytes, claim image admission, or create a workload network. Start with the
[Experiments guide](docs/experiments.md); use [Local installation](docs/installation.md) to prepare
the CLI and private home, and [Local image names](docs/images.md) for operator-managed image
mappings.

## Controlled configuration

The workload path exposes four primary adaptation seams, a persistence switch, and bounded
identity/resource controls:

| Setting | Purpose | Default |
|---|---|---|
| `AGENT_LAB_AGENT_IMAGE` | agent image | locally built `agent-lab/devbox:local` |
| `AGENT_LAB_PROJECT_DIR` | host project mounted at `/workspace` | persistent `agent-workspace` volume |
| `AGENT_LAB_SECRETS_DIR` | file-backed secrets mounted read-only | `./secrets` |
| `AGENT_LAB_ALLOWLIST_RECIPES` | additive egress destination recipes | `base` (empty; deny all) |
| `AGENT_LAB_EPHEMERAL_HOME` | use tmpfs instead of persistent `agent-home` | `0` (persistent) |
| `AGENT_LAB_AGENT_UID` / `GID` | non-root workload identity | `1000:1000` |
| `AGENT_LAB_AGENT_MEM` / `CPUS` | workload resource limits | `4g`, `2` |

Networks, proxy route, mount targets, hardening, and the accepted ranges remain locked by the
launcher and Compose model. Do not put credentials in `.env.local`; it is runtime configuration,
not secret storage.

## Verification paths

These commands answer different questions:

| Command | Evidence |
|---|---|
| `./scripts/doctor` | host prerequisites, local configuration presence, secret scan, and rendered topology checks |
| `./scripts/agent --check` | side-effect-free workload configuration, recipe, and canonical mount preflight |
| `./scripts/egress-test` | operator acceptance smoke against live external behavior |
| `./scripts/dev/check default quick` | Docker-free source, policy, and security contracts |
| `./tools/validate.sh --strict` | strict Compose rendering and static containment invariants |
| `./scripts/dev/docker-gate` | deterministic Docker runtime containment evidence |

The acceptance smoke is useful, but it is not a substitute for the deterministic security gate.
See [Development and verification](docs/development.md) and [CI gate mapping](docs/ci.md).

## Documentation

Use the [documentation map](docs/README.md) for the complete index. The four main paths are:

- [Operate Agent Lab](docs/operations.md)
- [Author, check, and install Experiments](docs/experiments.md)
- [Understand the architecture and security model](docs/architecture.md)
- [Develop and verify the repository](docs/development.md)

Formal hard stops and guarantees remain in [SECURITY.md](SECURITY.md) and
[THREAT_MODEL.md](THREAT_MODEL.md).

## Important limits

- Containers share the host kernel. Agent Lab is practical Docker containment, not VM isolation.
- An allowlisted destination can still receive exfiltrated data.
- HTTPS policy currently checks the CONNECT hostname; TLS SNI mismatch protection is not
  implemented.
- Raw blocked direct traffic is not logged without an additional host firewall layer.
- The shipped agent network disables IPv6. Enabling host-wide or custom Docker IPv6 requires a new
  audit before relying on the same boundary.
- Browser automation, cloud infrastructure, and production deployment are outside the current
  guarantee.
- Experiment onboarding retains checked and authorized local evidence only. Experiment execution,
  image acquisition and admission, start/stop, and stored-artifact uninstall are not implemented.

Do not weaken containment to work around a failed command. A refusal or exit status 125 is evidence
to diagnose, not permission to bypass the control.

## Contributing, security, and license

External pull requests and issues are not accepted. Organization members follow `AGENTS.md` and the
[branch-derived integration workflow](docs/development.md#branch-and-integration-workflow). `dev`
remains authoritative; `flow` is a protected program-integration branch, verified intermediate
merges use the workstream helper, and humans own every final merge into `dev`.

Organization members report suspected boundary bypasses or secret exposure through the private
channel described in [SECURITY.md](SECURITY.md). This mirror publishes no external intake; never put
exploit details in a public issue.

Licensed under the [Apache License 2.0](LICENSE).
