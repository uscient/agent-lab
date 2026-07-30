# syntax=docker/dockerfile:1.7
# Thin default sandbox AND the canonical example of a compliant BYO image.
# Build context is the repo root (this COPYs tools/agent-entrypoint.sh).
FROM debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash ca-certificates curl dnsutils git jq python3 ripgrep tini \
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
