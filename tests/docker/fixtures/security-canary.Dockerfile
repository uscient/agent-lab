# Purpose-built fixture image for the additive Docker security canary
# (tests/docker/security-fixture.sh). Built and torn down by that canary alone.
#
# This image is deliberately independent of every product and dev image. It must
# never derive from, be tagged as, or otherwise consume agent-lab/devbox, the
# Docker gate's built image identity, or any other image this repository ships:
# the canary proves that the *runner* enforces containment, so a broken product
# image must not be able to mask that evidence and a broken canary must not be
# able to mask a product-image regression. The broader Docker suites keep
# product-image ownership.
#
# The base is content-pinned by digest. This digest is the fixture's own pin: it
# is never read from another image's identity, so bumping a product base leaves
# this canary untouched.
FROM debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818

# A read-only marker so the canary can prove from inside the container that it
# executed this purpose-built fixture image rather than whatever image it
# happened to find in the local store.
RUN printf '%s\n' 'agent-lab-docker-security-canary' > /etc/agent-lab-docker-security-canary \
 && chmod 0444 /etc/agent-lab-docker-security-canary

# Root on purpose. The canary's fixed non-root identity has to come from the
# runtime --user flag, so observing uid/gid 1000 inside the container is
# evidence that the runner applied it rather than an image default.
USER 0:0
