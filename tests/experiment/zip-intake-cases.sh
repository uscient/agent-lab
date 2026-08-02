#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
agent_lab="$repo_root/scripts/agent-lab"
fixture="$repo_root/tests/experiment/fixtures/directories/minimal"
work="$(mktemp -d)"
trap 'find "$work" -type f -delete 2>/dev/null || true; find "$work" -depth -type d -exec rmdir {} + 2>/dev/null || true' EXIT
mkdir -p "$work/home" "$work/tmp"

if ! python3 -I -B "$repo_root/tests/experiment/zip-fixtures.py" \
  "$fixture/experiment.cue" "$work"; then
  printf 'SUMMARY assertions=0 expected=25 failures=0 infra=1\n'
  exit 125
fi

capture() {
  local name="$1"
  shift
  CAPTURE_RC=0
  env -i PATH=/usr/bin:/bin HOME="$work/home" TMPDIR="$work/tmp" LC_ALL=C \
    AGENT_LAB_CUE_TOOL_DIR="${AGENT_LAB_CUE_TOOL_DIR:-$repo_root/.cache/dev/tools/cue}" \
    AGENT_LAB_CEDAR_TOOL_DIR="${AGENT_LAB_CEDAR_TOOL_DIR:-$repo_root/.cache/dev/tools/cedar}" \
    "$@" > "$work/$name.out" 2> "$work/$name.err" || CAPTURE_RC=$?
}

failures=0
observed="$work/observed"
: > "$observed"
pass() { printf 'PASS %s %s\n' "$1" "$2"; printf '%s\n' "$1" >> "$observed"; }
fail() { printf 'FAIL %s %s\n' "$1" "$2"; printf '%s\n' "$1" >> "$observed"; failures=$((failures + 1)); }
init_home() {
  local label="$1" home="$2"
  capture "$label" "$agent_lab" --home "$home" init
  if [ "$CAPTURE_RC" -ne 0 ]; then
    printf 'INFRA temporary Agent Lab home initialization failed\n' >&2
    printf 'SUMMARY assertions=%s expected=25 failures=%s infra=1\n' \
      "$(wc -l < "$observed")" "$failures"
    exit 125
  fi
}
expect_all_reject() {
  local id="$1" code="$2" detail="$3"
  shift 3
  local archive accepted=0
  for archive in "$@"; do
    capture "reject-${archive%.zip}" "$agent_lab" experiment check --zip "$work/$archive"
    if [ "$CAPTURE_RC" -ne 1 ] || [ -s "$work/reject-${archive%.zip}.out" ] ||
       [ "$(wc -l < "$work/reject-${archive%.zip}.err")" -ne 1 ] ||
       ! grep -Fq "FAIL Experiment manifest zip archive $code" \
         "$work/reject-${archive%.zip}.err"; then
      accepted=1
    fi
  done
  if [ "$accepted" -eq 0 ]; then
    pass "$id" "$detail"
  else
    fail "$id" "$detail"
  fi
}

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

expect_all_reject ZIP-PATH-001 ZIP-PATH "only the exact ASCII root member name is accepted" \
  wrong-case.zip wrapper.zip dotdot.zip backslash.zip absolute.zip drive.zip unc.zip \
  nul-name.zip control-name.zip nonascii.zip

expect_all_reject ZIP-COUNT-001 ZIP-COUNT "the archive has exactly one member" \
  zero-count.zip extra-entry.zip duplicate.zip

expect_all_reject ZIP-TYPE-001 ZIP-TYPE "the sole member is a regular file" \
  directory-type.zip symlink-type.zip fifo-type.zip

expect_all_reject ZIP-META-001 ZIP-META "member and archive metadata are closed" \
  extra-field.zip file-comment.zip archive-comment.zip

expect_all_reject ZIP-FLAG-001 ZIP-FLAG "encrypted and descriptor-based members are refused" \
  encrypted.zip strong-encrypted.zip data-descriptor.zip

expect_all_reject ZIP-METHOD-001 ZIP-METHOD "only stored and raw deflate members are accepted" \
  unsupported-method.zip

expect_all_reject ZIP-ZIP64-001 ZIP-ZIP64 "ZIP64 and multidisk records are refused" \
  zip64-version.zip zip64-sentinel.zip multidisk.zip

expect_all_reject ZIP-HEADER-001 ZIP-HEADER "central and local headers agree exactly" \
  central-signature.zip central-name-mismatch.zip central-flags-mismatch.zip

expect_all_reject ZIP-CRC-001 ZIP-CRC "member CRC is verified" bad-crc.zip

expect_all_reject ZIP-LENGTH-001 ZIP-LENGTH "declared and decoded lengths agree" \
  bad-length.zip

expect_all_reject ZIP-SIZE-001 ZIP-SIZE "archive and expanded source bounds apply before planning" \
  archive-over.zip expanded-over.zip deflate-bomb.zip

expect_all_reject ZIP-BOMB-001 ZIP-BOMB "declared-small deflate expansion stops at the source bound" \
  declared-small-large.zip

expect_all_reject ZIP-TRUNC-001 ZIP-TRUNC "truncated records and deflate streams are refused" \
  missing-central.zip truncated-deflate.zip

expect_all_reject ZIP-TRAIL-001 ZIP-TRAIL "bytes after the canonical archive end are refused" trailing.zip

capture expanded-limit "$agent_lab" experiment check --zip "$work/expanded-limit.zip"
limit_digest="$(python3 -I -B - "$work/expanded-limit.cue" <<'PY'
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
if [ "$CAPTURE_RC" -eq 0 ] && [ ! -s "$work/expanded-limit.err" ] &&
   [ "$(wc -c < "$work/expanded-limit.cue")" -eq 262144 ] &&
   [ "$(jq -r '.source.digest' "$work/expanded-limit.out")" = "$limit_digest" ]; then
  pass ZIP-SIZE-002 "the exact expanded source limit remains valid"
else
  fail ZIP-SIZE-002 "the exact expanded source limit remains valid"
fi

ln -s "$work/stored.zip" "$work/archive-link.zip"
mkdir "$work/archive-directory"
capture missing "$agent_lab" experiment check --zip "$work/missing.zip"
missing_rc="$CAPTURE_RC"
capture linked "$agent_lab" experiment check --zip "$work/archive-link.zip"
linked_rc="$CAPTURE_RC"
capture archive-directory "$agent_lab" experiment check --zip "$work/archive-directory"
directory_path_rc="$CAPTURE_RC"
if [ "$missing_rc" -eq 125 ] && [ "$linked_rc" -eq 125 ] &&
   [ "$directory_path_rc" -eq 125 ] && [ ! -s "$work/missing.out" ] &&
   [ ! -s "$work/linked.out" ] && [ ! -s "$work/archive-directory.out" ]; then
  pass ZIP-READ-001 "unavailable or unsafe archive paths are infrastructure failures"
else
  fail ZIP-READ-001 "unavailable or unsafe archive paths are infrastructure failures"
fi

if python3 -I -B - "$repo_root/scripts/experiment.py" "$work/expanded-limit.zip" <<'PY'
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import sys

spec = spec_from_file_location("zip_read_probe", sys.argv[1])
assert spec is not None and spec.loader is not None
module = module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
archive = Path(sys.argv[2])
original_read = module.os.read
changed = False

def mutating_read(descriptor, size):
    global changed
    data = original_read(descriptor, size)
    if data and not changed:
        changed = True
        with archive.open("ab") as stream:
            stream.write(b"x")
    return data

module.os.read = mutating_read
try:
    module.read_zip_snapshot(str(archive))
except module.InfrastructureError as error:
    assert "ZIP-READ" in str(error)
else:
    raise AssertionError("mid-read archive mutation was accepted")
assert changed
PY
then
  pass ZIP-READ-002 "mid-read archive mutation is infrastructure uncertainty"
else
  fail ZIP-READ-002 "mid-read archive mutation is infrastructure uncertainty"
fi

if python3 -I -B - "$repo_root/scripts/experiment.py" "$work/deflated.zip" <<'PY'
from importlib.util import module_from_spec, spec_from_file_location
import sys

spec = spec_from_file_location("zip_decode_probe", sys.argv[1])
assert spec is not None and spec.loader is not None
module = module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

def uncertain_decoder(*_args, **_kwargs):
    raise RuntimeError("injected decoder uncertainty")

module.zlib.decompressobj = uncertain_decoder
try:
    module.read_zip_snapshot(sys.argv[2])
except module.InfrastructureError as error:
    assert "ZIP-DECODE" in str(error)
else:
    raise AssertionError("unexpected decoder exception was accepted")
PY
then
  pass ZIP-DECODE-001 "unexpected decoder exceptions are infrastructure uncertainty"
else
  fail ZIP-DECODE-001 "unexpected decoder exceptions are infrastructure uncertainty"
fi

if python3 -I -B - "$repo_root/scripts/experiment.py" "$work/deflated.zip" <<'PY'
from importlib.util import module_from_spec, spec_from_file_location
import sys

spec = spec_from_file_location("zip_timeout_probe", sys.argv[1])
assert spec is not None and spec.loader is not None
module = module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
ticks = iter((0.0, 10.0))
module.time.monotonic = lambda: next(ticks, 10.0)
try:
    module.read_zip_snapshot(sys.argv[2])
except module.InfrastructureError as error:
    assert "ZIP-TIMEOUT" in str(error)
else:
    raise AssertionError("decoder deadline was accepted")
PY
then
  pass ZIP-TIMEOUT-001 "decoder deadline uncertainty is bounded and classified"
else
  fail ZIP-TIMEOUT-001 "decoder deadline uncertainty is bounded and classified"
fi

if AGENT_LAB_CUE_TOOL_DIR="${AGENT_LAB_CUE_TOOL_DIR:-$repo_root/.cache/dev/tools/cue}" \
  python3 -I -B - "$repo_root/scripts/experiment.py" "$work/stored.zip" <<'PY'
from importlib.util import module_from_spec, spec_from_file_location
import sys

spec = spec_from_file_location("zip_output_probe", sys.argv[1])
assert spec is not None and spec.loader is not None
module = module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

class ShortBuffer:
    def write(self, data):
        return max(0, len(data) - 1)

    def flush(self):
        return None

class ShortOutput:
    buffer = ShortBuffer()

    def flush(self):
        return None

module.sys.stdout = ShortOutput()
try:
    result = module.main(["experiment.py", "check-zip", sys.argv[2]])
except SystemExit as error:
    result = error.code
raise SystemExit(0 if result == 125 else 1)
PY
then
  pass ZIP-OUTPUT-001 "partial checked output is infrastructure uncertainty"
else
  fail ZIP-OUTPUT-001 "partial checked output is infrastructure uncertainty"
fi

if python3 -I -B - "$repo_root/scripts/experiment.py" \
  "$work/wrapper.zip" "$work/encrypted.zip" "$work/bad-crc.zip" <<'PY'
from importlib.util import module_from_spec, spec_from_file_location
import contextlib
import io
import sys

spec = spec_from_file_location("zip_noeffect_probe", sys.argv[1])
assert spec is not None and spec.loader is not None
module = module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
reached = False

def forbidden(_snapshot):
    global reached
    reached = True
    raise AssertionError("downstream planning reached")

module.authored_manifest = forbidden
for archive in sys.argv[2:]:
    with contextlib.redirect_stderr(io.StringIO()):
        try:
            module.main(["experiment.py", "check-zip", archive])
        except SystemExit as error:
            assert error.code == 1
        else:
            raise AssertionError("hostile archive returned")
assert not reached
PY
then
  pass ZIP-NOEF-001 "structural rejection occurs before common planning"
else
  fail ZIP-NOEF-001 "structural rejection occurs before common planning"
fi

capture directory-authorize "$agent_lab" experiment authorize install "$fixture"
directory_authorize_rc="$CAPTURE_RC"
capture zip-authorize "$agent_lab" experiment authorize install --zip "$work/stored.zip"
zip_authorize_rc="$CAPTURE_RC"
if [ "$directory_authorize_rc" -eq 0 ] && [ "$zip_authorize_rc" -eq 0 ] &&
   [ ! -s "$work/directory-authorize.err" ] && [ ! -s "$work/zip-authorize.err" ] &&
   cmp -s "$work/directory-authorize.out" "$work/zip-authorize.out" &&
   jq -e '.verdict == "permit" and (.binding.sourceDigest | startswith("sha256:"))' \
     "$work/zip-authorize.out" >/dev/null 2>&1; then
  pass ZIP-AUTH-001 "zip authorization uses the directory decision path and identity"
else
  fail ZIP-AUTH-001 "zip authorization uses the directory decision path and identity"
fi

zip_home="$work/zip-home"
init_home zip-home-init "$zip_home"
capture zip-install "$agent_lab" --home "$zip_home" experiment install --zip "$work/stored.zip"
zip_install_rc="$CAPTURE_RC"
zip_target="$zip_home/experiments/first-experiment"
archive_digest="sha256:$(sha256sum "$work/stored.zip" | awk '{print $1}')"
archive_bytes="$(wc -c < "$work/stored.zip")"
source_identity="$(jq -r '.source.digest' "$work/directory.out")"
if [ "$zip_install_rc" -eq 0 ] && [ ! -s "$work/zip-install.err" ] &&
   jq -e '.changed == true and .name == "first-experiment"' \
     "$work/zip-install.out" >/dev/null 2>&1 &&
   cmp -s "$fixture/experiment.cue" "$zip_target/artifact/experiment.cue" &&
   jq -e --arg archive_digest "$archive_digest" --argjson archive_bytes "$archive_bytes" \
     --arg source_digest "$source_identity" \
     '.source.digest == $source_digest and
      .transport == {archiveBytes: $archive_bytes, archiveDigest: $archive_digest, kind: "zip"}' \
     "$zip_target/records/provenance.json" >/dev/null 2>&1; then
  pass ZIP-INSTALL-001 "zip install publishes the common artifact with closed archive provenance"
else
  fail ZIP-INSTALL-001 "zip install publishes the common artifact with closed archive provenance"
fi

retry_home="$work/retry-home"
init_home retry-home-init "$retry_home"
capture directory-first "$agent_lab" --home "$retry_home" experiment install "$fixture"
directory_first_rc="$CAPTURE_RC"
retry_receipt="$retry_home/experiments/first-experiment/records/install.json"
if [ "$directory_first_rc" -eq 0 ] && [ -f "$retry_receipt" ]; then
  cp "$retry_receipt" "$work/retry-receipt-before"
else
  : > "$work/retry-receipt-before"
fi
capture zip-retry "$agent_lab" --home "$retry_home" experiment install --zip "$work/deflated.zip"
zip_retry_rc="$CAPTURE_RC"
if [ "$directory_first_rc" -eq 0 ] && [ "$zip_retry_rc" -eq 0 ] &&
   [ ! -s "$work/directory-first.err" ] && [ ! -s "$work/zip-retry.err" ] &&
   jq -e '.changed == false and .name == "first-experiment"' \
     "$work/zip-retry.out" >/dev/null 2>&1 &&
   cmp -s "$work/retry-receipt-before" "$retry_receipt"; then
  pass ZIP-RETRY-001 "equivalent zip retry preserves the directory installation receipt"
else
  fail ZIP-RETRY-001 "equivalent zip retry preserves the directory installation receipt"
fi

expected="$work/expected"
printf '%s\n' \
  ZIP-001 ZIP-PATH-001 ZIP-COUNT-001 ZIP-TYPE-001 ZIP-META-001 \
  ZIP-FLAG-001 ZIP-METHOD-001 ZIP-ZIP64-001 ZIP-HEADER-001 ZIP-CRC-001 \
  ZIP-LENGTH-001 ZIP-SIZE-001 ZIP-BOMB-001 ZIP-TRUNC-001 ZIP-TRAIL-001 \
  ZIP-SIZE-002 ZIP-READ-001 ZIP-READ-002 ZIP-DECODE-001 ZIP-TIMEOUT-001 \
  ZIP-OUTPUT-001 ZIP-NOEF-001 ZIP-AUTH-001 ZIP-INSTALL-001 ZIP-RETRY-001 > "$expected"
if ! cmp -s "$expected" "$observed"; then
  printf 'INFRA assertion identity drift\n' >&2
  exit 125
fi
printf 'SUMMARY assertions=25 expected=25 failures=%s infra=0\n' "$failures"
[ "$failures" -eq 0 ]
