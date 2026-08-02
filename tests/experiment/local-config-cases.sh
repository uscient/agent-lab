#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
work="$(mktemp -d)"
trap 'find "$work" -type f -delete 2>/dev/null || true; find "$work" -type l -delete 2>/dev/null || true; find "$work" -depth -type d -exec rmdir {} + 2>/dev/null || true' EXIT
rc=0
"$repo_root/scripts/agent-lab" --home "$work/home" init > "$work/out" 2> "$work/err" || rc=$?
failures=0
if [ "$rc" -eq 0 ] && [ -f "$work/home/home.json" ] && [ -f "$work/home/config.json" ]; then
  printf 'PASS CFG-001 init creates the explicit private home\n'
else
  printf 'FAIL CFG-001 init creates the explicit private home\n'
  failures=1
fi
printf 'SUMMARY assertions=1 expected=1 failures=%s infra=0\n' "$failures"
[ "$failures" -eq 0 ]
