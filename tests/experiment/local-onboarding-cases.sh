#!/usr/bin/env bash
set -u -o pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
if [ ! -f "$script_dir/local-lifecycle-cases.sh" ] ||
   [ ! -r "$script_dir/local-lifecycle-cases.sh" ]; then
  printf 'INFRA shared lifecycle core unavailable\n' >&2
  printf 'SUMMARY assertions=0 expected=86 failures=0 infra=1\n'
  exit 125
fi
# The G0 operator-surface suite gates this route when it is present.  It stays
# silent on success so the route's exact assertion, summary, and final-marker
# shape is unchanged, and it is skipped where it is absent so a harness replica
# of this wrapper keeps its measured contract.
focused_g0="$script_dir/../flow/g0-operator-surface/cases.sh"
if [ -f "$focused_g0" ] && [ -r "$focused_g0" ]; then
  focused_g0_output="$(bash "$focused_g0" 2>&1)"
  focused_g0_rc=$?
  if [ "$focused_g0_rc" -ne 0 ]; then
    printf '%s\n' "$focused_g0_output" >&2
    exit "$focused_g0_rc"
  fi
fi
exec bash "$script_dir/local-lifecycle-cases.sh" local
