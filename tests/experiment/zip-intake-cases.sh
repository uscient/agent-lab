#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
agent_lab="$repo_root/scripts/agent-lab"
fixture="$repo_root/tests/experiment/fixtures/directories/minimal"
work="$(mktemp -d)"
trap 'find "$work" -type f -delete 2>/dev/null || true; find "$work" -depth -type d -exec rmdir {} + 2>/dev/null || true' EXIT
mkdir -p "$work/home" "$work/tmp"

python3 -I - "$fixture/experiment.cue" "$work/stored.zip" "$work/deflated.zip" <<'PY'
from pathlib import Path
import stat
import sys
import zipfile

source = Path(sys.argv[1]).read_bytes()
for target, method in (
    (Path(sys.argv[2]), zipfile.ZIP_STORED),
    (Path(sys.argv[3]), zipfile.ZIP_DEFLATED),
):
    info = zipfile.ZipInfo("experiment.cue", date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = method
    info.create_system = 3
    info.external_attr = (stat.S_IFREG | 0o600) << 16
    with zipfile.ZipFile(target, "w") as archive:
        archive.writestr(info, source)
PY

capture() {
  local name="$1"
  shift
  CAPTURE_RC=0
  env -i PATH=/usr/bin:/bin HOME="$work/home" TMPDIR="$work/tmp" LC_ALL=C \
    AGENT_LAB_CUE_TOOL_DIR="${AGENT_LAB_CUE_TOOL_DIR:-$repo_root/.cache/dev/tools/cue}" \
    "$@" > "$work/$name.out" 2> "$work/$name.err" || CAPTURE_RC=$?
}

failures=0
observed="$work/observed"
: > "$observed"
pass() { printf 'PASS %s %s\n' "$1" "$2"; printf '%s\n' "$1" >> "$observed"; }
fail() { printf 'FAIL %s %s\n' "$1" "$2"; printf '%s\n' "$1" >> "$observed"; failures=$((failures + 1)); }

capture directory "$agent_lab" experiment check "$fixture"
directory_rc="$CAPTURE_RC"
capture stored "$agent_lab" experiment check --zip "$work/stored.zip"
stored_rc="$CAPTURE_RC"
capture deflated "$agent_lab" experiment check --zip "$work/deflated.zip"
deflated_rc="$CAPTURE_RC"

if [ "$directory_rc" -eq 0 ] && [ "$stored_rc" -eq 0 ] && [ "$deflated_rc" -eq 0 ] &&
   [ ! -s "$work/directory.err" ] && [ ! -s "$work/stored.err" ] &&
   [ ! -s "$work/deflated.err" ] &&
   [ "$(jq -cS '.plan' "$work/directory.out")" = "$(jq -cS '.plan' "$work/stored.out")" ] &&
   [ "$(jq -cS '.plan' "$work/directory.out")" = "$(jq -cS '.plan' "$work/deflated.out")" ] &&
   [ "$(jq -r '.source.digest' "$work/directory.out")" = "$(jq -r '.source.digest' "$work/stored.out")" ] &&
   [ "$(jq -r '.source.digest' "$work/directory.out")" = "$(jq -r '.source.digest' "$work/deflated.out")" ] &&
   jq -e '.source.kind == "zip" and (.source.archiveDigest | startswith("sha256:"))' \
     "$work/stored.out" >/dev/null 2>&1 &&
   jq -e '.source.kind == "zip" and (.source.archiveDigest | startswith("sha256:"))' \
     "$work/deflated.out" >/dev/null 2>&1; then
  pass ZIP-001 "public zip check normalizes stored and deflated sources"
else
  fail ZIP-001 "public zip check normalizes stored and deflated sources"
fi

expected="$work/expected"
printf '%s\n' ZIP-001 > "$expected"
if ! cmp -s "$expected" "$observed"; then
  printf 'INFRA assertion identity drift\n' >&2
  exit 125
fi
printf 'SUMMARY assertions=1 expected=1 failures=%s infra=0\n' "$failures"
[ "$failures" -eq 0 ]
