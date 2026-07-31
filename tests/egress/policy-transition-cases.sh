#!/usr/bin/env bash
set -euo pipefail

# Docker-free lifecycle test for scripts/agent. The fake daemon models Squid loading its
# bind-mounted allowlist only when the service is first created or force-recreated.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
if ! work="$(mktemp -d)"; then
  printf 'INFRA egress policy transition cannot create isolated work directory\n' >&2
  exit 125
fi
agent_root="$work/agent-root"
cleanup() { find "$work" -xdev -depth -delete >/dev/null 2>&1 || true; }
trap cleanup EXIT

mkdir -p \
  "$work/bin" "$work/home" "$work/secrets" \
  "$agent_root/scripts/lib" "$agent_root/policies/recipes"
cp "$repo_root/scripts/agent" "$repo_root/scripts/common" "$agent_root/scripts/"
cp \
  "$repo_root/scripts/lib/allowlist.sh" \
  "$repo_root/scripts/lib/config.sh" \
  "$repo_root/scripts/lib/domain.sh" \
  "$repo_root/scripts/lib/egress.sh" \
  "$repo_root/scripts/lib/guard.sh" \
  "$repo_root/scripts/lib/image.sh" \
  "$agent_root/scripts/lib/"
cp "$repo_root"/policies/recipes/*.allowlist "$agent_root/policies/recipes/"
cp \
  "$repo_root/compose.yaml" \
  "$repo_root/compose.egress.yaml" \
  "$repo_root/compose.agent.yaml" \
  "$repo_root/compose.agent.ephemeral.yaml" \
  "$repo_root/compose.agent.persist.yaml" \
  "$agent_root/"
for fixture_input in \
  scripts/agent scripts/common \
  scripts/lib/allowlist.sh scripts/lib/config.sh scripts/lib/domain.sh \
  scripts/lib/egress.sh scripts/lib/guard.sh scripts/lib/image.sh \
  compose.yaml compose.egress.yaml compose.agent.yaml \
  compose.agent.ephemeral.yaml compose.agent.persist.yaml; do
  if [ ! -f "$agent_root/$fixture_input" ]; then
    printf 'INFRA egress policy transition fixture is incomplete: %s\n' \
      "$fixture_input" >&2
    exit 125
  fi
done
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

fake_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1"
  else
    shasum -a 256 "$1"
  fi
}

if [ "${1:-} ${2:-}" = "image inspect" ]; then
  if [ "${3:-}" = "--format" ] && [ "${4:-}" = "{{.Id}}" ]; then
    printf 'sha256:%064d\n' 0
  fi
  exit 0
fi

if [ "${1:-}" = "inspect" ]; then
  [ -f "${FAKE_ACTIVE_HASH:?}" ] || exit 1
  cat "$FAKE_ACTIVE_HASH"
  exit 0
fi

if [ "${1:-}" = "exec" ]; then
  fake_sha256 "${FAKE_ACTIVE_ALLOWLIST:?}"
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
      if { [ ! -f "${FAKE_ACTIVE_HASH:?}" ] || [ "$recreate" -eq 1 ]; } &&
         [ "${FAKE_IGNORE_RECREATE:-0}" != "1" ]; then
        hash="${AGENT_LAB_EGRESS_POLICY_SHA256:-}"
        if [ -z "$hash" ]; then
          hash="$(fake_sha256 "${AGENT_LAB_EGRESS_ALLOWLIST:?}" | awk '{print $1}')"
        fi
        printf '%s\n' "$hash" > "$FAKE_ACTIVE_HASH"
        rm -f "${FAKE_ACTIVE_ALLOWLIST:?}"
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
  env -i \
    PATH="$work/bin:/usr/bin:/bin" \
    HOME="$work/home" \
    FAKE_DOCKER_LOG="$docker_log" \
    FAKE_ACTIVE_HASH="$active_hash" \
    FAKE_ACTIVE_ALLOWLIST="$active_allowlist" \
    FAKE_IGNORE_RECREATE="${FAKE_IGNORE_RECREATE:-0}" \
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
    "$agent_root/scripts/agent" -- true >"$out" 2>&1 || rc=$?
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
if grep -Fq -- "--force-recreate egress-proxy" "$docker_log" &&
   ! grep -Eq -- "--force-recreate .*dns" "$docker_log"; then
  pass "policy mismatch force-recreates only Squid"
else
  fail "policy mismatch force-recreates only Squid"
fi

: > "$docker_log"
if run_agent "base" "$work/unchanged.out" &&
   ! grep -Fq -- "--force-recreate" "$docker_log" &&
   grep -Fq -- " up -d --wait " "$docker_log"; then
  pass "unchanged policy reconciles Compose without force recreation"
else
  fail "unchanged policy reconciles Compose without force recreation"
fi

if run_agent "base,node-dev" "$work/widen.out" &&
   grep -Fxq ".npmjs.org" "$active_allowlist"; then
  pass "narrow-to-broad transition replaces the active policy"
else
  fail "narrow-to-broad transition replaces the active policy"
fi

if FAKE_IGNORE_RECREATE=1 run_agent "base" "$work/stale.out"; then
  fail "agent refuses to run when the active policy cannot be verified"
elif grep -Fq "active egress policy mismatch" "$work/stale.out"; then
  pass "agent refuses to run when the active policy cannot be verified"
else
  fail "active-policy verification failure reports the mismatch"
fi

rm -f "$active_hash" "$active_allowlist"
run_agent "base" "$work/mount-baseline.out"
chmod u+w "$active_allowlist"
printf '.tampered.example\n' >> "$active_allowlist"
if run_agent "base" "$work/tampered-mount.out"; then
  fail "agent refuses a mounted policy whose bytes do not match its label"
elif grep -Fq "mounted egress policy mismatch" "$work/tampered-mount.out"; then
  pass "agent refuses a mounted policy whose bytes do not match its label"
else
  fail "mounted-policy verification failure reports the mismatch"
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
