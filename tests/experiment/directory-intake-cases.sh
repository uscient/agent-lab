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

extra="$work/extra"
mkdir "$extra"
cp "$fixture/experiment.cue" "$extra/experiment.cue"
: > "$extra/unexpected"
capture "$agent_lab" experiment check "$extra"
if [ "$CAPTURE_RC" -eq 1 ] && [ ! -s "$work/stdout" ]; then
  pass FMT-004 "an extra directory entry is stable invalid input"
else
  fail FMT-004 "an extra directory entry is stable invalid input"
fi

linked="$work/linked"
mkdir "$linked"
ln "$fixture/experiment.cue" "$linked/experiment.cue"
capture "$agent_lab" experiment check "$linked"
if [ "$CAPTURE_RC" -eq 1 ] && [ ! -s "$work/stdout" ]; then
  pass FMT-005 "a multiply linked authored file is refused"
else
  fail FMT-005 "a multiply linked authored file is refused"
fi

executable="$work/executable"
mkdir "$executable"
cp "$fixture/experiment.cue" "$executable/experiment.cue"
chmod 700 "$executable/experiment.cue"
capture "$agent_lab" experiment check "$executable"
if [ "$CAPTURE_RC" -eq 1 ] && [ ! -s "$work/stdout" ]; then
  pass FMT-006 "an executable authored file is refused"
else
  fail FMT-006 "an executable authored file is refused"
fi

expected_digest="$(python3 - "$fixture/experiment.cue" <<'PY'
from hashlib import sha256
from pathlib import Path
import sys
data = Path(sys.argv[1]).read_bytes()
name = b"experiment.cue"
digest = sha256(b"agent-lab.experiment-tree.v1\0")
digest.update(len(name).to_bytes(4, "big"))
digest.update(name)
digest.update(len(data).to_bytes(8, "big"))
digest.update(data)
print("sha256:" + digest.hexdigest())
PY
)"
capture "$agent_lab" experiment check "$fixture"
if [ "$CAPTURE_RC" -eq 0 ] && [ "$(jq -r '.source.digest' "$work/stdout")" = "$expected_digest" ]; then
  pass FMT-007 "source identity uses the independently framed exact bytes"
else
  fail FMT-007 "source identity uses the independently framed exact bytes"
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
printf '%s\n' FMT-001 FMT-002 FMT-004 FMT-005 FMT-006 FMT-007 FMT-003 > "$expected"
if ! cmp -s "$expected" "$observed"; then
  printf 'INFRA assertion identity drift\n' >&2
  exit 125
fi
printf 'SUMMARY assertions=7 expected=7 failures=%s infra=0\n' "$failures"
[ "$failures" -eq 0 ]
