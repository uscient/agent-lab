# Agent Lab documentation

This directory separates normal Agent Lab operation from repository development and from the formal
security model. Use the guide that matches the job you are doing.

## I want to…

| Goal | Start here |
|---|---|
| Understand what Agent Lab contains and where the boundaries are | [Architecture](architecture.md) |
| Prepare a new checkout and run the first contained shell | [Operations: first run](operations.md#first-run) |
| Run an agent against my own project | [Operations: run a workload](operations.md#run-a-workload) |
| Provide credentials without placing them in Compose or local config | [Operations: secrets](operations.md#provide-secrets) |
| Permit a narrow set of outbound destinations | [Operations: egress](operations.md#enable-narrow-egress) |
| Understand what persists and erase Agent Lab state | [Operations: state and cleanup](operations.md#state-and-cleanup) |
| Diagnose a startup, mount, image, or network refusal | [Operations: troubleshooting](operations.md#troubleshooting) |
| Develop this repository | [Development and verification](development.md) |
| Configure Claude, Codex, or Grok for repository development | [Development-agent configuration](agent-config.md) |
| Reproduce a GitHub check locally | [CI gate mapping](ci.md) |
| Audit the security claims and residual risks | [Security policy](../SECURITY.md) and [threat model](../THREAT_MODEL.md) |

## Command map

| Command | Role |
|---|---|
| `./scripts/doctor` | operator prerequisites and local topology checks |
| `./scripts/agent --check` | read-only workload configuration and mount preflight |
| `./scripts/agent -- <command>` | run one contained workload |
| `./scripts/agent down` | stop Agent Lab services and keep named volumes |
| `./scripts/agent --clean` | stop services and remove Agent Lab named volumes |
| `./scripts/up egress` | bring up a direct profile (`core`, `egress`, or `devtools`) |
| `./scripts/egress-test` | run the external operator acceptance smoke |
| `./scripts/dev/check default quick` | run the Docker-free required gate |
| `./tools/validate.sh --strict` | run strict static Compose/configuration validation |
| `./scripts/dev/docker-gate` | run deterministic Docker containment suites |

The commands are not interchangeable. In particular, a successful `doctor`, Compose render, or
external acceptance request does not prove runtime containment. The Docker gate supplies that
evidence.

## Documentation ownership

| Document | Canonical subject |
|---|---|
| [README](../README.md) | public orientation and shortest safe path |
| [Operations](operations.md) | operator configuration, workload lifecycle, and recovery |
| [Architecture](architecture.md) | planes, networks, data flow, storage, and authority |
| [Security policy](../SECURITY.md) | operational hard stops and secret policy |
| [Threat model](../THREAT_MODEL.md) | assumptions, guarantees, residual risks, and exclusions |
| [Development](development.md) | maintainer workflow and local evidence |
| [CI](ci.md) | required GitHub checks and exact replay model |
| [Development-agent configuration](agent-config.md) | repository agent policy and adapters |

Component READMEs document only their local implementation:

- [CoreDNS](../dns/coredns/README.md)
- [Squid](../gateway/squid/README.md)
- [OpenClaw image scaffold](../images/openclaw/README.md)
- [Egress acceptance tests](../tests/egress/README.md)

## Specialist development references

- [Development-agent configuration](agent-config.md): Claude, Codex, and Grok policy wiring
- [CI gate mapping](ci.md): required GitHub workers and replay evidence
- [Serena](serena.md): contained semantic tooling for Bash development

Source and executable checks determine actual behavior. Documentation explains that behavior but
does not override `AGENTS.md`, Compose, launcher validation, or the versioned security manifests.
