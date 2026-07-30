#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
entrypoint="$repo_root/tools/agent-entrypoint.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
secrets="$work/secrets"
marker="$work/SHOULD_NOT_EXIST"
mkdir -p "$secrets"

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

printf 'line\n\n' > "$secrets/TRAILING"
printf 'file-value' > "$secrets/DUPLICATE"
printf 'invalid-value' > "$secrets/invalid-name"
printf 'must-not-leak' > "$secrets/PRIVATE_VALUE"
{
  printf 'DUPLICATE=first-env\n'
  printf 'LITERAL=$(touch %s)\n' "$marker"
  printf '9INVALID=hidden-invalid-value\n'
} > "$secrets/a.env"
printf 'DUPLICATE=last-env' > "$secrets/z.env"

out="$work/stdout"
err="$work/stderr"
rc=0
AGENT_LAB_SECRETS_MOUNT="$secrets" \
  EXPECTED_LITERAL="\$(touch $marker)" \
  "$entrypoint" sh -c '
    set -e
    expected=$(printf "line\n\nx")
    expected=${expected%x}
    test "$TRAILING" = "$expected"
    test "${#TRAILING}" -eq 6
    test "$DUPLICATE" = "last-env"
    test "$LITERAL" = "$EXPECTED_LITERAL"
    test "$PRIVATE_VALUE" = "must-not-leak"
    printf "PARSER_OK\n"
  ' >"$out" 2>"$err" || rc=$?

if [ "$rc" -eq 0 ] && grep -Fxq "PARSER_OK" "$out"; then
  pass "file and env secrets follow the exact parser table"
else
  fail "file and env secrets follow the exact parser table"
fi
if [ ! -e "$marker" ]; then
  pass "env-file shell metacharacters remain literal and never execute"
else
  fail "env-file shell metacharacters remain literal and never execute"
fi
if ! grep -Fq "invalid-name" "$err" &&
   ! grep -Fq "9INVALID" "$err" &&
   grep -Fq "skip invalid secret filename" "$err" &&
   grep -Fq "skip invalid identifier in env file" "$err"; then
  pass "invalid identifiers are skipped without echoing attacker-controlled text"
else
  fail "invalid identifiers are skipped without echoing attacker-controlled text"
fi
if ! grep -Fq "must-not-leak" "$out" &&
   ! grep -Fq "must-not-leak" "$err" &&
   ! grep -Fq "hidden-invalid-value" "$err"; then
  pass "parser output never discloses secret values"
else
  fail "parser output never discloses secret values"
fi

if [ -f "$repo_root/.dockerignore" ] &&
   grep -Fxq 'secrets' "$repo_root/.dockerignore" &&
   grep -Fxq '.env*' "$repo_root/.dockerignore" &&
   grep -Fxq '.git' "$repo_root/.dockerignore"; then
  pass "repository-root Docker builds exclude secret and local metadata"
else
  fail "repository-root Docker builds exclude secret and local metadata"
fi

if [ -f "$repo_root/tests/security/docker.manifest" ] &&
   grep -Fq 'suite secret-nondisclosure tests/docker/secret-nondisclosure.sh' \
     "$repo_root/tests/security/docker.manifest"; then
  pass "Docker gate requires host-side secret non-disclosure scans"
else
  fail "Docker gate requires host-side secret non-disclosure scans"
fi

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
