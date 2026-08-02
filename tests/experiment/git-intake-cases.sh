#!/usr/bin/env bash
set -u -o pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
cases="$repo_root/tests/experiment/git-intake-cases.py"

if [ ! -f "$cases" ] || ! command -v python3 >/dev/null 2>&1; then
  printf 'SUMMARY assertions=0 expected=12 failures=0 infra=1\n'
  exit 125
fi

exec python3 -I -B "$cases"
