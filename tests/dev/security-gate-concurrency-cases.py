#!/usr/bin/env python3
"""Adversarial and differential contracts for bounded security-gate execution."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts/dev/security-gate"
HELPER = ROOT / "scripts/dev/security-gate.py"
# Expected-leak mutants report ready only after starting TERM-ignoring descendants.
MUTANT_LEAK_OBSERVATION_SECONDS = 0.2
failures = 0


def pass_test(name: str) -> None:
    print(f"PASS {name}")


def fail_test(name: str, detail: str = "") -> None:
    global failures
    failures += 1
    suffix = f" ({detail})" if detail else ""
    print(f"FAIL {name}{suffix}")


def check(condition: bool, name: str, detail: str = "") -> None:
    if condition:
        pass_test(name)
    else:
        fail_test(name, detail)


class Result:
    def __init__(self, completed: subprocess.CompletedProcess[bytes], seconds: float):
        self.rc = completed.returncode
        self.stdout = completed.stdout
        self.stderr = completed.stderr
        self.seconds = seconds


def write_script(work: Path, name: str, body: str) -> Path:
    work.mkdir(parents=True, exist_ok=True)
    path = work / name
    path.write_text("#!/usr/bin/env bash\nset -u\n" + body, encoding="utf-8")
    path.chmod(0o755)
    return path


def write_manifest(work: Path, name: str, suites: list[tuple[str, Path, str]]) -> Path:
    work.mkdir(parents=True, exist_ok=True)
    path = work / name
    lines = ["tool bash"]
    lines.extend(
        f"suite {suite_id} {script} {marker}"
        for suite_id, script, marker in suites
    )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def run_gate(
    manifest: Path,
    jobs: int,
    *,
    mode: str = "fast",
    evidence: Path | None = None,
    extra_env: dict[str, str] | None = None,
    helper: Path | None = None,
) -> Result:
    env = dict(os.environ)
    env["AGENT_LAB_SECURITY_GATE_JOBS"] = str(jobs)
    if evidence is not None:
        if not evidence.exists() and not evidence.is_symlink():
            evidence.mkdir(parents=True, exist_ok=True)
        env["AGENT_LAB_SECURITY_GATE_EVIDENCE_DIR"] = str(evidence)
    if extra_env:
        env.update(extra_env)
    if helper is None:
        command = [str(GATE), mode, "--manifest", str(manifest)]
    else:
        command = [sys.executable, "-I", str(helper), mode, "--manifest", str(manifest)]
    started = time.perf_counter()
    completed = subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return Result(completed, time.perf_counter() - started)


def headings(output: bytes) -> list[str]:
    return [
        line.removeprefix("== security suite: ").split(" ", 1)[0]
        for line in output.decode(errors="replace").splitlines()
        if line.startswith("== security suite: ")
    ]


def reverse_fixture(work: Path) -> tuple[Path, list[str], Path]:
    completion_log = work / "reverse-completion.log"
    suites: list[tuple[str, Path, str]] = []
    for suite_id, delay in (
        ("first", "0.24"),
        ("second", "0.18"),
        ("third", "0.12"),
        ("fourth", "0.06"),
    ):
        script = write_script(
            work,
            f"reverse-{suite_id}.sh",
            f"sleep {delay}\n"
            f"printf 'BODY {suite_id}\\nDONE {suite_id}\\n'\n"
            f"printf '{suite_id}\\n' >> \"$COMPLETION_LOG\"\n",
        )
        suites.append((suite_id, script, f"DONE {suite_id}"))
    return write_manifest(work, "reverse.manifest", suites), [item[0] for item in suites], completion_log


def test_reverse_completion(work: Path) -> None:
    manifest, expected_order, completion_log = reverse_fixture(work)
    serial = run_gate(
        manifest,
        1,
        extra_env={"COMPLETION_LOG": str(completion_log)},
    )
    completion_log.write_text("", encoding="utf-8")
    parallel = run_gate(
        manifest,
        4,
        extra_env={"COMPLETION_LOG": str(completion_log)},
    )
    completed = completion_log.read_text(encoding="utf-8").splitlines()
    check(serial.rc == parallel.rc == 0, "jobs=1 and jobs=4 reverse fixture pass")
    check(
        serial.stdout == parallel.stdout and serial.stderr == parallel.stderr == b"",
        "jobs=1 and jobs=4 buffered evidence is byte-identical",
    )
    check(
        headings(parallel.stdout) == expected_order,
        "reverse-completion evidence remains in manifest order",
        repr(headings(parallel.stdout)),
    )
    check(
        completed == list(reversed(expected_order)),
        "reverse fixture really completes out of order",
        repr(completed),
    )
    check(
        parallel.seconds < serial.seconds * 0.70,
        "four workers materially accelerate independent suites",
        f"serial={serial.seconds:.3f}s parallel={parallel.seconds:.3f}s",
    )


def classification_fixture(work: Path) -> tuple[Path, list[str], Path]:
    execution_log = work / "execution.log"
    definitions = (
        ("pass-before", "BODY pass-before\\nDONE pass-before", 0, "DONE pass-before"),
        ("warn", "WARN fixture\\nDONE warn", 0, "DONE warn"),
        ("skip", "SKIP fixture", 77, "DONE skip"),
        ("missing", "BODY missing", 0, "DONE missing"),
        ("infra", "INFRA fixture", 125, "INFRA fixture"),
        ("fail", "FAIL fixture", 9, "DONE fail"),
        ("pass-after", "BODY pass-after\\nDONE pass-after", 0, "DONE pass-after"),
    )
    suites: list[tuple[str, Path, str]] = []
    for suite_id, output, rc, marker in definitions:
        script = write_script(
            work,
            f"class-{suite_id}.sh",
            f"printf '{suite_id}\\n' >> \"$EXEC_LOG\"\n"
            f"printf '{output}\\n'\nexit {rc}\n",
        )
        suites.append((suite_id, script, marker))
    return (
        write_manifest(work, "classification.manifest", suites),
        [item[0] for item in definitions],
        execution_log,
    )


def test_classification_and_evidence(work: Path) -> None:
    manifest, expected_ids, execution_log = classification_fixture(work)
    expected_stderr = (
        "FAIL suite warn emitted forbidden status output\n"
        "SKIP suite skip returned 77\n"
        "FAIL suite missing missing completion marker: DONE missing\n"
        "INFRA suite infra reported infrastructure failure\n"
        "FAIL suite fail exited 9\n"
    ).encode()
    expected_summary = b"SECURITY GATE SUMMARY pass=2 fail=3 skip=1 infra=1\n"
    serial = run_gate(
        manifest,
        1,
        extra_env={"EXEC_LOG": str(execution_log)},
    )
    execution_log.write_text("", encoding="utf-8")
    evidence = work / "classification-evidence"
    parallel = run_gate(
        manifest,
        4,
        evidence=evidence,
        extra_env={"EXEC_LOG": str(execution_log)},
    )
    executed = execution_log.read_text(encoding="utf-8").splitlines()
    check(serial.rc == parallel.rc == 1, "assertion failure outranks infrastructure failure")
    check(
        serial.stdout == parallel.stdout and serial.stderr == parallel.stderr,
        "mixed classifications are exact across jobs=1 and jobs=4",
    )
    check(parallel.stderr == expected_stderr, "SKIP WARN missing-marker infra and fail diagnostics are exact")
    check(expected_summary in parallel.stdout, "mixed result summary is exact")
    check(headings(parallel.stdout) == expected_ids, "mixed evidence remains manifest ordered")
    check(set(executed) == set(expected_ids), "every suite runs after early failures", repr(executed))
    evidence_ok = all(
        (evidence / f"{index:03d}-{suite_id}.out").is_file()
        and (evidence / f"{index:03d}-{suite_id}.status").is_file()
        for index, suite_id in enumerate(expected_ids)
    )
    check(evidence_ok, "per-suite output and status evidence remains readable")


def bounded_script(suite_id: str) -> str:
    return f"""
while ! mkdir "$ACTIVE_DIR/.lock" 2>/dev/null; do sleep 0.002; done
mkdir "$ACTIVE_DIR/{suite_id}"
count="$(find "$ACTIVE_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)"
count=$((count - 1))
printf '%s\n' "$count" >> "$COUNT_LOG"
rmdir "$ACTIVE_DIR/.lock"
sleep 0.10
while ! mkdir "$ACTIVE_DIR/.lock" 2>/dev/null; do sleep 0.002; done
rmdir "$ACTIVE_DIR/{suite_id}"
rmdir "$ACTIVE_DIR/.lock"
printf 'DONE {suite_id}\n'
"""


def bound_fixture(work: Path) -> Path:
    suites = [
        (
            suite_id,
            write_script(work, f"bound-{suite_id}.sh", bounded_script(suite_id)),
            f"DONE {suite_id}",
        )
        for suite_id in (f"worker-{index}" for index in range(6))
    ]
    return write_manifest(work, "bound.manifest", suites)


def run_bound_case(
    work: Path,
    manifest: Path,
    label: str,
    mode: str,
    helper: Path | None = None,
) -> tuple[Result, int]:
    active = work / f"active-{label}"
    active.mkdir(exist_ok=True)
    count_log = work / f"counts-{label}.log"
    count_log.write_text("", encoding="utf-8")
    fake_bin = work / "fake-bin"
    fake_bin.mkdir(exist_ok=True)
    fake_docker = fake_bin / "docker"
    fake_docker.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    fake_docker.chmod(0o755)
    result = run_gate(
        manifest,
        4,
        mode=mode,
        helper=helper,
        extra_env={
            "ACTIVE_DIR": str(active),
            "COUNT_LOG": str(count_log),
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
        },
    )
    counts = [int(value) for value in count_log.read_text(encoding="utf-8").splitlines()]
    return result, max(counts, default=0)


def test_worker_bound_and_docker_serial(work: Path) -> None:
    manifest = bound_fixture(work)
    fast, fast_max = run_bound_case(work, manifest, "fast", "fast")
    docker, docker_max = run_bound_case(work, manifest, "docker", "docker")
    check(fast.rc == 0, "fast worker-bound fixture passes")
    check(fast_max == 4, "fast worker maximum is exactly four", f"observed={fast_max}")
    check(docker.rc == 0, "Docker worker-bound fixture passes")
    check(docker_max == 1, "Docker worker maximum remains exactly one", f"observed={docker_max}")
    check(docker.seconds >= 0.52, "Docker stays serial despite a four-worker override")


def test_preflight_signal_cleanup(work: Path) -> None:
    work.mkdir(parents=True, exist_ok=True)
    preflight_dir = work / "preflight-state"
    preflight_dir.mkdir()
    fake_bin = work / "fake-bin"
    fake_bin.mkdir()
    fake_docker = write_script(
        fake_bin,
        "docker",
        """
if [ "${1:-}" != info ]; then
  exit 0
fi
cleanup() {
  : > "$PREFLIGHT_DIR/term.observed"
  wait
}
trap cleanup TERM
printf '%s\n' "$$" > "$PREFLIGHT_DIR/preflight.pid"
(
  trap '' TERM
  printf '%s\n' "$BASHPID" > "$PREFLIGHT_DIR/descendant.pid"
  while :; do sleep 1; done
) &
wait
""",
    )
    passing = write_script(work, "preflight-pass.sh", "printf 'DONE preflight pass\n'\n")
    manifest = write_manifest(
        work,
        "preflight-signal.manifest",
        [("preflight-pass", passing, "DONE preflight pass")],
    )
    env = dict(os.environ)
    env["PATH"] = f"{fake_bin}:{env['PATH']}"
    env["PREFLIGHT_DIR"] = str(preflight_dir)
    process = subprocess.Popen(
        [sys.executable, "-I", str(HELPER), "docker", "--manifest", str(manifest)],
        cwd=ROOT,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    required = (
        preflight_dir / "preflight.pid",
        preflight_dir / "descendant.pid",
    )
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline and not all(path.is_file() for path in required):
        if process.poll() is not None:
            break
        time.sleep(0.01)
    if not all(path.is_file() for path in required):
        process.kill()
        stdout, stderr = process.communicate()
        fail_test(
            "Docker preflight cancellation fixture becomes ready",
            (stdout + stderr).decode(errors="replace"),
        )
        return
    preflight_pid = int(required[0].read_text(encoding="ascii").strip())
    descendant_pid = int(required[1].read_text(encoding="ascii").strip())
    os.kill(process.pid, signal.SIGTERM)
    time.sleep(0.05)
    if process.poll() is None:
        os.kill(process.pid, signal.SIGTERM)
    try:
        stdout, stderr = process.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        stdout, stderr = process.communicate()
    clean = wait_gone(preflight_pid) and wait_gone(descendant_pid)
    if not clean:
        for pid in (preflight_pid, descendant_pid):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    check(process.returncode == 143, "Docker preflight cancellation returns 143")
    check(
        stdout == b"" and stderr == b"INFRA security-gate interrupted by TERM\n",
        "Docker preflight cancellation diagnostic is exact",
        (stdout + stderr).decode(errors="replace"),
    )
    check(
        (preflight_dir / "term.observed").is_file(),
        "Docker preflight process group receives cooperative TERM",
    )
    check(clean, "Docker preflight cancellation removes the entire process group")


def load_helper() -> object:
    spec = importlib.util.spec_from_file_location("agent_lab_security_gate_cases", HELPER)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {HELPER}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def test_evidence_fail_closed(work: Path) -> None:
    work.mkdir(parents=True, exist_ok=True)
    passing = write_script(work, "evidence-pass.sh", "printf 'DONE evidence\\n'\n")
    manifest = write_manifest(work, "evidence.manifest", [("evidence", passing, "DONE evidence")])

    stale = work / "stale-evidence"
    stale.mkdir()
    (stale / "stale.out").write_text("stale\n", encoding="utf-8")
    stale_result = run_gate(manifest, 1, evidence=stale)
    check(stale_result.rc == 125, "nonempty configured evidence directory fails closed")
    check(stale_result.stdout == b"", "stale evidence emits no suite output")
    check(
        stale_result.stderr
        == f"INFRA security-gate evidence directory is not empty: {stale}\n".encode(),
        "stale evidence diagnostic is exact",
        stale_result.stderr.decode(errors="replace"),
    )

    isolated_evidence = work / "isolated-evidence"
    isolated = write_script(
        work,
        "isolated-controls.sh",
        """
if [ -n "${AGENT_LAB_SECURITY_GATE_JOBS+x}" ] ||
   [ -n "${AGENT_LAB_SECURITY_GATE_EVIDENCE_DIR+x}" ]; then
  printf 'WARN runner controls leaked into suite\n'
else
  printf 'DONE isolated controls\n'
fi
""",
    )
    isolated_manifest = write_manifest(
        work,
        "isolated-controls.manifest",
        [("isolated", isolated, "DONE isolated controls")],
    )
    isolated_result = run_gate(isolated_manifest, 1, evidence=isolated_evidence)
    check(isolated_result.rc == 0, "runner controls do not leak into suite environments")

    output_evidence = work / "output-open-evidence"
    poison_output = write_script(
        work,
        "poison-output.sh",
        'mkdir "$EVIDENCE_DIR/001-victim.out"\nprintf \'DONE poison\\n\'\n',
    )
    output_manifest = write_manifest(
        work,
        "output-open.manifest",
        [
            ("poison", poison_output, "DONE poison"),
            ("victim", passing, "DONE evidence"),
        ],
    )
    output_result = run_gate(
        output_manifest,
        1,
        evidence=output_evidence,
        extra_env={"EVIDENCE_DIR": str(output_evidence)},
    )
    check(output_result.rc == 125, "output evidence open failure returns infrastructure")
    check(output_result.stdout == b"", "output evidence failure emits no partial suite output")
    check(
        output_result.stderr
        == (
            "INFRA security-gate evidence directory changed during suite execution: "
            f"{output_evidence}\n"
        ).encode(),
        "output evidence injection diagnostic is exact",
        output_result.stderr.decode(errors="replace"),
    )

    status_evidence = work / "status-write-evidence"
    poison_status = write_script(
        work,
        "poison-status.sh",
        'mkdir "$EVIDENCE_DIR/000-status.status"\nprintf \'DONE status\\n\'\n',
    )
    status_manifest = write_manifest(
        work,
        "status-write.manifest",
        [("status", poison_status, "DONE status")],
    )
    status_result = run_gate(
        status_manifest,
        1,
        evidence=status_evidence,
        extra_env={"EVIDENCE_DIR": str(status_evidence)},
    )
    check(status_result.rc == 125, "status evidence write failure returns infrastructure")
    check(status_result.stdout == b"", "status evidence failure emits no partial suite output")
    check(
        status_result.stderr
        == (
            "INFRA security-gate evidence directory changed during suite execution: "
            f"{status_evidence}\n"
        ).encode(),
        "status evidence injection diagnostic is exact",
        status_result.stderr.decode(errors="replace"),
    )

    helper = load_helper()
    with mock.patch.object(helper.os, "environ", {}):
        default_evidence = helper.evidence_directory()
    check(
        default_evidence is None,
        "default anonymous capture creates no named evidence directory",
    )

    fixture_suite = helper.Suite(
        "fixture",
        work / "unused-fixture.sh",
        "unused-fixture.sh",
        "DONE fixture",
    )
    fault_cases = (
        ("open", "open", OSError("fixture"), "persist"),
        ("zero-write", "write", None, "persist"),
        ("fsync", "fsync", OSError("fixture"), "persist"),
        ("readback", "read", OSError("fixture"), "verify"),
    )
    for case_name, attribute, exception, diagnostic_kind in fault_cases:
        fault_path = work / f"fault-{case_name}"
        with mock.patch.dict(
            os.environ,
            {"AGENT_LAB_SECURITY_GATE_EVIDENCE_DIR": str(fault_path)},
        ):
            evidence = helper.evidence_directory()
        fault_stderr = io.StringIO()
        patch_kwargs = (
            {"return_value": 0}
            if case_name == "zero-write"
            else {"side_effect": exception}
        )
        with mock.patch.object(helper.os, attribute, **patch_kwargs), \
             contextlib.redirect_stderr(fault_stderr):
            try:
                helper.persist_evidence(
                    evidence,
                    [fixture_suite],
                    [0],
                    [b"DONE fixture\n"],
                )
            except SystemExit as error:
                fault_rc = error.code
            else:
                fault_rc = 0
        helper.close_evidence_directory(evidence)
        target = fault_path / "000-fixture.out"
        expected_fault = (
            f"INFRA cannot {diagnostic_kind} security-gate evidence: {target}\n"
        )
        check(fault_rc == 125, f"{case_name} evidence failure returns infrastructure")
        check(
            fault_stderr.getvalue() == expected_fault,
            f"{case_name} evidence diagnostic is exact",
            fault_stderr.getvalue(),
        )

    growth_path = work / "fault-growth"
    with mock.patch.dict(
        os.environ,
        {"AGENT_LAB_SECURITY_GATE_EVIDENCE_DIR": str(growth_path)},
    ):
        growth_evidence = helper.evidence_directory()
    growth_payload = b"DONE fixture\n"
    growth_stderr = io.StringIO()
    with mock.patch.object(
        helper.os,
        "read",
        return_value=growth_payload + b"X",
    ) as read_mock, contextlib.redirect_stderr(growth_stderr):
        try:
            helper.persist_evidence(
                growth_evidence,
                [fixture_suite],
                [0],
                [growth_payload],
            )
        except SystemExit as error:
            growth_rc = error.code
        else:
            growth_rc = 0
    helper.close_evidence_directory(growth_evidence)
    growth_target = growth_path / "000-fixture.out"
    check(growth_rc == 125, "growing evidence readback returns infrastructure")
    check(
        growth_stderr.getvalue()
        == f"INFRA cannot verify security-gate evidence: {growth_target}\n",
        "growing evidence readback diagnostic is exact",
        growth_stderr.getvalue(),
    )
    check(
        read_mock.call_args.args[1] == len(growth_payload) + 1,
        "evidence readback is bounded to expected size plus one byte",
    )


def test_evidence_tampering(work: Path) -> None:
    work.mkdir(parents=True, exist_ok=True)
    prior = write_script(work, "prior.sh", "printf 'WARN prior\\nDONE prior\\n'\n")
    victim = write_script(work, "victim.sh", "printf 'DONE victim\\n'\n")
    sentinel = work / "external-sentinel"
    sentinel_bytes = b"external bytes must survive\n"
    sentinel.write_bytes(sentinel_bytes)

    for position in ("prior", "future"):
        for suffix in ("out", "status"):
            for entry_kind in ("regular", "directory", "symlink"):
                case_name = f"{position}-{suffix}-{entry_kind}"
                evidence = work / f"evidence-{case_name}"
                target_index = 0 if position == "prior" else 1
                target_id = "prior" if position == "prior" else "victim"
                target_name = f"{target_index:03d}-{target_id}.{suffix}"
                if entry_kind == "regular":
                    attack = f"printf 'forged\\n' > \"$EVIDENCE_DIR/{target_name}\""
                elif entry_kind == "directory":
                    attack = f"mkdir \"$EVIDENCE_DIR/{target_name}\""
                else:
                    attack = f"ln -s \"$SENTINEL\" \"$EVIDENCE_DIR/{target_name}\""
                attacker = write_script(
                    work,
                    f"attacker-{case_name}.sh",
                    f"{attack}\nprintf 'DONE attacker\\n'\n",
                )
                suites = (
                    [("prior", prior, "DONE prior"), ("attacker", attacker, "DONE attacker")]
                    if position == "prior"
                    else [("attacker", attacker, "DONE attacker"), ("victim", victim, "DONE victim")]
                )
                manifest = write_manifest(work, f"{case_name}.manifest", suites)
                result = run_gate(
                    manifest,
                    1,
                    evidence=evidence,
                    extra_env={
                        "EVIDENCE_DIR": str(evidence),
                        "SENTINEL": str(sentinel),
                    },
                )
                expected = (
                    "INFRA security-gate evidence directory changed during suite execution: "
                    f"{evidence}\n"
                ).encode()
                check(result.rc == 125, f"{case_name} evidence injection fails closed")
                check(
                    result.stdout == b"" and result.stderr == expected,
                    f"{case_name} emits only the exact infrastructure diagnostic",
                    (result.stdout + result.stderr).decode(errors="replace"),
                )
                check(
                    sentinel.read_bytes() == sentinel_bytes,
                    f"{case_name} cannot overwrite an external sentinel",
                )

    real_evidence = work / "real-evidence"
    real_evidence.mkdir()
    evidence_link = work / "evidence-link"
    evidence_link.symlink_to(real_evidence, target_is_directory=True)
    symlink_manifest = write_manifest(
        work,
        "evidence-symlink.manifest",
        [("victim", victim, "DONE victim")],
    )
    symlink_result = run_gate(symlink_manifest, 1, evidence=evidence_link)
    check(symlink_result.rc == 125, "final evidence-directory symlink fails closed")
    check(
        symlink_result.stdout == b""
        and symlink_result.stderr
        == f"INFRA cannot open security-gate evidence directory: {evidence_link}\n".encode(),
        "evidence-directory symlink diagnostic is exact",
        (symlink_result.stdout + symlink_result.stderr).decode(errors="replace"),
    )
    check(not any(real_evidence.iterdir()), "evidence-directory symlink receives no writes")

    swap_evidence = work / "swap-evidence"
    swapped_original = work / "swap-evidence-original"
    swapper = write_script(
        work,
        "swap-evidence.sh",
        """
mv "$EVIDENCE_DIR" "$SWAPPED_ORIGINAL"
mkdir "$EVIDENCE_DIR"
printf 'DONE swap\n'
""",
    )
    swap_manifest = write_manifest(
        work,
        "swap-evidence.manifest",
        [("swap", swapper, "DONE swap")],
    )
    swap_result = run_gate(
        swap_manifest,
        1,
        evidence=swap_evidence,
        extra_env={
            "EVIDENCE_DIR": str(swap_evidence),
            "SWAPPED_ORIGINAL": str(swapped_original),
        },
    )
    check(swap_result.rc == 125, "evidence-directory path swap fails closed")
    check(
        swap_result.stdout == b""
        and swap_result.stderr
        == f"INFRA security-gate evidence directory identity changed: {swap_evidence}\n".encode(),
        "evidence-directory path-swap diagnostic is exact",
        (swap_result.stdout + swap_result.stderr).decode(errors="replace"),
    )
    check(
        not any(swap_evidence.iterdir()) and not any(swapped_original.iterdir()),
        "dirfd persistence cannot be redirected by a path swap",
    )


def cross_capture_fixture(work: Path) -> tuple[Path, Path]:
    victim_pid_file = work / "cross-capture-victim.pid"
    victim = write_script(
        work,
        "cross-capture-victim.sh",
        "printf '%s\\n' \"$$\" > \"$VICTIM_PID_FILE\"\n"
        "printf 'WARN real victim failure\\n'\n"
        "sleep 0.4\n"
        "printf 'DONE victim\\n'\n",
    )
    attacker = write_script(
        work,
        "cross-capture-attacker.sh",
        """
while [ ! -s "$VICTIM_PID_FILE" ]; do sleep 0.005; done
python3 -I - "$PPID" "$(cat "$VICTIM_PID_FILE")" <<'PY'
import os
import sys

opened = False
parent_visible = False
for position, pid in enumerate((int(sys.argv[1]), int(sys.argv[2]))):
    fd_root = f"/proc/{pid}/fd"
    try:
        entries = os.listdir(fd_root)
    except OSError:
        continue
    if position == 0:
        parent_visible = True
    for entry in entries:
        path = f"{fd_root}/{entry}"
        try:
            target = os.readlink(path)
        except OSError:
            continue
        if entry != "1" and "(deleted)" not in target:
            continue
        try:
            descriptor = os.open(path, os.O_WRONLY | os.O_TRUNC)
        except OSError:
            continue
        try:
            os.write(descriptor, b"DONE victim\\n")
            opened = True
        finally:
            os.close(descriptor)
os.write(
    1,
    b"PARENT_FDS_VISIBLE\\n" if parent_visible else b"PARENT_FDS_BLOCKED\\n",
)
if not opened:
    os.write(1, b"CAPTURE_FDS_UNOPENABLE\\n")
os.write(1, b"DONE attacker\\n")
PY
""",
    )
    return (
        write_manifest(
            work,
            "cross-capture.manifest",
            [
                ("victim", victim, "DONE victim"),
                ("attacker", attacker, "DONE attacker"),
            ],
        ),
        victim_pid_file,
    )


def test_cross_suite_capture_forgery(work: Path) -> None:
    if sys.platform != "linux":
        pass_test("Linux parent-capture forgery regression is not applicable")
        return
    manifest, victim_pid_file = cross_capture_fixture(work)
    result = run_gate(
        manifest,
        2,
        extra_env={"VICTIM_PID_FILE": str(victim_pid_file)},
    )
    check(result.rc == 1, "a sibling suite cannot forge a cross-capture pass")
    check(
        b"WARN real victim failure\n" in result.stdout
        and b"PARENT_FDS_BLOCKED\n" in result.stdout
        and b"CAPTURE_FDS_UNOPENABLE\n" in result.stdout
        and b"SECURITY GATE PASS" not in result.stdout,
        "the real victim evidence survives and parent descriptors stay inaccessible",
        result.stdout.decode(errors="replace"),
    )
    check(
        result.stderr == b"FAIL suite victim emitted forbidden status output\n",
        "cross-capture attack retains the exact victim failure",
        result.stderr.decode(errors="replace"),
    )

    import ctypes

    helper = load_helper()
    protection_stderr = io.StringIO()
    with mock.patch.object(ctypes, "CDLL", side_effect=OSError("fixture")), \
         contextlib.redirect_stderr(protection_stderr):
        try:
            helper.protect_runner_process()
        except SystemExit as error:
            protection_rc = error.code
        else:
            protection_rc = 0
    check(protection_rc == 125, "unavailable Linux parent protection fails closed")
    check(
        protection_stderr.getvalue()
        == "INFRA cannot protect security-gate runner process\n",
        "parent-protection failure diagnostic is exact",
        protection_stderr.getvalue(),
    )


def child_signal_mask_fixture(work: Path) -> Path:
    probe = write_script(
        work,
        "child-signal-mask.sh",
        """
python3 -I - <<'PY'
import signal
import sys

blocked = signal.pthread_sigmask(signal.SIG_BLOCK, set())
handled = {signal.SIGHUP, signal.SIGINT, signal.SIGQUIT, signal.SIGTERM}
if handled & blocked:
    print("WARN suite inherited a blocked cancellation signal")
    raise SystemExit(1)
print("DONE child signal mask")
PY
""",
    )
    return write_manifest(
        work,
        "child-signal-mask.manifest",
        [("child-mask", probe, "DONE child signal mask")],
    )


def test_child_signal_mask(work: Path) -> None:
    manifest = child_signal_mask_fixture(work)
    result = run_gate(manifest, 4)
    check(result.rc == 0, "suite child inherits no blocked HUP INT QUIT or TERM")


def test_ci_foundation_limits_and_deadlines(work: Path) -> None:
    helper = load_helper()
    check(
        getattr(helper, "MODE_LIMITS", None)
        == {"fast": (120.0, 600.0, 3.0), "docker": (900.0, 1800.0, 15.0)},
        "CI-010 production suite phase and cleanup limits are exact",
    )
    check(
        getattr(helper, "PREFLIGHT_EXECUTION_SECONDS", None) == 30.0
        and getattr(helper, "PREFLIGHT_TERMINATION_SECONDS", None) == 1.0,
        "CI-010 Docker preflight limits are exact",
    )

    timed_helper = transformed_helper(
        work,
        "short-deadlines",
        (
            (
                "FAST_SUITE_EXECUTION_SECONDS = 120.0",
                "FAST_SUITE_EXECUTION_SECONDS = 0.15",
            ),
            (
                "FAST_GATE_PHASE_SECONDS = 600.0",
                "FAST_GATE_PHASE_SECONDS = 0.45",
            ),
            (
                "FAST_TERMINATION_SECONDS = 3.0",
                "FAST_TERMINATION_SECONDS = 0.05",
            ),
            (
                "DOCKER_SUITE_EXECUTION_SECONDS = 900.0",
                "DOCKER_SUITE_EXECUTION_SECONDS = 0.15",
            ),
            (
                "DOCKER_GATE_PHASE_SECONDS = 1800.0",
                "DOCKER_GATE_PHASE_SECONDS = 0.30",
            ),
            (
                "DOCKER_TERMINATION_SECONDS = 15.0",
                "DOCKER_TERMINATION_SECONDS = 0.05",
            ),
            ("PREFLIGHT_EXECUTION_SECONDS = 30.0", "PREFLIGHT_EXECUTION_SECONDS = 0.15"),
            ("PREFLIGHT_TERMINATION_SECONDS = 1.0", "PREFLIGHT_TERMINATION_SECONDS = 0.05"),
        ),
    )
    if timed_helper is None:
        fail_test("CI-001 through CI-011 deadline contract is implemented")
        return

    fixture = work / "fixtures"
    hanging = write_script(fixture, "hang.sh", "printf 'DONE hang\\n'\nsleep 30\n")
    passing = write_script(fixture, "pass.sh", "printf 'DONE pass\\n'\n")
    queued = write_script(
        fixture,
        "queued.sh",
        "printf 'queued\\n' >> \"$EXEC_LOG\"\nprintf 'DONE queued\\n'\n",
    )
    manifest = write_manifest(
        fixture,
        "suite-timeout.manifest",
        [("hang", hanging, "DONE hang"), ("pass", passing, "DONE pass"), ("queued", queued, "DONE queued")],
    )
    execution_log = fixture / "execution.log"
    result = run_gate(
        manifest,
        2,
        helper=timed_helper,
        extra_env={"EXEC_LOG": str(execution_log)},
    )
    check(result.rc == 125 and result.seconds < 2.0, "CI-001 and CI-004 suite timeout is bounded infrastructure")
    check(
        execution_log.read_text(encoding="utf-8").splitlines() == ["queued"],
        "CI-008 fast timeout preserves completing and queued siblings",
    )
    check(headings(result.stdout) == ["hang", "pass", "queued"], "CI-008 timeout evidence remains manifest ordered")

    phase_log = fixture / "phase.log"
    fake_docker = write_script(
        fixture,
        "docker",
        "case \"${1-} ${2-}\" in\n  'info '|'compose version') exit 0 ;;\n  *) exit 99 ;;\nesac\n",
    )
    phase_hang = write_script(fixture, "phase-hang.sh", "sleep 30\n")
    phase_queued = write_script(
        fixture,
        "phase-queued.sh",
        "printf 'launched\\n' >> \"$PHASE_LOG\"\nprintf 'DONE phase queued\\n'\n",
    )
    phase_manifest = write_manifest(
        fixture,
        "phase-timeout.manifest",
        [("phase-hang", phase_hang, "DONE phase hang"), ("phase-queued", phase_queued, "DONE phase queued")],
    )
    phase_result = run_gate(
        phase_manifest,
        1,
        mode="docker",
        helper=timed_helper,
        extra_env={"PHASE_LOG": str(phase_log), "PATH": str(fixture) + os.pathsep + os.environ["PATH"]},
    )
    check(phase_result.rc == 125 and phase_result.seconds < 2.0, "CI-006 and CI-011 Docker deadline is bounded infrastructure")
    check(not phase_log.exists(), "CI-011 Docker timeout launches no queued suite")

    fake_docker.write_text(
        "#!/usr/bin/env bash\nset -u\n"
        "case \"${1-} ${2-}\" in\n"
        "  'info ') sleep 30 ;;\n"
        "  'compose version') exit 0 ;;\n"
        "  *) exit 99 ;;\n"
        "esac\n",
        encoding="utf-8",
    )
    fake_docker.chmod(0o755)
    preflight_result = run_gate(
        phase_manifest,
        1,
        mode="docker",
        helper=timed_helper,
        extra_env={"PHASE_LOG": str(phase_log), "PATH": str(fixture) + os.pathsep + os.environ["PATH"]},
    )
    check(
        preflight_result.rc == 125 and preflight_result.seconds < 2.0,
        "CI-009 Docker preflight timeout is bounded infrastructure",
    )
    check(not phase_log.exists(), "CI-009 preflight timeout launches no suite")


def process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    stat_path = Path(f"/proc/{pid}/stat")
    if stat_path.exists():
        try:
            return stat_path.read_text(encoding="ascii").split()[2] != "Z"
        except (OSError, IndexError):
            pass
    return True


def group_exists(pgid: int) -> bool:
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    return True


def wait_gone(pid: int, timeout: float = 3.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not process_exists(pid):
            return True
        time.sleep(0.05)
    return not process_exists(pid)


def stubborn_signal_fixture(work: Path) -> Path:
    script = write_script(
        work,
        "stubborn-descendant.sh",
        """
printf '%s\n' "$$" > "$SIGNAL_DIR/suite.pid"
printf '%s\n' "$$" > "$SIGNAL_DIR/group.id"
(
  trap '' INT TERM
  printf '%s\n' "$BASHPID" > "$SIGNAL_DIR/descendant.pid"
  while :; do sleep 1; done
) &
wait
""",
    )
    return write_manifest(work, "stubborn-signal.manifest", [("signal", script, "DONE signal")])


def cooperative_signal_fixture(work: Path) -> Path:
    script = write_script(
        work,
        "cooperative-cleanup.sh",
        """
cleanup() {
  sleep "$CLEANUP_DELAY"
  printf 'cleanup complete\n' > "$SIGNAL_DIR/cleanup.done"
  exit 0
}
trap cleanup TERM
printf '%s\n' "$$" > "$SIGNAL_DIR/suite.pid"
printf '%s\n' "$$" > "$SIGNAL_DIR/group.id"
while :; do sleep 1; done
""",
    )
    return write_manifest(
        work,
        "cooperative-signal.manifest",
        [("cooperative", script, "DONE cooperative")],
    )


def signal_flood_fixture(work: Path) -> Path:
    script = write_script(
        work,
        "signal-flood.sh",
        """
flood() {
  python3 -I - <<'PY'
import os
import time

chunk = b"s" * 4096
for _ in range(64):
    os.write(1, chunk)
    time.sleep(0.002)
PY
  exit 0
}
trap flood TERM
printf '%s\n' "$$" > "$SIGNAL_DIR/suite.pid"
printf '%s\n' "$$" > "$SIGNAL_DIR/group.id"
while :; do sleep 1; done
""",
    )
    return write_manifest(
        work,
        "signal-flood.manifest",
        [("signal-flood", script, "DONE signal flood")],
    )


def run_signal_case(
    work: Path,
    manifest: Path,
    label: str,
    signum: signal.Signals,
    helper: Path | None = None,
    *,
    descendant: bool = False,
    cleanup_delay: float = 0.0,
    repeat_signal: bool = False,
    disappearance_timeout: float = 3.0,
) -> tuple[int, bytes, bytes, bool, float, Path]:
    signal_dir = work / f"signal-{label}-{signum.name}"
    signal_dir.mkdir(exist_ok=True)
    env = dict(os.environ)
    env["SIGNAL_DIR"] = str(signal_dir)
    env["CLEANUP_DELAY"] = str(cleanup_delay)
    env["AGENT_LAB_SECURITY_GATE_JOBS"] = "4"
    command = (
        [str(GATE), "fast", "--manifest", str(manifest)]
        if helper is None
        else [sys.executable, "-I", str(helper), "fast", "--manifest", str(manifest)]
    )
    process = subprocess.Popen(
        command,
        cwd=ROOT,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    required_names = ["suite.pid", "group.id"]
    if descendant:
        required_names.append("descendant.pid")
    required = tuple(signal_dir / name for name in required_names)
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline and not all(path.exists() for path in required):
        time.sleep(0.02)
    if not all(path.exists() for path in required):
        process.kill()
        stdout, stderr = process.communicate()
        return process.returncode, stdout, stderr, False, 0.0, signal_dir
    suite_pid = int(required[0].read_text(encoding="ascii").strip())
    pgid = int((signal_dir / "group.id").read_text(encoding="ascii").strip())
    descendant_pid = (
        int((signal_dir / "descendant.pid").read_text(encoding="ascii").strip())
        if descendant
        else None
    )
    started = time.perf_counter()
    os.kill(process.pid, signum)
    if repeat_signal:
        time.sleep(0.05)
        if process.poll() is None:
            os.kill(process.pid, signum)
    try:
        stdout, stderr = process.communicate(timeout=6)
    except subprocess.TimeoutExpired:
        process.kill()
        stdout, stderr = process.communicate()
    seconds = time.perf_counter() - started
    clean = wait_gone(suite_pid, disappearance_timeout)
    if descendant_pid is not None:
        clean = wait_gone(descendant_pid, disappearance_timeout) and clean
    clean = clean and not group_exists(pgid)
    if not clean:
        try:
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    return process.returncode, stdout, stderr, clean, seconds, signal_dir


def test_signal_cleanup(work: Path) -> None:
    cooperative = cooperative_signal_fixture(work)
    handled = (
        (signal.SIGHUP, 129),
        (signal.SIGINT, 130),
        (signal.SIGQUIT, 131),
        (signal.SIGTERM, 143),
    )
    for signum, expected_rc in handled:
        cleanup_delay = 1.0 if signum == signal.SIGTERM else 0.0
        rc, stdout, stderr, clean, seconds, signal_dir = run_signal_case(
            work,
            cooperative,
            "cooperative",
            signum,
            cleanup_delay=cleanup_delay,
        )
        name = signum.name.removeprefix("SIG")
        check(rc == expected_rc, f"{name} returns {expected_rc}", f"rc={rc}")
        check(
            stderr == f"INFRA security-gate interrupted by {name}\n".encode(),
            f"{name} diagnostic is exact",
            stderr.decode(errors="replace"),
        )
        check(stdout == b"", f"{name} emits no partial unordered evidence")
        check(clean, f"{name} leaves no suite descendant or process group")
        cleanup_path = signal_dir / "cleanup.done"
        cleanup_output = (
            cleanup_path.read_text(encoding="utf-8") if cleanup_path.is_file() else ""
        )
        check(
            cleanup_output == "cleanup complete\n",
            f"{name} permits cooperative suite cleanup",
        )
        if signum == signal.SIGTERM:
            check(
                1.0 <= seconds < 2.5,
                "fast cancellation permits cleanup beyond 500ms before escalation",
                f"seconds={seconds:.3f}",
            )

    stubborn = stubborn_signal_fixture(work)
    rc, stdout, stderr, clean, seconds, _ = run_signal_case(
        work,
        stubborn,
        "stubborn",
        signal.SIGTERM,
        descendant=True,
        repeat_signal=True,
    )
    check(rc == 143, "repeated stubborn cancellation returns 143", f"rc={rc}")
    check(
        stderr == b"INFRA security-gate interrupted by TERM\n" and stdout == b"",
        "repeated stubborn cancellation diagnostic is exact",
        (stdout + stderr).decode(errors="replace"),
    )
    check(clean, "repeated cancellation still removes the registered group")
    check(
        seconds >= 2.5,
        "stubborn cancellation exercises the fast kill fallback",
        f"seconds={seconds:.3f}",
    )

    signal_flood = signal_flood_fixture(work)
    small_helper = transformed_helper(
        work,
        "signal-output-limit",
        (
            (
                "FAST_TERMINATION_SECONDS = 3.0",
                "FAST_TERMINATION_SECONDS = 1.0",
            ),
            (
                "MAX_SUITE_OUTPUT_BYTES = 8 * 1024 * 1024",
                "MAX_SUITE_OUTPUT_BYTES = 64 * 1024",
            ),
            (
                "MAX_TOTAL_OUTPUT_BYTES = 32 * 1024 * 1024",
                "MAX_TOTAL_OUTPUT_BYTES = 256 * 1024",
            ),
        ),
    )
    if small_helper is not None:
        rc, stdout, stderr, clean, _, _ = run_signal_case(
            work,
            signal_flood,
            "signal-flood",
            signal.SIGTERM,
            helper=small_helper,
        )
        check(rc == 143, "signal outranks a cleanup-time output overflow", f"rc={rc}")
        check(
            stdout == b""
            and stderr == b"INFRA security-gate interrupted by TERM\n",
            "signal and output-cap collision has one exact diagnostic",
            (stdout + stderr).decode(errors="replace"),
        )
        check(clean, "signal and output-cap collision removes the registered group")


def transformed_helper(
    work: Path,
    name: str,
    replacements: tuple[tuple[str, str], ...],
) -> Path | None:
    source = HELPER.read_text(encoding="utf-8")
    for old, new in replacements:
        if source.count(old) != 1:
            fail_test(f"{name} sensitivity mutation has one exact source seam")
            return None
        source = source.replace(old, new)
    path = work / "mutants" / name / "scripts/dev/security-gate.py"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(source, encoding="utf-8")
    return path


def make_mutant(work: Path, name: str, old: str, new: str) -> Path | None:
    return transformed_helper(work, name, ((old, new),))


def output_writer(
    work: Path,
    name: str,
    byte_count: int,
    marker: str,
    *,
    keep_running: bool,
) -> Path:
    readiness = ""
    tail = ""
    if keep_running:
        readiness = (
            'printf \'%s\\n\' "$$" > "$CAP_DIR/suite.pid"\n'
            'printf \'%s\\n\' "$$" > "$CAP_DIR/group.id"\n'
        )
        tail = "\nwhile True:\n    time.sleep(1)\n"
    return write_script(
        work,
        name,
        readiness
        + f"""
python3 -I - <<'PY'
import os
import signal
import time

signal.signal(signal.SIGTERM, signal.SIG_IGN)
remaining = {byte_count}
chunk = b"x" * 65536
while remaining:
    payload = chunk[:remaining]
    written = os.write(1, payload)
    remaining -= written
os.write(1, b"\\n{marker}\\n")
{tail}PY
""",
    )


def run_output_limit_case(
    work: Path,
    manifest: Path,
    label: str,
    *,
    helper: Path | None = None,
    jobs: int = 4,
    timeout: float = 4.0,
) -> tuple[int, bytes, bytes, bool, bool]:
    cap_dir = work / f"cap-{label}"
    cap_dir.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env["CAP_DIR"] = str(cap_dir)
    env["AGENT_LAB_SECURITY_GATE_JOBS"] = str(jobs)
    command = (
        [str(GATE), "fast", "--manifest", str(manifest)]
        if helper is None
        else [sys.executable, "-I", str(helper), "fast", "--manifest", str(manifest)]
    )
    process = subprocess.Popen(
        command,
        cwd=ROOT,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    required = (cap_dir / "suite.pid", cap_dir / "group.id")
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline and not all(path.exists() for path in required):
        if process.poll() is not None:
            break
        time.sleep(0.01)
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        os.kill(process.pid, signal.SIGTERM)
        try:
            stdout, stderr = process.communicate(timeout=4)
        except subprocess.TimeoutExpired:
            process.kill()
            stdout, stderr = process.communicate()
    if not all(path.exists() for path in required):
        return process.returncode, stdout, stderr, False, timed_out
    suite_pid = int(required[0].read_text(encoding="ascii").strip())
    pgid = int(required[1].read_text(encoding="ascii").strip())
    clean = wait_gone(suite_pid) and not group_exists(pgid)
    if not clean:
        try:
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    return process.returncode, stdout, stderr, clean, timed_out


def test_output_limits(work: Path) -> None:
    work.mkdir(parents=True, exist_ok=True)
    flood = output_writer(
        work,
        "flood.sh",
        8 * 1024 * 1024 + 65536,
        "DONE flood",
        keep_running=True,
    )
    flood_manifest = write_manifest(
        work,
        "flood.manifest",
        [("flood", flood, "DONE flood")],
    )
    rc, stdout, stderr, clean, timed_out = run_output_limit_case(
        work,
        flood_manifest,
        "production",
    )
    check(
        rc == 125 and not timed_out,
        "a live nonterminating writer hits the suite output cap",
    )
    check(
        stdout == b""
        and stderr
        == b"INFRA suite flood exceeded the output limit of 8388608 bytes\n",
        "suite output-cap diagnostic is exact and emits no captured payload",
        (stdout + stderr).decode(errors="replace"),
    )
    check(clean, "suite output overflow removes its registered process group")

    small_helper = transformed_helper(
        work,
        "small-output-limits",
        (
            (
                "MAX_SUITE_OUTPUT_BYTES = 8 * 1024 * 1024",
                "MAX_SUITE_OUTPUT_BYTES = 256 * 1024",
            ),
            (
                "MAX_TOTAL_OUTPUT_BYTES = 32 * 1024 * 1024",
                "MAX_TOTAL_OUTPUT_BYTES = 512 * 1024",
            ),
        ),
    )
    if small_helper is None:
        return
    first = output_writer(
        work, "aggregate-first.sh", 200 * 1024, "DONE first", keep_running=False
    )
    second = output_writer(
        work, "aggregate-second.sh", 200 * 1024, "DONE second", keep_running=False
    )
    live = output_writer(
        work, "aggregate-live.sh", 200 * 1024, "DONE live", keep_running=True
    )
    aggregate_manifest = write_manifest(
        work,
        "aggregate.manifest",
        [
            ("first", first, "DONE first"),
            ("second", second, "DONE second"),
            ("live", live, "DONE live"),
        ],
    )
    rc, stdout, stderr, clean, timed_out = run_output_limit_case(
        work,
        aggregate_manifest,
        "aggregate",
        helper=small_helper,
        jobs=2,
    )
    check(rc == 125 and not timed_out, "retained plus live output hits the aggregate cap")
    check(
        stdout == b""
        and stderr
        == b"INFRA security-gate suite output exceeded the aggregate limit of 524288 bytes\n",
        "aggregate output-cap diagnostic is exact and emits no captured payload",
        (stdout + stderr).decode(errors="replace"),
    )
    check(clean, "aggregate output overflow removes its registered process group")

    assertion = write_script(
        work,
        "output-collision-assertion.sh",
        "printf 'WARN collision assertion\nDONE collision assertion\n'\n",
    )
    collision_flood = output_writer(
        work,
        "output-collision-flood.sh",
        320 * 1024,
        "DONE collision flood",
        keep_running=False,
    )
    collision_manifest = write_manifest(
        work,
        "output-collision.manifest",
        [
            ("collision-assertion", assertion, "DONE collision assertion"),
            ("collision-flood", collision_flood, "DONE collision flood"),
        ],
    )
    collision = run_gate(collision_manifest, 2, helper=small_helper)
    check(
        collision.rc == 125,
        "runner output infrastructure precedes completed-result classification",
        f"rc={collision.rc}",
    )
    check(
        collision.stdout == b""
        and collision.stderr
        == b"INFRA suite collision-flood exceeded the output limit of 262144 bytes\n",
        "runner output failure emits no partial assertion transcript",
        (collision.stdout + collision.stderr).decode(errors="replace"),
    )


def residual_flood_fixture(work: Path) -> tuple[Path, Path, Path, Path, Path, Path]:
    work.mkdir(parents=True, exist_ok=True)
    completion = work / "descendant-flood-completed"
    group_file = work / "residual-flood.group"
    started = work / "residual-flood.started"
    arm = work / "residual-flood.arm"
    ready = work / "residual-flood.ready"
    flood = write_script(
        work,
        "residual-flood.sh",
        """
printf '%s\n' "$$" > "$GROUP_FILE"
(
  flood() {
    python3 -I - <<'PY'
import os
import time

chunk = b"r" * 4096
for _ in range(256):
    os.write(1, chunk)
    time.sleep(0.002)
PY
    : > "$FLOOD_COMPLETION"
    exit 0
  }
  trap '' TERM
  : > "$FLOOD_STARTED"
  while [ ! -f "$FLOOD_ARM" ]; do sleep 0.002; done
  trap flood TERM
  : > "$FLOOD_READY"
  while :; do sleep 1; done
) &
for ((attempt = 0; attempt < 500; attempt++)); do
  if [ -f "$FLOOD_STARTED" ]; then
    : > "$FLOOD_ARM"
    for ((ready_attempt = 0; ready_attempt < 500; ready_attempt++)); do
      if [ -f "$FLOOD_READY" ]; then
        exit 0
      fi
      sleep 0.002
    done
    exit 125
  fi
  sleep 0.002
done
exit 125
""",
    )
    return (
        write_manifest(
            work,
            "residual-flood.manifest",
            [("residual-flood", flood, "DONE residual flood")],
        ),
        completion,
        group_file,
        started,
        arm,
        ready,
    )


def test_residual_cleanup_output_limit(work: Path) -> None:
    manifest, completion, group_file, started, arm, ready = residual_flood_fixture(work)
    small_helper = transformed_helper(
        work,
        "residual-output-limit",
        (
            (
                "FAST_TERMINATION_SECONDS = 3.0",
                "FAST_TERMINATION_SECONDS = 1.0",
            ),
            (
                "MAX_SUITE_OUTPUT_BYTES = 8 * 1024 * 1024",
                "MAX_SUITE_OUTPUT_BYTES = 64 * 1024",
            ),
            (
                "MAX_TOTAL_OUTPUT_BYTES = 32 * 1024 * 1024",
                "MAX_TOTAL_OUTPUT_BYTES = 256 * 1024",
            ),
        ),
    )
    if small_helper is None:
        return
    result = run_gate(
        manifest,
        1,
        helper=small_helper,
        extra_env={
            "FLOOD_ARM": str(arm),
            "FLOOD_COMPLETION": str(completion),
            "GROUP_FILE": str(group_file),
            "FLOOD_READY": str(ready),
            "FLOOD_STARTED": str(started),
        },
    )
    check(result.rc == 125, "residual descendant output overflow returns infrastructure")
    check(
        result.stdout == b""
        and result.stderr
        == b"INFRA suite residual-flood exceeded the output limit of 65536 bytes\n",
        "residual descendant output-cap diagnostic is exact",
        (result.stdout + result.stderr).decode(errors="replace"),
    )
    check(
        not completion.exists() and result.seconds < 0.8,
        "residual output monitoring kills a flood before it completes",
        f"completion={completion.exists()} seconds={result.seconds:.3f}",
    )
    if group_file.is_file():
        pgid = int(group_file.read_text(encoding="ascii").strip())
        clean = not group_exists(pgid)
        if not clean:
            try:
                os.killpg(pgid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        check(clean, "residual output overflow removes the registered process group")
    else:
        fail_test("residual output fixture records its process group")


def residual_marker_fixture(work: Path) -> tuple[Path, Path, Path]:
    work.mkdir(parents=True, exist_ok=True)
    ready = work / "residual-marker.ready"
    group_file = work / "residual-marker.group"
    script = write_script(
        work,
        "residual-marker.sh",
        """
printf '%s\n' "$$" > "$RESIDUAL_GROUP_FILE"
(
  trap 'printf "DONE residual marker\n"; exit 0' TERM
  : > "$RESIDUAL_READY"
  while :; do sleep 1; done
) &
while [ ! -e "$RESIDUAL_READY" ]; do sleep 0.002; done
exit 0
""",
    )
    return (
        write_manifest(
            work,
            "residual-marker.manifest",
            [("residual-marker", script, "DONE residual marker")],
        ),
        ready,
        group_file,
    )


def test_residual_marker_forgery(work: Path) -> None:
    manifest, ready, group_file = residual_marker_fixture(work)
    result = run_gate(
        manifest,
        1,
        extra_env={
            "RESIDUAL_READY": str(ready),
            "RESIDUAL_GROUP_FILE": str(group_file),
        },
    )
    check(result.rc == 125, "a zero-exit suite with a residual group is infrastructure")
    check(
        result.stderr
        == b"INFRA suite residual-marker reported infrastructure failure\n",
        "residual-marker forgery has an exact infrastructure diagnostic",
        result.stderr.decode(errors="replace"),
    )
    check(
        b"SECURITY GATE PASS" not in result.stdout,
        "gate-induced descendant output cannot produce a pass",
    )
    if group_file.is_file():
        pgid = int(group_file.read_text(encoding="ascii").strip())
        clean = not group_exists(pgid)
        if not clean:
            try:
                os.killpg(pgid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        check(clean, "residual-marker cleanup removes the registered process group")
    else:
        fail_test("residual-marker fixture records its process group")


def test_sensitivity_mutants(work: Path) -> None:
    deadline_mutant = transformed_helper(
        work,
        "deadline-removal",
        (
            ("if time.monotonic() >= gate_deadline:", "if False:  # deadline-removal mutant"),
            ("expired = [item for item in running if time.monotonic() >= item.deadline]", "expired = []  # deadline-removal mutant"),
            ("FAST_SUITE_EXECUTION_SECONDS = 120.0", "FAST_SUITE_EXECUTION_SECONDS = 0.10"),
            ("FAST_GATE_PHASE_SECONDS = 600.0", "FAST_GATE_PHASE_SECONDS = 0.20"),
        ),
    )
    if deadline_mutant is not None:
        fixture_work = work / "mutant-deadline"
        group_file = fixture_work / "suite.group"
        hanging = write_script(
            fixture_work,
            "hang.sh",
            "printf '%s\\n' \"$$\" > \"$GROUP_FILE\"\nsleep 30\n",
        )
        manifest = write_manifest(fixture_work, "hang.manifest", [("hang", hanging, "DONE hang")])
        env = dict(os.environ)
        env["GROUP_FILE"] = str(group_file)
        process = subprocess.Popen(
            [sys.executable, "-I", str(deadline_mutant), "fast", "--manifest", str(manifest)],
            cwd=ROOT,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        try:
            process.communicate(timeout=0.6)
            timed_out = False
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
        if group_file.is_file():
            try:
                os.killpg(int(group_file.read_text(encoding="ascii")), signal.SIGKILL)
            except ProcessLookupError:
                pass
        check(timed_out, "deadline-removal sensitivity mutation turns RED")

    marker_mutant = make_mutant(
        work,
        "premature-marker",
        "marker_valid = (\n                    marker_count == 1\n                    and bool(nonempty_lines)\n                    and nonempty_lines[-1] == suite.marker\n                )",
        "marker_valid = suite.marker in decoded  # premature-marker mutant",
    )
    if marker_mutant is not None:
        fixture_work = work / "mutant-marker"
        prefixed = write_script(fixture_work, "prefixed.sh", "printf 'prefix DONE exact\\n'\n")
        manifest = write_manifest(fixture_work, "prefixed.manifest", [("prefixed", prefixed, "DONE exact")])
        result = run_gate(manifest, 1, helper=marker_mutant)
        check(result.rc == 0, "premature-marker sensitivity mutation turns RED")

    order_mutant = make_mutant(
        work,
        "order",
        "for suite, status, output in zip(suites, statuses, outputs, strict=True):",
        "for suite, status, output in reversed(list(zip(suites, statuses, outputs, strict=True))):",
    )
    if order_mutant is not None:
        manifest, expected_order, completion_log = reverse_fixture(work / "mutant-order")
        completion_log.parent.mkdir(parents=True, exist_ok=True)
        result = run_gate(
            manifest,
            4,
            helper=order_mutant,
            extra_env={"COMPLETION_LOG": str(completion_log)},
        )
        check(
            headings(result.stdout) != expected_order,
            "manifest-order sensitivity mutation turns RED",
        )

    bound_mutant = make_mutant(
        work,
        "bound",
        "len(running) < jobs",
        "len(running) < len(suites)",
    )
    if bound_mutant is not None:
        fixture_work = work / "mutant-bound"
        fixture_work.mkdir(parents=True, exist_ok=True)
        manifest = bound_fixture(fixture_work)
        _, observed = run_bound_case(
            fixture_work,
            manifest,
            "mutant-bound",
            "fast",
            helper=bound_mutant,
        )
        check(observed > 4, "worker-bound sensitivity mutation turns RED", f"observed={observed}")

    precedence_mutant = make_mutant(
        work,
        "precedence",
        "if failed or skipped:\n        return 1\n    if infrastructure:\n        return 125",
        "if infrastructure:\n        return 125\n    if failed or skipped:\n        return 1",
    )
    if precedence_mutant is not None:
        fixture_work = work / "mutant-precedence"
        fixture_work.mkdir(parents=True, exist_ok=True)
        manifest, _, execution_log = classification_fixture(fixture_work)
        result = run_gate(
            manifest,
            4,
            helper=precedence_mutant,
            extra_env={"EXEC_LOG": str(execution_log)},
        )
        check(result.rc == 125, "failure-precedence sensitivity mutation turns RED")

    cleanup_mutant = transformed_helper(
        work,
        "cleanup",
        (
            ("FAST_TERMINATION_SECONDS = 3.0", "FAST_TERMINATION_SECONDS = 0.1"),
            (
                "for item in running:\n        if process_group_alive(item.process):\n            try:\n                os.killpg(item.process.pid, signal.SIGKILL)",
                "for item in running:\n        if process_group_alive(item.process):\n            try:\n                item.process.kill()",
            ),
        ),
    )
    if cleanup_mutant is not None:
        fixture_work = work / "mutant-cleanup"
        fixture_work.mkdir(parents=True, exist_ok=True)
        manifest = stubborn_signal_fixture(fixture_work)
        _, _, _, clean, _, _ = run_signal_case(
            fixture_work,
            manifest,
            "mutant-cleanup",
            signal.SIGTERM,
            helper=cleanup_mutant,
            descendant=True,
            disappearance_timeout=MUTANT_LEAK_OBSERVATION_SECONDS,
        )
        check(not clean, "descendant-cleanup sensitivity mutation turns RED")

    mask_mutant = make_mutant(
        work,
        "child-mask",
        "                        preexec_fn=restore_child_signal_mask,\n",
        "",
    )
    if mask_mutant is not None:
        fixture_work = work / "mutant-child-mask"
        fixture_work.mkdir(parents=True, exist_ok=True)
        manifest = child_signal_mask_fixture(fixture_work)
        result = run_gate(manifest, 4, helper=mask_mutant)
        check(result.rc != 0, "child-signal-mask sensitivity mutation turns RED")

    output_mutant = transformed_helper(
        work,
        "live-output-limit",
        (
            ("FAST_TERMINATION_SECONDS = 3.0", "FAST_TERMINATION_SECONDS = 0.1"),
            ("MAX_SUITE_OUTPUT_BYTES = 8 * 1024 * 1024", "MAX_SUITE_OUTPUT_BYTES = 256 * 1024"),
            ("MAX_TOTAL_OUTPUT_BYTES = 32 * 1024 * 1024", "MAX_TOTAL_OUTPUT_BYTES = 512 * 1024"),
            (
                "            drain_ready_outputs(\n"
                "                selector,\n"
                "                suites,\n"
                "                running,\n"
                "                total_output_bytes,\n"
                "                0.005,\n"
                "            )\n",
                "            time.sleep(0.005)  # output-limit sensitivity mutant\n",
            ),
        ),
    )
    if output_mutant is not None:
        fixture_work = work / "mutant-live-output"
        fixture_work.mkdir(parents=True, exist_ok=True)
        flood = output_writer(
            fixture_work,
            "mutant-flood.sh",
            320 * 1024,
            "DONE mutant flood",
            keep_running=True,
        )
        manifest = write_manifest(
            fixture_work,
            "mutant-flood.manifest",
            [("mutant-flood", flood, "DONE mutant flood")],
        )
        rc, _, _, clean, timed_out = run_output_limit_case(
            fixture_work,
            manifest,
            "mutant",
            helper=output_mutant,
            timeout=0.5,
        )
        check(
            timed_out,
            "live-output-cap sensitivity mutation turns RED",
            f"timed_out={timed_out} rc={rc}",
        )
        check(clean, "live-output-cap mutant cleanup removes its process group")

    if sys.platform == "linux":
        protection_mutant = make_mutant(
            work,
            "parent-capture-protection",
            "    protect_runner_process()\n",
            "",
        )
        if protection_mutant is not None:
            fixture_work = work / "mutant-parent-capture"
            fixture_work.mkdir(parents=True, exist_ok=True)
            manifest, victim_pid_file = cross_capture_fixture(fixture_work)
            result = run_gate(
                manifest,
                2,
                helper=protection_mutant,
                extra_env={"VICTIM_PID_FILE": str(victim_pid_file)},
            )
            check(
                result.rc == 1 and b"PARENT_FDS_VISIBLE\n" in result.stdout,
                "parent-capture-protection sensitivity mutation turns RED",
                f"rc={result.rc}",
            )

    residual_mutant = transformed_helper(
        work,
        "residual-output-monitor",
        (
            (
                "FAST_TERMINATION_SECONDS = 3.0",
                "FAST_TERMINATION_SECONDS = 1.0",
            ),
            (
                "MAX_SUITE_OUTPUT_BYTES = 8 * 1024 * 1024",
                "MAX_SUITE_OUTPUT_BYTES = 64 * 1024",
            ),
            (
                "MAX_TOTAL_OUTPUT_BYTES = 32 * 1024 * 1024",
                "MAX_TOTAL_OUTPUT_BYTES = 256 * 1024",
            ),
            (
                "    while True:\n"
                "        monitor_output()\n"
                "        if not process_group_alive(item.process):\n",
                "    while True:\n"
                "        if not process_group_alive(item.process):\n",
            ),
        ),
    )
    if residual_mutant is not None:
        fixture_work = work / "mutant-residual-output"
        fixture_work.mkdir(parents=True, exist_ok=True)
        manifest, completion, group_file, started, arm, ready = residual_flood_fixture(fixture_work)
        result = run_gate(
            manifest,
            1,
            helper=residual_mutant,
            extra_env={
                "FLOOD_ARM": str(arm),
                "FLOOD_COMPLETION": str(completion),
                "GROUP_FILE": str(group_file),
                "FLOOD_READY": str(ready),
                "FLOOD_STARTED": str(started),
            },
        )
        check(
            result.rc == 125 and result.seconds >= 0.8,
            "residual-output-monitor sensitivity mutation turns RED",
            f"rc={result.rc} seconds={result.seconds:.3f}",
        )
        if group_file.is_file():
            pgid = int(group_file.read_text(encoding="ascii").strip())
            try:
                os.killpg(pgid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    repeated_signal_mutant = transformed_helper(
        work,
        "repeated-signal",
        (
            (
                "    def interrupted(signum: int, _frame: object) -> None:\n"
                "        for handled_signal in HANDLED_SIGNALS:\n"
                "            signal.signal(handled_signal, signal.SIG_IGN)\n"
                "        try:\n",
                "    def interrupted(signum: int, _frame: object) -> None:\n"
                "        for handled_signal in HANDLED_SIGNALS:\n"
                "            signal.signal(handled_signal, signal.SIG_DFL)\n"
                "        try:\n",
            ),
        ),
    )
    if repeated_signal_mutant is not None:
        fixture_work = work / "mutant-repeated-signal"
        fixture_work.mkdir(parents=True, exist_ok=True)
        manifest = stubborn_signal_fixture(fixture_work)
        rc, _, _, clean, _, _ = run_signal_case(
            fixture_work,
            manifest,
            "mutant-repeated-signal",
            signal.SIGTERM,
            helper=repeated_signal_mutant,
            descendant=True,
            repeat_signal=True,
            disappearance_timeout=MUTANT_LEAK_OBSERVATION_SECONDS,
        )
        check(
            rc != 143 and not clean,
            "repeated-signal sensitivity mutation turns RED",
            f"rc={rc} clean={clean}",
        )

    residual_marker_mutant = make_mutant(
        work,
        "residual-marker",
        "                if had_residual and status == 0:\n"
        "                    status = 125\n",
        "",
    )
    if residual_marker_mutant is not None:
        fixture_work = work / "mutant-residual-marker"
        fixture_work.mkdir(parents=True, exist_ok=True)
        manifest, ready, group_file = residual_marker_fixture(fixture_work)
        result = run_gate(
            manifest,
            1,
            helper=residual_marker_mutant,
            extra_env={
                "RESIDUAL_READY": str(ready),
                "RESIDUAL_GROUP_FILE": str(group_file),
            },
        )
        check(
            result.rc == 0 and b"SECURITY GATE PASS" in result.stdout,
            "residual-marker sensitivity mutation turns RED",
            f"rc={result.rc}",
        )


def main() -> int:
    if sys.version_info < (3, 11):
        print("INFRA security-gate concurrency contract requires Python 3.11 or newer", file=sys.stderr)
        return 125
    if not GATE.is_file() or not os.access(GATE, os.X_OK):
        fail_test("stable security-gate entrypoint exists and is executable")
    else:
        pass_test("stable security-gate entrypoint exists and is executable")
    if not HELPER.is_file():
        fail_test("stdlib security-gate helper exists")
        print(f"SUMMARY failures={failures}")
        return 1
    pass_test("stdlib security-gate helper exists")

    with tempfile.TemporaryDirectory(prefix="agent-lab-gate-concurrency-") as directory:
        work = Path(directory)
        test_reverse_completion(work / "reverse")
        test_classification_and_evidence(work / "classification")
        test_worker_bound_and_docker_serial(work / "bound")
        test_preflight_signal_cleanup(work / "preflight-signal")
        test_evidence_fail_closed(work / "evidence")
        test_evidence_tampering(work / "evidence-tampering")
        test_cross_suite_capture_forgery(work / "cross-capture")
        test_child_signal_mask(work / "child-mask")
        test_ci_foundation_limits_and_deadlines(work / "ci-foundation")
        test_signal_cleanup(work / "signal")
        test_output_limits(work / "output-limits")
        test_residual_cleanup_output_limit(work / "residual-output")
        test_residual_marker_forgery(work / "residual-marker")
        test_sensitivity_mutants(work / "sensitivity")
    print(f"SUMMARY failures={failures}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
