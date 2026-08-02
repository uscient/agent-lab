#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
expected="$repo_root/tests/install/fixtures/expected-runtime-files.txt"
manifest="$repo_root/packaging/agent-lab-local.manifest"
installer="$repo_root/scripts/install-local"
work="$(mktemp -d)"
trap 'find "$work" -type f -delete 2>/dev/null || true; find "$work" -type l -delete 2>/dev/null || true; find "$work" -depth -type d -exec rmdir {} + 2>/dev/null || true' EXIT
failures=0
pass() { printf 'PASS %s %s\n' "$1" "$2"; }
fail() { printf 'FAIL %s %s\n' "$1" "$2"; failures=$((failures + 1)); }

if [ -f "$manifest" ] && cmp -s "$expected" "$manifest"; then
  pass PKG-001 "production runtime manifest matches the independent allowlist"
else
  fail PKG-001 "production runtime manifest matches the independent allowlist"
fi

if [ -x "$installer" ]; then
  pass PKG-002 "local installer entrypoint exists"
else
  fail PKG-002 "local installer entrypoint exists"
fi

printf 'SUMMARY assertions=2 expected=2 failures=%s infra=0\n' "$failures"
[ "$failures" -eq 0 ]
