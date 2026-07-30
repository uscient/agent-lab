# Operating Agent Lab

This guide covers the normal data-plane workflow: prepare a checkout, run a contained workload,
control its project, secrets and egress, understand retained state, and recover from refusals.

For the design behind these steps, read [Architecture](architecture.md). For repository maintenance,
use [Development and verification](development.md).

## Before you start

Use a non-root host account with:

- Bash;
- Docker CLI;
- a reachable Docker daemon;
- Docker Compose v2.

Image builds and pulls happen on the host before the workload starts. They may require host network
access. The running agent remains on Agent Lab's internal network.

Create the operator-local configuration:

```bash
cp .env.example .env.local
```

`.env.local` is configuration, not secret storage. Keep API keys, tokens, and other credentials out
of it.

## First run

Check host prerequisites and the rendered base topology:

```bash
./scripts/doctor
```

Then run the workload launcher's side-effect-free preflight:

```bash
AGENT_LAB_EPHEMERAL_HOME=1 ./scripts/agent --check
```

`--check` strictly parses configuration, validates recipes and canonical mount paths, and prints
effective values. It does not create the secrets directory, publish a generated allowlist, inspect
or start an image, or call Docker.

Start a shell in the default locally built workload image:

```bash
AGENT_LAB_EPHEMERAL_HOME=1 ./scripts/agent -- bash
```

The first run builds `agent-lab/devbox:local` if it is absent. The agent container is one-shot and
removed on exit. CoreDNS and Squid continue running so another workload can reuse the verified
readiness and policy state.

The default `base` recipe permits no destination, including an agent API. Network failure is
expected in this first shell until you deliberately enable a narrow recipe.

Stop those services:

```bash
./scripts/agent down
```

## Run a workload

Anything after `--` is the command executed inside the agent image:

```bash
./scripts/agent -- bash
./scripts/agent -- python3 -V
./scripts/agent -- rg --version
```

With no `-- <command>`, Agent Lab uses the image's own command.

### Use a host project

The default `/workspace` is the persistent Docker volume `agent-workspace`. To mount a host project,
pass an absolute path. Match the container identity to the non-root host user when the project must
be writable:

```bash
export AGENT_LAB_PROJECT_DIR=/absolute/path/to/project
export AGENT_LAB_AGENT_UID="$(id -u)"
export AGENT_LAB_AGENT_GID="$(id -g)"
export AGENT_LAB_EPHEMERAL_HOME=1
./scripts/agent --check
./scripts/agent -- bash
```

Assignments may be exported as above, scoped directly to each command, or written as literal values
in `.env.local`. Exports remain active in the current shell until unset:

```bash
unset AGENT_LAB_PROJECT_DIR AGENT_LAB_AGENT_UID AGENT_LAB_AGENT_GID AGENT_LAB_EPHEMERAL_HOME
```

A standalone, unexported shell assignment will not reach a later command, and `.env.local` does not
evaluate `$(id -u)` or other shell syntax.

Every real run repeats configuration, recipe, image, and path checks; the explicit `--check` is a
preview, not the only enforcement point.

The guard refuses:

- the filesystem root, the whole host home, broad shared directories, system paths, and credential
  stores;
- paths with credential-bearing components or known credential artifacts at the selected root;
- broken or ambiguous symlinks;
- a project and secrets directory that contain one another;
- changed path identities between preflight and Docker use;
- control characters or path forms unsafe for Compose interpolation.

The host remains responsible for the project after it is mounted read-write. `--clean` never deletes
host project data.

The ephemeral HOME in this example avoids ownership inherited from the default image's uid/gid 1000
named volume. If you need persistent HOME with another identity, use an image and volume ownership
that are compatible with that configured uid/gid.

## Configuration authority

For `scripts/agent`, precedence is exact:

```text
shell environment (including explicitly empty)
    > strictly parsed local configuration
    > launcher default
```

The launcher parses the local file as data and passes `/dev/null` as Compose's env file. It accepts
blank lines, comments beginning in column one, and exact unquoted `KEY=VALUE` records. It rejects
duplicates, unknown keys, `export`, quotes, any whitespace in a value, inline comments, CRLF, shell
metacharacters, and other ambiguous syntax before side effects.

The main settings are:

| Setting | Accepted value | Default |
|---|---|---|
| `AGENT_LAB_AGENT_IMAGE` | validated local/remote image reference | `agent-lab/devbox:local` |
| `AGENT_LAB_PROJECT_DIR` | empty or guarded directory | empty → `agent-workspace` volume |
| `AGENT_LAB_SECRETS_DIR` | guarded directory, disjoint from project | `./secrets` |
| `AGENT_LAB_ALLOWLIST_RECIPES` | unique comma-separated lower-kebab names | `base` |
| `AGENT_LAB_EPHEMERAL_HOME` | exactly `0` or `1` | `0` |
| `AGENT_LAB_AGENT_UID` / `GID` | canonical decimal `1..2147483647` | `1000` |
| `AGENT_LAB_AGENT_MEM` | `64m..65536m` or `1g..64g` | `4g` |
| `AGENT_LAB_AGENT_CPUS` | canonical `0.1..64`, at most three decimals | `2` |

Treat the network topology as fixed at `172.30.0.0/24`, DNS `.10`, proxy `.20:3128`, and egress
subnet `198.18.0.0/24`. Some values are accepted by Compose interpolation, but the CoreDNS records
and Squid client ACL use the shipped topology; arbitrary overrides are not a supported operating
mode.

Ambient uppercase `HTTP_PROXY`, `HTTPS_PROXY`, or `NO_PROXY` values take shell precedence. Values
that do not exactly describe Agent Lab's proxy are rejected. To diagnose an unrelated host proxy:

```bash
env -u HTTP_PROXY -u HTTPS_PROXY -u NO_PROXY ./scripts/agent --check
```

The direct infrastructure helpers (`scripts/up`, `scripts/down`, `scripts/doctor`, and
`scripts/egress-test`) are a separate path: they pass `.env.local` to Compose for the test substrate.
Do not infer the workload launcher's strict parsing guarantees from those helpers.

## Provide secrets

Put runtime credentials in a guarded directory outside the mounted project. Project and secrets
paths must be disjoint. The secrets directory is mounted read-only at `/run/agent-secrets`.

If this Agent Lab checkout is itself the mounted project, override the default `./secrets` path with
a disjoint directory outside the checkout.

The compliant image entrypoint supports:

- one file per variable, where the filename is a valid environment identifier; and
- `*.env` bundles parsed without sourcing shell.

For a bundle, blank lines and column-one comments are skipped, optional `export ` is removed, and
valid `KEY=VALUE` assignments are exported literally. Nonassignments and invalid identifiers are
skipped rather than executed. Prefer one-file-per-variable secrets when silent skipping would be
hard to notice.

For example, an operator may create a file named `SERVICE_TOKEN` whose bytes are the token. The
entrypoint reads it after container start and exports it only into the workload process environment.
The value does not appear in Compose environment data or `docker inspect`.

Residual exposure remains inside the container: the agent receiving the credential can use it and
may observe it through its process environment. File-backed loading prevents a Docker-metadata leak;
it does not make a secret unknowable to the workload.

The default missing `./secrets` directory is approved during preflight and created with restrictive
permissions only during a real run. `--check` does not create it.

Host permissions still apply through the bind mount. The configured non-root agent uid/gid must be
able to traverse the directory and read the intended files; solve that with deliberate ownership or
group access, not world-readable credentials.

Never put real credentials in:

- `.env.local`;
- Compose `environment:`;
- an image `ENV`;
- command-line environment-file flags;
- the mounted project;
- tracked source.

See [Security](../SECURITY.md) for hard stops.

## Enable narrow egress

`scripts/agent` always starts and verifies Squid, including in deny-all mode. The default `base`
recipe is empty, so the active proxy policy permits no destination—not even the agent's own API.

Select additive recipes for one run:

```bash
AGENT_LAB_ALLOWLIST_RECIPES=base,node-dev \
./scripts/agent -- curl -fsS https://registry.npmjs.org/
```

Shipped recipes are:

| Recipe | Intended destinations |
|---|---|
| `base` | none |
| `node-dev` | npm registry suffix |
| `python-dev` | PyPI and package-file hosts |
| `claude-code` | published Anthropic API host |
| `codex` | published OpenAI API host |

API clients and package managers may contact more hosts as they evolve. Start denied, observe the
actual proxy-mediated requests, and add only destinations you have reviewed.

Recipe files live in `policies/recipes/`. Names are unique lower-kebab identifiers. Entries are
lowercase DNS names or a leading-dot domain suffix; wildcards, URLs, IP addresses, ports, malformed
labels, and duplicates are rejected.

Review proxy log candidates without applying them:

```bash
scripts/dev/harvest-allowlist > /tmp/candidates.txt
```

The output is review-only. Copy only trusted destinations into a narrowly named recipe, run
preflight with that exact selection, and relaunch:

```bash
AGENT_LAB_ALLOWLIST_RECIPES=base,my-reviewed-recipe ./scripts/agent --check
AGENT_LAB_ALLOWLIST_RECIPES=base,my-reviewed-recipe ./scripts/agent -- bash
```

The launcher publishes content-addressed policy bytes, recreates Squid when the requested hash
changes, and verifies both the running container label and the mounted file before the agent starts.

Important limits:

- the agent has no raw direct route, but only proxy-mediated attempts appear in Squid logs;
- Squid permits HTTP/HTTPS ports 80 and 443, with `CONNECT` only to 443;
- private, loopback, link-local, metadata, raw-IP, and unsafe-port destinations are denied ahead of
  allow rules;
- HTTPS policy checks the CONNECT hostname, not TLS ClientHello SNI;
- an allowed destination can receive data the agent sends.

The generic `scripts/up egress` test profile accepts a directly interpolated allowlist path and uses
the tracked example by default. It is not the same policy path as the content-addressed recipes used
by `scripts/agent`.

## Bring a compatible image

Set a compatible image for one run:

```bash
AGENT_LAB_AGENT_IMAGE=registry.example/team/agent:tag ./scripts/agent
```

If the image is not local, Agent Lab pulls it on the host for metadata validation. It resolves the
tag to an immutable image ID before Compose starts.

An image must work as a non-root process with:

- read-only root filesystem;
- `/workspace`, `/home/agent`, `/tmp`, and `/run/agent-secrets` as the only allowed runtime writable
  or mounted surfaces;
- Agent Lab's file-backed secret entrypoint;
- `/usr/bin/env`, POSIX `sh`, `cat`, and `basename` for that entrypoint.

Images declaring other Docker `VOLUME` targets are refused because Docker would create anonymous
writable mounts outside the documented surface.

The wrapper can add the secret-loading entrypoint while preserving exec-form entrypoint, command,
and user metadata:

```bash
scripts/wrap-image registry.example/team/agent:tag
AGENT_LAB_AGENT_IMAGE=agent-lab/agent:wrapped ./scripts/agent
```

Wrapping does not make every image compatible. It does not remove unsupported volume declarations,
make a root-only/read-only-incompatible application safe, or relax any runtime guard. Its isolated,
no-network build context prevents a hostile base image's build hooks from seeing the repository.
Distroless or scratch-style images without the entrypoint runtime can remain incompatible.

## State and cleanup

| Surface | Default lifetime | Removed by `scripts/agent --clean` |
|---|---|---|
| one-off agent container | removed after each run | already gone |
| default `/workspace` | persistent `agent-workspace` volume | yes |
| host project at `/workspace` | host-managed | no |
| default `/home/agent` | persistent `agent-home` volume; may contain tokens | yes |
| ephemeral `/home/agent` | per-container tmpfs | disappears on exit |
| `/tmp` | per-container tmpfs | disappears on exit |
| Squid logs | persistent `audit` volume | yes |
| host secret directory | host-managed | no |
| generated `.cache/squid` policies | ignored host cache | no |

`AGENT_LAB_EPHEMERAL_HOME=1` affects only `/home/agent`. It does not make the workspace, audit
volume, host mounts, or generated host cache ephemeral.

Lifecycle commands:

```bash
./scripts/agent down      # stop services, keep named volumes
./scripts/agent --clean   # stop services, remove workspace/home/audit volumes
```

Use `scripts/agent --clean` for workload state. `scripts/down` and `scripts/down --volumes` belong to
the direct profile/test path and do not load the agent HOME overlay.

## Exercise the infrastructure directly

The lower-level profile helpers are useful for topology inspection and operator acceptance testing.
Choose the profile or test you need:

```bash
./scripts/up core
./scripts/up egress       # implies core
./scripts/up devtools     # implies core
./scripts/egress-test
./scripts/egress-test no-internet
```

Then choose whether teardown retains or erases the direct profile's named volumes:

```bash
./scripts/down
```

or:

```bash
./scripts/down --volumes  # destructive: removes the direct profile's named volumes
```

`scripts/egress-test` builds a disposable test image and exercises live external behavior. Network
availability and third-party endpoints can affect it, so it is an acceptance smoke—not the
deterministic security proof used by required CI. Use `./scripts/dev/docker-gate` for the latter.

## Troubleshooting

| Symptom | Meaning and recovery |
|---|---|
| missing local configuration | run `cp .env.example .env.local`; do not add secrets |
| Docker or Compose unavailable | start the daemon and require Compose v2; rerun `./scripts/doctor` |
| `--check` rejects local syntax | use simple, unique, unquoted `KEY=VALUE` records or shell-scoped values |
| project or secrets path refused | use narrow, canonical, disjoint directories without credential-bearing path components or known root-level credential artifacts |
| workload cannot write the host project | pass the non-root host `id -u` and `id -g` as the agent UID/GID |
| image volume refusal | rebuild the image without undeclared writable surfaces; wrapping does not bypass this |
| package manager or API cannot connect | `base` denies all; select the smallest recipe and inspect proxy-mediated logs |
| policy changed but behavior did not | relaunch through `scripts/agent`; it verifies and recreates Squid for a new policy hash |
| no log for a blocked direct request | expected: routing blocks raw direct traffic before Squid can log it |
| state reappears | identify workspace, HOME, audit, host mount, or host cache; ephemeral HOME covers only one surface |
| a required gate or documented smoke exits 125 | infrastructure or prerequisite failure; no security pass/fail conclusion was reached |

Do not add host networking, attach the agent to `egress`, expose a public port, mount the Docker
socket, or broaden a host mount to make a failure disappear. Preserve the refusal and diagnose the
smallest missing capability.
