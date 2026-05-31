# syntax=docker/dockerfile:1.7

# M1 self-build scaffold for OpenClaw.
# Build context must be the verified source directory produced by
# scripts/openclaw-fetch-source. Do not clone moving branches in this Dockerfile.

ARG OPENCLAW_SOURCE_REPO="https://github.com/openclaw/openclaw.git"
ARG OPENCLAW_SOURCE_COMMIT="a825b5576b1c3a0a2f07466ea9d3dffc8dc8e54d"
ARG OPENCLAW_EXTENSIONS=""
ARG OPENCLAW_BUNDLED_PLUGIN_DIR="extensions"
ARG OPENCLAW_NODE_BOOKWORM_IMAGE="node:24-bookworm@sha256:3a09aa6354567619221ef6c45a5051b671f953f0a1924d1f819ffb236e520e6b"
ARG OPENCLAW_NODE_BOOKWORM_SLIM_IMAGE="node:24-bookworm-slim@sha256:e8e2e91b1378f83c5b2dd15f0247f34110e2fe895f6ca7719dbb780f929368eb"
ARG OPENCLAW_NODE_BOOKWORM_SLIM_DIGEST="sha256:e8e2e91b1378f83c5b2dd15f0247f34110e2fe895f6ca7719dbb780f929368eb"
ARG OPENCLAW_BUN_IMAGE="oven/bun:1.3.13@sha256:87416c977a612a204eb54ab9f3927023c2a3c971f4f345a01da08ea6262ae30e"

FROM ${OPENCLAW_NODE_BOOKWORM_IMAGE} AS workspace-deps
ARG OPENCLAW_EXTENSIONS
ARG OPENCLAW_BUNDLED_PLUGIN_DIR

RUN --mount=type=bind,source=packages,target=/tmp/packages,readonly \
    --mount=type=bind,source=${OPENCLAW_BUNDLED_PLUGIN_DIR},target=/tmp/${OPENCLAW_BUNDLED_PLUGIN_DIR},readonly \
    mkdir -p /out/packages "/out/${OPENCLAW_BUNDLED_PLUGIN_DIR}" && \
    for manifest in /tmp/packages/*/package.json; do \
      [ -f "$manifest" ] || continue; \
      pkg_dir="${manifest%/package.json}"; \
      pkg_name="${pkg_dir##*/}"; \
      mkdir -p "/out/packages/$pkg_name" && \
      cp "$manifest" "/out/packages/$pkg_name/package.json"; \
    done && \
    for ext in $(printf '%s\n' "$OPENCLAW_EXTENSIONS" | tr ',' ' '); do \
      if [ -f "/tmp/${OPENCLAW_BUNDLED_PLUGIN_DIR}/$ext/package.json" ]; then \
        mkdir -p "/out/${OPENCLAW_BUNDLED_PLUGIN_DIR}/$ext" && \
        cp "/tmp/${OPENCLAW_BUNDLED_PLUGIN_DIR}/$ext/package.json" "/out/${OPENCLAW_BUNDLED_PLUGIN_DIR}/$ext/package.json"; \
      fi; \
    done

FROM ${OPENCLAW_BUN_IMAGE} AS bun-binary

FROM ${OPENCLAW_NODE_BOOKWORM_IMAGE} AS build
ARG OPENCLAW_BUNDLED_PLUGIN_DIR
ARG OPENCLAW_EXTENSIONS

COPY --from=bun-binary /usr/local/bin/bun /usr/local/bin/bun

RUN corepack enable

WORKDIR /app

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY openclaw.mjs ./
COPY ui/package.json ./ui/package.json
COPY patches ./patches
COPY scripts/postinstall-bundled-plugins.mjs scripts/preinstall-package-manager-warning.mjs scripts/npm-runner.mjs scripts/windows-cmd-helpers.mjs scripts/prepare-git-hooks.mjs ./scripts/
COPY scripts/lib/package-dist-imports.mjs ./scripts/lib/package-dist-imports.mjs
COPY --from=workspace-deps /out/packages/ ./packages/
COPY --from=workspace-deps /out/${OPENCLAW_BUNDLED_PLUGIN_DIR}/ ./${OPENCLAW_BUNDLED_PLUGIN_DIR}/

RUN --mount=type=cache,id=agent-lab-openclaw-pnpm-store,target=/root/.local/share/pnpm/store,sharing=locked \
    NODE_OPTIONS=--max-old-space-size=2048 pnpm install --frozen-lockfile \
      --config.supportedArchitectures.os=linux \
      --config.supportedArchitectures.cpu="$(node -p 'process.arch')" \
      --config.supportedArchitectures.libc=glibc

RUN set -eux; \
    if ! printf '%s\n' "$OPENCLAW_EXTENSIONS" | tr ',' ' ' | tr ' ' '\n' | grep -qx 'matrix'; then \
      echo "matrix not bundled; skipping matrix-sdk-crypto check"; \
      exit 0; \
    fi; \
    for attempt in 1 2 3 4 5; do \
      if find /app/node_modules -name "matrix-sdk-crypto*.node" 2>/dev/null | grep -q .; then \
        exit 0; \
      fi; \
      node /app/node_modules/@matrix-org/matrix-sdk-crypto-nodejs/download-lib.js || true; \
      sleep $((attempt * 2)); \
    done; \
    find /app/node_modules -name "matrix-sdk-crypto*.node" 2>/dev/null | grep -q . || \
      (echo "ERROR: matrix-sdk-crypto native addon missing after retries" >&2 && exit 1)

COPY . .

RUN for dir in /app/${OPENCLAW_BUNDLED_PLUGIN_DIR} /app/.agent /app/.agents; do \
      if [ -d "$dir" ]; then \
        find "$dir" -type d -exec chmod 755 {} +; \
        find "$dir" -type f -exec chmod 644 {} +; \
      fi; \
    done

RUN pnpm_config_verify_deps_before_run=false pnpm canvas:a2ui:bundle || \
    (echo "A2UI bundle: creating stub (non-fatal)" && \
     mkdir -p extensions/canvas/src/host/a2ui && \
     echo "/* A2UI bundle unavailable in this build */" > extensions/canvas/src/host/a2ui/a2ui.bundle.js && \
     echo "stub" > extensions/canvas/src/host/a2ui/.bundle.hash && \
     rm -rf vendor/a2ui apps/shared/OpenClawKit/Tools/CanvasA2UI)

RUN NODE_OPTIONS=--max-old-space-size=8192 pnpm_config_verify_deps_before_run=false pnpm build:docker
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm_config_verify_deps_before_run=false pnpm ui:build
RUN pnpm_config_verify_deps_before_run=false pnpm qa:lab:build

FROM build AS runtime-assets
ARG OPENCLAW_EXTENSIONS
ARG OPENCLAW_BUNDLED_PLUGIN_DIR

RUN --mount=type=cache,id=agent-lab-openclaw-pnpm-store,target=/root/.local/share/pnpm/store,sharing=locked \
    pnpm list --prod --depth Infinity --json | node scripts/list-prod-store-packages.mjs | xargs -r pnpm store add && \
    CI=true pnpm prune --prod \
      --config.offline=true \
      --config.supportedArchitectures.os=linux \
      --config.supportedArchitectures.cpu="$(node -p 'process.arch')" \
      --config.supportedArchitectures.libc=glibc && \
    OPENCLAW_EXTENSIONS="$OPENCLAW_EXTENSIONS" OPENCLAW_BUNDLED_PLUGIN_DIR="$OPENCLAW_BUNDLED_PLUGIN_DIR" node scripts/prune-docker-plugin-dist.mjs && \
    node scripts/postinstall-bundled-plugins.mjs && \
    find dist -type f \( -name '*.d.ts' -o -name '*.d.mts' -o -name '*.d.cts' -o -name '*.map' \) -delete && \
    node scripts/check-package-dist-imports.mjs /app

FROM ${OPENCLAW_NODE_BOOKWORM_SLIM_IMAGE} AS runtime
ARG OPENCLAW_SOURCE_REPO
ARG OPENCLAW_SOURCE_COMMIT
ARG OPENCLAW_BUNDLED_PLUGIN_DIR
ARG OPENCLAW_NODE_BOOKWORM_SLIM_DIGEST

LABEL org.opencontainers.image.title="agent-lab OpenClaw" \
  org.opencontainers.image.description="Self-built OpenClaw runtime scaffold for agent-lab locked v0 hardening" \
  org.opencontainers.image.source="${OPENCLAW_SOURCE_REPO}" \
  org.opencontainers.image.revision="${OPENCLAW_SOURCE_COMMIT}" \
  org.opencontainers.image.base.name="docker.io/library/node:24-bookworm-slim" \
  org.opencontainers.image.base.digest="${OPENCLAW_NODE_BOOKWORM_SLIM_DIGEST}" \
  agent-lab.profile="openclaw" \
  agent-lab.capability-posture="locked-v0-build-scaffold" \
  agent-lab.openclaw.sandbox="disabled" \
  agent-lab.openclaw.browser="not-installed" \
  agent-lab.openclaw.docker-cli="not-installed"

WORKDIR /app

# Keep the first runtime close to upstream. Package reduction is an M2+ task
# after locked-mode behavior is proven. This intentionally does not install
# Docker CLI, Chromium, Playwright browser binaries, or OpenClaw sandbox support.
RUN --mount=type=cache,id=agent-lab-openclaw-apt-cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=agent-lab-openclaw-apt-lists,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl git hostname lsof openssl procps python3 tini && \
    update-ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN chown node:node /app

COPY --from=runtime-assets --chown=node:node /app/dist ./dist
COPY --from=runtime-assets --chown=node:node /app/node_modules ./node_modules
COPY --from=runtime-assets --chown=node:node /app/package.json .
COPY --from=runtime-assets --chown=node:node /app/pnpm-workspace.yaml .
COPY --from=runtime-assets --chown=node:node /app/patches ./patches
COPY --from=runtime-assets --chown=node:node /app/openclaw.mjs .
COPY --from=runtime-assets --chown=node:node /app/src/agents/templates ./src/agents/templates
COPY --from=runtime-assets --chown=node:node /app/${OPENCLAW_BUNDLED_PLUGIN_DIR} ./${OPENCLAW_BUNDLED_PLUGIN_DIR}
COPY --from=runtime-assets --chown=node:node /app/skills ./skills
COPY --from=runtime-assets --chown=node:node /app/docs ./docs
COPY --from=runtime-assets --chown=node:node /app/qa ./qa

ENV COREPACK_HOME=/usr/local/share/corepack
RUN install -d -m 0755 "$COREPACK_HOME" && \
    corepack enable && \
    for attempt in 1 2 3 4 5; do \
      if corepack prepare "$(node -p "require('./package.json').packageManager")" --activate; then \
        break; \
      fi; \
      if [ "$attempt" -eq 5 ]; then \
        exit 1; \
      fi; \
      sleep $((attempt * 2)); \
    done && \
    chmod -R a+rX "$COREPACK_HOME"

RUN ln -sf /app/openclaw.mjs /usr/local/bin/openclaw && \
    chmod 755 /app/openclaw.mjs

RUN install -d -m 0755 -o node -g node /home/node/.config && \
    install -d -m 0700 -o node -g node \
      /home/node/.openclaw \
      /home/node/.openclaw/workspace \
      /home/node/.config/openclaw && \
    stat -c '%U:%G %a' /home/node/.openclaw | grep -qx 'node:node 700' && \
    stat -c '%U:%G %a' /home/node/.openclaw/workspace | grep -qx 'node:node 700' && \
    stat -c '%U:%G %a' /home/node/.config | grep -qx 'node:node 755' && \
    stat -c '%U:%G %a' /home/node/.config/openclaw | grep -qx 'node:node 700'

ENV HOME=/home/node \
    OPENCLAW_HOME=/home/node \
    OPENCLAW_STATE_DIR=/home/node/.openclaw \
    OPENCLAW_CONFIG_PATH=/home/node/.openclaw/openclaw.json \
    OPENCLAW_CONFIG_DIR=/home/node/.openclaw \
    OPENCLAW_WORKSPACE_DIR=/home/node/.openclaw/workspace \
    NODE_ENV=production

USER node

# M2/M3 must verify this probe remains valid after locked config/preflight is added.
HEALTHCHECK --interval=3m --timeout=10s --start-period=15s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:18789/healthz').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

ENTRYPOINT ["tini", "-s", "--"]
CMD ["node", "openclaw.mjs", "gateway"]
