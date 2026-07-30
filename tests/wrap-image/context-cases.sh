#!/usr/bin/env bash
set -euo pipefail

# Docker-free contract test for wrapper build-context isolation and metadata preservation.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
work="$(mktemp -d)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

mkdir -p "$work/bin"
docker_log="$work/docker.log"
captured_context="$work/context.files"
captured_dockerfile="$work/Dockerfile"
: > "$docker_log"

cat > "$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_DOCKER_LOG:?}"
case "${1:-}" in
  image)
    exit 0
    ;;
  inspect)
    case "$*" in
      *".Config.Entrypoint"*) printf '%s\n' "${FAKE_ENTRYPOINT:-null}" ;;
      *".Config.Cmd"*)        printf '%s\n' "${FAKE_CMD:-null}" ;;
      *".Config.User"*)       printf '%s\n' "${FAKE_USER:-}" ;;
    esac
    ;;
  build)
    context="${!#}"
    dockerfile=""
    previous=""
    for arg in "$@"; do
      if [ "$previous" = "-f" ]; then dockerfile="$arg"; fi
      previous="$arg"
    done
    find "$context" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort > "${FAKE_CAPTURED_CONTEXT:?}"
    cp "$dockerfile" "${FAKE_CAPTURED_DOCKERFILE:?}"
    ;;
esac
EOF
chmod +x "$work/bin/docker"

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

run_wrap() {
  local base="$1" out="$2" rc=0
  : > "$docker_log"
  PATH="$work/bin:$PATH" \
    FAKE_DOCKER_LOG="$docker_log" \
    FAKE_CAPTURED_CONTEXT="$captured_context" \
    FAKE_CAPTURED_DOCKERFILE="$captured_dockerfile" \
    FAKE_ENTRYPOINT='["/bin/tool"]' \
    FAKE_CMD='["serve","--safe"]' \
    FAKE_USER='1001:1002' \
    "$repo_root/scripts/wrap-image" "$base" "fixture:wrapped" >"$out" 2>&1 || rc=$?
  return "$rc"
}

if run_wrap "fixture:base" "$work/wrap.out"; then
  pass "wrapper build completes against deterministic image metadata"
else
  fail "wrapper build completes against deterministic image metadata"
fi

expected_context=$'.dockerignore\nDockerfile\nagent-entrypoint.sh'
if [ "$(cat "$captured_context" 2>/dev/null || true)" = "$expected_context" ]; then
  pass "build context contains only the explicit wrapper inputs"
else
  fail "build context contains only the explicit wrapper inputs"
fi
if grep -Fq 'COPY agent-entrypoint.sh /usr/local/bin/agent-entrypoint' "$captured_dockerfile" &&
   ! grep -Fq 'COPY tools/' "$captured_dockerfile"; then
  pass "Dockerfile copies only the isolated entrypoint"
else
  fail "Dockerfile copies only the isolated entrypoint"
fi
if grep -Fq 'USER 1001:1002' "$captured_dockerfile" &&
   grep -Fq 'CMD ["/bin/tool","serve","--safe"]' "$captured_dockerfile"; then
  pass "original user and ENTRYPOINT plus CMD behavior are preserved"
else
  fail "original user and ENTRYPOINT plus CMD behavior are preserved"
fi
if grep -Fq -- "--network=none" "$docker_log"; then
  pass "wrapper build disables build-time networking"
else
  fail "wrapper build disables build-time networking"
fi

: > "$docker_log"
if run_wrap "--pull" "$work/invalid.out"; then
  fail "option-like base image reference is rejected"
elif grep -Fq "invalid base image reference" "$work/invalid.out" &&
     [ ! -s "$docker_log" ]; then
  pass "option-like base image reference is rejected before Docker"
else
  fail "invalid base image rejection is fail-closed"
fi

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
