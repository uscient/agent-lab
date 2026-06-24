# OpenClaw Image Scaffold

This directory is the source-pin and self-build scaffold for OpenClaw.

## Strategy

`agent-lab` builds its OpenClaw image from a verified pinned upstream source commit. The upstream GHCR image is useful reference material, but it is not a trust anchor for this integration.

This scaffold does not run OpenClaw, does not create a Compose runtime profile, does not onboard, and does not add model/provider access or secrets.

The image preserves upstream runtime assumptions until safe overrides are proven:

- user: `node`, uid `1000`
- config: `/home/node/.openclaw`
- workspace: `/home/node/.openclaw/workspace`
- auth secret dir: `/home/node/.config/openclaw`
- logs: `/tmp/openclaw`

## Hard Boundaries For Future Runtime Work

The locked runtime must have no Docker socket, no host home mounts, no broad host binds, no public bind, no `host.docker.internal`, no browser binaries, no Docker CLI, no messaging channels, no MCP servers, no plugin or skill install surface, no exec/shell/process tools, and no secrets in Compose environment.

OpenClaw sandboxing stays disabled because the Docker backend requires Docker socket access.

## Source Fetch Workflow

Fetch the exact pinned source:

```bash
./scripts/openclaw-fetch-source
```

The script reads `images/openclaw/openclaw.lock`, fetches the full pinned SHA, checks it out detached under `.cache/openclaw/source/<sha>`, and verifies `git rev-parse HEAD`.

Build the local development image without running it:

```bash
./images/openclaw/build.sh
```

## Planned Work

- Build verification, image inspection, SBOM, and vulnerability scan.
- Schema-verified locked capability config and fail-closed preflight.
- Hardened Compose gateway profile on a dedicated internal network.
