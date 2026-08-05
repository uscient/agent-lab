#!/usr/bin/env bash
set -u -o pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
if [ ! -f "$script_dir/local-lifecycle-cases.sh" ] ||
   [ ! -r "$script_dir/local-lifecycle-cases.sh" ]; then
  printf 'INFRA shared lifecycle core unavailable\n' >&2
  printf 'SUMMARY assertions=0 expected=1 failures=0 infra=1\n'
  exit 125
fi
exec bash "$script_dir/local-lifecycle-cases.sh" catalog-name-bound
