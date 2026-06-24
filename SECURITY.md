# Security

`agent-lab` treats agent workloads as hostile or compromised. A broken experiment is acceptable; a silent boundary bypass is not.

## Secret Policy

Never commit real secrets. This includes API keys, tokens, private keys, SSH keys, browser profiles, cloud credentials, password-manager data, `.env`, `.env.local`, `secrets/`, runtime state, model caches, and generated logs.

Only `.env.example` belongs in source, and it must contain non-secret placeholders or safe defaults. Future real credentials should be files under `secrets/`, mounted read-only per service. Do not place real secrets in environment variables; env leaks through Docker inspection and process metadata.

Concretely: `docker inspect` exposes a container's `Config.Env`, which includes image `ENV`, compose `environment:`, and `--env-file` values — so a secret passed any of those ways is visible to anyone who can inspect the container. The `agent` profile instead bind-mounts `secrets/` read-only and the baked-in entrypoint (`tools/agent-entrypoint.sh`) reads each file and exports it at runtime. Runtime-exported variables do not appear in `docker inspect`. The residual exposure is `/proc` inside the container — i.e. the agent that already holds the key.

## Hard Stops

Stop work and report before continuing if tracked source contains or introduces:

- Real secret, token, API key, private key, browser profile, SSH key, or cloud credential.
- `.env`, `.env.local`, private env files, `secrets/`, runtime state, browser profiles, model caches, or key material.
- Docker socket mounts.
- Host home-directory mounts.
- `network_mode: host`.
- Privileged containers.
- Public port bindings by default.
- Agent/test containers attached directly to the internet-capable `egress` network.
- Agent containers with both broad credentials and open internet.
- Direct internet paths from agents that bypass the proxy.
- Security claims that are not implemented and tested.

## Network Rules

Agent and test containers must attach only to the internal `agents` network. Only `egress-proxy` may attach to both `agents` and `egress`.

No service publishes public ports. Any operator-facing ports must bind to `127.0.0.1` unless explicitly approved.

The Docker socket must never be mounted into an agent container. Host home directories, SSH directories, cloud-drive roots, browser profiles, and password-manager data must never be mounted into agent containers.

## Allowlist Limitation

Domain allowlisting controls where traffic can go. It does not control what an agent sends to an allowed destination. If `example.com` is allowlisted, a compromised agent can send data to `example.com`.

## Vulnerability Reporting

**This is a closed project.** Do not open public GitHub issues for security matters.

Report suspected boundary bypasses, secret exposure, or dangerous defaults to the repository owner through the private project channel used for this repository.

See also the contributing policy in the repository for details on external vs. internal participation.
