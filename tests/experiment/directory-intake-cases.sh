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
expect_invalid() {
  local id="$1" directory="$2" detail="$3"
  capture "$agent_lab" experiment check "$directory"
  if [ "$CAPTURE_RC" -eq 1 ] && [ ! -s "$work/stdout" ] &&
     grep -Fq 'FAIL Experiment manifest' "$work/stderr"; then
    pass "$id" "$detail"
  else
    fail "$id" "$detail"
  fi
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
cp "$fixture/experiment.cue" "$work/hardlink-source"
ln "$work/hardlink-source" "$linked/experiment.cue"
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

symlinked="$work/symlinked"
mkdir "$symlinked"
ln -s "$fixture/experiment.cue" "$symlinked/experiment.cue"
expect_invalid FMT-008 "$symlinked" "an authored symlink is refused"

mutable="$work/mutable"
mkdir "$mutable"
sed 's/@sha256:[a-f0-9]\{64\}/:latest/' "$fixture/experiment.cue" > "$mutable/experiment.cue"
expect_invalid SEL-001 "$mutable" "a mutable OCI reference is refused"

unknown="$work/unknown"
mkdir "$unknown"
sed '/kind:/a\\\tunexpected: true' "$fixture/experiment.cue" > "$unknown/experiment.cue"
expect_invalid CUE-001 "$unknown" "an unknown authored field is refused"

commented="$work/commented"
mkdir "$commented"
{ printf '// distinct source bytes\n'; cat "$fixture/experiment.cue"; } > "$commented/experiment.cue"
capture "$agent_lab" experiment check "$fixture"
cp "$work/stdout" "$work/base-candidate"
capture "$agent_lab" experiment check "$commented"
if [ "$CAPTURE_RC" -eq 0 ] &&
   [ "$(jq -cS '.plan' "$work/base-candidate")" = "$(jq -cS '.plan' "$work/stdout")" ] &&
   [ "$(jq -r '.source.digest' "$work/base-candidate")" != "$(jq -r '.source.digest' "$work/stdout")" ]; then
  pass FMT-009 "non-semantic CUE comments change source but not plan identity"
else
  fail FMT-009 "non-semantic CUE comments change source but not plan identity"
fi

if python3 -I - "$repo_root/scripts/experiment.py" "$fixture" <<'PY'
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import sys
spec = spec_from_file_location("experiment_mutant", sys.argv[1])
assert spec is not None and spec.loader is not None
module = module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
original = module.read_directory_snapshot(sys.argv[2]).digest
module.SOURCE_DIGEST_DOMAIN = b"agent-lab.insecure-unframed\0"
mutated = module.read_directory_snapshot(sys.argv[2]).digest
assert original != mutated
PY
then
  pass M-FMT-001 "source-domain mutation changes the independent identity"
else
  fail M-FMT-001 "source-domain mutation changes the independent identity"
fi

if python3 -I - "$repo_root/scripts/experiment.py" <<'PY'
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import sys
spec = spec_from_file_location("experiment_resolver", sys.argv[1])
assert spec is not None and spec.loader is not None
module = module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
subject = "registry.example/lab/base@sha256:" + "b" * 64
plan = {
    "apiVersion": "agent-lab.request/v0alpha1",
    "contract": {"digest": "sha256:" + "a" * 64, "name": "agent-lab.experiment", "version": "v0alpha1"},
    "kind": "RequestedExperimentPlan",
    "metadata": {"requestedName": "resolver-test"},
    "spec": {"members": [{
        "command": [], "name": "one", "resourceClass": "small",
        "requestedSelector": {"catalogName": "agent-lab.base"},
    }]},
}
catalog = {
    "apiVersion": "agent-lab.experiment-images/v0alpha1",
    "entries": [{"name": "agent-lab.base", "subject": subject}],
}
resolved = module.resolve_plan(plan, Path("/nonexistent"), catalog)
image = resolved["spec"]["members"][0]["resolvedImage"]
assert image["origin"] == "agent-lab"
assert image["subject"] == subject
assert image["generation"] == 1
assert image["entryDigest"].startswith("sha256:")
assert module.valid_catalog_name("vendor.image")
for invalid in ("Agent.image", "vendor.image.extra", "vendor_1.image", "a" * 32 + ".image", "vendor.é"):
    assert not module.valid_catalog_name(invalid), invalid
PY
then
  pass SEL-002 "trusted bundled resolution binds exact names, subjects, and entry identity"
else
  fail SEL-002 "trusted bundled resolution binds exact names, subjects, and entry identity"
fi

expected="$work/expected"
printf '%s\n' \
  FMT-001 FMT-002 FMT-004 FMT-005 FMT-006 FMT-007 FMT-003 \
  FMT-008 SEL-001 CUE-001 FMT-009 M-FMT-001 SEL-002 > "$expected"
if ! cmp -s "$expected" "$observed"; then
  printf 'INFRA assertion identity drift\n' >&2
  exit 125
fi
printf 'SUMMARY assertions=13 expected=13 failures=%s infra=0\n' "$failures"
[ "$failures" -eq 0 ]
