# syntax=docker/dockerfile:1.7
FROM debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818 AS builder

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates git nodejs npm python3 python3-venv xz-utils \
 && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/serena \
 && /opt/serena/bin/pip install --no-cache-dir \
      "serena-agent @ git+https://github.com/oraios/serena.git@6c1c9653700cbe644cb5a5b026b77db2f4071c36"

# Serena 1.6.2.dev0 pins bash-language-server 5.6.0 and ShellCheck 0.10.0.
# Trigger Serena's supported installer during the image build; runtime has no
# network and consumes only these version-pinned, preseeded resources.
RUN install -d /tmp/serena-seed-project \
 && printf '%s\n' \
      '#!/usr/bin/env bash' \
      'seed_function() {' \
      '  printf "%s\n" "seed"' \
      '}' \
      'seed_function' \
      > /tmp/serena-seed-project/seed.sh \
 && SERENA_HOME=/opt/serena-assets \
      SERENA_USAGE_REPORTING=false \
      /opt/serena/bin/serena project create \
        /tmp/serena-seed-project \
        --name agent-lab-image-seed \
        --ls bash \
        --index \
        --log-level INFO \
 && test -x \
      /opt/serena-assets/language_servers/static/BashLanguageServer/bash-lsp/node_modules/.bin/bash-language-server \
 && test -x \
      /opt/serena-assets/language_servers/static/BashLanguageServer/bash-lsp/shellcheck/shellcheck-v0.10.0/shellcheck \
 && find /tmp/serena-seed-project -depth -delete

FROM debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818

LABEL org.opencontainers.image.title="Agent Lab Serena MCP" \
      org.opencontainers.image.source="https://github.com/oraios/serena" \
      org.agent-lab.serena.version="1.6.2.dev0" \
      org.agent-lab.serena.ref="6c1c9653700cbe644cb5a5b026b77db2f4071c36" \
      org.agent-lab.bash-language-server.version="5.6.0" \
      org.agent-lab.shellcheck.version="0.10.0"

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates git nodejs npm python3 tini \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 1000 agent \
 && useradd \
      --uid 1000 \
      --gid 1000 \
      --create-home \
      --home-dir /home/agent \
      --shell /bin/bash \
      agent \
 && install -d -m 0755 -o agent -g agent /workspace

COPY --from=builder /opt/serena /opt/serena
COPY --from=builder /opt/serena-assets/language_servers /opt/serena-assets/language_servers
COPY tools/serena-entrypoint.sh /usr/local/bin/serena-entrypoint
RUN chmod 0755 /usr/local/bin/serena-entrypoint

ENV HOME=/tmp/serena-home \
    PATH=/opt/serena/bin:/usr/local/bin:/usr/bin:/bin \
    SERENA_HOME=/tmp/serena \
    SERENA_USAGE_REPORTING=false

WORKDIR /workspace
USER agent
ENTRYPOINT ["tini", "-s", "--", "/usr/local/bin/serena-entrypoint"]
CMD ["--version"]
