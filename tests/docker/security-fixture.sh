#!/usr/bin/env bash
set -euo pipefail

# A deliberately small runtime fixture for the Docker-security worker. The
# broader suites retain ownership of product containment; this canary proves
# the runner can create one content-pinned, least-privilege container and
# observe the kernel-enforced result before larger Flow groups begin.
#
# The canary owns its fixture image end to end: it builds the tracked, digest-
# pinned Dockerfile under tests/docker/fixtures/ into a throwaway tag and then
# runs that build by image ID. It never inspects, references, tags, or executes
# agent-lab/devbox, the Docker gate's built image identity, or any other product
# or dev image — runner-level evidence and product-image evidence must not be
# able to mask one another.

infra() {
  printf 'INFRA %s\n' "$*" >&2
  exit 125
}

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
fixture_context="$repo_root/tests/docker/fixtures"
fixture_dockerfile="$fixture_context/security-canary.Dockerfile"
[ -f "$fixture_dockerfile" ] ||
  infra "purpose-built fixture Dockerfile is missing: ${fixture_dockerfile}"

command -v docker >/dev/null 2>&1 || infra "Docker CLI is unavailable"
docker info >/dev/null 2>&1 || infra "Docker daemon is unavailable"

fixture_tag="agent-lab-test/docker-security-canary:fixture-$$-${RANDOM}"
container="agent-lab-security-fixture-$$-${RANDOM}"
# Installed before the first mutating Docker call so an interrupted or failed
# build can never leak the throwaway container or the throwaway tag and image.
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker image rm -f "$fixture_tag" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

docker build --quiet --tag "$fixture_tag" --file "$fixture_dockerfile" \
  "$fixture_context" >/dev/null ||
  infra "purpose-built fixture image failed to build"

fixture_image_id="$(
  docker image inspect --format '{{.Id}}' "$fixture_tag" 2>/dev/null
)" || infra "purpose-built fixture image is unavailable after its own build"
[[ "$fixture_image_id" =~ ^sha256:[0-9a-f]{64}$ ]] ||
  infra "purpose-built fixture image has a malformed identity"

fixture_rc=0
fixture_out="$(
  docker run --name "$container" \
    --network none \
    --read-only \
    --tmpfs /tmp:rw,nosuid,nodev,noexec,size=16m \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --user 1000:1000 \
    --entrypoint /bin/sh \
    "$fixture_image_id" -c '
      failures=0
      check() {
        if "$@"; then
          return 0
        fi
        failures=$((failures + 1))
        return 0
      }
      refute() {
        if "$@"; then
          failures=$((failures + 1))
        fi
        return 0
      }

      # The container was started from the purpose-built canary fixture image.
      check test "$(cat /etc/agent-lab-docker-security-canary)" = agent-lab-docker-security-canary
      # A fixed non-root identity, supplied by --user and not by the image.
      check test "$(id -u)" = 1000
      check test "$(id -g)" = 1000
      # Only the bounding set and NoNewPrivs change when those two flags are lost.
      check grep -Eq "^CapBnd:[[:space:]]+0000000000000000$" /proc/self/status
      check grep -Eq "^NoNewPrivs:[[:space:]]+1$" /proc/self/status
      # Loopback is the only interface, and no default route exists.
      check test "$(cd /sys/class/net && echo *)" = lo
      refute grep -Eq "^[^[:space:]]+[[:space:]]+00000000[[:space:]]" /proc/net/route
      # The root filesystem is mounted read-only.
      check grep -Eq "^[0-9]+ [0-9]+ [0-9]+:[0-9]+ [^ ]+ / ro[, ]" /proc/self/mountinfo
      # /tmp is a writable tmpfs that stays constrained in options and in size.
      check grep -Eq "^[0-9]+ [0-9]+ [0-9]+:[0-9]+ [^ ]+ /tmp rw,nosuid,nodev,noexec[, ].* - tmpfs " /proc/self/mountinfo
      check touch /tmp/agent-lab-tmp-write-probe
      find /tmp/agent-lab-tmp-write-probe -maxdepth 0 -delete
      refute dd if=/dev/zero of=/tmp/agent-lab-tmpfs-limit-probe bs=1024k count=17 2>/dev/null
      printf "DOCKER SECURITY FIXTURE SUMMARY failures=%s\\n" "$failures"
      test "$failures" -eq 0
    '
)" || fixture_rc=$?

printf '%s\n' "$fixture_out"
if [ "$fixture_rc" -ne 0 ]; then
  exit 1
fi
grep -Fxq 'DOCKER SECURITY FIXTURE SUMMARY failures=0' <<<"$fixture_out" || exit 1
