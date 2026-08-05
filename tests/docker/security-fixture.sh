#!/usr/bin/env bash
set -euo pipefail

# A deliberately small runtime fixture for the Docker-security worker. The
# broader suites retain ownership of product containment; this canary proves
# the runner can create one content-pinned, least-privilege container and
# observe the kernel-enforced result before larger Flow groups begin.

infra() {
  printf 'INFRA %s\n' "$*" >&2
  exit 125
}

command -v docker >/dev/null 2>&1 || infra "Docker CLI is unavailable"
docker info >/dev/null 2>&1 || infra "Docker daemon is unavailable"

image_id="$(
  docker image inspect --format '{{.Id}}' agent-lab/devbox:local 2>/dev/null
)" || infra "required local devbox image is unavailable"
[[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] ||
  infra "local devbox image has a malformed identity"

container="agent-lab-security-fixture-$$-${RANDOM}"
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

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
    "$image_id" -c '
      failures=0
      check() {
        if "$@"; then
          return 0
        fi
        failures=$((failures + 1))
        return 0
      }

      check test "$(id -u)" = 1000
      check test "$(id -g)" = 1000
      check test "$(awk "/^CapBnd:/ { print \$2 }" /proc/self/status)" = 0000000000000000
      check test "$(awk "/^NoNewPrivs:/ { print \$2 }" /proc/self/status)" = 1
      check test "$(find /sys/class/net -mindepth 1 -maxdepth 1 -printf "%f\\n" | sort)" = lo
      check grep -Eq "^[0-9]+ [0-9]+ [0-9]+:[0-9]+ [^ ]+ / ro[, ]" /proc/self/mountinfo
      check touch /tmp/agent-lab-tmp-write-probe
      find /tmp/agent-lab-tmp-write-probe -maxdepth 0 -delete
      printf "DOCKER SECURITY FIXTURE SUMMARY failures=%s\\n" "$failures"
      test "$failures" -eq 0
    '
)" || fixture_rc=$?

printf '%s\n' "$fixture_out"
if [ "$fixture_rc" -ne 0 ]; then
  exit 1
fi
grep -Fxq 'DOCKER SECURITY FIXTURE SUMMARY failures=0' <<<"$fixture_out" || exit 1
