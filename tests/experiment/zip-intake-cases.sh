#!/usr/bin/env bash
set -u -o pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
agent_lab="$repo_root/scripts/agent-lab"
bounded_helper="$repo_root/tests/helpers/run-bounded.py"
fixture="$repo_root/tests/experiment/fixtures/directories/minimal"
runtime_manifest="$repo_root/packaging/agent-lab-local.manifest"
expected_runtime="$repo_root/tests/install/fixtures/expected-runtime-files.txt"
expected_count=33
work=""
failures=0
infrastructure=0
cleanup_work() {
  local failed=0
  if [ -n "$work" ] && [ -e "$work" ]; then
    find "$work" -type f -exec chmod u+rw {} + 2>/dev/null || failed=1
    find "$work" -depth -type d -exec chmod u+rwx {} + 2>/dev/null || failed=1
    find "$work" -type f -delete 2>/dev/null || failed=1
    find "$work" -type l -delete 2>/dev/null || failed=1
    find "$work" -depth -type d -exec rmdir {} + 2>/dev/null || failed=1
    [ ! -e "$work" ] || failed=1
  fi
  return "$failed"
}

if ! work="$(mktemp -d)"; then
  printf 'SUMMARY assertions=0 expected=%s failures=0 infra=1\n' "$expected_count"
  exit 125
fi
trap 'cleanup_work >/dev/null 2>&1 || true' EXIT
if ! mkdir -p "$work/home" "$work/tmp"; then
  printf 'SUMMARY assertions=0 expected=%s failures=0 infra=1\n' "$expected_count"
  exit 125
fi

if [ ! -x "$agent_lab" ] || [ ! -f "$bounded_helper" ] || [ ! -d "$fixture" ] ||
   [ ! -f "$runtime_manifest" ] || [ ! -f "$expected_runtime" ] ||
   ! command -v jq >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  printf 'INFRA zip-intake prerequisites are unavailable\n' >&2
  printf 'SUMMARY assertions=0 expected=%s failures=0 infra=1\n' "$expected_count"
  exit 125
fi
if ! python3 -I -B "$bounded_helper" --self-test \
  > "$work/bounded-self-test.out" 2> "$work/bounded-self-test.err"; then
  printf 'INFRA bounded command helper self-test failed\n' >&2
  printf 'SUMMARY assertions=0 expected=%s failures=0 infra=1\n' "$expected_count"
  exit 125
fi

if ! python3 -I -B "$repo_root/tests/experiment/zip-fixtures.py" \
  "$fixture/experiment.cue" "$work"; then
  printf 'SUMMARY assertions=0 expected=%s failures=0 infra=1\n' "$expected_count"
  exit 125
fi

capture() {
  local name="$1"
  local status="$work/$name.status"
  local status_line=""
  shift
  CAPTURE_RC=0
  find "$status" -delete 2>/dev/null || true
  python3 -I -B "$bounded_helper" --timeout 5 --status "$status" \
    --stdout "$work/$name.out" --stderr "$work/$name.err" -- \
    env -i PATH="${CAPTURE_PATH:-/usr/bin:/bin}" HOME="$work/home" TMPDIR="$work/tmp" LC_ALL=C \
      CANARY_DIR="${CANARY_DIR:-$work/no-canary}" \
      AGENT_LAB_CUE_TOOL_DIR="${AGENT_LAB_CUE_TOOL_DIR:-$repo_root/.cache/dev/tools/cue}" \
      AGENT_LAB_CEDAR_TOOL_DIR="${AGENT_LAB_CEDAR_TOOL_DIR:-$repo_root/.cache/dev/tools/cedar}" \
      "$@" || CAPTURE_RC=$?
  if [ -f "$status" ]; then
    status_line="$(cat "$status")"
  fi
  if [ "$status_line" != "child:$CAPTURE_RC" ]; then
    printf 'INFRA bounded command status is inconsistent: %s rc=%s status=%s\n' \
      "$name" "$CAPTURE_RC" "$status_line" >&2
    infrastructure=1
    CAPTURE_RC=125
  fi
}

observed="$work/observed"
: > "$observed"
pass() { printf 'PASS %s %s\n' "$1" "$2"; printf '%s\n' "$1" >> "$observed"; }
fail() { printf 'FAIL %s %s\n' "$1" "$2"; printf '%s\n' "$1" >> "$observed"; failures=$((failures + 1)); }
init_home() {
  local label="$1" home="$2"
  capture "$label" "$agent_lab" --home "$home" init
  if [ "$CAPTURE_RC" -ne 0 ]; then
    printf 'INFRA temporary Agent Lab home initialization failed\n' >&2
    printf 'SUMMARY assertions=%s expected=%s failures=%s infra=1\n' \
      "$(wc -l < "$observed")" "$expected_count" "$failures"
    exit 125
  fi
}
tree_fingerprint() {
  python3 -I -B - "$1" <<'PY'
from hashlib import sha256
import os
from pathlib import Path
import stat
import sys

root = Path(sys.argv[1])
records = []
if root.exists():
    for path in sorted(root.rglob("*"), key=lambda item: os.fsencode(str(item.relative_to(root)))):
        metadata = path.lstat()
        relative = str(path.relative_to(root))
        if stat.S_ISREG(metadata.st_mode):
            content = sha256(path.read_bytes()).hexdigest()
            kind = "file"
        elif stat.S_ISDIR(metadata.st_mode):
            content = ""
            kind = "directory"
        elif stat.S_ISLNK(metadata.st_mode):
            content = os.readlink(path)
            kind = "symlink"
        else:
            content = ""
            kind = "other"
        records.append((relative, kind, stat.S_IMODE(metadata.st_mode), content))
print(sha256(repr(records).encode("utf-8")).hexdigest())
PY
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

capture utf8-ascii "$agent_lab" experiment check --zip "$work/utf8-ascii.zip"
utf8_ascii_rc="$CAPTURE_RC"
capture creator-version "$agent_lab" experiment check --zip "$work/creator-version-45.zip"
creator_version_rc="$CAPTURE_RC"
capture deflate-level-hint "$agent_lab" experiment check --zip "$work/deflate-level-hint.zip"
deflate_level_hint_rc="$CAPTURE_RC"
capture dos-archive-file "$agent_lab" experiment check --zip "$work/dos-archive-file.zip"
dos_archive_file_rc="$CAPTURE_RC"
capture ntfs-archive-file "$agent_lab" experiment check --zip "$work/ntfs-archive-file.zip"
ntfs_archive_file_rc="$CAPTURE_RC"
capture vfat-archive-file "$agent_lab" experiment check --zip "$work/vfat-archive-file.zip"
vfat_archive_file_rc="$CAPTURE_RC"
if [ "$utf8_ascii_rc" -eq 0 ] && [ "$creator_version_rc" -eq 0 ] &&
   [ "$deflate_level_hint_rc" -eq 0 ] && [ "$dos_archive_file_rc" -eq 0 ] &&
   [ "$ntfs_archive_file_rc" -eq 0 ] &&
   [ "$vfat_archive_file_rc" -eq 0 ] &&
   [ ! -s "$work/utf8-ascii.err" ] && [ ! -s "$work/creator-version.err" ] &&
   [ ! -s "$work/deflate-level-hint.err" ] && [ ! -s "$work/dos-archive-file.err" ] &&
   [ ! -s "$work/ntfs-archive-file.err" ] &&
   [ ! -s "$work/vfat-archive-file.err" ] &&
   [ "$(jq -r '.source.digest' "$work/utf8-ascii.out")" = \
     "$(jq -r '.source.digest' "$work/directory.out")" ] &&
   [ "$(jq -r '.source.digest' "$work/creator-version.out")" = \
     "$(jq -r '.source.digest' "$work/directory.out")" ] &&
   [ "$(jq -r '.source.digest' "$work/deflate-level-hint.out")" = \
     "$(jq -r '.source.digest' "$work/directory.out")" ] &&
   [ "$(jq -r '.source.digest' "$work/dos-archive-file.out")" = \
     "$(jq -r '.source.digest' "$work/directory.out")" ] &&
   [ "$(jq -r '.source.digest' "$work/ntfs-archive-file.out")" = \
     "$(jq -r '.source.digest' "$work/directory.out")" ] &&
   [ "$(jq -r '.source.digest' "$work/vfat-archive-file.out")" = \
     "$(jq -r '.source.digest' "$work/directory.out")" ]; then
  pass ZIP-COMPAT-001 "benign ZIP creator and compression metadata remain compatible"
else
  fail ZIP-COMPAT-001 "benign ZIP creator and compression metadata remain compatible"
fi

capture usage-check "$agent_lab" experiment check --zip
usage_check_rc="$CAPTURE_RC"
capture usage-authorize "$agent_lab" experiment authorize install --zip
usage_authorize_rc="$CAPTURE_RC"
capture usage-install "$agent_lab" experiment install --zip
usage_install_rc="$CAPTURE_RC"
if [ "$usage_check_rc" -eq 2 ] && [ "$usage_authorize_rc" -eq 2 ] &&
   [ "$usage_install_rc" -eq 2 ] && [ ! -s "$work/usage-check.out" ] &&
   [ ! -s "$work/usage-authorize.out" ] && [ ! -s "$work/usage-install.out" ]; then
  pass ZIP-USAGE-001 "incomplete zip options are usage errors before source or home access"
else
  fail ZIP-USAGE-001 "incomplete zip options are usage errors before source or home access"
fi

expect_all_reject ZIP-PATH-001 ZIP-PATH "only the exact ASCII root member name is accepted" \
  wrong-case.zip wrapper.zip dotdot.zip backslash.zip absolute.zip drive.zip unc.zip \
  nul-name.zip control-name.zip nonascii.zip

expect_all_reject ZIP-COUNT-001 ZIP-COUNT "the archive has exactly one member" \
  zero-count.zip eocd-count-mismatch.zip extra-entry.zip duplicate.zip \
  duplicate-encoding.zip normalized-collision.zip slash-backslash-collision.zip

expect_all_reject ZIP-TYPE-001 ZIP-TYPE "the sole member is a regular file" \
  directory-type.zip symlink-type.zip fifo-type.zip dos-volume-label.zip \
  ntfs-device.zip ntfs-reparse.zip

expect_all_reject ZIP-META-001 ZIP-META "member and archive metadata are closed" \
  extra-field.zip file-comment.zip archive-comment.zip

expect_all_reject ZIP-FLAG-001 ZIP-FLAG "encrypted and descriptor-based members are refused" \
  encrypted.zip strong-encrypted.zip data-descriptor.zip stored-option-flag.zip

expect_all_reject ZIP-METHOD-001 ZIP-METHOD "only stored and raw deflate members are accepted" \
  unsupported-method.zip

expect_all_reject ZIP-ZIP64-001 ZIP-ZIP64 "ZIP64 and multidisk records are refused" \
  zip64-version.zip zip64-sentinel.zip multidisk.zip

expect_all_reject ZIP-HEADER-001 ZIP-HEADER "central and local headers agree exactly" \
  central-signature.zip central-name-mismatch.zip central-flags-mismatch.zip \
  local-method-mismatch.zip local-crc-mismatch.zip local-size-mismatch.zip \
  eocd-offset-mismatch.zip eocd-size-mismatch.zip prefixed.zip duplicate-eocd.zip \
  concatenated.zip deflate-version-too-low.zip

expect_all_reject ZIP-CRC-001 ZIP-CRC "member CRC is verified" \
  bad-crc.zip corrupt-payload.zip

expect_all_reject ZIP-LENGTH-001 ZIP-LENGTH "declared and decoded lengths agree" \
  bad-length.zip payload-gap.zip

expect_all_reject ZIP-SIZE-001 ZIP-SIZE "archive and expanded source bounds apply before planning" \
  archive-over.zip expanded-over.zip deflate-bomb.zip

expect_all_reject ZIP-BOMB-001 ZIP-BOMB "declared-small deflate expansion stops at the source bound" \
  declared-small-large.zip

expect_all_reject ZIP-TRUNC-001 ZIP-TRUNC "truncated records and deflate streams are refused" \
  missing-central.zip truncated-deflate.zip

expect_all_reject ZIP-TRAIL-001 ZIP-TRAIL "bytes after the canonical archive end are refused" \
  trailing.zip deflate-unused-input.zip

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

if python3 -I -B - "$repo_root/scripts/experiment.py" \
  "$work/expanded-limit.zip" "$work/archive-limit.zip" <<'PY'
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import sys

spec = spec_from_file_location("zip_read_probe", sys.argv[1])
assert spec is not None and spec.loader is not None
module = module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
original_read = module.os.read
for archive_name in sys.argv[2:]:
    archive = Path(archive_name)
    changed = False

    def mutating_read(descriptor, size):
        global changed
        data = original_read(descriptor, size)
        if data and not changed:
            changed = True
            with archive.open("ab") as stream:
                stream.write(b"xx")
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

spec = spec_from_file_location("zip_late_decode_probe", sys.argv[1])
assert spec is not None and spec.loader is not None
module = module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
original_decompressobj = module.zlib.decompressobj

class LateFaultDecoder:
    def __init__(self):
        self.delegate = original_decompressobj(-15)

    @property
    def eof(self):
        raise RuntimeError("injected late decoder uncertainty")

    @property
    def unconsumed_tail(self):
        return self.delegate.unconsumed_tail

    @property
    def unused_data(self):
        return self.delegate.unused_data

    def decompress(self, data, size):
        return self.delegate.decompress(data, size)

    def flush(self, size):
        return self.delegate.flush(size)

module.zlib.decompressobj = lambda _window: LateFaultDecoder()
try:
    module.read_zip_snapshot(sys.argv[2])
except module.InfrastructureError as error:
    assert "ZIP-DECODE" in str(error)
else:
    raise AssertionError("late decoder exception was accepted")
PY
then
  pass ZIP-DECODE-003 "late decoder exceptions are infrastructure uncertainty"
else
  fail ZIP-DECODE-003 "late decoder exceptions are infrastructure uncertainty"
fi

if python3 -I -B - "$repo_root/scripts/experiment.py" "$work/deflated.zip" <<'PY'
from importlib.util import module_from_spec, spec_from_file_location
import sys

spec = spec_from_file_location("zip_clock_probe", sys.argv[1])
assert spec is not None and spec.loader is not None
module = module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

def uncertain_clock():
    raise RuntimeError("injected monotonic-clock uncertainty")

module.time.monotonic = uncertain_clock
try:
    module.read_zip_snapshot(sys.argv[2])
except module.InfrastructureError as error:
    assert "ZIP-DECODE" in str(error)
else:
    raise AssertionError("initial decoder clock failure was accepted")
PY
then
  pass ZIP-DECODE-002 "initial decoder clock failure is infrastructure uncertainty"
else
  fail ZIP-DECODE-002 "initial decoder clock failure is infrastructure uncertainty"
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
import io
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
errors = io.StringIO()
module.sys.stderr = errors
try:
    result = module.main(["experiment.py", "check-zip", sys.argv[2]])
except SystemExit as error:
    result = error.code
expected = "INFRA Experiment checked source output could not be written\n"
raise SystemExit(0 if result == 125 and errors.getvalue() == expected else 1)
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

deny_home="$work/deny-home"
init_home deny-home-init "$deny_home"
deny_runtime="$work/deny-runtime"
deny_runtime_ok=0
if cmp -s "$expected_runtime" "$runtime_manifest"; then
  deny_runtime_ok=1
fi
while IFS= read -r runtime_name; do
  if [ -z "$runtime_name" ] || [ ! -f "$repo_root/$runtime_name" ]; then
    deny_runtime_ok=0
    continue
  fi
  mkdir -p "$deny_runtime/$(dirname -- "$runtime_name")"
  cp "$repo_root/$runtime_name" "$deny_runtime/$runtime_name" || deny_runtime_ok=0
done < "$expected_runtime"
if [ "$deny_runtime_ok" -eq 1 ]; then
  sed 's/^permit (/forbid (/' \
    "$repo_root/authorization/experiment/v0alpha1/operator.cedar" \
    > "$deny_runtime/authorization/experiment/v0alpha1/operator.cedar"
fi
deny_before="$(tree_fingerprint "$deny_home")"
capture deny-preview "$deny_runtime/scripts/agent-lab" --home "$deny_home" \
  experiment authorize install --zip "$work/stored.zip"
deny_preview_rc="$CAPTURE_RC"
deny_after_preview="$(tree_fingerprint "$deny_home")"
capture deny-install "$deny_runtime/scripts/agent-lab" --home "$deny_home" \
  experiment install --zip "$work/stored.zip"
deny_install_rc="$CAPTURE_RC"
deny_after_install="$(tree_fingerprint "$deny_home")"
if [ "$deny_runtime_ok" -eq 1 ] && [ "$deny_preview_rc" -eq 1 ] &&
   [ "$deny_install_rc" -eq 1 ] && [ ! -s "$work/deny-preview.err" ] &&
   [ ! -s "$work/deny-install.out" ] &&
   [ "$(wc -l < "$work/deny-install.err")" -eq 1 ] &&
   grep -Fxq 'FAIL Experiment fresh Experiment installation authorization denied' \
     "$work/deny-install.err" &&
   jq -e '.verdict == "deny"' "$work/deny-preview.out" >/dev/null 2>&1 &&
   [ "$deny_before" = "$deny_after_preview" ] &&
   [ "$deny_before" = "$deny_after_install" ]; then
  pass ZIP-DENY-001 "fresh zip denial leaves the initialized home unchanged"
else
  fail ZIP-DENY-001 "fresh zip denial leaves the initialized home unchanged"
fi

if python3 -I -B - "$repo_root/scripts/agent-lab.py" <<'PY'
from importlib.util import module_from_spec, spec_from_file_location
import io
from pathlib import Path
import sys

spec = spec_from_file_location("zip_platform_probe", sys.argv[1])
assert spec is not None and spec.loader is not None
module = module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
reached = []

def forbidden(*_args, **_kwargs):
    reached.append(True)
    raise AssertionError("pre-acquisition platform guard was bypassed")

module.sys.platform = "darwin"
module.load_config_receipt = forbidden
module.experiment_store_module = forbidden
errors = io.StringIO()
module.sys.stderr = errors
result = module.experiment_command(
    Path("/unavailable-home"), ["install", "--zip", "/unavailable-archive"]
)
assert result == 125
assert not reached
assert errors.getvalue() == "INFRA Agent Lab Experiment installation requires Linux\n"
PY
then
  pass ZIP-PLAT-001 "non-Linux zip install stops before home and archive acquisition"
else
  fail ZIP-PLAT-001 "non-Linux zip install stops before home and archive acquisition"
fi

canary_bin="$work/canary-bin"
canary_marks="$work/canary-marks"
mkdir "$canary_bin" "$canary_marks"
for command in docker git curl wget zip unzip; do
  printf '%s\n' '#!/bin/sh' 'set -eu' ': > "$CANARY_DIR/${0##*/}"' 'exit 97' \
    > "$canary_bin/$command"
  chmod 700 "$canary_bin/$command"
  CANARY_DIR="$canary_marks" "$canary_bin/$command" >/dev/null 2>&1 || true
done
canaries_calibrated="$(find "$canary_marks" -type f -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')"
find "$canary_marks" -type f -delete
noeffect_home="$work/noeffect-home"
init_home noeffect-home-init "$noeffect_home"
archive_before="$(sha256sum "$work/deflated.zip")"
CAPTURE_PATH="$canary_bin:/usr/bin:/bin"
CANARY_DIR="$canary_marks"
capture noeffect-check "$agent_lab" experiment check --zip "$work/deflated.zip"
noeffect_check_rc="$CAPTURE_RC"
capture noeffect-authorize "$agent_lab" experiment authorize install --zip "$work/deflated.zip"
noeffect_authorize_rc="$CAPTURE_RC"
capture noeffect-install "$agent_lab" --home "$noeffect_home" experiment install --zip "$work/deflated.zip"
noeffect_install_rc="$CAPTURE_RC"
unset CAPTURE_PATH CANARY_DIR
archive_after="$(sha256sum "$work/deflated.zip")"
if [ "$canaries_calibrated" = "curl docker git unzip wget zip " ] &&
   [ "$noeffect_check_rc" -eq 0 ] && [ "$noeffect_authorize_rc" -eq 0 ] &&
   [ "$noeffect_install_rc" -eq 0 ] && [ ! -s "$work/noeffect-check.err" ] &&
   [ ! -s "$work/noeffect-authorize.err" ] && [ ! -s "$work/noeffect-install.err" ] &&
   [ -z "$(find "$canary_marks" -type f -print -quit)" ] &&
   [ "$archive_before" = "$archive_after" ]; then
  pass ZIP-NOEF-002 "zip intake invokes no archive tool, Git, downloader, or Docker command"
else
  fail ZIP-NOEF-002 "zip intake invokes no archive tool, Git, downloader, or Docker command"
fi

installed_source="$work/installed-source"
installed_unavailable="$work/installed-source-unavailable"
installed_prefix="$work/installed-prefix"
installed_home="$work/installed-home"
installed_unrelated="$work/installed-unrelated"
installed_tools="$work/installed-tools"
installed_ok=0
if cmp -s "$expected_runtime" "$runtime_manifest"; then
  installed_ok=1
fi
mkdir -p "$installed_source/packaging" "$installed_source/scripts" \
  "$installed_unrelated" "$installed_tools/cue" "$installed_tools/cedar" || installed_ok=0
while IFS= read -r runtime_name; do
  if [ -z "$runtime_name" ] || [ ! -f "$repo_root/$runtime_name" ]; then
    installed_ok=0
    continue
  fi
  mkdir -p "$installed_source/$(dirname -- "$runtime_name")" || installed_ok=0
  cp "$repo_root/$runtime_name" "$installed_source/$runtime_name" || installed_ok=0
done < "$expected_runtime"
cp "$runtime_manifest" "$installed_source/packaging/agent-lab-local.manifest" || installed_ok=0
cp "$repo_root/scripts/install-local" "$repo_root/scripts/install-local.py" \
  "$installed_source/scripts/" || installed_ok=0
cp -a "$repo_root/.cache/dev/tools/cue/." "$installed_tools/cue/" || installed_ok=0
cp -a "$repo_root/.cache/dev/tools/cedar/." "$installed_tools/cedar/" || installed_ok=0
chmod +x "$installed_source/scripts/install-local" "$installed_source/scripts/agent-lab" || installed_ok=0
capture installed-bundle "$installed_source/scripts/install-local" --prefix "$installed_prefix"
installed_bundle_rc="$CAPTURE_RC"
if [ "$installed_bundle_rc" -eq 0 ]; then
  mv "$installed_source" "$installed_unavailable" || installed_ok=0
fi
capture installed-init env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
  /bin/sh -c 'cd "$1" || exit 125; shift; exec "$@"' agent-lab-installed \
  "$installed_unrelated" "$installed_prefix/bin/agent-lab" --home "$installed_home" init
installed_init_rc="$CAPTURE_RC"
if [ "$installed_init_rc" -eq 0 ]; then
  cp -a "$installed_tools/cue/." "$installed_home/cache/tools/cue/" || installed_ok=0
  cp -a "$installed_tools/cedar/." "$installed_home/cache/tools/cedar/" || installed_ok=0
fi
capture installed-check env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
  /bin/sh -c 'cd "$1" || exit 125; shift; exec "$@"' agent-lab-installed \
  "$installed_unrelated" "$installed_prefix/bin/agent-lab" --home "$installed_home" \
  experiment check --zip "$work/stored.zip"
installed_check_rc="$CAPTURE_RC"
capture installed-authorize env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
  /bin/sh -c 'cd "$1" || exit 125; shift; exec "$@"' agent-lab-installed \
  "$installed_unrelated" "$installed_prefix/bin/agent-lab" --home "$installed_home" \
  experiment authorize install --zip "$work/stored.zip"
installed_authorize_rc="$CAPTURE_RC"
capture installed-install env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
  /bin/sh -c 'cd "$1" || exit 125; shift; exec "$@"' agent-lab-installed \
  "$installed_unrelated" "$installed_prefix/bin/agent-lab" --home "$installed_home" \
  experiment install --zip "$work/stored.zip"
installed_install_rc="$CAPTURE_RC"
if [ "$installed_ok" -eq 1 ] && [ "$installed_bundle_rc" -eq 0 ] &&
   [ "$installed_init_rc" -eq 0 ] && [ "$installed_check_rc" -eq 0 ] &&
   [ "$installed_authorize_rc" -eq 0 ] && [ "$installed_install_rc" -eq 0 ] &&
   [ ! -s "$work/installed-bundle.err" ] && [ ! -s "$work/installed-check.err" ] &&
   [ ! -s "$work/installed-authorize.err" ] && [ ! -s "$work/installed-install.err" ] &&
   jq -e '.source.kind == "zip"' "$work/installed-check.out" >/dev/null 2>&1 &&
   jq -e '.verdict == "permit"' "$work/installed-authorize.out" >/dev/null 2>&1 &&
   jq -e '.changed == true and .name == "first-experiment"' \
     "$work/installed-install.out" >/dev/null 2>&1 &&
   [ ! -e "$installed_source" ] && [ -d "$installed_unavailable" ] &&
   [ -z "$(find "$installed_prefix" -name __pycache__ -print -quit)" ]; then
  pass ZIP-RUNTIME-001 "installed runtime handles zip intake without its source replica"
else
  fail ZIP-RUNTIME-001 "installed runtime handles zip intake without its source replica"
fi

expected="$work/expected"
printf '%s\n' \
  ZIP-001 ZIP-COMPAT-001 ZIP-USAGE-001 ZIP-PATH-001 ZIP-COUNT-001 ZIP-TYPE-001 ZIP-META-001 \
  ZIP-FLAG-001 ZIP-METHOD-001 ZIP-ZIP64-001 ZIP-HEADER-001 ZIP-CRC-001 \
  ZIP-LENGTH-001 ZIP-SIZE-001 ZIP-BOMB-001 ZIP-TRUNC-001 ZIP-TRAIL-001 \
  ZIP-SIZE-002 ZIP-READ-001 ZIP-READ-002 ZIP-DECODE-001 ZIP-DECODE-003 ZIP-DECODE-002 ZIP-TIMEOUT-001 \
  ZIP-OUTPUT-001 ZIP-NOEF-001 ZIP-AUTH-001 ZIP-INSTALL-001 ZIP-RETRY-001 \
  ZIP-DENY-001 ZIP-PLAT-001 ZIP-NOEF-002 ZIP-RUNTIME-001 > "$expected"
if ! cmp -s "$expected" "$observed"; then
  printf 'INFRA assertion identity drift\n' >&2
  infrastructure=1
fi
if ! cleanup_work; then
  infrastructure=1
fi
trap - EXIT
printf 'SUMMARY assertions=%s expected=%s failures=%s infra=%s\n' \
  "$expected_count" "$expected_count" "$failures" "$infrastructure"
[ "$infrastructure" -eq 0 ] || exit 125
[ "$failures" -eq 0 ]
