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
  local base="$1" out="$2"
  local entrypoint="${3:-[\"/bin/tool\"]}"
  local cmd="${4:-[\"serve\",\"--safe\"]}"
  local user="${5:-1001:1002}"
  local rc=0
  : > "$docker_log"
  PATH="$work/bin:$PATH" \
    FAKE_DOCKER_LOG="$docker_log" \
    FAKE_CAPTURED_CONTEXT="$captured_context" \
    FAKE_CAPTURED_DOCKERFILE="$captured_dockerfile" \
    FAKE_ENTRYPOINT="$entrypoint" \
    FAKE_CMD="$cmd" \
    FAKE_USER="$user" \
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
if grep -Fq 'ENTRYPOINT ["/usr/local/bin/agent-entrypoint","/bin/tool"]' "$captured_dockerfile" &&
   grep -Fq 'CMD ["serve","--safe"]' "$captured_dockerfile" &&
   ! grep -Eq '^USER[[:space:]]' "$captured_dockerfile"; then
  pass "original user, ENTRYPOINT, CMD, and runtime-argument behavior are preserved"
else
  fail "original user, ENTRYPOINT, CMD, and runtime-argument behavior are preserved"
fi
if grep -Fq -- "--network=none" "$docker_log"; then
  pass "wrapper build disables build-time networking"
else
  fail "wrapper build disables build-time networking"
fi

if run_wrap "fixture:base" "$work/cmd-only.out" "null" '["sh","-c","true"]' "" &&
   grep -Fq 'ENTRYPOINT ["/usr/local/bin/agent-entrypoint"]' "$captured_dockerfile" &&
   grep -Fq 'CMD ["sh","-c","true"]' "$captured_dockerfile" &&
   ! grep -Eq '^USER[[:space:]]' "$captured_dockerfile"; then
  pass "CMD-only and root-user metadata stay inherited"
else
  fail "CMD-only and root-user metadata stay inherited"
fi

if run_wrap "fixture:base" "$work/null-command.out" "null" "null" "" &&
   grep -Fq "base declares neither ENTRYPOINT nor CMD" "$work/null-command.out"; then
  pass "null ENTRYPOINT and CMD require an explicit runtime command"
else
  fail "null ENTRYPOINT and CMD require an explicit runtime command"
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
