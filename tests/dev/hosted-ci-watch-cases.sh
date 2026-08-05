#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
exec python3 -I -B "$repo_root/tests/dev/hosted-ci-watch-cases.py"
