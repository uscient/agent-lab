#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
agent_lab="$repo_root/scripts/agent-lab"
fixture="$repo_root/tests/experiment/fixtures/directories/minimal"
work="$(mktemp -d)"
trap 'find "$work" -type f -delete 2>/dev/null || true; find "$work" -depth -type d -exec rmdir {} + 2>/dev/null || true' EXIT
mkdir -p "$work/home" "$work/tmp"
rc=0
env -i PATH=/usr/bin:/bin HOME="$work/home" TMPDIR="$work/tmp" LC_ALL=C \
  AGENT_LAB_CUE_TOOL_DIR="${AGENT_LAB_CUE_TOOL_DIR:-$repo_root/.cache/dev/tools/cue}" \
  AGENT_LAB_CEDAR_TOOL_DIR="${AGENT_LAB_CEDAR_TOOL_DIR:-$repo_root/.cache/dev/tools/cedar}" \
  "$agent_lab" experiment authorize install "$fixture" > "$work/out" 2> "$work/err" || rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$work/err" ] &&
   jq -e '.verdict == "permit" and (.binding.sourceDigest | startswith("sha256:")) and (.binding.planDigest | startswith("sha256:"))' "$work/out" >/dev/null 2>&1; then
  printf 'PASS AUTH-001 fresh preview binds source and plan\n'
  failures=0
else
  printf 'FAIL AUTH-001 fresh preview binds source and plan\n'
  failures=1
fi
printf 'SUMMARY assertions=1 expected=1 failures=%s infra=0\n' "$failures"
[ "$failures" -eq 0 ] || exit 1
printf 'EXPERIMENT AUTHORIZATION PASS\n'
