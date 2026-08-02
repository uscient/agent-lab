#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
agent_lab="$repo_root/scripts/agent-lab"
fixture="$repo_root/tests/experiment/fixtures/directories/minimal"
work="$(mktemp -d)"
trap 'find "$work" -type f -delete 2>/dev/null || true; find "$work" -depth -type d -exec rmdir {} + 2>/dev/null || true' EXIT
mkdir -p "$work/home" "$work/tmp"

failures=0
observed="$work/observed"
: > "$observed"
pass() { printf 'PASS %s %s\n' "$1" "$2"; printf '%s\n' "$1" >> "$observed"; }
fail() { printf 'FAIL %s %s\n' "$1" "$2"; printf '%s\n' "$1" >> "$observed"; failures=$((failures + 1)); }
capture() {
  CAPTURE_RC=0
  env -i PATH=/usr/bin:/bin HOME="$work/home" TMPDIR="$work/tmp" LC_ALL=C \
    AGENT_LAB_CUE_TOOL_DIR="${AGENT_LAB_CUE_TOOL_DIR:-$repo_root/.cache/dev/tools/cue}" \
    "$@" > "$work/stdout" 2> "$work/stderr" || CAPTURE_RC=$?
}

if [ -x "$agent_lab" ]; then
  pass FMT-001 "repository agent-lab entrypoint exists"
else
  fail FMT-001 "repository agent-lab entrypoint exists"
fi

capture "$agent_lab" experiment check "$fixture"
if [ "$CAPTURE_RC" -eq 0 ] && [ ! -s "$work/stderr" ] &&
   jq -e '.source.kind == "directory" and (.source.digest | startswith("sha256:")) and .plan.kind == "RequestedExperimentPlan"' "$work/stdout" >/dev/null 2>&1; then
  pass FMT-002 "sole-entry directory produces a source-bound checked candidate"
else
  fail FMT-002 "sole-entry directory produces a source-bound checked candidate"
fi

capture "$agent_lab" experiment check "$fixture"
cp "$work/stdout" "$work/second"
capture "$agent_lab" experiment check "$fixture"
if [ "$CAPTURE_RC" -eq 0 ] && cmp -s "$work/second" "$work/stdout"; then
  pass FMT-003 "repeated directory checks are byte-identical"
else
  fail FMT-003 "repeated directory checks are byte-identical"
fi

expected="$work/expected"
printf '%s\n' FMT-001 FMT-002 FMT-003 > "$expected"
if ! cmp -s "$expected" "$observed"; then
  printf 'INFRA assertion identity drift\n' >&2
  exit 125
fi
printf 'SUMMARY assertions=3 expected=3 failures=%s infra=0\n' "$failures"
[ "$failures" -eq 0 ]
