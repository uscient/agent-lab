#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
command -v python3 >/dev/null 2>&1 || {
  printf 'INFRA security-gate concurrency contract requires python3\n' >&2
  exit 125
}
exec python3 -I "$repo_root/tests/dev/security-gate-concurrency-cases.py"
