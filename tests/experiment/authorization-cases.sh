#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
experiment="$repo_root/scripts/experiment"
cedar_tool="$repo_root/scripts/dev/cedar-tool"
fixture_root="$repo_root/tests/experiment/fixtures"

work="$(mktemp -d)"
cleanup() {
  find "$work" -type f -delete 2>/dev/null || true
  find "$work" -type l -delete 2>/dev/null || true
  find "$work" -depth -type d -exec rmdir {} + 2>/dev/null || true
}
trap cleanup EXIT
mkdir -p "$work/bin" "$work/home" "$work/runtime-tmp"

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

spy_log="$work/tool-spy.log"
: > "$spy_log"
for tool in docker docker-compose podman curl wget; do
  spy="$work/bin/$tool"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$0 $*" >> %q\n' "$spy_log"
    printf 'exit 97\n'
  } > "$spy"
  chmod +x "$spy"
done

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
    AGENT_LAB_CUE_TOOL_DIR="${AGENT_LAB_CUE_TOOL_DIR:-$repo_root/.cache/dev/tools/cue}" \
    AGENT_LAB_CEDAR_TOOL_DIR="${AGENT_LAB_CEDAR_TOOL_DIR:-$repo_root/.cache/dev/tools/cedar}" \
    "$@" > "$CAPTURE_STDOUT" 2> "$CAPTURE_STDERR" || CAPTURE_RC=$?
}

capture usage-authorize "$experiment" authorize
if [ "$CAPTURE_RC" -eq 2 ] && [ ! -s "$CAPTURE_STDOUT" ] &&
   grep -Fq 'Usage: scripts/experiment authorize install [--] MANIFEST' "$CAPTURE_STDERR"; then
  pass "authorize requires one bounded install request"
else
  fail "authorize usage is not exposed exactly (rc=$CAPTURE_RC)"
fi

capture usage-action "$experiment" authorize start -- "$fixture_root/valid.json"
if [ "$CAPTURE_RC" -eq 2 ] && [ ! -s "$CAPTURE_STDOUT" ]; then
  pass "runtime lifecycle actions are outside the requested-plan seam"
else
  fail "authorize accepted a runtime lifecycle action (rc=$CAPTURE_RC)"
fi

capture usage-override "$experiment" authorize install --principal attacker "$fixture_root/valid.json"
if [ "$CAPTURE_RC" -eq 2 ] && [ ! -s "$CAPTURE_STDOUT" ]; then
  pass "the public command rejects caller-selected Cedar inputs"
else
  fail "authorize accepted a caller-selected Cedar input (rc=$CAPTURE_RC)"
fi

for required in \
  "$cedar_tool" \
  "$repo_root/scripts/dev/cedar-tool.py" \
  "$repo_root/tools/cedar.lock" \
  "$repo_root/authorization/experiment/v0alpha1/schema.cedarschema" \
  "$repo_root/authorization/experiment/v0alpha1/operator.cedar"; do
  if [ ! -f "$required" ]; then
    printf 'INFRA Experiment authorization input is missing: %s\n' "$required" >&2
    exit 125
  fi
done
if [ ! -x "$experiment" ] || [ ! -x "$cedar_tool" ]; then
  printf 'INFRA Experiment authorization entrypoints are not executable\n' >&2
  exit 125
fi

cedar_preflight_rc=0
cedar_preflight_out="$($cedar_tool --version 2>&1)" || cedar_preflight_rc=$?
if [ "$cedar_preflight_rc" -ne 0 ]; then
  printf 'INFRA Experiment authorization requires provisioned pinned Cedar: %s\n' \
    "$cedar_preflight_out" >&2
  exit 125
fi

repo_before="$work/repo.before"
git -C "$repo_root" status --porcelain=v1 --untracked-files=all > "$repo_before"

authorization_sha256() {
  python3 - "$repo_root" <<'PY'
from hashlib import sha256
from pathlib import Path
import sys

root = Path(sys.argv[1])
names = sorted((
    "authorization/experiment/v0alpha1/operator.cedar",
    "authorization/experiment/v0alpha1/schema.cedarschema",
    "tools/cedar.lock",
))
digest = sha256(b"agent-lab.authorization-contract.v1\0")
for name in names:
    encoded = name.encode("utf-8")
    data = (root / name).read_bytes()
    digest.update(len(encoded).to_bytes(4, "big"))
    digest.update(encoded)
    digest.update(len(data).to_bytes(8, "big"))
    digest.update(data)
print(f"sha256:{digest.hexdigest()}")
PY
}

capture checked "$experiment" check -- "$fixture_root/valid.json"
if [ "$CAPTURE_RC" -ne 0 ] || [ -s "$CAPTURE_STDERR" ]; then
  printf 'INFRA baseline CUE contract failed before authorization tests\n' >&2
  exit 125
fi
capture permitted "$experiment" authorize install -- "$fixture_root/valid.json"

checked_plan_digest="$(jq -er '.digest' "$work/checked.stdout" 2>/dev/null || true)"
checked_contract_digest="$(jq -er '.plan.contract.digest' "$work/checked.stdout" 2>/dev/null || true)"
expected_authorization_digest="$(authorization_sha256)"
if [ "$CAPTURE_RC" -eq 0 ] && [ ! -s "$CAPTURE_STDERR" ] &&
   jq -e \
     --arg plan "$checked_plan_digest" \
     --arg contract "$checked_contract_digest" \
     --arg authorization "$expected_authorization_digest" '
       .apiVersion == "agent-lab.authorization/v0alpha1" and
       .kind == "ExperimentAuthorizationDecision" and
       .verdict == "permit" and
       .action == "experiment.install" and
       .principal == {
         assurance: "none",
         authenticated: false,
         id: "legacy-local-operator",
         source: "fixed-local-cli",
         type: "AgentLab::Principal"
       } and
       .binding == {
         authorizationDigest: $authorization,
         contractDigest: $contract,
         planDigest: $plan
       } and
       .resource == {
         id: $plan,
         requestedName: "first-experiment",
         type: "AgentLab::RequestedExperimentPlan"
       }
     ' "$CAPTURE_STDOUT" >/dev/null 2>&1; then
  pass "Cedar permits the fixed operator for the exact CUE plan"
else
  fail "Cedar did not bind its permit to the exact CUE plan (rc=$CAPTURE_RC)"
fi

if [ "$(wc -l < "$work/permitted.stdout" | tr -d ' ')" -eq 1 ] &&
   [ "$(jq -cS . "$work/permitted.stdout" 2>/dev/null || true)" = "$(cat "$work/permitted.stdout")" ] &&
   LC_ALL=C grep -Eq '^[ -~]+$' "$work/permitted.stdout"; then
  pass "the authorization decision is one canonical review-safe ASCII line"
else
  fail "the authorization decision is not canonical ASCII"
fi

capture reordered "$experiment" authorize install -- "$fixture_root/valid-reordered.json"
if [ "$CAPTURE_RC" -eq 0 ] && [ ! -s "$CAPTURE_STDERR" ] &&
   cmp -s "$work/permitted.stdout" "$CAPTURE_STDOUT"; then
  pass "equivalent manifests authorize the same requested plan"
else
  fail "equivalent manifests changed authorization identity (rc=$CAPTURE_RC)"
fi

different="$work/different.json"
jq '.spec.members[1].resourceClass = "standard"' "$fixture_root/valid.json" > "$different"
capture different "$experiment" authorize install -- "$different"
different_plan_digest="$(jq -er '.binding.planDigest' "$CAPTURE_STDOUT" 2>/dev/null || true)"
if [ "$CAPTURE_RC" -eq 0 ] && [ ! -s "$CAPTURE_STDERR" ] &&
   [ "$(jq -r '.resource.requestedName' "$CAPTURE_STDOUT" 2>/dev/null || true)" = first-experiment ] &&
   [ -n "$different_plan_digest" ] && [ "$different_plan_digest" != "$checked_plan_digest" ] &&
   [ "$(jq -r '.resource.id' "$CAPTURE_STDOUT" 2>/dev/null || true)" = "$different_plan_digest" ]; then
  pass "same-name different intent receives a different digest resource"
else
  fail "requested name became authorization identity (rc=$CAPTURE_RC)"
fi

capture envelope "$experiment" authorize install -- "$work/checked.stdout"
if [ "$CAPTURE_RC" -eq 1 ] && [ ! -s "$CAPTURE_STDOUT" ] &&
   grep -Fq 'FAIL Experiment manifest' "$CAPTURE_STDERR"; then
  pass "authorize revalidates manifest intent instead of accepting an envelope"
else
  fail "authorize accepted or mishandled a caller-supplied plan envelope (rc=$CAPTURE_RC)"
fi

copy_root="$work/authorization-copy"
mkdir -p \
  "$copy_root/scripts/dev" \
  "$copy_root/contracts/experiment/v0alpha1/cue.mod" \
  "$copy_root/authorization/experiment/v0alpha1" \
  "$copy_root/tests/experiment/fixtures" \
  "$copy_root/tools"
cp "$repo_root/scripts/experiment" "$repo_root/scripts/experiment.py" \
  "$copy_root/scripts/"
cp "$repo_root/scripts/dev/cue-tool" "$repo_root/scripts/dev/cue-tool.py" \
  "$repo_root/scripts/dev/cedar-tool.py" "$copy_root/scripts/dev/"
cp "$repo_root/contracts/experiment/v0alpha1/schema.cue" \
  "$repo_root/contracts/experiment/v0alpha1/plan.cue" \
  "$copy_root/contracts/experiment/v0alpha1/"
cp "$repo_root/contracts/experiment/v0alpha1/cue.mod/module.cue" \
  "$copy_root/contracts/experiment/v0alpha1/cue.mod/"
cp "$repo_root/authorization/experiment/v0alpha1/schema.cedarschema" \
  "$repo_root/authorization/experiment/v0alpha1/operator.cedar" \
  "$copy_root/authorization/experiment/v0alpha1/"
cp "$repo_root/tools/cue.lock" "$repo_root/tools/cedar.lock" "$copy_root/tools/"
cp "$fixture_root/valid.json" "$copy_root/tests/experiment/fixtures/"
chmod +x "$copy_root/scripts/experiment" "$copy_root/scripts/dev/cue-tool"

printf '%s\n' \
  '' \
  '@id("emergency-stop-v0")' \
  'forbid (principal, action, resource);' >> \
  "$copy_root/authorization/experiment/v0alpha1/operator.cedar"
capture public-deny env \
  AGENT_LAB_CUE_TOOL_DIR="${AGENT_LAB_CUE_TOOL_DIR:-$repo_root/.cache/dev/tools/cue}" \
  AGENT_LAB_CEDAR_TOOL_DIR="${AGENT_LAB_CEDAR_TOOL_DIR:-$repo_root/.cache/dev/tools/cedar}" \
  "$copy_root/scripts/experiment" authorize install -- \
  "$copy_root/tests/experiment/fixtures/valid.json"
if [ "$CAPTURE_RC" -eq 1 ] && [ ! -s "$CAPTURE_STDERR" ] &&
   [ "$(jq -r '.verdict' "$CAPTURE_STDOUT" 2>/dev/null || true)" = deny ] &&
   [ "$(jq -r '.binding.planDigest' "$CAPTURE_STDOUT" 2>/dev/null || true)" = "$checked_plan_digest" ] &&
   [ "$(jq -cS . "$CAPTURE_STDOUT" 2>/dev/null || true)" = "$(cat "$CAPTURE_STDOUT")" ]; then
  pass "a strict repository forbid produces one canonical ordinary deny"
else
  fail "ordinary Cedar deny was not translated canonically (rc=$CAPTURE_RC)"
fi

printf '\nthis is not Cedar\n' >> \
  "$copy_root/authorization/experiment/v0alpha1/operator.cedar"
capture corrupt-policy env \
  AGENT_LAB_CUE_TOOL_DIR="${AGENT_LAB_CUE_TOOL_DIR:-$repo_root/.cache/dev/tools/cue}" \
  AGENT_LAB_CEDAR_TOOL_DIR="${AGENT_LAB_CEDAR_TOOL_DIR:-$repo_root/.cache/dev/tools/cedar}" \
  "$copy_root/scripts/experiment" authorize install -- \
  "$copy_root/tests/experiment/fixtures/valid.json"
if [ "$CAPTURE_RC" -eq 125 ] && [ ! -s "$CAPTURE_STDOUT" ] &&
   grep -Fq 'INFRA Experiment strict Cedar policy validation was not exact' "$CAPTURE_STDERR"; then
  pass "invalid trusted policy is infrastructure uncertainty, never a deny"
else
  fail "invalid trusted policy was translated as a decision (rc=$CAPTURE_RC)"
fi

if python3 - "$repo_root" "$fixture_root/valid.json" <<'PY'
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import json
import os
import signal
import subprocess
import sys

root = Path(sys.argv[1])
spec = spec_from_file_location("experiment_authorization", root / "scripts/experiment.py")
assert spec is not None and spec.loader is not None
module = module_from_spec(spec)
spec.loader.exec_module(module)

manifest = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
plan = module.cue_plan(manifest)
binding = module.plan_binding(plan)
request, entities = module.cedar_documents(binding)
authorization_digest, snapshot = module.authorization_snapshot(root)

assert binding.plan_digest == request["context"]["planDigest"]
assert request["resource"] == (
    f'AgentLab::RequestedExperimentPlan::"{binding.plan_digest}"'
)
assert request["principal"] == (
    'AgentLab::Principal::"legacy-local-operator"'
)

observed_helpers = []
observed_arguments = []
real_invoke = module.invoke_cedar
def observing_invoke(helper, arguments, repository):
    observed_helpers.append(helper)
    observed_arguments.append(arguments)
    assert str(helper).startswith("/tmp/agent-lab-authorization-")
    assert helper.read_bytes() == snapshot[module.CEDAR_HELPER]
    return real_invoke(helper, arguments, repository)
module.invoke_cedar = observing_invoke
assert module.evaluate_cedar(snapshot, request, entities, root) == "permit"
assert len(observed_helpers) == 2
assert observed_arguments[0][2] == "validate"
assert "--deny-warnings" in observed_arguments[0]
assert observed_arguments[0][observed_arguments[0].index("--validation-mode") + 1] == "strict"
assert observed_arguments[1][2] == "authorize"
assert observed_arguments[1][observed_arguments[1].index("--request-validation") + 1] == "true"
module.invoke_cedar = real_invoke

alternate_request = dict(request)
alternate_request["principal"] = 'AgentLab::Principal::"intruder"'
alternate_entities = json.loads(json.dumps(entities))
alternate_entities.append({
    "uid": {"type": "AgentLab::Principal", "id": "intruder"},
    "attrs": {"authenticated": False, "assurance": "none", "source": "fixed-local-cli"},
    "parents": [],
})
assert module.evaluate_cedar(snapshot, alternate_request, alternate_entities, root) == "deny"

mismatch_request = json.loads(json.dumps(request))
mismatch_request["context"]["planDigest"] = "sha256:" + ("f" * 64)
assert module.evaluate_cedar(snapshot, mismatch_request, entities, root) == "deny"

contract_request = json.loads(json.dumps(request))
contract_request["context"]["contractDigest"] = "sha256:" + ("e" * 64)
assert module.evaluate_cedar(snapshot, contract_request, entities, root) == "deny"

version_request = json.loads(json.dumps(request))
version_request["context"]["bindingVersion"] = "v0alpha2"
assert module.evaluate_cedar(snapshot, version_request, entities, root) == "deny"

empty = dict(snapshot)
empty["authorization/experiment/v0alpha1/operator.cedar"] = b""
assert module.evaluate_cedar(empty, request, entities, root) == "deny"

forbidden = dict(snapshot)
forbidden["authorization/experiment/v0alpha1/operator.cedar"] += b'''\n@id("emergency-stop-v0")
forbid (principal, action, resource);\n'''
assert module.evaluate_cedar(forbidden, request, entities, root) == "deny"

completed = subprocess.CompletedProcess([], 0, b"\nALLOW\n", b"")
assert module.parse_cedar_authorization(completed) == "permit"
completed = subprocess.CompletedProcess([], 2, b"\nDENY\n", b"")
assert module.parse_cedar_authorization(completed) == "deny"
for outcome in (
    subprocess.CompletedProcess([], 0, b"ALLOW\n", b""),
    subprocess.CompletedProcess([], 0, b"\nALLOW\nextra", b""),
    subprocess.CompletedProcess([], 0, b"\nALLOW\n", b"warning"),
    subprocess.CompletedProcess([], 1, b"\nDENY\n", b""),
    subprocess.CompletedProcess([], 2, b"\nALLOW\n", b""),
    subprocess.CompletedProcess([], -9, b"", b""),
):
    try:
        module.parse_cedar_authorization(outcome)
    except module.InfrastructureError:
        pass
    else:
        raise AssertionError(f"ambiguous evaluator tuple accepted: {outcome}")

# The production runner bounds bytes while the evaluator is live and kills timeouts.
from tempfile import TemporaryDirectory
import time
control_signals = (signal.SIGHUP, signal.SIGINT, signal.SIGQUIT, signal.SIGTERM)
original_dispositions = {signum: signal.getsignal(signum) for signum in control_signals}
original_signal_mask = set(signal.pthread_sigmask(signal.SIG_BLOCK, set()))
with TemporaryDirectory(prefix="cedar-runner-cases-", dir="/tmp") as directory:
    fake = Path(directory) / "fake.py"
    original_limit = module.MAX_CEDAR_OUTPUT_BYTES
    original_timeout = module.CEDAR_TIMEOUT_SECONDS
    module.MAX_CEDAR_OUTPUT_BYTES = 1024
    fake.write_text(
        "import sys, time\n"
        "sys.stdout.buffer.write(b'x' * 2048)\n"
        "sys.stdout.buffer.flush()\n"
        "time.sleep(5)\n",
        encoding="utf-8",
    )
    started = time.monotonic()
    try:
        module.invoke_cedar(fake, (), root)
    except module.InfrastructureError as error:
        assert str(error) == "pinned Cedar emitted overlong output"
    else:
        raise AssertionError("overlong live evaluator output was accepted")
    assert time.monotonic() - started < 2

    module.MAX_CEDAR_OUTPUT_BYTES = original_limit
    module.CEDAR_TIMEOUT_SECONDS = 0.1
    fake.write_text("import time\ntime.sleep(5)\n", encoding="utf-8")
    started = time.monotonic()
    try:
        module.invoke_cedar(fake, (), root)
    except module.InfrastructureError as error:
        assert str(error) == "pinned Cedar evaluation timed out"
    else:
        raise AssertionError("evaluator timeout was accepted")
    assert time.monotonic() - started < 2
    module.MAX_CEDAR_OUTPUT_BYTES = original_limit
    module.CEDAR_TIMEOUT_SECONDS = original_timeout

    marker = Path(directory) / "cancelled.pid"
    fake.write_text(
        "from pathlib import Path\n"
        "import os, sys, time\n"
        "Path(sys.argv[1]).write_text(str(os.getpid()), encoding='ascii')\n"
        "time.sleep(30)\n",
        encoding="utf-8",
    )
    driver = Path(directory) / "driver.py"
    driver.write_text(
        "from importlib.util import module_from_spec, spec_from_file_location\n"
        "from pathlib import Path\n"
        "import sys\n"
        "spec = spec_from_file_location('cancel_contract', sys.argv[1])\n"
        "assert spec is not None and spec.loader is not None\n"
        "module = module_from_spec(spec)\n"
        "spec.loader.exec_module(module)\n"
        "module.invoke_cedar(Path(sys.argv[2]), (sys.argv[3],), Path(sys.argv[4]))\n",
        encoding="utf-8",
    )
    parent = subprocess.Popen(
        [sys.executable, str(driver), str(root / "scripts/experiment.py"),
         str(fake), str(marker), str(root)],
    )
    deadline = time.monotonic() + 2
    while not marker.exists() and parent.poll() is None and time.monotonic() < deadline:
        time.sleep(0.01)
    assert marker.exists()
    evaluator_pid = int(marker.read_text(encoding="ascii"))
    parent.terminate()
    assert parent.wait(timeout=2) == 143
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        try:
            os.kill(evaluator_pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.01)
    else:
        raise AssertionError("cancelled Cedar evaluator survived its parent")

    signal_race_failures = []
    spawn_race_pid = Path(directory) / "spawn-race.pid"
    race_driver = Path(directory) / "spawn-race-driver.py"
    race_driver.write_text(
        "from importlib.util import module_from_spec, spec_from_file_location\n"
        "from pathlib import Path\n"
        "import os, signal, sys\n"
        "spec = spec_from_file_location('spawn_race_contract', sys.argv[1])\n"
        "assert spec is not None and spec.loader is not None\n"
        "module = module_from_spec(spec)\n"
        "spec.loader.exec_module(module)\n"
        "real_popen = module.subprocess.Popen\n"
        "def signal_after_spawn(*args, **kwargs):\n"
        "    child = real_popen(*args, **kwargs)\n"
        "    Path(sys.argv[3]).write_text(str(child.pid), encoding='ascii')\n"
        "    os.kill(os.getpid(), signal.SIGTERM)\n"
        "    return child\n"
        "module.subprocess.Popen = signal_after_spawn\n"
        "module.invoke_cedar(Path(sys.argv[2]), ('unused',), Path(sys.argv[4]))\n",
        encoding="utf-8",
    )
    raced = subprocess.Popen(
        [sys.executable, str(race_driver), str(root / "scripts/experiment.py"),
         str(fake), str(spawn_race_pid), str(root)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    raced_stdout, raced_stderr = raced.communicate(timeout=2)
    assert spawn_race_pid.exists()
    raced_child = int(spawn_race_pid.read_text(encoding="ascii"))
    try:
        os.kill(raced_child, 0)
    except ProcessLookupError:
        spawn_race_leaked = False
    else:
        spawn_race_leaked = True
        try:
            os.killpg(raced_child, signal.SIGKILL)
        except ProcessLookupError:
            pass
    if raced.returncode != 143:
        signal_race_failures.append(f"spawn-race rc={raced.returncode}")
    if raced_stdout != b"" or raced_stderr != b"":
        signal_race_failures.append("spawn-race emitted output")
    if spawn_race_leaked:
        signal_race_failures.append("signal between Popen and assignment leaked Cedar")

    cleanup_marker = Path(directory) / "cleanup-signal.pid"
    cleanup_driver = Path(directory) / "cleanup-signal-driver.py"
    cleanup_driver.write_text(
        "from importlib.util import module_from_spec, spec_from_file_location\n"
        "from pathlib import Path\n"
        "import os, signal, sys\n"
        "spec = spec_from_file_location('cleanup_signal_contract', sys.argv[1])\n"
        "assert spec is not None and spec.loader is not None\n"
        "module = module_from_spec(spec)\n"
        "spec.loader.exec_module(module)\n"
        "real_terminate = module.terminate_cedar_group\n"
        "def signal_during_cleanup(process):\n"
        "    os.kill(os.getpid(), signal.SIGTERM)\n"
        "    real_terminate(process)\n"
        "module.terminate_cedar_group = signal_during_cleanup\n"
        "module.invoke_cedar(Path(sys.argv[2]), (sys.argv[3],), Path(sys.argv[4]))\n",
        encoding="utf-8",
    )
    cleaning = subprocess.Popen(
        [sys.executable, str(cleanup_driver), str(root / "scripts/experiment.py"),
         str(fake), str(cleanup_marker), str(root)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    deadline = time.monotonic() + 2
    while not cleanup_marker.exists() and cleaning.poll() is None and time.monotonic() < deadline:
        time.sleep(0.01)
    assert cleanup_marker.exists()
    cleanup_child = int(cleanup_marker.read_text(encoding="ascii"))
    os.kill(cleaning.pid, signal.SIGTERM)
    cleanup_stdout, cleanup_stderr = cleaning.communicate(timeout=2)
    try:
        os.kill(cleanup_child, 0)
    except ProcessLookupError:
        cleanup_child_leaked = False
    else:
        cleanup_child_leaked = True
        try:
            os.killpg(cleanup_child, signal.SIGKILL)
        except ProcessLookupError:
            pass
    if cleaning.returncode != 143:
        signal_race_failures.append(f"cleanup-signal rc={cleaning.returncode}")
    if cleanup_stdout != b"" or cleanup_stderr != b"":
        signal_race_failures.append("cleanup-signal emitted output or traceback")
    if cleanup_child_leaked:
        signal_race_failures.append("second handled signal interrupted Cedar cleanup")
    assert not signal_race_failures, "; ".join(signal_race_failures)

    residual_marker = Path(directory) / "residual.pid"
    fake.write_text(
        "from pathlib import Path\n"
        "import subprocess, sys\n"
        "child = subprocess.Popen([sys.executable, '-c', "
        "'import time; time.sleep(30)'])\n"
        "Path(sys.argv[1]).write_text(str(child.pid), encoding='ascii')\n",
        encoding="utf-8",
    )
    try:
        module.invoke_cedar(fake, (str(residual_marker),), root)
    except module.InfrastructureError as error:
        assert str(error) == "pinned Cedar left a residual process group"
    else:
        raise AssertionError("a residual Cedar process group was accepted")
    residual_pid = int(residual_marker.read_text(encoding="ascii"))
    try:
        os.kill(residual_pid, 0)
    except ProcessLookupError:
        pass
    else:
        raise AssertionError("residual Cedar child survived cleanup")

assert {signum: signal.getsignal(signum) for signum in control_signals} == original_dispositions
assert set(signal.pthread_sigmask(signal.SIG_BLOCK, set())) == original_signal_mask

# Main dispatch reads manifest bytes exactly once and supplies no caller input to Cedar.
reads = []
captured = []
real_read = module.read_manifest_once
real_cue = module.cue_plan
real_authorize = module.authorize_plan
real_write = module.write_decision
module.read_manifest_once = lambda path: reads.append(path) or b'{}'
module.cue_plan = lambda value: plan
module.authorize_plan = lambda value: captured.append(value) or ({"verdict": "permit"}, 0)
module.write_decision = lambda value: None
assert module.main(["experiment.py", "authorize", "install", "/manifest.json"]) == 0
assert reads == ["/manifest.json"]
assert captured == [plan]
module.read_manifest_once = real_read
module.cue_plan = real_cue
module.authorize_plan = real_authorize
module.write_decision = real_write

assert authorization_digest.startswith("sha256:")
PY
then
  pass "policy, parser, timeout, cancellation, and residual-process cases fail closed"
else
  fail "low-level Cedar authorization invariants failed"
fi

if [ ! -s "$spy_log" ]; then
  pass "authorization invokes no engine or network command from caller PATH"
else
  fail "authorization invoked a forbidden caller PATH tool: $(tr '\n' ' ' < "$spy_log")"
fi
if ! grep -Eiq 'docker|podman|docker-compose|urllib|requests|socket' \
    "$repo_root/scripts/experiment" "$repo_root/scripts/experiment.py"; then
  pass "the authorization adapter contains no engine or network client surface"
else
  fail "the authorization adapter gained engine or network client code"
fi
if [ -z "$(find "$work/home" "$work/runtime-tmp" -mindepth 1 -print -quit)" ]; then
  pass "authorization leaves no persistent home or runtime state"
else
  fail "authorization left persistent state"
fi
git -C "$repo_root" status --porcelain=v1 --untracked-files=all > "$work/repo.after"
if cmp -s "$repo_before" "$work/repo.after"; then
  pass "authorization leaves the checkout tree unchanged"
else
  fail "authorization changed the checkout tree"
fi

if printf '%s\n' "$cedar_preflight_out" | grep -Fxq 'cedar-policy-cli 4.12.0'; then
  pass "Experiment authorization uses the pinned Cedar release"
else
  fail "pinned Cedar release is unavailable or wrong"
fi
if "$cedar_tool" format --check --policies \
    "$repo_root/authorization/experiment/v0alpha1/operator.cedar" >/dev/null; then
  pass "the tracked Cedar policy is canonically formatted"
else
  fail "the tracked Cedar policy needs cedar format"
fi

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
