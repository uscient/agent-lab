#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$test_dir/lib.sh"
scanner="$test_dir/check-secret-absence.sh"

trap docker_test_cleanup EXIT
docker_test_init "secrets" || exit $?

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  else
    shasum -a 256
  fi
}

sentinel="fixture-${LAB_MARKER}-${RANDOM}-${RANDOM}"
sentinel_hash="$(printf '%s' "$sentinel" | sha256_stdin | awk '{print $1}')"
printf '%s' "$sentinel" > "$LAB_COPY/secrets/RUNTIME_SENTINEL"

launcher_out="$LAB_WORK/agent.out"
LAB_EPHEMERAL_HOME=1
export LAB_EPHEMERAL_HOME
docker_test_agent "base" sh -c \
  "actual=\$(printf '%s' \"\$RUNTIME_SENTINEL\" | sha256sum | awk '{print \$1}')
   test \"\$actual\" = '$sentinel_hash'
   printf 'SECRET_READY\n'
   while :; do sleep 5; done" >"$launcher_out" 2>&1 &
launcher=$!

container_id=""
attempt=0
while [ "$attempt" -lt 30 ]; do
  container_id="$(
    docker ps -q \
      --filter "label=com.docker.compose.project=${LAB_PROJECT}" \
      --filter "label=com.docker.compose.service=agent"
  )"
  if [ -n "$container_id" ] && grep -Fq "SECRET_READY" "$launcher_out"; then
    break
  fi
  if ! kill -0 "$launcher" 2>/dev/null; then
    docker_test_infra "secret fixture agent exited before inspection"
    exit 125
  fi
  sleep 1
  attempt=$((attempt + 1))
done
if [ -n "$container_id" ] && grep -Fq "SECRET_READY" "$launcher_out"; then
  pass "agent process receives the file-backed sentinel without printing it"
else
  docker_test_infra "secret fixture agent did not become ready"
  exit 125
fi

docker inspect "$container_id" > "$LAB_WORK/container-inspect.json"
docker image inspect "$LAB_DEVBOX_IMAGE_ID" > "$LAB_WORK/image-inspect.json"
docker history --no-trunc "$LAB_DEVBOX_IMAGE_ID" > "$LAB_WORK/image-history.txt"
docker_test_compose --profile core --profile egress --profile agent config \
  > "$LAB_WORK/compose-config.txt"
docker logs "$container_id" > "$LAB_WORK/container-logs.txt" 2>&1 || true
proxy_id="$(docker_test_proxy_container)"
docker exec "$proxy_id" sh -c \
  'find /var/log/squid -type f -maxdepth 1 -exec cat {} \;' \
  > "$LAB_WORK/squid-logs.txt" 2>&1 || true
grep -R -I -n -F \
  --exclude-dir=secrets \
  --exclude-dir=.cache \
  --exclude='.env*' \
  "$sentinel" "$LAB_COPY" > "$LAB_WORK/tracked-scan.txt" 2>&1 || true
if [ -d "$LAB_COPY/.cache" ]; then
  grep -R -I -n -F "$sentinel" "$LAB_COPY/.cache" \
    > "$LAB_WORK/generated-scan.txt" 2>&1 || true
else
  : > "$LAB_WORK/generated-scan.txt"
fi

scan_out="$LAB_WORK/scan.out"
if "$scanner" "$sentinel" \
     "compose=$LAB_WORK/compose-config.txt" \
     "container-inspect=$LAB_WORK/container-inspect.json" \
     "image-inspect=$LAB_WORK/image-inspect.json" \
     "image-history=$LAB_WORK/image-history.txt" \
     "agent-stdout-stderr=$launcher_out" \
     "container-logs=$LAB_WORK/container-logs.txt" \
     "squid-audit=$LAB_WORK/squid-logs.txt" \
     "tracked-files=$LAB_WORK/tracked-scan.txt" \
     "generated-files=$LAB_WORK/generated-scan.txt" >"$scan_out"; then
  pass "sentinel is absent from metadata, history, logs, audit, and generated files"
else
  fail "sentinel is absent from metadata, history, logs, audit, and generated files"
fi
if ! grep -Fq "$sentinel" "$scan_out"; then
  pass "secret scanner failures and successes never print the matched value"
else
  fail "secret scanner failures and successes never print the matched value"
fi

if docker inspect "$container_id" |
     jq -e 'any(.[0].Mounts[];
       .Destination == "/run/agent-secrets" and .RW == false)' >/dev/null; then
  pass "secret mount is structurally read-only"
else
  fail "secret mount is structurally read-only"
fi

# Exercise the repository .dockerignore against a hostile root-context COPY.
capture_df="$LAB_WORK/Capture.Dockerfile"
capture_tag="${LAB_PROJECT}-context-capture:local"
{
  printf 'FROM scratch\n'
  printf 'COPY . /captured/\n'
} > "$capture_df"
docker build --network=none -t "$capture_tag" -f "$capture_df" "$LAB_COPY" >/dev/null
capture_container="${LAB_PROJECT}-context-capture"
docker create --name "$capture_container" "$capture_tag" \
  /captured/tools/agent-entrypoint.sh >/dev/null
docker_test_track_container "$capture_container"
docker export "$capture_container" > "$LAB_WORK/context.tar"
context_list="$LAB_WORK/context.list"
tar -tf "$LAB_WORK/context.tar" > "$context_list"
if grep -Fxq 'captured/tools/agent-entrypoint.sh' "$context_list" &&
   ! grep -Eq '(^|/)(secrets|\.git|\.env|\.cache)(/|$)' "$context_list" &&
   ! tar -xOf "$LAB_WORK/context.tar" captured/tools/agent-entrypoint.sh |
      grep -Fq "$sentinel"; then
  pass "repository-root build context excludes every secret-bearing local path"
else
  fail "repository-root build context excludes every secret-bearing local path"
fi

# Sensitivity: inject the sentinel into captured inspection metadata. The scanner must
# turn red and name only the channel, never the value.
jq --arg value "RUNTIME_SENTINEL=$sentinel" \
  '.[0].Config.Env += [$value]' "$LAB_WORK/container-inspect.json" \
  > "$LAB_WORK/insecure-inspect.json"
mutation_out="$LAB_WORK/mutation.out"
if "$scanner" "$sentinel" \
     "container-env=$LAB_WORK/insecure-inspect.json" >"$mutation_out" 2>&1; then
  fail "environment-injection sensitivity mutation is detected"
elif grep -Fq "secret disclosed in channel: container-env" "$mutation_out" &&
     ! grep -Fq "$sentinel" "$mutation_out"; then
  pass "environment-injection sensitivity mutation is detected without disclosure"
else
  fail "environment-injection sensitivity mutation reports a safe exact reason"
fi

docker stop "$container_id" >/dev/null
wait "$launcher" || true
docker rm -f "$capture_container" >/dev/null 2>&1 || true
docker image rm "$capture_tag" >/dev/null 2>&1 || true

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
