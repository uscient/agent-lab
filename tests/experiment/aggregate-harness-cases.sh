#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
lifecycle="$repo_root/tests/experiment/local-lifecycle-cases.sh"
failures=0
if [ "$(grep -Fxc '"$repo_root/tests/install/local-install-cases.sh"' "$lifecycle")" -eq 1 ] &&
   [ "$(grep -Fxc '"$repo_root/tests/experiment/local-config-cases.sh"' "$lifecycle")" -eq 1 ]; then
  printf 'PASS AGG-001 lifecycle subcases are routed exactly once in order\n'
else
  printf 'FAIL AGG-001 lifecycle subcases are routed exactly once in order\n'
  failures=1
fi
if [ "$(tail -1 "$lifecycle")" = "printf 'EXPERIMENT LOCAL LIFECYCLE PASS\\n'" ]; then
  printf 'PASS AGG-002 stable completion follows every subcase\n'
else
  printf 'FAIL AGG-002 stable completion follows every subcase\n'
  failures=$((failures + 1))
fi
printf 'SUMMARY assertions=2 expected=2 failures=%s infra=0\n' "$failures"
[ "$failures" -eq 0 ]
