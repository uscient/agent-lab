#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
cue_tool="$repo_root/scripts/dev/cue-tool"
helper="$repo_root/scripts/dev/cue-tool.py"
lock="$repo_root/tools/cue.lock"

for required in "$cue_tool" "$helper" "$lock"; do
  if [ ! -f "$required" ]; then
    printf 'INFRA CUE tool contract input is missing: %s\n' "$required" >&2
    exit 125
  fi
done
if [ ! -x "$cue_tool" ]; then
  printf 'INFRA CUE tool entrypoint is not executable\n' >&2
  exit 125
fi
cue_preflight_rc=0
cue_preflight_out="$("$cue_tool" version 2>&1)" || cue_preflight_rc=$?
if [ "$cue_preflight_rc" -ne 0 ]; then
  printf 'INFRA CUE tool contract requires a provisioned pin: %s\n' \
    "$cue_preflight_out" >&2
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
  pass "CUE tool helper is valid isolated Python"
else
  fail "CUE tool helper is not valid Python"
fi

capture version "$cue_tool" version
if [ "$CAPTURE_RC" -eq 0 ] &&
   grep -Fxq 'cue version v0.17.1' "$CAPTURE_STDOUT" &&
   [ ! -s "$CAPTURE_STDERR" ]; then
  pass "verified cached tool executes the pinned release"
else
  fail "verified cached tool did not execute the pinned release (rc=$CAPTURE_RC)"
fi

sed_spy="$work/sed-spy.log"
: > "$sed_spy"
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "called\\n" >> %q\n' "$sed_spy"
  printf 'exec /usr/bin/sed "$@"\n'
} > "$work/bin/sed"
chmod +x "$work/bin/sed"
capture hostile-path env PATH="$work/bin:/usr/bin:/bin" "$cue_tool" version
if [ "$CAPTURE_RC" -eq 0 ] && [ ! -s "$sed_spy" ] &&
   grep -Fxq 'cue version v0.17.1' "$CAPTURE_STDOUT"; then
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
    printf 'INFRA unsupported CUE tool test platform\n' >&2
    exit 125
    ;;
esac

tampered_root="$work/tampered"
mkdir -p "$tampered_root/v0.17.1/$platform_path"
tampered="$tampered_root/v0.17.1/$platform_path/cue"
tampered_marker="$work/tampered-executed"
{
  printf '#!/usr/bin/env bash\n'
  printf ': > %q\n' "$tampered_marker"
  printf 'printf "cue version v0.17.1\\n"\n'
} > "$tampered"
chmod +x "$tampered"
capture tampered env AGENT_LAB_CUE_TOOL_DIR="$tampered_root" "$cue_tool" version
if [ "$CAPTURE_RC" -eq 125 ] && [ ! -e "$tampered_marker" ]; then
  pass "tampered cached bytes fail before execution"
else
  fail "tampered cached bytes reached execution (rc=$CAPTURE_RC)"
fi

cache_link="$work/cache-link"
ln -s "$work/outside" "$cache_link"
capture symlink-root env AGENT_LAB_CUE_TOOL_DIR="$cache_link" "$cue_tool" provision
if [ "$CAPTURE_RC" -eq 125 ] &&
   [ -z "$(find "$work/outside" -mindepth 1 -print -quit)" ]; then
  pass "provisioning rejects a symlinked cache root before writes"
else
  fail "provisioning escaped through a symlinked cache root (rc=$CAPTURE_RC)"
fi

copy_root="$work/copy"
mkdir -p "$copy_root/scripts/dev" "$copy_root/tools"
cp "$cue_tool" "$helper" "$copy_root/scripts/dev/"
cp "$lock" "$copy_root/tools/"
chmod +x "$copy_root/scripts/dev/cue-tool"
printf 'unknown record\n' >> "$copy_root/tools/cue.lock"
capture bad-lock env AGENT_LAB_CUE_TOOL_DIR="$work/unused" \
  "$copy_root/scripts/dev/cue-tool" version
if [ "$CAPTURE_RC" -eq 125 ] && [ ! -s "$CAPTURE_STDOUT" ]; then
  pass "tool lock has a closed grammar and exact platform matrix"
else
  fail "tool lock accepted an unknown record (rc=$CAPTURE_RC)"
fi

capture relative-root env AGENT_LAB_CUE_TOOL_DIR=relative-cache \
  "$copy_root/scripts/dev/cue-tool" provision
if [ "$CAPTURE_RC" -eq 125 ] && [ ! -e "$repo_root/relative-cache" ]; then
  pass "cache overrides must be absolute and outside tracked paths"
else
  fail "relative cache override was accepted (rc=$CAPTURE_RC)"
fi

if python3 - "$helper" "$work" <<'PY'
from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stdout
from hashlib import sha256
from importlib.util import module_from_spec, spec_from_file_location
from io import StringIO
from pathlib import Path
from types import SimpleNamespace
import os
import sys

helper = Path(sys.argv[1])
work = Path(sys.argv[2])

def load(name):
    spec = spec_from_file_location(name, helper)
    assert spec is not None and spec.loader is not None
    module = module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module

module = load("cue_tool_descriptor_contract")
module.cache_root = lambda repo_root: Path("/cache")
module.binary_path = lambda root, lock, key: Path("/cache/cue")
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
lock_value = module.Lock("v1.2.3", {("linux", "amd64"): artifact})
try:
    module.execute(Path("/repo"), lock_value, ("linux", "amd64"), ["version"])
except ExecObserved:
    pass
else:
    raise AssertionError("descriptor execution was not attempted")
assert closed == [71, 73]
assert observed["target"] == 73
assert observed["arguments"] == ["/cache/cue", "version"]
assert observed["environment"] == {"SAFE": "1"}

module = load("cue_tool_path_fallback_contract")
target = work / "fallback-cue"
target.write_bytes(b"reviewed fallback bytes")
target.chmod(0o555)
descriptor = os.open(target, os.O_RDONLY)
observed = {}
real_execve = module.os.execve
real_supports_fd = module.os.supports_fd
module.os.execve = fake_execve
module.os.supports_fd = set()
try:
    module.execute_verified(descriptor, target, ["version"], {"SAFE": "1"})
except ExecObserved:
    pass
else:
    raise AssertionError("verified-path execution fallback was not attempted")
assert observed["target"] == str(target)
assert observed["arguments"] == [str(target), "version"]

descriptor = os.open(target, os.O_RDONLY)
replacement = work / "replacement-cue"
replacement.write_bytes(b"substituted fallback bytes")
replacement.chmod(0o555)
os.replace(replacement, target)
observed.clear()
try:
    module.execute_verified(descriptor, target, ["version"], {"SAFE": "1"})
except module.ToolError:
    pass
else:
    raise AssertionError("verified-path identity substitution was accepted")
assert observed == {}
module.os.execve = real_execve
module.os.supports_fd = real_supports_fd

module = load("cue_tool_directory_contract")
checked = work / "checked-platform"
parked = work / "parked-platform"
outside = work / "outside-platform"
checked.mkdir()
outside.mkdir()
directory = module.open_directory_chain(checked, create=False)
checked.rename(parked)
checked.symlink_to(outside, target_is_directory=True)
try:
    module.install_binary(directory, "cue", b"directory-bound")
finally:
    os.close(directory)
assert (parked / "cue").read_bytes() == b"directory-bound"
assert not (outside / "cue").exists()

module = load("cue_tool_provision_contract")
cache = work / "provision-cache"
key = module.current_platform()
binary = b"deterministic provisioned CUE fixture"
archive = b"deterministic release archive fixture"
artifact = module.Artifact(sha256(archive).hexdigest(), sha256(binary).hexdigest())
lock_value = module.Lock("v9.9.9", {key: artifact})
module.cache_root = lambda repo_root: cache
module.extract_binary = lambda value: binary

platform_directory = cache / lock_value.version / f"{key[0]}_{key[1]}"
platform_directory.mkdir(parents=True)
(platform_directory / ".cue.interrupted").write_bytes(b"orphan")

from threading import Barrier
barrier = Barrier(2)
def download(url):
    barrier.wait(timeout=5)
    return archive
module.download_archive = download

def run_provision():
    module.provision(Path("/unused"), lock_value, key)

with redirect_stdout(StringIO()):
    with ThreadPoolExecutor(max_workers=2) as executor:
        futures = [executor.submit(run_provision) for _ in range(2)]
        for future in futures:
            future.result(timeout=10)

target = platform_directory / "cue"
assert target.read_bytes() == binary
assert target.stat().st_mode & 0o777 == 0o555
assert (platform_directory / ".cue.interrupted").read_bytes() == b"orphan"
PY
then
  pass "execution uses checked descriptors or the verified-inode fallback"
else
  fail "execution or provisioning escaped its verified binary identity"
fi

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
