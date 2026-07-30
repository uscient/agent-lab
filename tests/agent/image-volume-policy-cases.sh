#!/usr/bin/env bash
set -euo pipefail

# Docker-free contract test for the BYO-image VOLUME preflight. A fake Docker CLI
# makes image metadata deterministic and records whether Compose was reached.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
work="$(mktemp -d)"
secrets_rel=".image-volume-secrets-$$-${RANDOM}"
secrets_path="$repo_root/$secrets_rel"
cleanup() {
  rmdir "$secrets_path" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/bin"
env_file="$work/agent.env"
docker_log="$work/docker.log"
: > "$env_file"
: > "$docker_log"

cat > "$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_DOCKER_LOG:?}"
case "${1:-} ${2:-}" in
  "image inspect")
    if [ "${3:-}" = "--format" ]; then
      case "${4:-}" in
        '{{.Id}}') printf 'sha256:%064d\n' 0 ;;
        *) printf '%s\n' "${FAKE_IMAGE_VOLUMES:-}" ;;
      esac
    fi
    ;;
  "inspect --format")
    printf '%s\n' "${AGENT_LAB_EGRESS_POLICY_SHA256:?}"
    ;;
  "exec fixture-proxy")
    printf '%s  /etc/squid/allowlist.txt\n' "${AGENT_LAB_EGRESS_POLICY_SHA256:?}"
    ;;
  "compose "*)
    case " $* " in
      *" ps -q egress-proxy "*) printf 'fixture-proxy\n' ;;
    esac
    ;;
  *)
    ;;
esac
EOF
chmod +x "$work/bin/docker"

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

run_agent() {
  local volumes="$1" out="$2" rc=0
  : > "$docker_log"
  env -i \
    PATH="$work/bin:/usr/bin:/bin" \
    HOME="$HOME" \
    FAKE_DOCKER_LOG="$docker_log" \
    FAKE_IMAGE_VOLUMES="$volumes" \
    AGENT_LAB_ENV_FILE="$env_file" \
    AGENT_LAB_AGENT_IMAGE="fixture:test" \
    AGENT_LAB_PROJECT_DIR="" \
    AGENT_LAB_SECRETS_DIR="./$secrets_rel" \
    AGENT_LAB_ALLOWLIST_RECIPES="base" \
    AGENT_LAB_EPHEMERAL_HOME="1" \
    AGENT_LAB_AGENT_UID="1000" \
    AGENT_LAB_AGENT_GID="1000" \
    AGENT_LAB_AGENT_MEM="1g" \
    AGENT_LAB_AGENT_CPUS="1" \
    "$repo_root/scripts/agent" -- true >"$out" 2>&1 || rc=$?
  return "$rc"
}

hostile_out="$work/hostile.out"
if run_agent $'/etc\n/opt/extra' "$hostile_out"; then
  fail "hostile image-declared writable volumes are rejected"
else
  if grep -Fq "unsupported image-declared VOLUME: /etc" "$hostile_out" &&
     grep -Fq "unsupported image-declared VOLUME: /opt/extra" "$hostile_out"; then
    pass "hostile image-declared writable volumes are rejected with exact reasons"
  else
    fail "hostile image rejection reports each unsupported target"
  fi
fi
if grep -Fq "compose " "$docker_log"; then
  fail "hostile image rejection happens before Compose"
else
  pass "hostile image rejection happens before Compose"
fi
if [ ! -e "$secrets_path" ]; then
  pass "hostile image rejection happens before secrets materialization"
else
  fail "hostile image rejection happens before secrets materialization"
fi

safe_out="$work/safe.out"
if run_agent $'/workspace\n/home/agent\n/tmp\n/run/agent-secrets' "$safe_out"; then
  pass "documented writable-surface targets are accepted"
else
  fail "documented writable-surface targets are accepted"
fi
if grep -Fq "compose " "$docker_log"; then
  pass "accepted image reaches Compose"
else
  fail "accepted image reaches Compose"
fi
if [ -d "$secrets_path" ]; then
  pass "validated image permits planned secrets materialization"
else
  fail "validated image permits planned secrets materialization"
fi
if grep -Fq -- "--env-file /dev/null" "$docker_log"; then
  pass "Compose consumes validated exports instead of rereading the raw env file"
else
  fail "Compose consumes validated exports instead of rereading the raw env file"
fi

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
