# Agent Lab documentation

This directory separates normal Agent Lab operation, Experiment onboarding, repository development,
and the formal security model. Use the guide that matches the job you are doing.

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
| Install the local CLI and initialize a private Agent Lab home | [Local installation](installation.md) |
| Author, check, authorize, install, or inspect an Experiment | [Experiments](experiments.md) |
| Manage shared local image names for Experiments | [Local image names](images.md) |
| Develop this repository | [Development and verification](development.md) |
| Configure Claude, Codex, or Grok for repository development | [Development-agent configuration](agent-config.md) |
| Reproduce a GitHub check locally | [CI gate mapping](ci.md) |
| Audit the security claims and residual risks | [Security policy](../SECURITY.md) and [threat model](../THREAT_MODEL.md) |

## Runtime and verification command map

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

## Experiments

Experiment onboarding is a separate local control-plane workflow. Read these guides in order for a
first installation, or jump directly to the guide that owns the state you are changing:

| Guide | Canonical subject |
|---|---|
| [Local installation](installation.md) | install the verified CLI bundle, initialize a private home, and provision pinned CUE and Cedar tools |
| [Experiments](experiments.md) | author, check, authorize, install, and inspect one declarative Experiment |
| [Local image names](images.md) | map an operator-owned name to an immutable OCI subject for use by Experiments |

The current Experiment lifecycle stops after a permitted install stores verified onboarding
evidence. It does not run content, invoke Docker, acquire or admit image bytes, create a network, or
start a workload. Linux is the supported v0alpha1 host; see the Experiments guide for the
operation-specific limits.

### Experiment command map

These commands use the installed `agent-lab` CLI and its explicit or configured private home. They
are distinct from the `./scripts/agent` workload launcher above.

| Command | Role |
|---|---|
| `agent-lab --home ABSOLUTE_HOME init` | initialize the private local control-plane home |
| `agent-lab --home ABSOLUTE_HOME tools provision` | acquire and verify the pinned CUE and Cedar tools |
| `agent-lab --home ABSOLUTE_HOME experiment check SOURCE` | validate and resolve one source without durable Experiment state |
| `agent-lab --home ABSOLUTE_HOME experiment authorize install SOURCE` | preview a fresh source- and plan-bound install decision |
| `agent-lab --home ABSOLUTE_HOME experiment install SOURCE` | freshly check and authorize, then retain a closed evidence envelope only on permit |
| `agent-lab --home ABSOLUTE_HOME experiment inspect NAME` | verify and report one retained Experiment without repair |
| `agent-lab --home ABSOLUTE_HOME image add NAME DIGEST_REF` | add an operator-local image-name mapping |
| `agent-lab --home ABSOLUTE_HOME image inspect NAME` | verify and report one image-name mapping |
| `agent-lab --home ABSOLUTE_HOME image list` | list active local image-name mappings |
| `agent-lab --home ABSOLUTE_HOME image remove NAME --expect ENTRY_DIGEST` | compare-and-swap remove one image-name mapping |

Uppercase words are syntax placeholders. `SOURCE` is a directory, `--zip ARCHIVE`, or
`--git https://github.com/OWNER/REPOSITORY.git --commit COMMIT_ID`. The
[Experiments guide](experiments.md#source-formats) defines each form and its bounds.

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
| [Local installation](installation.md) | verified local program bundle, private home, tools, and stored evidence layout |
| [Experiments](experiments.md) | authored format, source intake, planning, authorization, and onboarding lifecycle |
| [Local image names](images.md) | shared local Experiment image-name authority and mutation rules |

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
