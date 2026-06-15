# syntax=docker/dockerfile:1.7
# Thin default sandbox AND the canonical example of a compliant BYO image.
# Build context is the repo root (this COPYs tools/agent-entrypoint.sh).
# TODO: pin debian:bookworm-slim by digest before publishing (see THREAT_MODEL.md
# image-pinning note); the OpenClaw image already digest-pins its bases.
FROM debian:bookworm-slim
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash ca-certificates curl git jq python3 ripgrep tini \
 && rm -rf /var/lib/apt/lists/*
RUN groupadd --gid 1000 agent \
 && useradd --uid 1000 --gid 1000 --create-home --home-dir /home/agent --shell /bin/bash agent \
 && install -d -m 0700 -o agent -g agent /home/agent/.config \
 && install -d -m 0755 -o agent -g agent /workspace
COPY tools/agent-entrypoint.sh /usr/local/bin/agent-entrypoint
RUN chmod 0755 /usr/local/bin/agent-entrypoint
ENV HOME=/home/agent AGENT_LAB_SECRETS_MOUNT=/run/agent-secrets
WORKDIR /workspace
USER agent
ENTRYPOINT ["tini", "-s", "--", "/usr/local/bin/agent-entrypoint"]
CMD ["bash"]
