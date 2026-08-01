#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
cedar_tool="$repo_root/scripts/dev/cedar-tool"
helper="$repo_root/scripts/dev/cedar-tool.py"
lock="$repo_root/tools/cedar.lock"

for required in "$cedar_tool" "$helper" "$lock"; do
  if [ ! -f "$required" ]; then
    printf 'INFRA Cedar tool contract input is missing: %s\n' "$required" >&2
    exit 125
  fi
done
if [ ! -x "$cedar_tool" ]; then
  printf 'INFRA Cedar tool entrypoint is not executable\n' >&2
  exit 125
fi
cedar_preflight_rc=0
cedar_preflight_out="$("$cedar_tool" --version 2>&1)" || cedar_preflight_rc=$?
if [ "$cedar_preflight_rc" -ne 0 ]; then
  printf 'INFRA Cedar tool contract requires a provisioned pin: %s\n' \
    "$cedar_preflight_out" >&2
  exit 125
fi

work="$(mktemp -d)"
cleanup() {
  find "$work" -type f -delete 2>/dev/null || true
  find "$work" -type l -delete 2>/dev/null || true
  find "$work" -depth -type d -exec rmdir {} + 2>/dev/null || true
}
trap cleanup EXIT
mkdir -p "$work/bin" "$work/outside"

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

capture() {
  local name="$1"
  shift
  CAPTURE_STDOUT="$work/$name.stdout"
  CAPTURE_STDERR="$work/$name.stderr"
  CAPTURE_RC=0
  "$@" > "$CAPTURE_STDOUT" 2> "$CAPTURE_STDERR" || CAPTURE_RC=$?
}

if python3 - "$helper" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
compile(path.read_text(encoding="utf-8"), str(path), "exec")
PY
then
  pass "Cedar tool helper is valid isolated Python"
else
  fail "Cedar tool helper is not valid Python"
fi

capture version "$cedar_tool" --version
if [ "$CAPTURE_RC" -eq 0 ] &&
   grep -Fxq 'cedar-policy-cli 4.12.0' "$CAPTURE_STDOUT" &&
   [ ! -s "$CAPTURE_STDERR" ]; then
  pass "verified cached tool executes the pinned release"
else
  fail "verified cached tool did not execute the pinned release (rc=$CAPTURE_RC)"
fi

tar_spy="$work/tar-spy.log"
: > "$tar_spy"
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "called\\n" >> %q\n' "$tar_spy"
  printf 'exec /usr/bin/tar "$@"\n'
} > "$work/bin/tar"
chmod +x "$work/bin/tar"
capture hostile-path env PATH="$work/bin:/usr/bin:/bin" "$cedar_tool" --version
if [ "$CAPTURE_RC" -eq 0 ] && [ ! -s "$tar_spy" ] &&
   grep -Fxq 'cedar-policy-cli 4.12.0' "$CAPTURE_STDOUT"; then
  pass "verification and execution ignore ambient PATH helpers"
else
  fail "ambient PATH participated in verified execution (rc=$CAPTURE_RC)"
fi

case "$(uname -s):$(uname -m)" in
  Linux:x86_64|Linux:amd64) platform_path="linux_amd64" ;;
  Linux:aarch64|Linux:arm64) platform_path="linux_arm64" ;;
  Darwin:x86_64|Darwin:amd64) platform_path="darwin_amd64" ;;
  Darwin:arm64) platform_path="darwin_arm64" ;;
  *)
    printf 'INFRA unsupported Cedar tool test platform\n' >&2
    exit 125
    ;;
esac

tampered_root="$work/tampered"
mkdir -p "$tampered_root/4.12.0/$platform_path"
tampered="$tampered_root/4.12.0/$platform_path/cedar"
tampered_marker="$work/tampered-executed"
{
  printf '#!/usr/bin/env bash\n'
  printf ': > %q\n' "$tampered_marker"
  printf 'printf "cedar-policy-cli 4.12.0\\n"\n'
} > "$tampered"
chmod 555 "$tampered"
capture tampered env AGENT_LAB_CEDAR_TOOL_DIR="$tampered_root" \
  "$cedar_tool" --version
if [ "$CAPTURE_RC" -eq 125 ] && [ ! -e "$tampered_marker" ]; then
  pass "tampered cached bytes fail before execution"
else
  fail "tampered cached bytes reached execution (rc=$CAPTURE_RC)"
fi

mode_root="$work/writable-mode"
mkdir -p "$mode_root/4.12.0/$platform_path"
trusted_root="${AGENT_LAB_CEDAR_TOOL_DIR:-$repo_root/.cache/dev/tools/cedar}"
cp "$trusted_root/4.12.0/$platform_path/cedar" \
  "$mode_root/4.12.0/$platform_path/cedar"
chmod 755 "$mode_root/4.12.0/$platform_path/cedar"
capture writable-mode env AGENT_LAB_CEDAR_TOOL_DIR="$mode_root" \
  "$cedar_tool" --version
if [ "$CAPTURE_RC" -eq 125 ]; then
  pass "writable cached binaries fail before execution"
else
  fail "writable cached binary reached execution (rc=$CAPTURE_RC)"
fi

cache_link="$work/cache-link"
ln -s "$work/outside" "$cache_link"
capture symlink-root env AGENT_LAB_CEDAR_TOOL_DIR="$cache_link" \
  "$cedar_tool" provision
if [ "$CAPTURE_RC" -eq 125 ] &&
   [ -z "$(find "$work/outside" -mindepth 1 -print -quit)" ]; then
  pass "provisioning rejects a symlinked cache root before writes"
else
  fail "provisioning escaped through a symlinked cache root (rc=$CAPTURE_RC)"
fi

copy_root="$work/copy"
mkdir -p "$copy_root/scripts/dev" "$copy_root/tools"
cp "$cedar_tool" "$helper" "$copy_root/scripts/dev/"
cp "$lock" "$copy_root/tools/"
chmod +x "$copy_root/scripts/dev/cedar-tool"
printf 'unknown record\n' >> "$copy_root/tools/cedar.lock"
capture bad-lock env AGENT_LAB_CEDAR_TOOL_DIR="$work/unused" \
  "$copy_root/scripts/dev/cedar-tool" --version
if [ "$CAPTURE_RC" -eq 125 ] && [ ! -s "$CAPTURE_STDOUT" ]; then
  pass "tool lock has a closed grammar and exact platform matrix"
else
  fail "tool lock accepted an unknown record (rc=$CAPTURE_RC)"
fi

capture relative-root env AGENT_LAB_CEDAR_TOOL_DIR=relative-cache \
  "$copy_root/scripts/dev/cedar-tool" provision
if [ "$CAPTURE_RC" -eq 125 ] && [ ! -e "$repo_root/relative-cache" ]; then
  pass "cache overrides must be absolute and outside tracked paths"
else
  fail "relative cache override was accepted (rc=$CAPTURE_RC)"
fi

capture extra-provision-argument "$cedar_tool" provision unexpected
if [ "$CAPTURE_RC" -eq 125 ] && [ ! -s "$CAPTURE_STDOUT" ]; then
  pass "provisioning rejects additional arguments"
else
  fail "provisioning accepted an additional argument (rc=$CAPTURE_RC)"
fi

if python3 - "$helper" "$work" <<'PY'
from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stdout
from hashlib import sha256
from importlib.util import module_from_spec, spec_from_file_location
from io import BytesIO, StringIO
from pathlib import Path
from types import SimpleNamespace
import os
import sys
import tarfile

helper = Path(sys.argv[1])
work = Path(sys.argv[2])

def load(name):
    spec = spec_from_file_location(name, helper)
    assert spec is not None and spec.loader is not None
    module = module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module

module = load("cedar_tool_descriptor_contract")
module.cache_root = lambda repo_root: Path("/cache")
module.binary_path = lambda root, lock, key: Path("/cache/cedar")
module.open_directory_chain = lambda path, create: 71
module.verified_descriptor = lambda directory, name, digest: 73

class ExecObserved(Exception):
    pass

observed = {}
def fake_execve(target, arguments, environment):
    observed.update(target=target, arguments=arguments, environment=environment)
    raise ExecObserved

closed = []
module.os = SimpleNamespace(
    close=closed.append,
    environ={"SAFE": "1"},
    execve=fake_execve,
    supports_fd={fake_execve},
)
artifact = module.Artifact("0" * 64, "1" * 64)
lock_value = module.Lock("4.12.0", {("linux", "amd64"): artifact})
try:
    module.execute(Path("/repo"), lock_value, ("linux", "amd64"), ["--version"])
except ExecObserved:
    pass
else:
    raise AssertionError("descriptor execution was not attempted")
assert closed == [71, 73]
assert observed["target"] == 73
assert observed["arguments"] == ["/cache/cedar", "--version"]
assert observed["environment"] == {"SAFE": "1"}

module = load("cedar_tool_path_fallback_contract")
target = work / "fallback-cedar"
target.write_bytes(b"reviewed fallback bytes")
target.chmod(0o555)
descriptor = os.open(target, os.O_RDONLY)
observed = {}
real_execve = module.os.execve
real_supports_fd = module.os.supports_fd
module.os.execve = fake_execve
module.os.supports_fd = set()
try:
    module.execute_verified(descriptor, target, ["--version"], {"SAFE": "1"})
except ExecObserved:
    pass
else:
    raise AssertionError("verified-path execution fallback was not attempted")
assert observed["target"] == str(target)
assert observed["arguments"] == [str(target), "--version"]

descriptor = os.open(target, os.O_RDONLY)
replacement = work / "replacement-cedar"
replacement.write_bytes(b"substituted fallback bytes")
replacement.chmod(0o555)
os.replace(replacement, target)
observed.clear()
try:
    module.execute_verified(descriptor, target, ["--version"], {"SAFE": "1"})
except module.ToolError:
    pass
else:
    raise AssertionError("verified-path identity substitution was accepted")
assert observed == {}
module.os.execve = real_execve
module.os.supports_fd = real_supports_fd

module = load("cedar_tool_directory_contract")
checked = work / "checked-platform"
parked = work / "parked-platform"
outside = work / "outside-platform"
checked.mkdir()
outside.mkdir()
directory = module.open_directory_chain(checked, create=False)
checked.rename(parked)
checked.symlink_to(outside, target_is_directory=True)
try:
    module.install_binary(directory, "cedar", b"directory-bound")
finally:
    os.close(directory)
assert (parked / "cedar").read_bytes() == b"directory-bound"
assert not (outside / "cedar").exists()

module = load("cedar_tool_archive_contract")
module.MAX_BINARY_BYTES = 64
module.MAX_ARCHIVE_MEMBERS = 8
module.MAX_EXPANDED_ARCHIVE_BYTES = 256
expected = "cedar-policy-cli-x86_64-unknown-linux-gnu/cedar"

def archive(entries):
    output = BytesIO()
    with tarfile.open(fileobj=output, mode="w:xz") as bundle:
        for name, kind, data in entries:
            member = tarfile.TarInfo(name)
            if kind == "file":
                member.size = len(data)
                member.mode = 0o755
                bundle.addfile(member, BytesIO(data))
            elif kind == "symlink":
                member.type = tarfile.SYMTYPE
                member.linkname = "elsewhere"
                bundle.addfile(member)
            else:
                raise AssertionError(kind)
    return output.getvalue()

binary = b"exact Cedar release binary"
valid = archive([
    ("cedar-policy-cli-x86_64-unknown-linux-gnu/README.md", "file", b"notice"),
    (expected, "file", binary),
])
assert module.extract_binary(valid, expected) == binary

invalid_archives = [
    b"not an xz archive",
    archive([("cedar", "file", binary)]),
    archive([(expected, "symlink", b"")]),
    archive([(expected, "file", binary), (expected, "file", binary)]),
    archive([(expected, "file", b"x" * 65)]),
    archive([(f"extra-{index}", "file", b"") for index in range(9)]),
    archive(
        [(expected, "file", binary)]
        + [(f"expanded-{index}", "file", b"x" * 60) for index in range(4)]
    ),
]
for value in invalid_archives:
    try:
        module.extract_binary(value, expected)
    except module.ToolError:
        pass
    else:
        raise AssertionError("unsafe archive shape was accepted")

class BoundedResponse:
    def __init__(self):
        self.chunks = iter((b"123", b"456", b""))
    def read(self, size):
        return next(self.chunks)

try:
    module.read_bounded(BoundedResponse(), 5)
except module.ToolError:
    pass
else:
    raise AssertionError("overlong download was accepted")

module = load("cedar_tool_archive_checksum_contract")
key = module.current_platform()
checksum_cache = work / "archive-checksum-cache"
module.cache_root = lambda repo_root: checksum_cache
downloaded = b"downloaded archive bytes"
artifact = module.Artifact("0" * 64, sha256(b"binary").hexdigest())
lock_value = module.Lock("9.9.9", {key: artifact})
module.download_archive = lambda url: downloaded
module.extract_binary = lambda value, member: (_ for _ in ()).throw(
    AssertionError("unverified archive reached extraction")
)
try:
    module.provision(Path("/unused"), lock_value, key)
except module.ToolError:
    pass
else:
    raise AssertionError("archive checksum mismatch was accepted")
assert not (checksum_cache / "9.9.9" / f"{key[0]}_{key[1]}" / "cedar").exists()

module = load("cedar_tool_binary_checksum_contract")
key = module.current_platform()
checksum_cache = work / "binary-checksum-cache"
module.cache_root = lambda repo_root: checksum_cache
downloaded = b"verified archive bytes"
extracted = b"untrusted extracted bytes"
artifact = module.Artifact(sha256(downloaded).hexdigest(), "1" * 64)
lock_value = module.Lock("9.9.9", {key: artifact})
module.download_archive = lambda url: downloaded
module.extract_binary = lambda value, member: extracted
try:
    module.provision(Path("/unused"), lock_value, key)
except module.ToolError:
    pass
else:
    raise AssertionError("binary checksum mismatch was accepted")
assert not (checksum_cache / "9.9.9" / f"{key[0]}_{key[1]}" / "cedar").exists()

module = load("cedar_tool_provision_contract")
cache = work / "provision-cache"
key = module.current_platform()
binary = b"deterministic provisioned Cedar fixture"
release_archive = b"deterministic release archive fixture"
artifact = module.Artifact(
    sha256(release_archive).hexdigest(),
    sha256(binary).hexdigest(),
)
lock_value = module.Lock("9.9.9", {key: artifact})
module.cache_root = lambda repo_root: cache
expected_member = module.archive_member(key)
module.extract_binary = lambda value, member: (
    binary if member == expected_member else (_ for _ in ()).throw(AssertionError(member))
)

platform_directory = cache / lock_value.version / f"{key[0]}_{key[1]}"
platform_directory.mkdir(parents=True)
(platform_directory / ".cedar.interrupted").write_bytes(b"orphan")

from threading import Barrier
barrier = Barrier(2)
def download(url):
    assert url.endswith(f"/{module.archive_name(key)}")
    barrier.wait(timeout=5)
    return release_archive
module.download_archive = download

def run_provision():
    module.provision(Path("/unused"), lock_value, key)

with redirect_stdout(StringIO()):
    with ThreadPoolExecutor(max_workers=2) as executor:
        futures = [executor.submit(run_provision) for _ in range(2)]
        for future in futures:
            future.result(timeout=10)

target = platform_directory / "cedar"
assert target.read_bytes() == binary
assert target.stat().st_mode & 0o777 == 0o555
assert (platform_directory / ".cedar.interrupted").read_bytes() == b"orphan"
PY
then
  pass "archives, execution, and provisioning honor bounded identity contracts"
else
  fail "archive, execution, or provisioning violated its identity contract"
fi

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
