#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/lib.sh"

docker_test_init "volumes" || exit $?
trap docker_test_cleanup EXIT

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

hostile_tag="${LAB_PROJECT}-hostile-volumes:local"
safe_tag="${LAB_PROJECT}-safe-volumes:local"
hostile_df="$LAB_WORK/hostile.Dockerfile"
safe_df="$LAB_WORK/safe.Dockerfile"
{
  printf 'FROM agent-lab/devbox:local\n'
  printf 'VOLUME ["/etc", "/opt/extra"]\n'
} > "$hostile_df"
{
  printf 'FROM agent-lab/devbox:local\n'
  printf 'VOLUME ["/workspace", "/home/agent", "/tmp", "/run/agent-secrets"]\n'
} > "$safe_df"
docker build --network=none -t "$hostile_tag" -f "$hostile_df" "$LAB_WORK" >/dev/null
docker build --network=none -t "$safe_tag" -f "$safe_df" "$LAB_WORK" >/dev/null

hostile_out="$LAB_WORK/hostile.out"
hostile_rc=0
docker_test_agent_image "$hostile_tag" "base" true >"$hostile_out" 2>&1 ||
  hostile_rc=$?
if [ "$hostile_rc" -ne 0 ] &&
   grep -Fq "unsupported image-declared VOLUME: /etc" "$hostile_out" &&
   grep -Fq "unsupported image-declared VOLUME: /opt/extra" "$hostile_out"; then
  pass "blessed agent path rejects every hostile image volume before launch"
else
  fail "blessed agent path rejects every hostile image volume before launch"
fi
if [ -z "$(
  docker ps -aq \
    --filter "label=com.docker.compose.project=${LAB_PROJECT}" \
    --filter "label=com.docker.compose.service=agent"
)" ]; then
  pass "hostile volume rejection creates no agent container"
else
  fail "hostile volume rejection creates no agent container"
fi

# Sensitivity: read_only does not neutralize image VOLUME metadata. Bypassing the blessed
# check creates anonymous read-write mounts, proving the regression test targets a real risk.
sensitivity="${LAB_PROJECT}-volume-sensitivity"
docker run -d \
  --name "$sensitivity" \
  --read-only \
  --entrypoint sleep \
  "$hostile_tag" infinity >/dev/null
docker_test_track_container "$sensitivity"
extra_mounts="$(
  docker inspect "$sensitivity" |
    jq -r '.[0].Mounts[] |
      select((.Destination == "/etc" or .Destination == "/opt/extra") and .RW == true) |
      .Destination' |
    sort
)"
if [ "$extra_mounts" = $'/etc\n/opt/extra' ]; then
  pass "bypassing image policy recreates the hostile writable mounts"
else
  fail "bypassing image policy recreates the hostile writable mounts"
fi

if docker_test_agent_image "$safe_tag" "base" true >/dev/null; then
  pass "image volumes replaced by documented mounts are accepted"
else
  fail "image volumes replaced by documented mounts are accepted"
fi

docker rm -f "$sensitivity" >/dev/null 2>&1 || true
docker image rm "$hostile_tag" "$safe_tag" >/dev/null 2>&1 || true
printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
