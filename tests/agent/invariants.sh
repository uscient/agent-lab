#!/usr/bin/env bash
set -euo pipefail

# Static (no Docker daemon) check of the §3 agent-service invariants, asserted against the
# rendered `docker compose config` for the agent profile + each HOME overlay.
# Run: bash tests/agent/invariants.sh

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
cd "$repo_root"

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

render() {
  docker compose \
    -f compose.yaml -f compose.egress.yaml -f compose.agent.yaml -f "$1" \
    --profile core --profile egress --profile agent config
}

# Print just the `agent:` service block from a rendered config on stdin.
agent_block() {
  awk '
    /^  agent:$/ { in_s=1; next }
    in_s && (/^  [A-Za-z0-9_.-]+:$/ || /^[A-Za-z0-9_.-]/) { in_s=0 }
    in_s { print }
  '
}

for overlay in compose.agent.persist.yaml compose.agent.ephemeral.yaml; do
  if ! cfg="$(render "$overlay" 2>/dev/null)"; then
    fail "compose config renders ($overlay)"
    continue
  fi
  pass "compose config renders ($overlay)"

  block="$(printf '%s\n' "$cfg" | agent_block)"

  if printf '%s\n' "$block" | grep -qw agents; then
    pass "agent attaches to the internal agents network ($overlay)"
  else
    fail "agent does not attach to agents ($overlay)"
  fi

  if printf '%s\n' "$block" | grep -qw egress; then
    fail "agent is attached to the egress network ($overlay)"
  else
    pass "agent is NOT attached to egress ($overlay)"
  fi

  if printf '%s\n' "$block" | grep -q 'read_only: true'; then
    pass "agent rootfs is read_only ($overlay)"
  else
    fail "agent rootfs is not read_only ($overlay)"
  fi

  if printf '%s\n' "$block" | grep -q -- '- ALL'; then
    pass "agent drops all capabilities ($overlay)"
  else
    fail "agent does not cap_drop ALL ($overlay)"
  fi

  user_val="$(printf '%s\n' "$block" | grep -E '^[[:space:]]*user:' | head -n1 | sed -E 's/.*user:[[:space:]]*//; s/"//g' || true)"
  uid="${user_val%%:*}"
  if [ -n "$uid" ] && [ "$uid" != "0" ]; then
    pass "agent runs as a non-root user ($overlay)"
  else
    fail "agent runs as root or has no user set ($overlay)"
  fi

  if printf '%s\n' "$cfg" | grep -q '/var/run/docker.sock'; then
    fail "a service mounts the Docker socket ($overlay)"
  else
    pass "no service mounts the Docker socket ($overlay)"
  fi

  if printf '%s\n' "$cfg" | grep -qE 'privileged:[[:space:]]*true'; then
    fail "a service is privileged ($overlay)"
  else
    pass "no privileged service ($overlay)"
  fi

  if printf '%s\n' "$cfg" | grep -q 'published:'; then
    fail "a published host port is configured ($overlay)"
  else
    pass "no published host ports ($overlay)"
  fi
done

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
