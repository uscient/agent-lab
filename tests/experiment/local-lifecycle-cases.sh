#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
"$repo_root/tests/install/local-install-cases.sh"
"$repo_root/tests/experiment/local-config-cases.sh"
printf 'EXPERIMENT LOCAL LIFECYCLE PASS\n'
