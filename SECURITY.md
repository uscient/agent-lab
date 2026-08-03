# Security

`agent-lab` treats agent workloads as hostile or compromised. A broken experiment is acceptable; a
silent boundary bypass is not.

For system flow and supported operator commands, read [Architecture](docs/architecture.md) and
[Operations](docs/operations.md). The formal assumptions and residual risks are in
[THREAT_MODEL.md](THREAT_MODEL.md).

## Secret Policy

Never commit real secrets. This includes API keys, tokens, private keys, SSH keys, browser profiles, cloud credentials, password-manager data, `.env`, `.env.local`, `secrets/`, runtime state, model caches, and generated logs.

Only `.env.example` belongs in source, and it must contain non-secret placeholders or safe defaults.
Runtime credentials belong in the guarded secrets directory as files, mounted read-only for the
agent. Do not place real secrets in `.env.local`, Compose environment, image `ENV`, or environment
file flags; those values leak through Docker inspection and process metadata.

Concretely: `docker inspect` exposes a container's `Config.Env`, which includes image `ENV`,
Compose `environment:`, and `--env-file` values. The `agent` profile instead bind-mounts the guarded
secrets directory read-only, and the compliant entrypoint (`tools/agent-entrypoint.sh`) reads each
file and exports it after container start. Runtime-exported variables do not appear in
`docker inspect`. The residual exposure is the process environment and `/proc` inside the
container—the agent that holds the key can use and observe it.

See [Provide secrets](docs/operations.md#provide-secrets) for supported file formats and mount
behavior.

## Hard Stops

Stop work and report before continuing if tracked source contains or introduces:

- Real secret, token, API key, private key, browser profile, SSH key, or cloud credential.
- `.env`, `.env.local`, private env files, `secrets/`, runtime state, browser profiles, model caches, or key material.
- Docker socket mounts.
- Whole or broad host home-directory mounts.
- `network_mode: host`.
- Privileged containers.
- Public port bindings by default.
- Agent/test containers attached directly to the internet-capable `egress` network.
- Agent containers with both broad credentials and open internet.
- Direct internet paths from agents that bypass the proxy.
- Security claims that are not implemented and tested.

## Network Rules

Agent and test containers must attach only to the internal `agents` network. A narrowly scoped
development helper may instead use `network_mode: none`; Serena does so because MCP and its
preinstalled language server communicate over stdio and need no network. Only `egress-proxy` may
attach to both `agents` and `egress`.

No service publishes public ports. Any operator-facing ports must bind to `127.0.0.1` unless explicitly approved.

The Docker socket must never be mounted into an agent container. Whole or broad host-home mounts,
SSH directories, cloud-drive roots, browser profiles, and password-manager data must never be
mounted into agent containers. A narrowly selected project below a home directory is allowed only
after the project guard accepts it.

The Serena development helper binds the current repository RW at `/workspace`, then overlays Git
metadata, local environment/state paths, and protected rails with empty or read-only binds. A
private temporary bind receives only `.serena/cache` writes; global state is tmpfs. It has no Agent
Lab secrets mount, host home mount, proxy environment, Docker socket, or runtime install path.
All binds are private and non-recursive; preflight rejects child mounts and nested Git metadata
before Docker starts.
The ignored `proj/` collaboration tree is shared RW only for cooperating host-side development
agents. Startup rejects links, special objects, and multiply linked files already present there;
host writers are trusted not to introduce them after that snapshot.
The Serena source and direct language-server/tool versions are fetched at the explicit image build
and pinned before the no-network runtime is started.

## Allowlist Limitation

Domain allowlisting controls where traffic can go. It does not control what an agent sends to an allowed destination. If `example.com` is allowlisted, a compromised agent can send data to `example.com`.

## Security Verification

Required repository evidence is split into Docker-free contracts, strict static
topology/configuration invariants, and deterministic runtime containment. Exit 125 is an
infrastructure result, not a pass or assertion failure. The canonical commands and replay semantics
are in [Development and verification](docs/development.md) and [CI gate mapping](docs/ci.md).

## Vulnerability Reporting

**This is a closed project.** Do not open public GitHub issues for security matters.

Organization members report suspected boundary bypasses, secret exposure, or dangerous defaults
through the established private organization/project channel. This public mirror does not publish
an external security-report intake address. Do not disclose exploit details in an issue or pull
request.

See [the contributing policy](.github/CONTRIBUTING.md) for external vs. internal participation.
