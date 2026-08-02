#!/usr/bin/env python3
"""Adversarial Experiment-store filesystem, locking, and recovery cases."""

from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import hashlib
from importlib.util import module_from_spec, spec_from_file_location
import io
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time
from typing import Callable


REPO_ROOT = Path(__file__).resolve().parents[2]
AGENT_LAB = REPO_ROOT / "scripts" / "agent-lab"
AGENT_LAB_MODULE = REPO_ROOT / "scripts" / "agent-lab.py"
STORE_MODULE = REPO_ROOT / "scripts" / "experiment_store.py"
CUE_TOOLS = REPO_ROOT / ".cache" / "dev" / "tools" / "cue"
CEDAR_TOOLS = REPO_ROOT / ".cache" / "dev" / "tools" / "cedar"
SUBJECT = "registry.example/team/worker@sha256:" + "a" * 64
OTHER_SUBJECT = "registry.example/team/worker@sha256:" + "b" * 64
FAULT_POINTS = (
    "experiment artifact.after_write",
    "experiment receipt.after_fsync",
    "experiment envelope.before_noreplace",
    "experiment envelope.after_noreplace",
    "experiment store root.after_fsync",
)


def load_module(path: Path, name: str):
    spec = spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"{path.name} cannot be loaded")
    module = module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


MODULE = load_module(AGENT_LAB_MODULE, "agent_lab_install_state")
try:
    STORE = load_module(STORE_MODULE, "agent_lab_experiment_store_state")
    STORE_LOAD_ERROR: BaseException | None = None
except BaseException as error:  # Missing production is expected RED, not harness infrastructure.
    STORE = None
    STORE_LOAD_ERROR = error

FAILURES = 0
INFRA = 0
OBSERVED: list[str] = []


def check(assertion: str, condition: bool, message: str, detail: str = "") -> None:
    global FAILURES
    OBSERVED.append(assertion)
    if condition:
        print(f"PASS {assertion} {message}")
    else:
        FAILURES += 1
        suffix = f" ({detail})" if detail else ""
        print(f"FAIL {assertion} {message}{suffix}")


def command_environment() -> dict[str, str]:
    return {
        "PATH": "/usr/bin:/bin",
        "LANG": "C",
        "LC_ALL": "C",
        "AGENT_LAB_CUE_TOOL_DIR": str(CUE_TOOLS),
        "AGENT_LAB_CEDAR_TOOL_DIR": str(CEDAR_TOOLS),
    }


def run_command(arguments: list[str], timeout: float = 30.0) -> subprocess.CompletedProcess[bytes]:
    global INFRA
    try:
        process = subprocess.Popen(
            arguments,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=command_environment(),
            start_new_session=True,
        )
    except OSError as error:
        INFRA += 1
        return subprocess.CompletedProcess(arguments, 125, b"", str(error).encode())
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        INFRA += 1
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        stdout, stderr = process.communicate()
        return subprocess.CompletedProcess(arguments, 125, stdout, stderr + b"\nHARNESS TIMEOUT\n")
    return subprocess.CompletedProcess(arguments, process.returncode, stdout, stderr)


def cli(home: Path, *arguments: str) -> subprocess.CompletedProcess[bytes]:
    return run_command([str(AGENT_LAB), "--home", str(home), *arguments])


def start_cli(home: Path, source: Path) -> subprocess.Popen[bytes]:
    return subprocess.Popen(
        [str(AGENT_LAB), "--home", str(home), "experiment", "install", str(source)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=command_environment(),
        start_new_session=True,
    )


def finish_process(
    process: subprocess.Popen[bytes],
    timeout: float = 30.0,
) -> subprocess.CompletedProcess[bytes]:
    global INFRA
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        INFRA += 1
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        stdout, stderr = process.communicate()
        return subprocess.CompletedProcess(
            process.args,
            125,
            stdout,
            stderr + b"\nHARNESS TIMEOUT\n",
        )
    return subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)


def new_home(root: Path, name: str) -> Path:
    home = root / name
    completed = cli(home, "init")
    if completed.returncode != 0:
        raise RuntimeError(
            f"temporary home init failed: rc={completed.returncode} "
            f"stderr={completed.stderr.decode(errors='replace')}"
        )
    return home


def source_directory(
    root: Path,
    directory: str,
    *,
    requested_name: str = "first-experiment",
    subject: str = SUBJECT,
    command: str = "serve",
    catalog_name: str | None = None,
) -> Path:
    source = root / directory
    source.mkdir(mode=0o700)
    if catalog_name is None:
        selector = f'digestRef: "{subject}"'
    else:
        selector = f'catalogName: "{catalog_name}"'
    data = (
        "package experiment\n\n"
        "experiment: {\n"
        '\tapiVersion: "agent-lab/v0alpha1"\n'
        '\tkind:       "Experiment"\n'
        f'\tmetadata: name: "{requested_name}"\n'
        "\tspec: members: [{\n"
        '\t\tname: "worker"\n'
        f"\t\timage: {selector}\n"
        f'\t\tcommand: ["{command}"]\n'
        "\t}]\n"
        "}\n"
    ).encode("utf-8")
    path = source / "experiment.cue"
    path.write_bytes(data)
    path.chmod(0o600)
    return source


def fingerprint(root: Path) -> tuple[tuple[str, str, int, int, int, str], ...]:
    if not root.exists() and not root.is_symlink():
        return ()
    records: list[tuple[str, str, int, int, int, str]] = []

    def visit(path: Path, relative: str) -> None:
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            kind = "l"
            identity = os.readlink(path)
        elif stat.S_ISREG(metadata.st_mode):
            kind = "f"
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                while chunk := stream.read(65_536):
                    digest.update(chunk)
            identity = digest.hexdigest()
        elif stat.S_ISDIR(metadata.st_mode):
            kind = "d"
            identity = ""
        else:
            kind = "o"
            identity = ""
        records.append(
            (
                relative,
                kind,
                stat.S_IMODE(metadata.st_mode),
                metadata.st_nlink,
                metadata.st_size,
                identity,
            )
        )
        if kind == "d":
            children = sorted(path.iterdir(), key=lambda item: os.fsencode(item.name))
            for child in children:
                child_relative = child.name if relative == "." else f"{relative}/{child.name}"
                visit(child, child_relative)

    visit(root, ".")
    return tuple(records)


def json_object(completed: subprocess.CompletedProcess[bytes]) -> dict[str, object] | None:
    if completed.returncode != 0:
        return None
    try:
        value = json.loads(completed.stdout)
    except (UnicodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def store_install(
    home: Path,
    source: Path,
    *,
    fault: Callable[[str], None] | None = None,
) -> tuple[int | None, dict[str, object] | None, BaseException | None]:
    if STORE is None:
        return None, None, STORE_LOAD_ERROR or RuntimeError("experiment store module is missing")
    operation = getattr(STORE, "install_directory", None)
    if not callable(operation):
        return None, None, RuntimeError("experiment_store.install_directory is missing")
    try:
        value = operation(home, source, fault=fault)
        if not isinstance(value, dict):
            return None, None, RuntimeError("install_directory returned a non-object")
        return 0, value, None
    except getattr(STORE, "StoreReject", ()) as error:
        return 1, None, error
    except getattr(STORE, "StoreInfrastructure", ()) as error:
        return 125, None, error
    except BaseException as error:  # An uncontained production fault is RED, not harness infra.
        return None, None, error


def module_main(
    home: Path,
    arguments: list[str],
    output: io.TextIOBase | None = None,
) -> tuple[int | None, str, BaseException | None]:
    stream = output if output is not None else io.StringIO()
    errors = io.StringIO()
    old_cue = os.environ.get("AGENT_LAB_CUE_TOOL_DIR")
    old_cedar = os.environ.get("AGENT_LAB_CEDAR_TOOL_DIR")
    os.environ["AGENT_LAB_CUE_TOOL_DIR"] = str(CUE_TOOLS)
    os.environ["AGENT_LAB_CEDAR_TOOL_DIR"] = str(CEDAR_TOOLS)
    try:
        with redirect_stdout(stream), redirect_stderr(errors):
            result = MODULE.main(["--home", str(home), *arguments])
        return result, errors.getvalue(), None
    except BaseException as error:  # An uncontained production fault is RED, not harness infra.
        return None, errors.getvalue(), error
    finally:
        if old_cue is None:
            os.environ.pop("AGENT_LAB_CUE_TOOL_DIR", None)
        else:
            os.environ["AGENT_LAB_CUE_TOOL_DIR"] = old_cue
        if old_cedar is None:
            os.environ.pop("AGENT_LAB_CEDAR_TOOL_DIR", None)
        else:
            os.environ["AGENT_LAB_CEDAR_TOOL_DIR"] = old_cedar


def hard_exit_install(home: Path, source: Path, point: str) -> int:
    pid = os.fork()
    if pid == 0:
        def stop_at(observed: str) -> None:
            if observed == point:
                os._exit(99)

        result, _, _ = store_install(home, source, fault=stop_at)
        os._exit(97 if result == 0 else 96)
    deadline = time.monotonic() + 30.0
    while time.monotonic() < deadline:
        waited, status = os.waitpid(pid, os.WNOHANG)
        if waited == pid:
            return os.waitstatus_to_exitcode(status)
        time.sleep(0.01)
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    global INFRA
    INFRA += 1
    return 124


def lock_is_blocked(path: Path) -> bool:
    program = (
        "import fcntl, os, sys\n"
        "fd=os.open(sys.argv[1], os.O_RDWR|getattr(os,'O_CLOEXEC',0))\n"
        "try:\n"
        " fcntl.flock(fd, fcntl.LOCK_EX|fcntl.LOCK_NB)\n"
        "except BlockingIOError:\n"
        " raise SystemExit(3)\n"
        "raise SystemExit(0)\n"
    )
    completed = run_command([sys.executable, "-I", "-c", program, str(path)], timeout=5.0)
    return completed.returncode == 3


class BrokenOutput(io.StringIO):
    def write(self, value: str) -> int:
        raise OSError("injected result-output failure")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="agent-lab-install-state-") as directory:
        root = Path(directory)
        direct_source = source_directory(root, "direct-source")

        mode_home = new_home(root, "unsafe-mode-home")
        mode_store = mode_home / "experiments"
        mode_store.chmod(0o755)
        mode_before = fingerprint(mode_store)
        mode_result = cli(mode_home, "experiment", "install", str(direct_source))
        mode_after = fingerprint(mode_store)

        symlink_home = new_home(root, "symlink-store-home")
        symlink_store = symlink_home / "experiments"
        outside_store = root / "outside-store"
        symlink_store.rename(outside_store)
        os.symlink(outside_store, symlink_store)
        symlink_before = fingerprint(outside_store)
        symlink_result = cli(symlink_home, "experiment", "install", str(direct_source))
        symlink_after = fingerprint(outside_store)

        stage_home = new_home(root, "symlink-stage-home")
        stage = stage_home / "experiments" / ".staging"
        outside_stage = root / "outside-stage"
        stage.rename(outside_stage)
        os.symlink(outside_stage, stage)
        stage_before = fingerprint(outside_stage)
        stage_result = cli(stage_home, "experiment", "install", str(direct_source))
        stage_after = fingerprint(outside_stage)

        cross_home = new_home(root, "cross-device-home")
        cross_stage = cross_home / "experiments" / ".staging"
        cross_before = fingerprint(cross_home / "experiments")
        original_fstat = MODULE.os.fstat
        original_cross_lstat = MODULE.os.lstat
        cross_injected = False

        def cross_device_metadata(metadata: os.stat_result) -> os.stat_result:
            nonlocal cross_injected
            values = list(metadata)
            values[2] = metadata.st_dev + 1
            cross_injected = True
            return os.stat_result(values)

        def cross_device_fstat(descriptor: int):
            nonlocal cross_injected
            metadata = original_fstat(descriptor)
            try:
                target = os.readlink(f"/proc/self/fd/{descriptor}")
            except OSError:
                return metadata
            if target.rstrip("/") == str(cross_stage):
                return cross_device_metadata(metadata)
            return metadata

        def cross_device_lstat(path: object, *args, **kwargs):
            metadata = original_cross_lstat(path, *args, **kwargs)
            try:
                target = os.fsdecode(os.fspath(path)).rstrip("/")
            except TypeError:
                return metadata
            if target == str(cross_stage):
                return cross_device_metadata(metadata)
            return metadata

        MODULE.os.fstat = cross_device_fstat
        MODULE.os.lstat = cross_device_lstat
        try:
            cross_rc, _, cross_error = module_main(
                cross_home,
                ["experiment", "install", str(direct_source)],
            )
        finally:
            MODULE.os.lstat = original_cross_lstat
            MODULE.os.fstat = original_fstat
        cross_after = fingerprint(cross_home / "experiments")
        check(
            "IST-STATE-001",
            mode_result.returncode == 125
            and mode_before == mode_after
            and symlink_result.returncode == 125
            and symlink_before == symlink_after
            and stage_result.returncode == 125
            and stage_before == stage_after
            and cross_injected
            and cross_rc == 125
            and cross_error is None
            and cross_before == cross_after,
            "unsafe, linked, or cross-filesystem store and staging roots fail before publication",
            (
                f"mode={mode_result.returncode}/{mode_before != mode_after} "
                f"store_link={symlink_result.returncode}/{symlink_before != symlink_after} "
                f"stage_link={stage_result.returncode}/{stage_before != stage_after} "
                f"cross={cross_rc}/{cross_injected}/{cross_error!r}/{cross_before != cross_after}"
            ),
        )

        symlink_lock_home = new_home(root, "symlink-lock-home")
        lock = symlink_lock_home / "state" / "locks" / "experiments.lock"
        saved_lock = root / "saved-experiments.lock"
        lock.rename(saved_lock)
        os.symlink(saved_lock, lock)
        lock_before = fingerprint(saved_lock)
        symlink_lock_result = cli(
            symlink_lock_home,
            "experiment",
            "install",
            str(direct_source),
        )
        lock_after = fingerprint(saved_lock)
        hardlink_lock_home = new_home(root, "hardlink-lock-home")
        hardlink_lock = hardlink_lock_home / "state" / "locks" / "experiments.lock"
        os.link(hardlink_lock, root / "second-experiments-lock-link")
        hardlink_result = cli(
            hardlink_lock_home,
            "experiment",
            "install",
            str(direct_source),
        )
        check(
            "IST-LOCK-001",
            symlink_lock_result.returncode == 125
            and lock_before == lock_after
            and hardlink_result.returncode == 125
            and not tuple((hardlink_lock_home / "experiments" / ".staging").iterdir()),
            "the pre-created receipt-bound store lock is safe-opened with stable identity",
            (
                f"symlink={symlink_lock_result.returncode}/{lock_before != lock_after} "
                f"hardlink={hardlink_result.returncode}"
            ),
        )

        existing_home = new_home(root, "existing-target-home")
        existing_target = existing_home / "experiments" / "first-experiment"
        existing_target.mkdir(mode=0o700)
        sentinel = existing_target / "foreign"
        sentinel.write_bytes(b"foreign\n")
        sentinel.chmod(0o600)
        existing_before = fingerprint(existing_target)
        existing_result = cli(existing_home, "experiment", "install", str(direct_source))
        existing_after = fingerprint(existing_target)

        race_home = new_home(root, "publication-race-home")
        race_target = race_home / "experiments" / "first-experiment"
        race_triggered = False

        def create_racing_target(point: str) -> None:
            nonlocal race_triggered
            if point == "experiment envelope.before_noreplace" and not race_triggered:
                race_triggered = True
                race_target.mkdir(mode=0o700)
                marker = race_target / "foreign"
                marker.write_bytes(b"racing foreign target\n")
                marker.chmod(0o600)

        race_rc, _, race_error = store_install(
            race_home,
            direct_source,
            fault=create_racing_target,
        )
        race_fingerprint = fingerprint(race_target)
        check(
            "IST-STATE-002",
            existing_result.returncode == 125
            and existing_before == existing_after
            and race_triggered
            and race_rc == 125
            and race_error is not None
            and any(
                item[0] == "foreign"
                and item[-1]
                == hashlib.sha256(b"racing foreign target\n").hexdigest()
                for item in race_fingerprint
            ),
            "ambiguous and racing final targets are preserved by atomic no-replace publication",
            (
                f"existing={existing_result.returncode}/{existing_before != existing_after} "
                f"race={race_rc}/{race_triggered}/{race_error!r}/{race_fingerprint!r}"
            ),
        )

        foreign_home = new_home(root, "foreign-stage-home")
        foreign_wrapper = foreign_home / "experiments" / ".staging" / "foreign-wrapper"
        (foreign_wrapper / "payload").mkdir(mode=0o700, parents=True)
        foreign_intent = foreign_wrapper / "intent.json"
        foreign_intent.write_bytes(b'{"owner":"foreign"}\n')
        foreign_intent.chmod(0o600)
        foreign_before = fingerprint(foreign_wrapper)
        foreign_result = cli(foreign_home, "experiment", "install", str(direct_source))
        foreign_after = fingerprint(foreign_wrapper)

        bound_home = new_home(root, "overbound-stage-home")
        bound_stage = bound_home / "experiments" / ".staging"
        for index in range(17):
            path = bound_stage / f"foreign-{index:02d}"
            path.write_bytes(b"x")
            path.chmod(0o600)
        bound_before = fingerprint(bound_stage)
        bound_result = cli(bound_home, "experiment", "install", str(direct_source))
        bound_after = fingerprint(bound_stage)
        check(
            "IST-BOUND-001",
            foreign_result.returncode == 125
            and foreign_before == foreign_after
            and bound_result.returncode == 125
            and bound_before == bound_after,
            "unknown or over-bound staging residue blocks mutation without broad deletion",
            (
                f"foreign={foreign_result.returncode}/{foreign_before != foreign_after} "
                f"bound={bound_result.returncode}/{bound_before != bound_after}"
            ),
        )

        tamper_home = new_home(root, "committed-tamper-home")
        installed = cli(tamper_home, "experiment", "install", str(direct_source))
        envelope = tamper_home / "experiments" / "first-experiment"
        link_detected = mode_detected = digest_detected = restored = False
        tamper_detail = f"install={installed.returncode}"
        if installed.returncode == 0 and envelope.is_dir():
            records = sorted((envelope / "records").glob("*.json"))
            if records:
                record = records[0]
                outside_link = root / "outside-record-link"
                os.link(record, outside_link)
                linked_inspect = cli(tamper_home, "experiment", "inspect", "first-experiment")
                link_detected = linked_inspect.returncode == 125
                outside_link.unlink()
                restored_inspect = cli(tamper_home, "experiment", "inspect", "first-experiment")
                restored = restored_inspect.returncode == 0
                envelope.chmod(0o700)
                mode_inspect = cli(tamper_home, "experiment", "inspect", "first-experiment")
                mode_detected = mode_inspect.returncode == 125
                envelope.chmod(0o500)
                raw = record.read_bytes()
                record.chmod(0o600)
                record.write_bytes(bytes([raw[0] ^ 1]) + raw[1:])
                record.chmod(0o400)
                digest_inspect = cli(tamper_home, "experiment", "inspect", "first-experiment")
                digest_detected = digest_inspect.returncode == 125
                tamper_detail += (
                    f" link={linked_inspect.returncode} restore={restored_inspect.returncode} "
                    f"mode={mode_inspect.returncode} digest={digest_inspect.returncode}"
                )
        check(
            "IST-STATE-003",
            installed.returncode == 0
            and link_detected
            and restored
            and mode_detected
            and digest_detected,
            "inspect safe-reopens the whole receipt and detects link, mode, and byte drift",
            tamper_detail,
        )

        identical_home = new_home(root, "identical-concurrency-home")
        first = start_cli(identical_home, direct_source)
        second = start_cli(identical_home, direct_source)
        identical_results = [finish_process(first), finish_process(second)]
        identical_values = [json_object(item) for item in identical_results]
        identical_changes = sorted(
            value.get("changed")
            for value in identical_values
            if isinstance(value, dict) and isinstance(value.get("changed"), bool)
        )
        identical_inspect = cli(
            identical_home,
            "experiment",
            "inspect",
            "first-experiment",
        )
        check(
            "IST-CONC-001",
            [item.returncode for item in identical_results] == [0, 0]
            and identical_changes == [False, True]
            and identical_inspect.returncode == 0
            and not tuple((identical_home / "experiments" / ".staging").iterdir()),
            "concurrent identical installs publish once and return one verified idempotent success",
            (
                f"rcs={[item.returncode for item in identical_results]!r} "
                f"changes={identical_changes!r} inspect={identical_inspect.returncode}"
            ),
        )

        conflict_home = new_home(root, "different-concurrency-home")
        conflict_one = source_directory(
            root,
            "conflict-source-one",
            command="winner-one",
        )
        conflict_two = source_directory(
            root,
            "conflict-source-two",
            command="winner-two",
        )
        one = start_cli(conflict_home, conflict_one)
        two = start_cli(conflict_home, conflict_two)
        conflict_results = [finish_process(one), finish_process(two)]
        conflict_inspect = cli(
            conflict_home,
            "experiment",
            "inspect",
            "first-experiment",
        )
        check(
            "IST-CONC-002",
            sorted(item.returncode for item in conflict_results) == [0, 1]
            and conflict_inspect.returncode == 0
            and not tuple((conflict_home / "experiments" / ".staging").iterdir()),
            "concurrent different candidates have one winner and one ordinary conflict",
            (
                f"rcs={[item.returncode for item in conflict_results]!r} "
                f"inspect={conflict_inspect.returncode}"
            ),
        )

        seam_home = new_home(root, "fault-seam-home")
        observed_points: list[str] = []
        seam_rc, seam_value, seam_error = store_install(
            seam_home,
            direct_source,
            fault=observed_points.append,
        )
        crash_failures: list[str] = []
        for index, point in enumerate(
            (
                "experiment artifact.after_write",
                "experiment receipt.after_fsync",
                "experiment envelope.after_noreplace",
                "experiment store root.after_fsync",
            )
        ):
            crash_home = new_home(root, f"crash-home-{index}")
            child_rc = hard_exit_install(crash_home, direct_source, point)
            before_inspect_stage = fingerprint(crash_home / "experiments" / ".staging")
            inspected = cli(crash_home, "experiment", "inspect", "first-experiment")
            after_inspect_stage = fingerprint(crash_home / "experiments" / ".staging")
            retried = cli(crash_home, "experiment", "install", str(direct_source))
            retry_value = json_object(retried)
            committed_point = point in {
                "experiment envelope.after_noreplace",
                "experiment store root.after_fsync",
            }
            expected_changed = not committed_point
            if not (
                child_rc == 99
                and inspected.returncode == (0 if committed_point else 1)
                and before_inspect_stage == after_inspect_stage
                and retried.returncode == 0
                and isinstance(retry_value, dict)
                and retry_value.get("changed") is expected_changed
                and not tuple((crash_home / "experiments" / ".staging").iterdir())
            ):
                crash_failures.append(
                    f"{point}:child={child_rc}:inspect={inspected.returncode}:"
                    f"retry={retried.returncode}/{retry_value!r}:"
                    f"read_changed={before_inspect_stage != after_inspect_stage}"
                )

        output_home = new_home(root, "result-output-home")
        output_rc, _, output_error = module_main(
            output_home,
            ["experiment", "install", str(direct_source)],
            BrokenOutput(),
        )
        output_inspect = cli(output_home, "experiment", "inspect", "first-experiment")
        output_retry = cli(output_home, "experiment", "install", str(direct_source))
        output_value = json_object(output_retry)
        check(
            "IST-CRASH-001",
            seam_rc == 0
            and isinstance(seam_value, dict)
            and seam_error is None
            and set(FAULT_POINTS) <= set(observed_points)
            and not crash_failures
            and output_rc == 125
            and output_error is None
            and output_inspect.returncode == 0
            and output_retry.returncode == 0
            and isinstance(output_value, dict)
            and output_value.get("changed") is False,
            "fault seams preserve views, restart cleanup, and recover uncertain output",
            (
                f"seam={seam_rc}/{seam_error!r} "
                f"missing={sorted(set(FAULT_POINTS)-set(observed_points))!r} "
                f"crashes={crash_failures[:3]!r} output={output_rc}/{output_error!r}/"
                f"{output_inspect.returncode}/{output_retry.returncode}/{output_value!r}"
            ),
        )

        live_home = new_home(root, "selected-entry-live-home")
        added = cli(live_home, "image", "add", "vendor.worker", SUBJECT)
        added_value = json_object(added)
        local_source = source_directory(
            root,
            "local-source",
            catalog_name="vendor.worker",
        )
        live_events: list[str] = []
        held_catalog = held_store = False

        def observe_locks(point: str) -> None:
            nonlocal held_catalog, held_store
            live_events.append(point)
            if point == "experiment envelope.before_noreplace":
                held_catalog = lock_is_blocked(
                    live_home / "state" / "locks" / "image-catalog.lock"
                )
                held_store = lock_is_blocked(
                    live_home / "state" / "locks" / "experiments.lock"
                )

        live_rc, live_value, live_error = store_install(
            live_home,
            local_source,
            fault=observe_locks,
        )
        entry_digest = added_value.get("entryDigest") if isinstance(added_value, dict) else None
        if isinstance(entry_digest, str):
            removed = cli(
                live_home,
                "image",
                "remove",
                "vendor.worker",
                "--expect",
                entry_digest,
            )
        else:
            removed = subprocess.CompletedProcess([], 125, b"", b"missing entry digest")
        store_before_retry = fingerprint(live_home / "experiments")
        stale_retry = cli(live_home, "experiment", "install", str(local_source))
        store_after_retry = fingerprint(live_home / "experiments")
        retained = cli(live_home, "experiment", "inspect", "first-experiment")
        try:
            catalog_index = live_events.index("experiment catalog lock.after_acquire")
            store_index = live_events.index("experiment store lock.after_acquire")
            publish_index = live_events.index("experiment envelope.before_noreplace")
            order_ok = catalog_index < store_index < publish_index
        except ValueError:
            order_ok = False
        check(
            "IST-LIVE-001",
            added.returncode == 0
            and live_rc == 0
            and isinstance(live_value, dict)
            and live_error is None
            and order_ok
            and held_catalog
            and held_store
            and removed.returncode == 0
            and stale_retry.returncode == 1
            and store_before_retry == store_after_retry
            and retained.returncode == 0,
            "selected-entry and store locks remain held; removal blocks stale retry",
            (
                f"add={added.returncode} install={live_rc}/{live_error!r} events={live_events!r} "
                f"held={held_catalog}/{held_store} remove={removed.returncode} "
                f"retry={stale_retry.returncode}/{store_before_retry != store_after_retry} "
                f"inspect={retained.returncode}"
            ),
        )

        platform_home = new_home(root, "platform-home")
        platform_source = source_directory(root, "platform-source")
        platform_before = fingerprint(platform_home)
        source_touched = False
        original_platform = MODULE.sys.platform
        original_lstat = MODULE.os.lstat
        original_listdir = MODULE.os.listdir
        original_open = MODULE.os.open

        def touches_source(value: object) -> bool:
            try:
                rendered = os.fsdecode(os.fspath(value))
            except TypeError:
                return False
            base = str(platform_source)
            return rendered == base or rendered.startswith(base + os.sep)

        def observed_lstat(path: object, *args, **kwargs):
            nonlocal source_touched
            source_touched = source_touched or touches_source(path)
            return original_lstat(path, *args, **kwargs)

        def observed_listdir(path: object = "."):
            nonlocal source_touched
            source_touched = source_touched or touches_source(path)
            return original_listdir(path)

        def observed_open(path: object, flags: int, mode: int = 0o777, *, dir_fd=None):
            nonlocal source_touched
            source_touched = source_touched or touches_source(path)
            return original_open(path, flags, mode, dir_fd=dir_fd)

        MODULE.sys.platform = "darwin"
        MODULE.os.lstat = observed_lstat
        MODULE.os.listdir = observed_listdir
        MODULE.os.open = observed_open
        try:
            platform_rc, _, platform_error = module_main(
                platform_home,
                ["experiment", "install", str(platform_source)],
            )
        finally:
            MODULE.os.open = original_open
            MODULE.os.listdir = original_listdir
            MODULE.os.lstat = original_lstat
            MODULE.sys.platform = original_platform
        platform_after = fingerprint(platform_home)
        check(
            "IST-PLAT-001",
            platform_rc == 125
            and platform_error is None
            and not source_touched
            and platform_before == platform_after,
            "non-Linux install fails before caller-source access or persistent effect",
            (
                f"rc={platform_rc} error={platform_error!r} "
                f"source_touched={source_touched} changed={platform_before != platform_after}"
            ),
        )

    expected = [
        "IST-STATE-001",
        "IST-LOCK-001",
        "IST-STATE-002",
        "IST-BOUND-001",
        "IST-STATE-003",
        "IST-CONC-001",
        "IST-CONC-002",
        "IST-CRASH-001",
        "IST-LIVE-001",
        "IST-PLAT-001",
    ]
    if OBSERVED != expected:
        print(f"INFRA install state assertion identity drift: {OBSERVED!r}", file=sys.stderr)
        return 125
    print(f"SUMMARY assertions=10 expected=10 failures={FAILURES} infra={INFRA}")
    if INFRA:
        return 125
    return 0 if FAILURES == 0 else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except BaseException as error:
        print(f"INFRA install state harness failed: {error!r}", file=sys.stderr)
        print(
            f"SUMMARY assertions={len(OBSERVED)} expected=10 failures={FAILURES} infra=1"
        )
        raise SystemExit(125)
