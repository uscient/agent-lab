#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
subcase="$repo_root/tests/experiment/directory-intake-cases.sh"
[ -x "$subcase" ] || { printf 'INFRA directory intake subcase is missing\n' >&2; exit 125; }
"$subcase"
"$repo_root/tests/experiment/aggregate-harness-cases.sh"
printf 'EXPERIMENT CONTRACT PASS\n'
