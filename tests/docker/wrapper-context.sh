#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/lib.sh"

trap docker_test_cleanup EXIT
docker_test_init "wrapper" || exit $?

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

base_tag="${LAB_PROJECT}-onbuild-base:local"
wrapped_tag="${LAB_PROJECT}-onbuild-wrapped:local"
hostile_context="$LAB_WORK/hostile-base"
mkdir -p "$hostile_context"
{
  printf 'FROM scratch\n'
  printf 'ONBUILD COPY . /captured/\n'
  printf 'ENTRYPOINT ["/missing-entrypoint"]\n'
} > "$hostile_context/Dockerfile"
docker build --network=none -t "$base_tag" "$hostile_context" >/dev/null

# These ignored/local canaries are deliberately adjacent to the wrapper invocation. A
# repository-root context would expose them to the hostile ONBUILD instruction.
mkdir -p "$LAB_COPY/.git" "$LAB_COPY/secrets" "$LAB_COPY/.cache"
printf '%s\n' "$LAB_MARKER" > "$LAB_COPY/.env.local"
printf '%s\n' "$LAB_MARKER" > "$LAB_COPY/secrets/context-canary"
printf '%s\n' "$LAB_MARKER" > "$LAB_COPY/.git/context-canary"
printf '%s\n' "$LAB_MARKER" > "$LAB_COPY/.cache/context-canary"

"$LAB_COPY/scripts/wrap-image" "$base_tag" "$wrapped_tag" >/dev/null
created="${LAB_PROJECT}-wrapped-export"
docker create --name "$created" "$wrapped_tag" >/dev/null
docker_test_track_container "$created"
docker export "$created" > "$LAB_WORK/wrapped.tar"
wrapped_list="$LAB_WORK/wrapped.list"
tar -tf "$LAB_WORK/wrapped.tar" > "$wrapped_list"
captured="$(
  awk '
    {
      path = $0
      sub(/^\.\//, "", path)
      sub(/\/$/, "", path)
      if (path != "captured" && index(path, "captured/") == 1) {
        print path
      }
    }
  ' "$wrapped_list" |
    LC_ALL=C sort -u
)"
printf 'INFO hostile ONBUILD captured paths:\n'
if [ -n "$captured" ]; then
  printf '%s\n' "$captured" | sed 's/^/  /'
else
  printf '  <none>\n'
fi
if [ "$captured" = "captured/agent-entrypoint.sh" ]; then
  pass "hostile ONBUILD receives only the explicit isolated wrapper input"
else
  fail "hostile ONBUILD receives only the explicit isolated wrapper input"
fi
if ! tar -xOf "$LAB_WORK/wrapped.tar" captured/agent-entrypoint.sh |
     grep -Fq "$LAB_MARKER"; then
  pass "repository, secret, environment, cache, and Git canaries stay outside context"
else
  fail "repository, secret, environment, cache, and Git canaries stay outside context"
fi

behavior_tag="${LAB_PROJECT}-behavior-wrapped:local"
"$LAB_COPY/scripts/wrap-image" "$LAB_DEVBOX_PINNED_REF" "$behavior_tag" >/dev/null
base_user="$(docker inspect -f '{{.Config.User}}' "$LAB_DEVBOX_IMAGE_ID")"
wrapped_user="$(docker inspect -f '{{.Config.User}}' "$behavior_tag")"
base_cmd="$(docker inspect -f '{{json .Config.Cmd}}' "$LAB_DEVBOX_IMAGE_ID")"
wrapped_cmd="$(docker inspect -f '{{json .Config.Cmd}}' "$behavior_tag")"
if [ "$wrapped_user" = "$base_user" ] && [ "$wrapped_cmd" = "$base_cmd" ]; then
  pass "wrapped image preserves original USER and CMD metadata"
else
  fail "wrapped image preserves original USER and CMD metadata"
fi

secret_dir="$LAB_WORK/wrapper-secrets"
mkdir -p "$secret_dir"
printf '%s\n' "$LAB_MARKER" > "$secret_dir/WRAPPER_SENTINEL"
derived="$(
  docker run --rm \
    -e AGENT_LAB_SECRETS_MOUNT=/run/agent-secrets \
    -v "$secret_dir:/run/agent-secrets:ro" \
    "$behavior_tag" sh -c \
    'test -n "${WRAPPER_SENTINEL:-}" && printf "SECRET_LOADED\n"'
)"
if [ "$derived" = "SECRET_LOADED" ]; then
  pass "wrapped runtime loads secrets and preserves runtime argument overrides"
else
  fail "wrapped runtime loads secrets and preserves runtime argument overrides"
fi

signal_name="${LAB_PROJECT}-signal"
docker run -d --name "$signal_name" "$behavior_tag" sh -c \
  'trap "exit 0" TERM INT; while :; do sleep 1; done' >/dev/null
docker_test_track_container "$signal_name"
docker stop --time 5 "$signal_name" >/dev/null
signal_exit="$(docker inspect -f '{{.State.ExitCode}}' "$signal_name")"
if [ "$signal_exit" -eq 0 ]; then
  pass "wrapped entrypoint forwards termination signals to the original process"
else
  fail "wrapped entrypoint forwards termination signals to the original process"
fi

docker rm -f "$created" "$signal_name" >/dev/null 2>&1 || true
docker image rm "$base_tag" "$wrapped_tag" "$behavior_tag" >/dev/null 2>&1 || true
printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
