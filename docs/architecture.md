# Agent Lab architecture

Agent Lab separates contained workloads, infrastructure tests, and repository-development tooling.
Keeping those planes distinct prevents a convenience feature in one path from quietly becoming
authority in another.

## System view

```text
host
├── operator configuration and guarded launcher
│       │
│       ▼
│   one-off agent container
│       │
│       ├── /workspace
│       ├── /run/agent-secrets (read-only)
│       ├── /home/agent (volume or tmpfs)
│       └── internal `agents` bridge
│               ├── CoreDNS
│               └── Squid ── `egress` bridge ── allowed internet destinations
│
├── infrastructure acceptance path
│       └── core / egress / devtools profiles and egress-test
│
└── repository development control plane
        ├── AGENTS.md, hooks, guards, and client adapters
        ├── fast / static / Docker CI gates
        └── repository-scoped development helpers
```

Only Squid is attached to both Docker networks. The agent, DNS service, and test workload never join
the internet-capable `egress` bridge.

## Three separate planes

### Workload data plane

`scripts/agent` is the supported front door for running an agent. It combines:

- `compose.yaml`;
- `compose.egress.yaml`;
- `compose.agent.yaml`;
- exactly one HOME overlay: persistent or ephemeral.

The launcher owns configuration, mount validation, image resolution, policy publication, egress
verification, and the final one-off `docker compose run --rm agent`.

### Infrastructure and test plane

`scripts/up`, `scripts/down`, and `scripts/egress-test` operate the lower-level `core`, `egress`, and
`devtools` profiles. They are useful for inspecting topology and exercising live network behavior,
but they are not the normal workload launcher.

The required deterministic runtime evidence comes from `scripts/dev/docker-gate`, which uses
isolated fixtures, exact assertions, and cleanup rather than relying on an external endpoint to
stand in for a security proof.

### Repository development control plane

`AGENTS.md`, the `PreToolUse` guard, client adapters, Git workflow, CI, and specialist helpers govern
tools that develop this repository. They do not become part of an Agent Lab workload.

The guard is defense-in-depth for development workflow mistakes. Docker containment—not prompt
instructions or command policy—is the workload boundary. Development helpers receive only the
capabilities their documented task requires.

See [Development](development.md) and [development-agent configuration](agent-config.md).

## Experiment planning and installed evidence

`scripts/agent-lab experiment check DIRECTORY` snapshots and validates the closed authored
`agent-lab/v0alpha1` request with the
repository-pinned CUE contract and emits one canonical, digest-bound `RequestedExperimentPlan`.
`scripts/agent-lab experiment authorize install DIRECTORY` reads the snapshot once, derives that same plan
in-process, and asks the repository-pinned Cedar policy whether the fixed local compatibility
principal may submit the exact plan digest.

Those two commands are no-effect preflights. `experiment install DIRECTORY` instead repeats the
snapshot, planning, and Cedar evaluation, then stores the exact permitted evidence in the
initialized home. No caller-supplied decision is accepted. For a local image name, install rechecks
the selected entry under the shared catalog lock before taking the Experiment store lock
exclusively; both remain held through durable no-replace publication. Direct and bundled selectors
do not open local catalog state.

The installed envelope contains the exact artifact plus closed plan, decision, provenance, and
receipt records. Its installation key binds source, domain-separated plan, contract, authorization,
and selected-entry identities. The receipt binds the artifact and every other evidence record; its
returned receipt digest binds the receipt itself. An exact retry verifies the envelope and returns
the same identity; a different identity under the same requested name never overwrites it.
`experiment inspect NAME` takes the store lock shared and verifies the complete envelope without
repairing staging.

Installation is persistent onboarding evidence only. It makes no container-engine, network,
registration, image-acquisition, admission, or runtime change and does not waive the containment
envelope. The requested name identifies this stored envelope, not a running Broker identity or
runtime scope. Experiment start, stop, and runtime removal remain future Broker operations; stored
artifact uninstall is also not implemented.

## Workload launch sequence

The launcher is intentionally ordered so that untrusted or persistent state appears only after
read-only validation succeeds:

1. Read shell values, strictly parse the operator-local configuration, and apply defaults.
2. Validate every scalar, topology relationship, image reference, and project name.
3. Validate recipe names and every domain entry.
4. Preflight the generated-policy destination without writing it.
5. Canonicalize and guard the project and secrets paths; require them to be disjoint.
6. For `--check`, print the effective plan and stop here.
7. Build or pull the selected image on the host when necessary.
8. Resolve the mutable image reference to an immutable Docker image ID.
9. Reject image-declared writable volumes outside the documented mount surface.
10. Recheck the project identity, create only the already-approved secrets directory, and publish
    content-addressed allowlist bytes.
11. Recheck paths, start CoreDNS and Squid, and verify the active policy label and mounted policy
    bytes.
12. Recheck paths again immediately before the one-off agent consumes them.

The container receives validated exports; Compose does not reinterpret the original workload config
file.

## Network model

### `agents`

The `agents` bridge is:

- `internal: true`;
- IPv4-only in the shipped configuration;
- configured with isolated gateway mode;
- the only network joined by agent and test containers.

The shipped subnet is `172.30.0.0/24`.

CoreDNS is `172.30.0.10`. It answers the lab-local DNS and proxy names, then returns NXDOMAIN for
arbitrary external A and AAAA queries. It does not forward to the host, Docker's resolver, or a
public resolver.

Squid is `172.30.0.20:3128` on this network.

### `egress`

The `egress` bridge is internet-capable and uses `198.18.0.0/24` by default. Only Squid joins it.

Squid:

- accepts clients only from the shipped agent subnet;
- allows ports 80 and 443, with `CONNECT` only to 443;
- denies private, loopback, link-local, multicast, reserved, cloud-metadata, and raw-IP
  destinations;
- applies the selected domain allowlist;
- defaults to deny.

Proxy environment variables are cooperative routing hints. The security property comes from the
agent lacking any non-internal network attachment. A client that ignores the proxy still has no raw
internet route.

The subnet, DNS, and proxy values form a coupled static bundle. Compose accepts validated
interpolation values, but CoreDNS records and Squid's client ACL are shipped for the defaults.
Arbitrary independent topology customization is not supported.

## Two egress policy paths

The direct infrastructure profile accepts an interpolated allowlist path and defaults to
`policies/egress.allowlist.example`. That path exists for generic Compose operation and network
acceptance testing.

The workload launcher uses a different path:

```text
selected recipes
    → validated domain set
    → content-addressed .cache/squid file
    → Squid mount + expected SHA label
    → running-label and mounted-byte verification
```

`scripts/agent` rejects an arbitrary direct allowlist override. Recipes are the sole workload policy
authority. When recipe content changes, the launcher force-recreates Squid and verifies the new
policy before starting the agent.

## Filesystem and state model

The agent root filesystem is read-only. Writable or mounted surfaces are explicit:

| Container path | Backing | Access | Lifetime |
|---|---|---|---|
| `/workspace` | host project or `agent-workspace` volume | read-write | host-managed or persistent volume |
| `/run/agent-secrets` | guarded host directory | read-only | host-managed |
| `/home/agent` | `agent-home` volume by default | read-write | persistent volume |
| `/home/agent` with ephemeral flag | tmpfs | read-write | one container |
| `/tmp` | tmpfs | read-write | one container |

Squid logs live in the persistent `audit` volume. Generated content-addressed policies live under
the ignored host `.cache/squid` directory.

The agent HOME may become credential-bearing if a tool writes OAuth or login state. Ephemeral HOME
is the safer choice when persistence is unnecessary, but it affects only that mount.

Docker images can declare `VOLUME`s that silently create anonymous writable mounts. Agent Lab
inspects image metadata and permits only the four documented target paths; any other declaration
fails before secrets or policy state is materialized.

## Secret flow

Secrets are files, not Compose values:

```text
guarded host directory
    → read-only /run/agent-secrets mount
    → compliant entrypoint reads files after container start
    → workload process environment
```

This keeps values out of image `ENV`, Compose environment data, env-file flags, and
`docker inspect`. It does not protect a credential from the agent process that legitimately receives
it.

Project and secret paths are canonicalized, identity-checked, and required to be disjoint. The
launcher repeats identity checks around image preparation and egress reconciliation to narrow
path-replacement races. A concurrent privileged host process remains outside the guarantee.

## Security boundary

The primary system controls are:

- internal-only agent networking;
- a single dual-homed egress mediator;
- explicit filesystem surfaces;
- read-only secret mounts;
- no Docker socket, broad host-home mount, privileged mode, host networking, or public ports;
- fail-closed validation and runtime inspection.

The agent workload additionally has a read-only root filesystem, non-root identity, all Linux
capabilities dropped, no-new-privileges, and resource limits. Infrastructure services retain only
their documented exceptions: CoreDNS adds `NET_BIND_SERVICE`, while Squid's read-only-root and
capability hardening remain deferred until validated for the pinned image.

Agent Lab accepts that an experiment can fail. It does not accept treating absence of evidence,
external flakiness, or a skipped check as proof that a boundary held.

For formal assumptions and limits, read [Security](../SECURITY.md) and the
[threat model](../THREAT_MODEL.md).

## Source map

| Concern | Primary implementation |
|---|---|
| base networks and DNS service | `compose.yaml`, `dns/coredns/Corefile` |
| Squid and test service | `compose.egress.yaml`, `gateway/squid/` |
| workload container | `compose.agent.yaml` and HOME overlays |
| workload orchestration | `scripts/agent` |
| Experiment installed evidence | `scripts/agent-lab`, `scripts/experiment.py`, `scripts/experiment_store.py`, contracts, and authorization policy |
| config parsing and validation | `scripts/lib/config.sh` |
| project and secret guards | `scripts/lib/guard.sh` |
| recipe publication | `scripts/lib/allowlist.sh` |
| active policy verification | `scripts/lib/egress.sh` |
| image writable-surface validation | `scripts/lib/image.sh` |
| runtime secret loading | `tools/agent-entrypoint.sh` |
| deterministic security gates | `scripts/dev/security-gate`, `tests/security/*.manifest` |

Read [Operations](operations.md) for the supported commands rather than invoking these internals
directly.
