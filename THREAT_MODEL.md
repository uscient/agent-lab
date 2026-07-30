# Threat Model

## Assumption

Agent workloads may be prompt-injected, compromised by dependencies, configured incorrectly, or actively trying to reach credentials, the host, the LAN, Docker, or arbitrary internet endpoints.

## Controlled Assets

- Host files and home-directory data.
- Docker socket and Docker daemon control.
- Local network and host services.
- Cloud metadata endpoints.
- Secrets and future service credentials.
- Audit logs.
- Agent workspaces and runtime state.

## Trusted Components

- Docker Compose and Docker's bridge-network enforcement.
- The `agents` network declared `internal: true`.
- CoreDNS configuration for agent/test DNS.
- Squid configuration for mediated outbound HTTP/HTTPS.
- Helper scripts in `scripts/`.

These are trusted components, not perfect components. Bugs or misconfiguration in any of them can weaken the lab.

## Primary Controls

- Agent/test containers attach only to `agents`.
- `agents` is `internal: true` with an isolated IPv4 gateway, so it has no route to the
  internet, host, or LAN.
- `egress` is the only internet-capable bridge.
- Only `egress-proxy` is dual-homed to `agents` and `egress`.
- CoreDNS is pinned as DNS for agent/test containers and refuses arbitrary external recursion.
- Squid enforces a minimal domain allowlist, denies private/link-local/loopback/metadata ranges, denies unsafe ports, and defaults to deny.
- No Docker socket, host home mounts, privileged containers, host networking, or public ports are used.

## Agent Profile

The `agent` profile (`scripts/agent`) runs a bring-your-own agent under the same boundary as the test container, plus per-run hardening: read-only rootfs, `cap_drop: ALL`, `no-new-privileges`, non-root user, resource limits, and attachment to the internal `agents` network only. It exposes four guard-railed seams (image, project dir, secrets, egress recipes). Runtime configuration is parsed once without execution, validated before side effects, and exported as the only Compose authority. Project and secrets paths are canonicalized, required to be disjoint, and identity-checked again immediately before Compose. The inspected image is likewise passed to Compose by immutable image ID.

Writable surfaces are explicit and fall into three classes:

- Secrets — files under `secrets/`, bind-mounted read-only and loaded into the agent's environment at runtime by the baked-in entrypoint. They never appear in compose `environment:`, `--env-file`, or `docker inspect`.
- Agent state / cache — `/home/agent`, a persistent `agent-home` named volume by default. This volume can become credential-bearing (OAuth/login tokens an agent writes after sign-in) and is the main reason to prefer `AGENT_LAB_EPHEMERAL_HOME=1`, which maps it to tmpfs so nothing persists.
- Service / workspace data — `/workspace` (the project dir or a named volume) and `/tmp` (tmpfs). The rootfs itself stays read-only.

Images declaring additional Docker `VOLUME` targets are rejected before secrets or policy state
is materialized. The allowed runtime mount set is checked again from Docker inspection in the
blocking Docker gate.

Egress remains deny-by-default: the `base` recipe is empty, so an agent with no recipe reaches nothing, including its own API. Recipes are additive allowlist fragments; Squid still denies private ranges, raw IPs, and unsafe ports ahead of the allow rule, and matches the CONNECT host, not the TLS SNI (not yet implemented).

## Serena Development Helper

Serena is control-plane development tooling, not an `agent` workload or runtime dependency. Its
one-shot Compose service uses `network_mode: none`, a read-only root filesystem, a non-root user,
`cap_drop: ALL`, no-new-privileges, resource limits, and tmpfs for global state. The repository is
RW at `/workspace` for explicitly requested source edits, but Git metadata, local
environment/state paths, and protected rails are hidden or re-bound read-only. Project cache writes
go to a private temporary bind at `/workspace/.serena/cache`. It receives no host home, Agent Lab
secrets mount, credentials, proxy environment, Docker socket, or ports.
Every bind is private and non-recursive. A metadata-only preflight fails closed on child mounts or
nested Git metadata before an agent-controlled process starts.

The image pins Serena source and preinstalls its pinned Bash language server and ShellCheck during
the explicit build. At runtime the managed language-server directory is an immutable image path
linked into tmpfs state; an unexpected install attempt therefore fails rather than opening egress.
Usage reporting and the web dashboard are disabled in addition to the absent network.

## Residual Risks

- This is practical Docker containment, not VM isolation. A host kernel or container-runtime escape defeats this design.
- Allowlisted destinations can receive exfiltrated data.
- Raw direct egress attempts are blocked by lack of route but are not logged unless a future host firewall layer is added.
- TLS SNI mismatch protection is not implemented. Squid enforces CONNECT host/domain allowlisting only.
- If Docker IPv6 is enabled host-wide, IPv6 must be re-audited. The `agents` network is intended to be IPv4 only.
- DNS-over-HTTPS can reintroduce external DNS if a DoH endpoint is allowlisted.
- Squid and CoreDNS are part of the trust base.
- Path-based Docker APIs cannot eliminate a race by a concurrent privileged host process. The
  launcher canonicalizes and identity-checks paths immediately before use; hostile host control is
  outside the container-containment guarantee.
- Upstream infrastructure images (CoreDNS, Squid) are pinned by non-`latest` tags, not digests; digest-pinning them remains a TODO. The OpenClaw and canonical devbox images digest-pin their base images.

## Out of Scope

- Kernel-grade sandboxing.
- Kubernetes, service mesh, Cilium, OpenZiti, or host firewall automation.
- Browser automation hardening. Future browser profiles must treat browser profiles as secrets and browser escape as a separate high-risk attack surface.
- Cloud resources and CI/CD.
- General application stacks, databases, local LLM services, and agent runtimes.
