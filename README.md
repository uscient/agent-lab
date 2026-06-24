# agent-lab

`agent-lab` is a Docker Compose containment lab for experimenting with autonomous agent workloads behind explicit network, filesystem, credential, and egress controls.

> **Repository status (public mirror)**
>
> This code is published under the Apache 2.0 license for transparency, reference, and local use/forking.  
> **No contributions are accepted from non-members.** Pull requests and issues from outside the organization will be closed without review.
>
> See [CONTRIBUTING.md](.github/CONTRIBUTING.md) and [SECURITY.md](SECURITY.md) for details.

It is not a general AI application stack, a public SaaS control plane, or an unrestricted agent launcher. It implements the containment substrate — an internal agent network, controlled DNS, a Squid egress proxy, and acceptance tests — plus a bring-your-own-agent profile (`scripts/agent`) that runs any agent image on your project behind those controls.

## Default Posture

- No public ports.
- No direct internet from agent/test containers.
- No Docker socket mounts.
- No host home-directory mounts.
- No privileged containers.
- No real secrets in Git.
- Agent/test containers attach only to the `agents` network.
- The `agents` network is `internal: true`; this is the primary default-deny boundary.
- Squid is the only sanctioned outbound path.
- Proxy environment variables help cooperating tools, but they are not the security boundary.

This is practical Docker containment, not VM-grade isolation. Containers still share the host kernel. A container-runtime or kernel escape is outside the guarantees of this lab.

## Quick Start

```bash
cp .env.example .env.local
./scripts/doctor
./scripts/up core
./scripts/up egress
./scripts/egress-test
```

Stop the stack:

```bash
./scripts/down
```

`./scripts/down --volumes` also removes named volumes, including the `audit` log volume.

## Bring Your Own Agent

`scripts/agent` runs any agent image against your project, secure-by-default: read-only rootfs, attached only to the internal `agents` network, no Docker socket, no host home mount, all capabilities dropped, and deny-by-default egress.

```bash
cp .env.example .env.local
# Point at your project (optional; defaults to an ephemeral workspace volume):
#   AGENT_LAB_PROJECT_DIR=/abs/path/to/your/repo
./scripts/agent -- bash      # interactive shell in the sandbox (devbox built on first use)
./scripts/agent --clean      # stop and remove the named volumes
```

You adapt the lab through exactly four seams; everything else is locked:

| Seam | How | Effect |
| --- | --- | --- |
| Agent image | `AGENT_LAB_AGENT_IMAGE` | which image runs (default: locally-built `agent-lab/devbox:local`) |
| Project | `AGENT_LAB_PROJECT_DIR` | one host dir mounted RW at `/workspace` (guarded at preflight) |
| Secrets | files under `secrets/` | loaded into the agent's env at runtime, never into config or `docker inspect` |
| Egress | `AGENT_LAB_ALLOWLIST_RECIPES` | which `policies/recipes/*.allowlist` fragments compose into Squid |

Adaptability comes from these narrow, guard-railed openings, never from loosened defaults. Unsafe choices — mounting `$HOME`, a system path, or a directory holding `.ssh`/`.aws`/an `.npmrc` auth token — are refused at preflight, not silently honored.

### Egress is opt-in (deny-by-default)

The `base` recipe is empty, so with no recipes the agent reaches **nothing** — including its own API. Add recipes to open specific domains:

```bash
AGENT_LAB_ALLOWLIST_RECIPES=base,node-dev ./scripts/agent -- npm install
```

Shipped recipes: `base` (empty), `node-dev`, `python-dev`, `claude-code`, `codex`. The `claude-code`/`codex` recipes carry only the published API host; discover the rest of an agent's real domains from a run instead of guessing:

```bash
scripts/dev/harvest-allowlist > /tmp/candidates.txt   # review-only; never auto-applied
```

Then copy the lines you trust into a recipe. Recipe changes take effect on the next `./scripts/agent` run (Squid loads the allowlist at startup; run `./scripts/agent down` first if the proxy is already up).

### Bringing a third-party image into compliance

The agent image must load file-based secrets via the baked-in entrypoint. Make any image compliant in one command, preserving its original entrypoint/command:

```bash
scripts/wrap-image ghcr.io/example/agent:latest
AGENT_LAB_AGENT_IMAGE=agent-lab/agent:wrapped ./scripts/agent
```

`images/devbox/Dockerfile` is the canonical compliant example. Agent state/cache lives in the `agent-home` named volume by default and may hold login tokens; set `AGENT_LAB_EPHEMERAL_HOME=1` to map `/home/agent` to tmpfs so nothing persists. See `THREAT_MODEL.md` for the full writable-surface taxonomy.

## Profiles

- `core`: creates the internal network substrate and starts CoreDNS.
- `egress`: starts Squid as the only dual-homed service on `agents` and `egress`.
- `devtools`: enables the disposable `egress-test` container used by acceptance tests.

Nothing starts by default. The helper scripts activate profile combinations intentionally.

`./scripts/up egress` automatically includes `core`. `./scripts/up devtools` also includes `core`, so it can be used for no-internet tests without starting Squid.

## Egress Modes

No-internet mode is `core` plus `devtools`, without `egress-proxy`. The test container is attached only to the internal `agents` network, so raw direct internet attempts fail because there is no off-bridge route.

Allowlisted-egress mode is `core` plus `egress` plus `devtools`. The test container still has no direct internet route. Cooperating tools can use `HTTP_PROXY` or `HTTPS_PROXY` to reach Squid at `172.30.0.20:3128`. Squid allows only domains in `policies/egress.allowlist.example` by default.

Raw direct egress attempts are blocked by the internal Docker network, but they are not logged unless optional host firewall hardening is added. Proxy-mediated allowed and denied requests are logged by Squid.

## Static Network Defaults

```text
agents subnet: 172.30.0.0/24
CoreDNS:       172.30.0.10
Squid:         172.30.0.20:3128
```

These values are duplicated in `.env.example`, `compose.yaml`, `compose.egress.yaml`, `dns/coredns/Corefile`, and `gateway/squid/squid.conf` where needed so the generated configuration stays readable.

## What This Lab Does Not Prove

- TLS SNI peek/splice enforcement is not enabled yet. Squid currently enforces the CONNECT host/domain allowlist, private destination denies, unsafe port denies, and default deny. SNI mismatch protection is not yet implemented.
- Raw blocked attempts are not logged without a future host firewall layer.
- IPv6 is not enabled on the `agents` network. If Docker IPv6 is enabled host-wide, re-audit before relying on these rules.
- Allowlisted domains can still receive exfiltrated data. The allowlist bounds where data may go, not what data is sent.

## License

Licensed under the [Apache License 2.0](LICENSE).

## Contributing & PR Policy

**No contributions are accepted from non-members.**

- External pull requests will be closed.
- External issues will generally be closed (see the issue templates for redirects to documentation and private reporting).

Organization members: see `AGENTS.md`, `doctrine/`, and the internal process.

For everyone else: the repository is provided as-is for you to review or run locally. We are not accepting changes, feature requests, or support requests from the public.

## Security

See [SECURITY.md](SECURITY.md) for the lab's security model and how to report vulnerabilities (private channel only).
