#!/usr/bin/env bash
set -u -o pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
exec bash "$script_dir/local-lifecycle-cases.sh" install
