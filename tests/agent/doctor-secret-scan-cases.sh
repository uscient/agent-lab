#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
source "$repo_root/scripts/lib/secret-scan.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fixture="$work/repo"
failures=0

pass() {
  printf 'PASS %s\n' "$1"
}

fail() {
  printf 'FAIL %s\n' "$1"
  failures=$((failures + 1))
}

mkdir -p "$fixture"
git -C "$fixture" init -q

printf '%s\n' \
  'AGENT_LAB_SECRETS_MOUNT: /run/agent-secrets' \
  'ENV AGENT_LAB_SECRETS_MOUNT=/run/agent-secrets' \
  'OPENCLAW_AUTH_SECRET_DIR=/home/node/.config/openclaw' \
  'ENV AGENT_LAB_SECRETS_MOUNT=/run/agent-secrets OPENCLAW_AUTH_SECRET_DIR=/home/node/.config/openclaw' \
  > "$fixture/safe-mounts"
git -C "$fixture" add safe-mounts

if ! agent_lab_tracked_source_has_secret_pattern "$fixture"; then
  pass "known secret path assignments are not credential findings"
else
  fail "known secret path assignments are not credential findings"
fi

printf '%s%s\n' \
  'ENV AGENT_LAB_SECRETS_MOUNT=/run/agent-secrets SERVICE_API_KEY=' \
  '0123456789abcdef0123456789abcdef' > "$fixture/finding"
git -C "$fixture" add finding
if agent_lab_tracked_source_has_secret_pattern "$fixture"; then
  pass "safe path cannot hide a token assignment on the same line"
else
  fail "safe path cannot hide a token assignment on the same line"
fi

printf '%s\n' 'ordinary tracked source' > "$fixture/finding"
git -C "$fixture" add finding

if ! agent_lab_tracked_source_has_secret_pattern "$repo_root"; then
  pass "current tracked source has no high-confidence secret findings"
else
  fail "current tracked source has no high-confidence secret findings"
fi

printf '%s%s\n' 'SERVICE_API_KEY=' '0123456789abcdef0123456789abcdef' \
  > "$fixture/finding"
git -C "$fixture" add finding
if agent_lab_tracked_source_has_secret_pattern "$fixture"; then
  pass "token assignment sensitivity mutation is detected"
else
  fail "token assignment sensitivity mutation is detected"
fi

printf '%s%s\n' 'AGENT_LAB_SECRETS_MOUNT=' '/tmp/not-the-canonical-mount' \
  > "$fixture/finding"
git -C "$fixture" add finding
if agent_lab_tracked_source_has_secret_pattern "$fixture"; then
  pass "noncanonical secret mount assignment remains suspicious"
else
  fail "noncanonical secret mount assignment remains suspicious"
fi

printf '%s%s\n' \
  'BADAGENT_LAB_SECRETS_MOUNT=' '/run/agent-secrets' > "$fixture/finding"
git -C "$fixture" add finding
if agent_lab_tracked_source_has_secret_pattern "$fixture"; then
  pass "safe path exemption requires the exact variable name"
else
  fail "safe path exemption requires the exact variable name"
fi

printf '%s%s\n' \
  'badAGENT_LAB_SECRETS_MOUNT=' '/run/agent-secrets' > "$fixture/finding"
git -C "$fixture" add finding
if agent_lab_tracked_source_has_secret_pattern "$fixture"; then
  pass "lowercase identifier prefix cannot enter the safe exemption"
else
  fail "lowercase identifier prefix cannot enter the safe exemption"
fi

printf '%s%s\n' '-----BEGIN ' 'PRIVATE KEY-----' > "$fixture/finding"
git -C "$fixture" add finding
if agent_lab_tracked_source_has_secret_pattern "$fixture"; then
  pass "private-key sensitivity mutation is detected"
else
  fail "private-key sensitivity mutation is detected"
fi

if agent_lab_tracked_source_has_secret_pattern "$work/not-a-repository"; then
  pass "repository scan errors fail closed"
else
  fail "repository scan errors fail closed"
fi

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
