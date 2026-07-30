ARG AGENT_LAB_DEVBOX_IMAGE=agent-lab/devbox:local
FROM ${AGENT_LAB_DEVBOX_IMAGE}

COPY tests/egress/cases.sh /tests/egress/cases.sh
USER root
RUN chmod 0555 /tests/egress/cases.sh

USER 1000:1000
ENTRYPOINT ["/bin/bash", "/tests/egress/cases.sh"]
