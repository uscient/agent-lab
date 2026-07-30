#!/usr/bin/env bash
set -euo pipefail

# Docker-free contract checks for the strict runtime gate and isolated test lifecycle.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

project="$(
  COMPOSE_PROJECT_NAME="agent-lab-contract-fixture" \
    bash -c 'source "$1/scripts/common"; printf "%s" "$PROJECT_NAME"' _ "$repo_root"
)"
if [ "$project" = "agent-lab-contract-fixture" ]; then
  pass "Compose project names are caller-isolated"
else
  fail "Compose project names are caller-isolated"
fi

if grep -Fq 'com.docker.network.bridge.gateway_mode_ipv4: isolated' \
     "$repo_root/compose.yaml"; then
  pass "agent bridge requests isolated gateway mode"
else
  fail "agent bridge requests isolated gateway mode"
fi

if [ -f "$repo_root/tests/security/docker.manifest" ] &&
   grep -Fq 'suite network-boundary tests/docker/network-boundary.sh' \
     "$repo_root/tests/security/docker.manifest"; then
  pass "versioned Docker gate requires the network-boundary suite"
else
  fail "versioned Docker gate requires the network-boundary suite"
fi

if grep -Fq 'docker)' "$repo_root/scripts/dev/security-gate" &&
   grep -Fq 'docker info' "$repo_root/scripts/dev/security-gate" &&
   grep -Fq 'docker compose version' "$repo_root/scripts/dev/security-gate"; then
  pass "Docker gate classifies daemon and Compose prerequisites"
else
  fail "Docker gate classifies daemon and Compose prerequisites"
fi

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
