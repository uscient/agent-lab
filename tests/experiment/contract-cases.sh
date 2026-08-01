#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
experiment="$repo_root/scripts/experiment"
cue_tool="$repo_root/scripts/dev/cue-tool"
fixture_root="$repo_root/tests/experiment/fixtures"

for required in \
  "$experiment" \
  "$cue_tool" \
  "$repo_root/scripts/dev/cue-tool.py" \
  "$repo_root/contracts/experiment/v0alpha1/schema.cue" \
  "$repo_root/contracts/experiment/v0alpha1/plan.cue" \
  "$repo_root/contracts/experiment/v0alpha1/cue.mod/module.cue" \
  "$repo_root/tools/cue.lock"; do
  if [ ! -f "$required" ]; then
    printf 'INFRA Experiment contract input is missing: %s\n' "$required" >&2
    exit 125
  fi
done
if [ ! -x "$experiment" ] || [ ! -x "$cue_tool" ]; then
  printf 'INFRA Experiment contract entrypoints are not executable\n' >&2
  exit 125
fi
cue_preflight_rc=0
cue_preflight_out="$("$cue_tool" version 2>&1)" || cue_preflight_rc=$?
if [ "$cue_preflight_rc" -ne 0 ]; then
  printf 'INFRA Experiment contract requires provisioned pinned CUE: %s\n' \
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
mkdir -p "$work/bin" "$work/home" "$work/runtime-tmp"

spy_log="$work/tool-spy.log"
: > "$spy_log"
repo_before="$work/repo.before"
git -C "$repo_root" status --porcelain=v1 --untracked-files=all > "$repo_before"
for tool in docker docker-compose podman; do
  spy="$work/bin/$tool"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$0 $*" >> %q\n' "$spy_log"
    printf 'exit 97\n'
  } > "$spy"
  chmod +x "$spy"
done

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

tree_fingerprint() {
  python3 - "$1" <<'PY'
from hashlib import sha256
from pathlib import Path
import os
import stat
import sys

root = Path(sys.argv[1])
if not root.exists():
    print("missing")
    raise SystemExit(0)
for path in sorted(root.rglob("*"), key=lambda item: os.fsencode(item)):
    relative = os.fsencode(path.relative_to(root))
    metadata = path.lstat()
    if stat.S_ISREG(metadata.st_mode):
        kind = b"file"
        payload = sha256(path.read_bytes()).digest()
    elif stat.S_ISDIR(metadata.st_mode):
        kind = b"directory"
        payload = b""
    elif stat.S_ISLNK(metadata.st_mode):
        kind = b"symlink"
        payload = os.fsencode(os.readlink(path))
    else:
        kind = b"other"
        payload = b""
    record = b"\0".join((relative, kind, str(stat.S_IMODE(metadata.st_mode)).encode(), payload))
    print(sha256(record).hexdigest())
PY
}

cue_cache="$repo_root/.cache/dev/tools/cue"
cache_before="$work/cache.before"
tree_fingerprint "$cue_cache" > "$cache_before"

contract_sha256() {
  python3 - "$repo_root" <<'PY'
from hashlib import sha256
from pathlib import Path
import sys

root = Path(sys.argv[1])
names = sorted((
    "contracts/experiment/v0alpha1/cue.mod/module.cue",
    "contracts/experiment/v0alpha1/plan.cue",
    "contracts/experiment/v0alpha1/schema.cue",
    "tools/cue.lock",
))
digest = sha256(b"agent-lab.contract.v1\0")
for name in names:
    encoded = name.encode("utf-8")
    data = (root / name).read_bytes()
    digest.update(len(encoded).to_bytes(4, "big"))
    digest.update(encoded)
    digest.update(len(data).to_bytes(8, "big"))
    digest.update(data)
print(digest.hexdigest())
PY
}

capture() {
  local name="$1"
  shift
  CAPTURE_STDOUT="$work/$name.stdout"
  CAPTURE_STDERR="$work/$name.stderr"
  CAPTURE_RC=0
  env -i \
    PATH="$work/bin:/usr/bin:/bin" \
    HOME="$work/home" \
    TMPDIR="$work/runtime-tmp" \
    LC_ALL=C \
    EXPERIMENT_TOOL_SPY_LOG="$spy_log" \
    "$@" > "$CAPTURE_STDOUT" 2> "$CAPTURE_STDERR" || CAPTURE_RC=$?
}

expect_invalid() {
  local id="$1" path="$2" detail="$3"
  capture "$id" "$experiment" check -- "$path"
  if [ "$CAPTURE_RC" -eq 1 ] && [ ! -s "$CAPTURE_STDOUT" ] &&
     grep -Fq 'FAIL Experiment manifest' "$CAPTURE_STDERR"; then
    pass "$detail"
  else
    fail "$detail (rc=$CAPTURE_RC)"
  fi
}

capture usage-none "$experiment"
if [ "$CAPTURE_RC" -eq 2 ] && [ ! -s "$CAPTURE_STDOUT" ] &&
   grep -Fq 'Usage: scripts/experiment check [--] MANIFEST' "$CAPTURE_STDERR"; then
  pass "missing command has the exact usage contract"
else
  fail "missing command has the exact usage contract (rc=$CAPTURE_RC)"
fi

capture usage-extra "$experiment" check "$fixture_root/valid.json" extra
if [ "$CAPTURE_RC" -eq 2 ] && [ ! -s "$CAPTURE_STDOUT" ]; then
  pass "extra CLI arguments fail as usage"
else
  fail "extra CLI arguments fail as usage (rc=$CAPTURE_RC)"
fi

expected_contract_digest="$(contract_sha256)"
expected_plan="$(
  jq -cS --arg digest "sha256:$expected_contract_digest" \
    '.contract.digest = $digest' "$fixture_root/expected-plan.json"
)"
expected_digest="$(printf '%s' "$expected_plan" | sha256_stdin)"
expected_envelope="$(
  jq -cnS \
    --arg digest "sha256:$expected_digest" \
    --argjson plan "$expected_plan" \
    '{digest: $digest, plan: $plan}'
)"

capture valid "$experiment" check -- "$fixture_root/valid.json"
if [ "$CAPTURE_RC" -eq 0 ] && [ ! -s "$CAPTURE_STDERR" ] &&
   [ "$(cat "$CAPTURE_STDOUT")" = "$expected_envelope" ] &&
   [ "$(wc -l < "$CAPTURE_STDOUT" | tr -d ' ')" -eq 1 ]; then
  pass "valid manifest emits the exact canonical plan envelope"
else
  fail "valid manifest emits the exact canonical plan envelope (rc=$CAPTURE_RC)"
fi

capture reordered "$experiment" check -- "$fixture_root/valid-reordered.json"
if [ "$CAPTURE_RC" -eq 0 ] && [ ! -s "$CAPTURE_STDERR" ] &&
   cmp -s "$CAPTURE_STDOUT" "$work/valid.stdout"; then
  pass "field order, member order, whitespace, and explicit defaults are non-semantic"
else
  fail "equivalent reordered manifest changes the plan (rc=$CAPTURE_RC)"
fi

if python3 - "$repo_root" "$fixture_root/valid.json" <<'PY'
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import json
import subprocess
import sys
from types import SimpleNamespace

root = Path(sys.argv[1])
spec = spec_from_file_location("experiment_contract", root / "scripts/experiment.py")
assert spec is not None and spec.loader is not None
module = module_from_spec(spec)
spec.loader.exec_module(module)
manifest = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
digest, snapshot = module.contract_snapshot(root)
helper = (root / "scripts/dev/cue-tool.py").read_bytes()
private_roots = []

subprocess_calls = []
def fake_run(command, **kwargs):
    subprocess_calls.append((command, kwargs))
    return subprocess.CompletedProcess(command, 1, b"", b"")

real_subprocess = module.subprocess
module.subprocess = SimpleNamespace(
    PIPE=subprocess.PIPE,
    SubprocessError=subprocess.SubprocessError,
    run=fake_run,
)
private = Path("/private-validation-root")
module.invoke_cue(
    manifest,
    digest,
    private,
    root,
    private / "contracts/experiment/v0alpha1",
)
module.subprocess = real_subprocess
assert len(subprocess_calls) == 1
command = subprocess_calls[0][0]
assert command[:3] == (
    sys.executable,
    "-I",
    str(private / "scripts/dev/cue-tool.py"),
)
assert command[command.index("-C") + 1] == str(
    private / "contracts/experiment/v0alpha1"
)
assert not {"docker", "docker-compose", "podman"}.intersection(command)

def fake_invoke(value, actual_digest, validation_root, repo_root, contract_root):
    assert actual_digest == digest
    assert repo_root == root
    assert validation_root != root
    assert contract_root == validation_root / "contracts/experiment/v0alpha1"
    for name, data in snapshot.items():
        assert (validation_root / name).read_bytes() == data
    assert (validation_root / "scripts/dev/cue-tool.py").read_bytes() == helper
    private_roots.append(validation_root)
    plan = module.expected_plan(value, actual_digest)
    return subprocess.CompletedProcess([], 0, module.canonical_json(plan) + b"\n", b"")

module.invoke_cue = fake_invoke
module.cue_plan(manifest)
assert len(private_roots) == 2
assert private_roots[0] == private_roots[1]
assert not private_roots[0].exists()
PY
then
  pass "orchestration invokes only CUE over the exact hashed private snapshot"
else
  fail "orchestration escaped CUE or reopened live contract paths"
fi

actual_digest="$(jq -er '.digest' "$work/valid.stdout" 2>/dev/null || true)"
actual_plan="$(jq -cS '.plan' "$work/valid.stdout" 2>/dev/null || true)"
independent_digest="$(printf '%s' "$actual_plan" | sha256_stdin)"
if [ "$actual_digest" = "sha256:$independent_digest" ] &&
   [[ "$actual_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  pass "plan digest independently matches the canonical plan bytes"
else
  fail "plan digest does not match the canonical plan bytes"
fi

expect_invalid unknown "$fixture_root/invalid-unknown.json" \
  "unknown privileged member field is rejected"
expect_invalid duplicate-identical "$fixture_root/invalid-duplicate-identical.json" \
  "identical duplicate JSON key is rejected before CUE unification"
expect_invalid duplicate-escaped "$fixture_root/invalid-duplicate-escaped.json" \
  "escaped-equivalent duplicate JSON key is rejected"
expect_invalid duplicate-member "$fixture_root/invalid-duplicate-member.json" \
  "duplicate member names are rejected"
expect_invalid mutable-image "$fixture_root/invalid-mutable-image.json" \
  "mutable image reference is rejected"
expect_invalid numeric-overflow "$fixture_root/invalid-numeric-overflow.json" \
  "out-of-range JSON number is invalid input, not infrastructure uncertainty"
expect_invalid environment "$fixture_root/invalid-environment.json" \
  "generic environment cannot override future Lab-owned runtime controls"
expect_invalid empty-members "$fixture_root/invalid-empty.json" \
  "an Experiment must contain at least one member"

oversized="$work/oversized.json"
python3 - "$oversized" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_bytes(b"x" * 262_145)
PY
expect_invalid oversized "$oversized" "manifest byte limit fails closed"

deeply_nested="$work/deeply-nested.json"
python3 - "$deeply_nested" <<'PY'
from pathlib import Path
import sys

prefix = b'{"apiVersion":"agent-lab/v0alpha1","kind":"Experiment","metadata":{"name":"deep"},"spec":{"members":'
Path(sys.argv[1]).write_bytes(prefix + (b"[" * 1000) + b"null" + (b"]" * 1000) + b"}}")
PY
expect_invalid deeply-nested "$deeply_nested" \
  "excessive JSON nesting is invalid input without a traceback"

bidi="$work/bidi.json"
python3 - "$fixture_root/valid.json" "$bidi" <<'PY'
from pathlib import Path
import json
import sys

value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
value["spec"]["members"][0]["command"].append("review\N{RIGHT-TO-LEFT OVERRIDE}text")
Path(sys.argv[2]).write_text(json.dumps(value), encoding="utf-8")
PY
expect_invalid bidi "$bidi" "Unicode formatting controls are rejected"

capture missing "$experiment" check -- "$work/missing.json"
if [ "$CAPTURE_RC" -eq 125 ] && [ ! -s "$CAPTURE_STDOUT" ] &&
   grep -Fq 'INFRA Experiment manifest' "$CAPTURE_STDERR"; then
  pass "unreadable manifest is infrastructure uncertainty"
else
  fail "unreadable manifest has the wrong result (rc=$CAPTURE_RC)"
fi

ln -s "$fixture_root/valid.json" "$work/symlink.json"
capture symlink "$experiment" check -- "$work/symlink.json"
if [ "$CAPTURE_RC" -eq 125 ] && [ ! -s "$CAPTURE_STDOUT" ]; then
  pass "manifest symlinks are rejected without following them"
else
  fail "manifest symlink was followed (rc=$CAPTURE_RC)"
fi

if [ ! -s "$spy_log" ]; then
  pass "caller PATH engine shims cannot redirect Experiment validation"
else
  fail "validation invoked a caller PATH engine shim: $(tr '\n' ' ' < "$spy_log")"
fi
if [ -z "$(find "$work/home" "$work/runtime-tmp" -mindepth 1 -print -quit)" ]; then
  pass "validation creates no persistent home or runtime state"
else
  fail "validation left persistent state"
fi
git -C "$repo_root" status --porcelain=v1 --untracked-files=all > "$work/repo.after"
if cmp -s "$repo_before" "$work/repo.after"; then
  pass "validation leaves the checkout tree unchanged"
else
  fail "validation changed the checkout tree"
fi

if python3 - "$work/valid.stdout" <<'PY'
from pathlib import Path
import sys

data = Path(sys.argv[1]).read_bytes()
raise SystemExit(0 if all(byte == 10 or 32 <= byte <= 126 for byte in data) else 1)
PY
then
  pass "canonical envelope is one review-safe ASCII line"
else
  fail "canonical envelope contains raw non-ASCII or control bytes"
fi

copy_root="$work/contract-copy"
mkdir -p \
  "$copy_root/scripts/dev" \
  "$copy_root/contracts/experiment/v0alpha1/cue.mod" \
  "$copy_root/tests/experiment/fixtures" \
  "$copy_root/tools"
cp "$repo_root/scripts/experiment" "$repo_root/scripts/experiment.py" \
  "$copy_root/scripts/"
cp "$repo_root/scripts/dev/cue-tool" "$repo_root/scripts/dev/cue-tool.py" \
  "$copy_root/scripts/dev/"
cp "$repo_root/contracts/experiment/v0alpha1/schema.cue" \
  "$repo_root/contracts/experiment/v0alpha1/plan.cue" \
  "$copy_root/contracts/experiment/v0alpha1/"
cp "$repo_root/contracts/experiment/v0alpha1/cue.mod/module.cue" \
  "$copy_root/contracts/experiment/v0alpha1/cue.mod/"
cp "$repo_root/tools/cue.lock" "$copy_root/tools/"
cp "$fixture_root/valid.json" "$copy_root/tests/experiment/fixtures/"
chmod +x "$copy_root/scripts/experiment" "$copy_root/scripts/dev/cue-tool"

capture contract-before env \
  AGENT_LAB_CUE_TOOL_DIR="$repo_root/.cache/dev/tools/cue" \
  "$copy_root/scripts/experiment" check -- \
  "$copy_root/tests/experiment/fixtures/valid.json"
python3 - "$copy_root/contracts/experiment/v0alpha1/schema.cue" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("list.MaxItems(16)", "list.MaxItems(15)"), encoding="utf-8")
PY
capture contract-after env \
  AGENT_LAB_CUE_TOOL_DIR="$repo_root/.cache/dev/tools/cue" \
  "$copy_root/scripts/experiment" check -- \
  "$copy_root/tests/experiment/fixtures/valid.json"
if [ "$CAPTURE_RC" -eq 0 ] &&
   ! cmp -s "$work/contract-before.stdout" "$work/contract-after.stdout"; then
  pass "constraint-only contract changes alter the bound plan identity"
else
  fail "constraint-only contract change retained the old plan identity (rc=$CAPTURE_RC)"
fi

printf '\ninvalid: [\n' >> "$copy_root/contracts/experiment/v0alpha1/schema.cue"
capture corrupt-contract env \
  AGENT_LAB_CUE_TOOL_DIR="$repo_root/.cache/dev/tools/cue" \
  "$copy_root/scripts/experiment" check -- \
  "$copy_root/tests/experiment/fixtures/valid.json"
if [ "$CAPTURE_RC" -eq 125 ] && [ ! -s "$CAPTURE_STDOUT" ] &&
   grep -Fq 'INFRA Experiment' "$CAPTURE_STDERR"; then
  pass "corrupt trusted CUE contract is infrastructure uncertainty"
else
  fail "corrupt trusted CUE contract was blamed on the manifest (rc=$CAPTURE_RC)"
fi

if printf '%s\n' "$cue_preflight_out" | grep -Fxq 'cue version v0.17.1'; then
  pass "Experiment validation uses the pinned CUE release"
else
  fail "pinned CUE release is unavailable or wrong"
fi
if "$cue_tool" fmt --check --files \
    "$repo_root/contracts/experiment/v0alpha1/schema.cue" \
    "$repo_root/contracts/experiment/v0alpha1/plan.cue" \
    "$repo_root/contracts/experiment/v0alpha1/cue.mod/module.cue"; then
  pass "tracked CUE contract files are canonically formatted"
else
  fail "tracked CUE contract files need cue fmt"
fi
if "$cue_tool" -C "$repo_root/contracts/experiment/v0alpha1" vet -c=false ./...; then
  pass "the complete CUE module is satisfiable"
else
  fail "the complete CUE module contains a latent contradiction"
fi

cache_after="$work/cache.after"
tree_fingerprint "$cue_cache" > "$cache_after"
if cmp -s "$cache_before" "$cache_after"; then
  pass "validation leaves the ignored pinned CUE cache unchanged"
else
  fail "validation changed the ignored pinned CUE cache"
fi

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
