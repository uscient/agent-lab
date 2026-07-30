#!/usr/bin/env bash
set -euo pipefail

# Docker-free lifecycle test for scripts/agent. The fake daemon models Squid loading its
# bind-mounted allowlist only when the service is first created or force-recreated.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
work="$(mktemp -d)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

mkdir -p "$work/bin" "$work/secrets"
env_file="$work/agent.env"
docker_log="$work/docker.log"
active_hash="$work/active.hash"
active_allowlist="$work/active.allowlist"
: > "$env_file"
: > "$docker_log"

cat > "$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_DOCKER_LOG:?}"

if [ "${1:-} ${2:-}" = "image inspect" ]; then
  exit 0
fi

if [ "${1:-}" = "inspect" ]; then
  [ -f "${FAKE_ACTIVE_HASH:?}" ] || exit 1
  cat "$FAKE_ACTIVE_HASH"
  exit 0
fi

if [ "${1:-}" = "compose" ]; then
  case " $* " in
    *" ps -q egress-proxy "*)
      [ -f "${FAKE_ACTIVE_HASH:?}" ] && printf 'fixture-container\n'
      exit 0
      ;;
    *" up -d --wait "*)
      recreate=0
      case " $* " in *" --force-recreate "*) recreate=1 ;; esac
      if [ ! -f "${FAKE_ACTIVE_HASH:?}" ] || [ "$recreate" -eq 1 ]; then
        hash="${AGENT_LAB_EGRESS_POLICY_SHA256:-}"
        if [ -z "$hash" ]; then
          hash="$(sha256sum "${AGENT_LAB_EGRESS_ALLOWLIST:?}" | awk '{print $1}')"
        fi
        printf '%s\n' "$hash" > "$FAKE_ACTIVE_HASH"
        cp "${AGENT_LAB_EGRESS_ALLOWLIST:?}" "${FAKE_ACTIVE_ALLOWLIST:?}"
      fi
      exit 0
      ;;
  esac
  exit 0
fi

exit 0
EOF
chmod +x "$work/bin/docker"

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

run_agent() {
  local recipes="$1" out="$2" rc=0
  PATH="$work/bin:$PATH" \
    FAKE_DOCKER_LOG="$docker_log" \
    FAKE_ACTIVE_HASH="$active_hash" \
    FAKE_ACTIVE_ALLOWLIST="$active_allowlist" \
    AGENT_LAB_ENV_FILE="$env_file" \
    AGENT_LAB_AGENT_IMAGE="fixture:test" \
    AGENT_LAB_PROJECT_DIR="" \
    AGENT_LAB_SECRETS_DIR="$work/secrets" \
    AGENT_LAB_ALLOWLIST_RECIPES="$recipes" \
    AGENT_LAB_EPHEMERAL_HOME="1" \
    AGENT_LAB_AGENT_UID="1000" \
    AGENT_LAB_AGENT_GID="1000" \
    AGENT_LAB_AGENT_MEM="1g" \
    AGENT_LAB_AGENT_CPUS="1" \
    "$repo_root/scripts/agent" -- true >"$out" 2>&1 || rc=$?
  return "$rc"
}

if run_agent "base,node-dev" "$work/broad.out" &&
   grep -Fxq ".npmjs.org" "$active_allowlist"; then
  pass "initial broad policy becomes active"
else
  fail "initial broad policy becomes active"
fi
broad_hash="$(cat "$active_hash" 2>/dev/null || true)"

: > "$docker_log"
if run_agent "base" "$work/narrow.out" &&
   ! grep -Fq ".npmjs.org" "$active_allowlist" &&
   [ "$(cat "$active_hash")" != "$broad_hash" ]; then
  pass "broad-to-narrow transition replaces the active policy"
else
  fail "broad-to-narrow transition replaces the active policy"
fi
if grep -Fq -- "--force-recreate" "$docker_log"; then
  pass "policy mismatch force-recreates Squid"
else
  fail "policy mismatch force-recreates Squid"
fi

: > "$docker_log"
if run_agent "base" "$work/unchanged.out" &&
   ! grep -Fq -- "--force-recreate" "$docker_log"; then
  pass "unchanged policy reuses the verified proxy"
else
  fail "unchanged policy reuses the verified proxy"
fi

if run_agent "base,node-dev" "$work/widen.out" &&
   grep -Fxq ".npmjs.org" "$active_allowlist"; then
  pass "narrow-to-broad transition replaces the active policy"
else
  fail "narrow-to-broad transition replaces the active policy"
fi

rm -f "$active_hash" "$active_allowlist"
if run_agent "base" "$work/recover.out" &&
   [ -f "$active_hash" ] &&
   ! grep -Fq ".npmjs.org" "$active_allowlist"; then
  pass "missing or crashed proxy is recreated with the requested policy"
else
  fail "missing or crashed proxy is recreated with the requested policy"
fi

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
