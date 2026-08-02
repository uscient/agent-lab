#!/usr/bin/env python3
"""Adversarial Experiment-store filesystem, locking, and recovery cases."""

from __future__ import annotations

from contextlib import contextmanager, redirect_stderr, redirect_stdout
import errno
import hashlib
from importlib.util import module_from_spec, spec_from_file_location
import io
import json
import os
from pathlib import Path
import select
import signal
import stat
import subprocess
import sys
import tempfile
import time
from typing import Callable, NamedTuple


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


class FixtureSnapshot(NamedTuple):
    data: bytes
    digest: str


class FixtureResolution(NamedTuple):
    plan: dict[str, object]
    local_catalog: dict[str, object] | None


class FixtureInvalidManifest(Exception):
    """The isolated store fixture rejected its authored manifest."""


class FixtureInfrastructure(Exception):
    """The isolated store fixture could not establish a trusted result."""


class FaultFixtureExperiment:
    """Small deterministic planner used only for exhaustive store fault injection."""

    InvalidManifest = FixtureInvalidManifest
    InfrastructureError = FixtureInfrastructure

    def __init__(self, source_data: bytes, name: str) -> None:
        source_digest = store_source_digest(source_data)
        contract_digest = "sha256:" + "d" * 64
        plan: dict[str, object] = {
            "apiVersion": "agent-lab.request/v0alpha1",
            "contract": {
                "digest": contract_digest,
                "name": "agent-lab.experiment",
                "version": "v0alpha1",
            },
            "kind": "RequestedExperimentPlan",
            "metadata": {"requestedName": name},
            "spec": {
                "members": [
                    {
                        "command": ["fault-probe"],
                        "name": "worker",
                        "requestedSelector": {"digestRef": SUBJECT},
                        "resolvedImage": {"origin": "direct", "subject": SUBJECT},
                        "resourceClass": "small",
                    }
                ]
            },
        }
        plan_digest = "sha256:" + hashlib.sha256(canonical_json(plan)).hexdigest()
        self.source_data = source_data
        self.snapshot = FixtureSnapshot(source_data, source_digest)
        self.resolution = FixtureResolution(plan, None)
        self.decision: dict[str, object] = {
            "action": "experiment.install",
            "apiVersion": "agent-lab.authorization/v0alpha1",
            "binding": {
                "authorizationDigest": "sha256:" + "c" * 64,
                "contractDigest": contract_digest,
                "planDigest": plan_digest,
                "sourceDigest": source_digest,
            },
            "kind": "ExperimentAuthorizationDecision",
            "principal": {
                "assurance": "none",
                "authenticated": False,
                "id": "local-cli",
                "source": "fixed-local-cli",
                "type": "AgentLab::Principal",
            },
            "resource": {
                "id": plan_digest,
                "requestedName": name,
                "type": "AgentLab::RequestedExperimentPlan",
            },
            "verdict": "permit",
        }

    def read_directory_snapshot(self, source: str) -> FixtureSnapshot:
        try:
            observed = (Path(source) / "experiment.cue").read_bytes()
        except OSError as error:
            raise FixtureInfrastructure("fault fixture source cannot be read") from error
        if observed != self.source_data:
            raise FixtureInvalidManifest("fault fixture source changed")
        return self.snapshot

    def authored_manifest(self, snapshot: FixtureSnapshot) -> bytes:
        return snapshot.data

    def cue_plan_with_evidence(self, manifest: object) -> FixtureResolution:
        if manifest != self.source_data:
            raise FixtureInvalidManifest("fault fixture manifest changed")
        return self.resolution

    def authorize_plan(
        self,
        plan: dict[str, object],
        source_digest: str,
    ) -> tuple[dict[str, object], int]:
        if plan != self.resolution.plan or source_digest != self.snapshot.digest:
            raise FixtureInfrastructure("fault fixture authorization binding changed")
        return self.decision, 0


def canonical_json(value: object) -> bytes:
    return json.dumps(
        value,
        allow_nan=False,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("ascii")


def store_source_digest(data: bytes) -> str:
    value = hashlib.sha256(b"agent-lab.experiment-tree.v1\0")
    name = b"experiment.cue"
    value.update(len(name).to_bytes(4, "big"))
    value.update(name)
    value.update(len(data).to_bytes(8, "big"))
    value.update(data)
    return "sha256:" + value.hexdigest()


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


def start_inspect(home: Path, name: str) -> subprocess.Popen[bytes]:
    return subprocess.Popen(
        [str(AGENT_LAB), "--home", str(home), "experiment", "inspect", name],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=command_environment(),
        start_new_session=True,
    )


def start_remove(home: Path, name: str, entry_digest: str) -> subprocess.Popen[bytes]:
    return subprocess.Popen(
        [
            str(AGENT_LAB),
            "--home",
            str(home),
            "image",
            "remove",
            name,
            "--expect",
            entry_digest,
        ],
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


def store_inspect(
    home: Path,
    name: str,
) -> tuple[int | None, dict[str, object] | None, BaseException | None]:
    if STORE is None:
        return None, None, STORE_LOAD_ERROR or RuntimeError("experiment store module is missing")
    operation = getattr(STORE, "inspect_install", None)
    if not callable(operation):
        return None, None, RuntimeError("experiment_store.inspect_install is missing")
    try:
        value = operation(home, name)
        if not isinstance(value, dict):
            return None, None, RuntimeError("inspect_install returned a non-object")
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


def hard_exit_after_raw_publication(home: Path, source: Path) -> int:
    """Exit after no-replace succeeds but before the final root becomes read-only."""

    if STORE is None:
        return 95
    target = home / "experiments" / "first-experiment"
    pid = os.fork()
    if pid == 0:
        original_chmod = STORE.os.chmod

        def stop_before_final_chmod(path: object, mode: int, *args, **kwargs):
            if Path(os.fsdecode(os.fspath(path))) == target and mode == 0o500:
                os._exit(99)
            return original_chmod(path, mode, *args, **kwargs)

        STORE.os.chmod = stop_before_final_chmod
        result, _, _ = store_install(home, source)
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


def hard_exit_before_intent(home: Path, source: Path) -> int:
    """Exit after the operation wrapper exists but before intent bytes are written."""

    if STORE is None:
        return 95
    pid = os.fork()
    if pid == 0:
        original_write_file = STORE._write_file

        def stop_before_intent(path, data, purpose, fault):
            if purpose == "experiment intent":
                os._exit(99)
            return original_write_file(path, data, purpose, fault)

        STORE._write_file = stop_before_intent
        result, _, _ = store_install(home, source)
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


def hard_exit_during_cleanup(home: Path, source: Path, phase: str) -> int:
    """Exit after durable cleanup handoff or after the first cleanup-file removal."""

    if STORE is None:
        return 95
    pid = os.fork()
    if pid == 0:
        if phase == "handoff":
            original_rename = STORE._rename_noreplace

            def stop_after_handoff(source_path: Path, target_path: Path) -> None:
                original_rename(source_path, target_path)
                if target_path.name == STORE.CLEANUP_WRAPPER:
                    os._exit(99)

            STORE._rename_noreplace = stop_after_handoff
        elif phase == "remove":
            original_remove = STORE._remove_tree
            stopped = False

            def stop_after_first_file(path: Path, root: Path) -> None:
                nonlocal stopped
                was_file = False
                try:
                    was_file = stat.S_ISREG(path.lstat().st_mode)
                except OSError:
                    pass
                original_remove(path, root)
                if was_file and not stopped:
                    stopped = True
                    os._exit(99)

            STORE._remove_tree = stop_after_first_file
        else:
            os._exit(95)
        result, _, _ = store_install(home, source)
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


def start_paused_publication(home: Path, source: Path) -> tuple[int, int, int]:
    """Pause a child install while it holds the store lock before publication."""

    ready_read, ready_write = os.pipe()
    release_read, release_write = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(ready_read)
        os.close(release_write)
        paused = False

        def pause(point: str) -> None:
            nonlocal paused
            if point == "experiment envelope.before_noreplace" and not paused:
                paused = True
                os.write(ready_write, b"1")
                if os.read(release_read, 1) != b"1":
                    os._exit(94)

        result, _, _ = store_install(home, source, fault=pause)
        os._exit(0 if result == 0 else 96)
    os.close(ready_write)
    os.close(release_read)
    readable, _, _ = select.select((ready_read,), (), (), 30.0)
    if not readable or os.read(ready_read, 1) != b"1":
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os.waitpid(pid, 0)
        os.close(ready_read)
        os.close(release_write)
        global INFRA
        INFRA += 1
        return 0, -1, -1
    os.close(ready_read)
    return pid, release_write, 0


def finish_child(pid: int, timeout: float = 30.0) -> int:
    if pid <= 0:
        return 124
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        waited, status = os.waitpid(pid, os.WNOHANG)
        if waited == pid:
            return os.waitstatus_to_exitcode(status)
        time.sleep(0.01)
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    os.waitpid(pid, 0)
    global INFRA
    INFRA += 1
    return 124


def wait_for_lock_block(process: subprocess.Popen[bytes], timeout: float = 5.0) -> bool:
    """Observe the Linux flock wait channel rather than infer blocking from a sleep."""

    deadline = time.monotonic() + timeout
    path = Path(f"/proc/{process.pid}/wchan")
    while time.monotonic() < deadline:
        if process.poll() is not None:
            return False
        try:
            channel = path.read_text(encoding="ascii").strip()
        except OSError:
            channel = ""
        if channel == "locks_lock_inode_wait":
            return True
        time.sleep(0.005)
    return False


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

        inspect_lock_home = new_home(root, "inspect-lock-home")
        inspect_lock_install = cli(
            inspect_lock_home,
            "experiment",
            "install",
            str(direct_source),
        )
        inspect_lock = inspect_lock_home / "state" / "locks" / "experiments.lock"
        os.link(inspect_lock, root / "second-inspect-lock-link")
        hardlink_inspect = cli(
            inspect_lock_home,
            "experiment",
            "inspect",
            "first-experiment",
        )

        blocking_home = new_home(root, "inspect-blocking-home")
        install_pid, release_write, pause_status = start_paused_publication(
            blocking_home,
            direct_source,
        )
        blocking_inspect = start_inspect(blocking_home, "first-experiment")
        inspect_waited = wait_for_lock_block(blocking_inspect)
        if release_write >= 0:
            try:
                os.write(release_write, b"1")
            finally:
                os.close(release_write)
        blocking_install_rc = finish_child(install_pid)
        blocking_inspect_result = finish_process(blocking_inspect)
        blocking_inspect_value = json_object(blocking_inspect_result)
        check(
            "IST-LOCK-001",
            symlink_lock_result.returncode == 125
            and lock_before == lock_after
            and hardlink_result.returncode == 125
            and not tuple((hardlink_lock_home / "experiments" / ".staging").iterdir())
            and inspect_lock_install.returncode == 0
            and hardlink_inspect.returncode == 125
            and pause_status == 0
            and inspect_waited
            and blocking_install_rc == 0
            and blocking_inspect_result.returncode == 0
            and isinstance(blocking_inspect_value, dict)
            and blocking_inspect_value.get("state") == "installed",
            "the receipt-bound store lock protects install and read-only inspect",
            (
                f"symlink={symlink_lock_result.returncode}/{lock_before != lock_after} "
                f"hardlink={hardlink_result.returncode} inspect_install={inspect_lock_install.returncode} "
                f"inspect_hardlink={hardlink_inspect.returncode} pause={pause_status} "
                f"waited={inspect_waited} child={blocking_install_rc} "
                f"inspect={blocking_inspect_result.returncode}/{blocking_inspect_value!r}"
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

        cleanup_home = new_home(root, "foreign-cleanup-home")
        cleanup_wrapper = (
            cleanup_home
            / "experiments"
            / ".staging"
            / "experiment-install-cleanup"
        )
        cleanup_artifact = cleanup_wrapper / "payload" / "artifact"
        cleanup_artifact.mkdir(parents=True)
        for directory_path in (
            cleanup_wrapper,
            cleanup_wrapper / "payload",
            cleanup_artifact,
        ):
            directory_path.chmod(0o700)
        cleanup_canary = cleanup_artifact / "experiment.cue"
        cleanup_canary.write_bytes(b"foreign cleanup canary\n")
        cleanup_canary.chmod(0o600)
        cleanup_before = fingerprint(cleanup_wrapper)
        cleanup_result = cli(
            cleanup_home,
            "experiment",
            "install",
            str(direct_source),
        )
        cleanup_after = fingerprint(cleanup_wrapper)
        check(
            "IST-BOUND-001",
            foreign_result.returncode == 125
            and foreign_before == foreign_after
            and bound_result.returncode == 125
            and bound_before == bound_after
            and cleanup_result.returncode == 125
            and cleanup_before == cleanup_after,
            "unknown, over-bound, or unproven cleanup residue is preserved",
            (
                f"foreign={foreign_result.returncode}/{foreign_before != foreign_after} "
                f"bound={bound_result.returncode}/{bound_before != bound_after} "
                f"cleanup={cleanup_result.returncode}/{cleanup_before != cleanup_after}"
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

        layout_home = new_home(root, "changing-layout-home")
        layout_install = cli(layout_home, "experiment", "install", str(direct_source))
        layout_target = layout_home / "experiments" / "first-experiment"
        layout_changed = False
        layout_rc: int | None = None
        layout_error: BaseException | None = None
        if STORE is not None and layout_install.returncode == 0:
            original_directory_names = STORE._directory_names

            def change_after_enumeration(path: Path, purpose: str, maximum: int):
                nonlocal layout_changed
                names = original_directory_names(path, purpose, maximum)
                if path == layout_target and not layout_changed:
                    layout_changed = True
                    layout_target.chmod(0o700)
                    foreign = layout_target / "foreign-after-enumeration"
                    foreign.write_bytes(b"foreign layout entry\n")
                    foreign.chmod(0o400)
                    layout_target.chmod(0o500)
                return names

            STORE._directory_names = change_after_enumeration
            try:
                layout_rc, _, layout_error = store_inspect(
                    layout_home,
                    "first-experiment",
                )
            finally:
                STORE._directory_names = original_directory_names
        check(
            "IST-STATE-003",
            installed.returncode == 0
            and link_detected
            and restored
            and mode_detected
            and digest_detected
            and layout_install.returncode == 0
            and layout_changed
            and layout_rc == 125
            and layout_error is not None,
            "inspect detects link, mode, byte, and concurrent layout drift",
            f"{tamper_detail} layout={layout_install.returncode}/{layout_changed}/{layout_rc}/{layout_error!r}",
        )

        identical_home = new_home(root, "identical-concurrency-home")
        first_pid, first_release, first_pause = start_paused_publication(
            identical_home,
            direct_source,
        )
        second = start_cli(identical_home, direct_source)
        identical_waited = wait_for_lock_block(second)
        if first_release >= 0:
            try:
                os.write(first_release, b"1")
            finally:
                os.close(first_release)
        first_rc = finish_child(first_pid)
        second_result = finish_process(second)
        second_value = json_object(second_result)
        identical_inspect = cli(
            identical_home,
            "experiment",
            "inspect",
            "first-experiment",
        )
        check(
            "IST-CONC-001",
            first_pause == 0
            and identical_waited
            and first_rc == 0
            and second_result.returncode == 0
            and isinstance(second_value, dict)
            and second_value.get("changed") is False
            and identical_inspect.returncode == 0
            and not tuple((identical_home / "experiments" / ".staging").iterdir()),
            "overlapping identical installs block at the store lock and publish once",
            (
                f"pause={first_pause} waited={identical_waited} first={first_rc} "
                f"second={second_result.returncode}/{second_value!r} "
                f"inspect={identical_inspect.returncode}"
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
        one_pid, one_release, one_pause = start_paused_publication(
            conflict_home,
            conflict_one,
        )
        two = start_cli(conflict_home, conflict_two)
        conflict_waited = wait_for_lock_block(two)
        if one_release >= 0:
            try:
                os.write(one_release, b"1")
            finally:
                os.close(one_release)
        one_rc = finish_child(one_pid)
        two_result = finish_process(two)
        conflict_inspect = cli(
            conflict_home,
            "experiment",
            "inspect",
            "first-experiment",
        )
        conflict_artifact = (
            conflict_home
            / "experiments"
            / "first-experiment"
            / "artifact"
            / "experiment.cue"
        )
        check(
            "IST-CONC-002",
            one_pause == 0
            and conflict_waited
            and one_rc == 0
            and two_result.returncode == 1
            and conflict_inspect.returncode == 0
            and conflict_artifact.is_file()
            and conflict_artifact.read_bytes()
            == (conflict_one / "experiment.cue").read_bytes()
            and not tuple((conflict_home / "experiments" / ".staging").iterdir()),
            "overlapping different candidates serialize to the paused winner and one conflict",
            (
                f"pause={one_pause} waited={conflict_waited} first={one_rc} "
                f"second={two_result.returncode} inspect={conflict_inspect.returncode}"
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

        preintent_home = new_home(root, "preintent-crash-home")
        preintent_stage = preintent_home / "experiments" / ".staging"
        preintent_child_rc = hard_exit_before_intent(preintent_home, direct_source)
        preintent_before = fingerprint(preintent_stage)
        preintent_inspect = cli(
            preintent_home,
            "experiment",
            "inspect",
            "first-experiment",
        )
        preintent_after_inspect = fingerprint(preintent_stage)
        preintent_retry = cli(
            preintent_home,
            "experiment",
            "install",
            str(direct_source),
        )
        preintent_value = json_object(preintent_retry)

        raw_home = new_home(root, "raw-publication-crash-home")
        raw_child_rc = hard_exit_after_raw_publication(raw_home, direct_source)
        raw_stage = raw_home / "experiments" / ".staging"
        raw_before_inspect = fingerprint(raw_stage)
        raw_inspect = cli(
            raw_home,
            "experiment",
            "inspect",
            "first-experiment",
        )
        raw_after_inspect = fingerprint(raw_stage)
        raw_retry = cli(raw_home, "experiment", "install", str(direct_source))
        raw_retry_value = json_object(raw_retry)
        raw_final_inspect = cli(
            raw_home,
            "experiment",
            "inspect",
            "first-experiment",
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
        cleanup_crash_failures: list[str] = []
        for phase in ("handoff", "remove"):
            cleanup_crash_home = new_home(root, f"cleanup-{phase}-crash-home")
            cleanup_child_rc = hard_exit_during_cleanup(
                cleanup_crash_home,
                direct_source,
                phase,
            )
            cleanup_stage = cleanup_crash_home / "experiments" / ".staging"
            cleanup_before_inspect = fingerprint(cleanup_stage)
            cleanup_inspect = cli(
                cleanup_crash_home,
                "experiment",
                "inspect",
                "first-experiment",
            )
            cleanup_after_inspect = fingerprint(cleanup_stage)
            cleanup_retry = cli(
                cleanup_crash_home,
                "experiment",
                "install",
                str(direct_source),
            )
            cleanup_retry_value = json_object(cleanup_retry)
            if not (
                cleanup_child_rc == 99
                and cleanup_inspect.returncode == 0
                and cleanup_before_inspect == cleanup_after_inspect
                and cleanup_retry.returncode == 0
                and isinstance(cleanup_retry_value, dict)
                and cleanup_retry_value.get("changed") is False
                and not tuple(cleanup_stage.iterdir())
            ):
                cleanup_crash_failures.append(
                    f"{phase}:child={cleanup_child_rc}:inspect={cleanup_inspect.returncode}:"
                    f"read_changed={cleanup_before_inspect != cleanup_after_inspect}:"
                    f"retry={cleanup_retry.returncode}/{cleanup_retry_value!r}"
                )
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
            and output_value.get("changed") is False
            and not cleanup_crash_failures
            and preintent_child_rc == 99
            and preintent_inspect.returncode == 1
            and preintent_before == preintent_after_inspect
            and preintent_retry.returncode == 0
            and isinstance(preintent_value, dict)
            and preintent_value.get("changed") is True
            and not tuple(preintent_stage.iterdir())
            and raw_child_rc == 99
            and raw_inspect.returncode == 125
            and raw_before_inspect == raw_after_inspect
            and raw_retry.returncode == 0
            and isinstance(raw_retry_value, dict)
            and raw_retry_value.get("changed") is False
            and raw_final_inspect.returncode == 0
            and not tuple(raw_stage.iterdir()),
            "fault seams preserve views, restart cleanup, and recover uncertain output",
            (
                f"seam={seam_rc}/{seam_error!r} "
                f"missing={sorted(set(FAULT_POINTS)-set(observed_points))!r} "
                f"crashes={crash_failures[:3]!r} output={output_rc}/{output_error!r}/"
                f"{output_inspect.returncode}/{output_retry.returncode}/{output_value!r} "
                f"cleanup={cleanup_crash_failures[:2]!r} "
                f"preintent={preintent_child_rc}/{preintent_inspect.returncode}/"
                f"{preintent_before != preintent_after_inspect}/{preintent_retry.returncode}/"
                f"{preintent_value!r} "
                f"raw={raw_child_rc}/{raw_inspect.returncode}/"
                f"{raw_before_inspect != raw_after_inspect}/{raw_retry.returncode}/"
                f"{raw_retry_value!r}/{raw_final_inspect.returncode}"
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

        live_race_home = new_home(root, "selected-entry-removal-race-home")
        race_added = cli(
            live_race_home,
            "image",
            "add",
            "vendor.worker",
            SUBJECT,
        )
        race_added_value = json_object(race_added)
        race_entry_digest = (
            race_added_value.get("entryDigest")
            if isinstance(race_added_value, dict)
            else None
        )
        race_install_pid = 0
        race_release = -1
        race_pause = -1
        race_remove: subprocess.Popen[bytes] | None = None
        race_remove_waited = False
        race_install_rc = 124
        race_remove_result = subprocess.CompletedProcess([], 125, b"", b"missing entry digest")
        if isinstance(race_entry_digest, str):
            race_install_pid, race_release, race_pause = start_paused_publication(
                live_race_home,
                local_source,
            )
            race_remove = start_remove(
                live_race_home,
                "vendor.worker",
                race_entry_digest,
            )
            race_remove_waited = wait_for_lock_block(race_remove)
        if race_release >= 0:
            try:
                os.write(race_release, b"1")
            finally:
                os.close(race_release)
        if race_install_pid > 0:
            race_install_rc = finish_child(race_install_pid)
        if race_remove is not None:
            race_remove_result = finish_process(race_remove)
        race_retained = cli(
            live_race_home,
            "experiment",
            "inspect",
            "first-experiment",
        )
        race_before_retry = fingerprint(live_race_home / "experiments")
        race_stale_retry = cli(
            live_race_home,
            "experiment",
            "install",
            str(local_source),
        )
        race_after_retry = fingerprint(live_race_home / "experiments")
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
            and retained.returncode == 0
            and race_added.returncode == 0
            and race_pause == 0
            and race_remove_waited
            and race_install_rc == 0
            and race_remove_result.returncode == 0
            and race_retained.returncode == 0
            and race_stale_retry.returncode == 1
            and race_before_retry == race_after_retry,
            "selected-entry locks order correctly and serialize a real removal race",
            (
                f"add={added.returncode} install={live_rc}/{live_error!r} events={live_events!r} "
                f"held={held_catalog}/{held_store} remove={removed.returncode} "
                f"retry={stale_retry.returncode}/{store_before_retry != store_after_retry} "
                f"inspect={retained.returncode} race={race_added.returncode}/{race_pause}/"
                f"{race_remove_waited}/{race_install_rc}/{race_remove_result.returncode}/"
                f"{race_retained.returncode}/{race_stale_retry.returncode}/"
                f"{race_before_retry != race_after_retry}"
            ),
        )

        provenance_home = new_home(root, "provenance-snapshot-home")
        provenance_add = cli(
            provenance_home,
            "image",
            "add",
            "vendor.worker",
            SUBJECT,
        )
        provenance_source = source_directory(
            root,
            "provenance-source",
            catalog_name="vendor.worker",
        )
        initial_check = cli(
            provenance_home,
            "experiment",
            "check",
            str(provenance_source),
        )
        initial_check_value = json_object(initial_check)
        initial_catalog = None
        if isinstance(initial_check_value, dict):
            catalog_value = initial_check_value.get("catalog")
            if isinstance(catalog_value, dict):
                initial_catalog = catalog_value.get("local")
        provenance_rc: int | None = None
        provenance_value: dict[str, object] | None = None
        provenance_error: BaseException | None = None
        unrelated_result: subprocess.CompletedProcess[bytes] | None = None
        provenance_record: dict[str, object] | None = None
        if STORE is not None:
            original_held_catalog = STORE._held_catalog_context

            @contextmanager
            def mutate_unrelated_before_hold(home: Path, dependencies, fault):
                nonlocal unrelated_result
                unrelated_result = cli(
                    home,
                    "image",
                    "add",
                    "vendor.unrelated",
                    OTHER_SUBJECT,
                )
                with original_held_catalog(home, dependencies, fault) as held:
                    yield held

            STORE._held_catalog_context = mutate_unrelated_before_hold
            try:
                provenance_rc, provenance_value, provenance_error = store_install(
                    provenance_home,
                    provenance_source,
                )
            finally:
                STORE._held_catalog_context = original_held_catalog
            provenance_path = (
                provenance_home
                / "experiments"
                / "first-experiment"
                / "records"
                / "provenance.json"
            )
            if provenance_path.is_file():
                try:
                    loaded_provenance = json.loads(provenance_path.read_bytes())
                except (OSError, UnicodeError, json.JSONDecodeError):
                    loaded_provenance = None
                if isinstance(loaded_provenance, dict):
                    provenance_record = loaded_provenance
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
        check(
            "IST-PROV-001",
            provenance_add.returncode == 0
            and initial_check.returncode == 0
            and isinstance(initial_catalog, dict)
            and unrelated_result is not None
            and unrelated_result.returncode == 0
            and provenance_rc == 0
            and isinstance(provenance_value, dict)
            and provenance_error is None
            and isinstance(provenance_record, dict)
            and provenance_record.get("catalog") == initial_catalog,
            "provenance retains the authorized initial resolution snapshot across unrelated catalog mutation",
            (
                f"add={provenance_add.returncode} check={initial_check.returncode}/{initial_catalog!r} "
                f"unrelated={None if unrelated_result is None else unrelated_result.returncode} "
                f"install={provenance_rc}/{provenance_error!r} "
                f"stored={None if provenance_record is None else provenance_record.get('catalog')!r}"
            ),
        )

        planning = load_module(
            REPO_ROOT / "scripts" / "experiment.py",
            "agent_lab_experiment_store_adversarial",
        )

        cue_home = new_home(root, "preflight-cue-home")
        cue_source = source_directory(root, "preflight-cue-source")
        cue_path = cue_source / "experiment.cue"
        cue_raw = cue_path.read_bytes()
        cue_path.write_bytes(
            cue_raw.replace(
                b'\t\tcommand: ["serve"]\n',
                b'\t\tcommand: ["serve"]\n\t\tunknownField: true\n',
                1,
            )
        )
        cue_before = fingerprint(cue_home / "experiments")
        cue_failure = cli(cue_home, "experiment", "install", str(cue_source))
        cue_after = fingerprint(cue_home / "experiments")

        contract_home = new_home(root, "preflight-contract-home")
        contract_source = source_directory(root, "preflight-contract-source")
        contract_before = fingerprint(contract_home / "experiments")
        original_experiment_loader = STORE._experiment_module if STORE is not None else None
        original_verify_contract = planning.verify_contract_snapshot

        def report_contract_drift(repo_root: Path, expected: dict[str, bytes]) -> None:
            del repo_root, expected
            raise planning.InfrastructureError("contract snapshot changed during validation")

        contract_rc: int | None = None
        contract_error: BaseException | None = None
        if STORE is not None:
            STORE._experiment_module = lambda: planning
            planning.verify_contract_snapshot = report_contract_drift
            try:
                contract_rc, _, contract_error = store_install(
                    contract_home,
                    contract_source,
                )
            finally:
                planning.verify_contract_snapshot = original_verify_contract
                STORE._experiment_module = original_experiment_loader
        contract_after = fingerprint(contract_home / "experiments")

        selected_home = new_home(root, "preflight-selected-home")
        selected_add = cli(
            selected_home,
            "image",
            "add",
            "vendor.worker",
            SUBJECT,
        )
        selected_add_value = json_object(selected_add)
        selected_digest = (
            selected_add_value.get("entryDigest")
            if isinstance(selected_add_value, dict)
            else None
        )
        selected_source = source_directory(
            root,
            "preflight-selected-source",
            catalog_name="vendor.worker",
        )
        selected_before = fingerprint(selected_home / "experiments")
        selected_remove: subprocess.CompletedProcess[bytes] | None = None
        selected_rc: int | None = None
        selected_error: BaseException | None = None
        if STORE is not None and isinstance(selected_digest, str):
            original_held_context = STORE._held_catalog_context

            @contextmanager
            def remove_selected_before_hold(home: Path, dependencies, fault):
                nonlocal selected_remove
                selected_remove = cli(
                    home,
                    "image",
                    "remove",
                    "vendor.worker",
                    "--expect",
                    selected_digest,
                )
                with original_held_context(home, dependencies, fault) as held:
                    yield held

            STORE._held_catalog_context = remove_selected_before_hold
            try:
                selected_rc, _, selected_error = store_install(
                    selected_home,
                    selected_source,
                )
            finally:
                STORE._held_catalog_context = original_held_context
        selected_after = fingerprint(selected_home / "experiments")
        check(
            "IST-PREFLIGHT-001",
            cue_raw != cue_path.read_bytes()
            and cue_failure.returncode == 1
            and not cue_failure.stdout
            and cue_before == cue_after
            and contract_rc == 125
            and contract_error is not None
            and contract_before == contract_after
            and selected_add.returncode == 0
            and selected_remove is not None
            and selected_remove.returncode == 0
            and selected_rc == 1
            and selected_error is not None
            and selected_before == selected_after,
            "CUE, contract, and selected-entry drift fail before store-visible effects",
            (
                f"cue={cue_failure.returncode}/{cue_before != cue_after} "
                f"contract={contract_rc}/{contract_error!r}/{contract_before != contract_after} "
                f"selected={selected_add.returncode}/"
                f"{None if selected_remove is None else selected_remove.returncode}/"
                f"{selected_rc}/{selected_error!r}/{selected_before != selected_after}"
            ),
        )

        snapshot_mutation_home = new_home(root, "snapshot-after-mutation-home")
        snapshot_mutation_source = source_directory(
            root,
            "snapshot-after-mutation-source",
            requested_name="snapshot-mutated",
        )
        snapshot_mutation_path = snapshot_mutation_source / "experiment.cue"
        snapshot_original = snapshot_mutation_path.read_bytes()
        snapshot_changed = snapshot_original.replace(b"serve", b"mutat", 1)
        original_authored_manifest = planning.authored_manifest
        mutation_after_snapshot = False

        def mutate_after_snapshot(snapshot):
            nonlocal mutation_after_snapshot
            snapshot_mutation_path.write_bytes(snapshot_changed)
            mutation_after_snapshot = True
            return original_authored_manifest(snapshot)

        snapshot_mutation_rc: int | None = None
        snapshot_mutation_error: BaseException | None = None
        if STORE is not None:
            STORE._experiment_module = lambda: planning
            planning.authored_manifest = mutate_after_snapshot
            try:
                snapshot_mutation_rc, _, snapshot_mutation_error = store_install(
                    snapshot_mutation_home,
                    snapshot_mutation_source,
                )
            finally:
                planning.authored_manifest = original_authored_manifest
                STORE._experiment_module = original_experiment_loader
        stored_mutation_artifact = (
            snapshot_mutation_home
            / "experiments"
            / "snapshot-mutated"
            / "artifact"
            / "experiment.cue"
        )

        snapshot_deletion_home = new_home(root, "snapshot-after-deletion-home")
        snapshot_deletion_source = source_directory(
            root,
            "snapshot-after-deletion-source",
            requested_name="snapshot-deleted",
        )
        snapshot_deletion_path = snapshot_deletion_source / "experiment.cue"
        deletion_original = snapshot_deletion_path.read_bytes()
        deletion_after_snapshot = False

        def delete_after_snapshot(snapshot):
            nonlocal deletion_after_snapshot
            snapshot_deletion_path.unlink()
            deletion_after_snapshot = True
            return original_authored_manifest(snapshot)

        snapshot_deletion_rc: int | None = None
        snapshot_deletion_error: BaseException | None = None
        if STORE is not None:
            STORE._experiment_module = lambda: planning
            planning.authored_manifest = delete_after_snapshot
            try:
                snapshot_deletion_rc, _, snapshot_deletion_error = store_install(
                    snapshot_deletion_home,
                    snapshot_deletion_source,
                )
            finally:
                planning.authored_manifest = original_authored_manifest
                STORE._experiment_module = original_experiment_loader
        stored_deletion_artifact = (
            snapshot_deletion_home
            / "experiments"
            / "snapshot-deleted"
            / "artifact"
            / "experiment.cue"
        )

        snapshot_race_home = new_home(root, "snapshot-during-read-home")
        snapshot_race_source = source_directory(
            root,
            "snapshot-during-read-source",
            requested_name="snapshot-raced",
        )
        snapshot_race_path = snapshot_race_source / "experiment.cue"
        race_original = snapshot_race_path.read_bytes()
        race_changed = race_original.replace(b"serve", b"mutat", 1)
        race_metadata = snapshot_race_path.stat()
        snapshot_race_before = fingerprint(snapshot_race_home / "experiments")
        original_planning_read = planning.os.read
        race_mutated_during_read = False

        def mutate_during_read(descriptor: int, maximum: int) -> bytes:
            nonlocal race_mutated_during_read
            data = original_planning_read(descriptor, maximum)
            try:
                target = os.readlink(f"/proc/self/fd/{descriptor}")
            except OSError:
                target = ""
            if (
                data
                and not race_mutated_during_read
                and target == str(snapshot_race_path)
            ):
                time.sleep(0.001)
                snapshot_race_path.write_bytes(race_changed)
                os.utime(
                    snapshot_race_path,
                    ns=(race_metadata.st_atime_ns, race_metadata.st_mtime_ns),
                )
                race_mutated_during_read = True
            return data

        snapshot_race_rc: int | None = None
        snapshot_race_error: BaseException | None = None
        if STORE is not None:
            STORE._experiment_module = lambda: planning
            planning.os.read = mutate_during_read
            try:
                snapshot_race_rc, _, snapshot_race_error = store_install(
                    snapshot_race_home,
                    snapshot_race_source,
                )
            finally:
                planning.os.read = original_planning_read
                STORE._experiment_module = original_experiment_loader
        snapshot_race_after = fingerprint(snapshot_race_home / "experiments")
        race_final_metadata = snapshot_race_path.stat()
        check(
            "IST-SNAPSHOT-001",
            snapshot_original != snapshot_changed
            and mutation_after_snapshot
            and snapshot_mutation_rc == 0
            and snapshot_mutation_error is None
            and stored_mutation_artifact.is_file()
            and stored_mutation_artifact.read_bytes() == snapshot_original
            and deletion_after_snapshot
            and snapshot_deletion_rc == 0
            and snapshot_deletion_error is None
            and not snapshot_deletion_path.exists()
            and stored_deletion_artifact.is_file()
            and stored_deletion_artifact.read_bytes() == deletion_original
            and race_original != race_changed
            and race_mutated_during_read
            and race_final_metadata.st_mtime_ns == race_metadata.st_mtime_ns
            and race_final_metadata.st_ctime_ns != race_metadata.st_ctime_ns
            and snapshot_race_rc == 125
            and snapshot_race_error is not None
            and snapshot_race_before == snapshot_race_after,
            "post-snapshot source drift cannot change bytes and during-read drift is uncertain",
            (
                f"mutation={mutation_after_snapshot}/{snapshot_mutation_rc}/"
                f"{snapshot_mutation_error!r}/"
                f"{stored_mutation_artifact.is_file() and stored_mutation_artifact.read_bytes() == snapshot_original} "
                f"deletion={deletion_after_snapshot}/{snapshot_deletion_rc}/"
                f"{snapshot_deletion_error!r}/"
                f"{stored_deletion_artifact.is_file() and stored_deletion_artifact.read_bytes() == deletion_original} "
                f"during={race_mutated_during_read}/{snapshot_race_rc}/"
                f"{snapshot_race_error!r}/{snapshot_race_before != snapshot_race_after}/"
                f"mtime={race_final_metadata.st_mtime_ns == race_metadata.st_mtime_ns}/"
                f"ctime={race_final_metadata.st_ctime_ns != race_metadata.st_ctime_ns}"
            ),
        )

        config_home = new_home(root, "changing-config-home")
        config_source = source_directory(root, "changing-config-source")
        config_path = config_home / "config.json"
        config_raw = config_path.read_bytes()
        config_stage = config_home / "experiments" / ".staging"
        config_target = config_home / "experiments" / "first-experiment"
        config_changed = False
        config_rc: int | None = None
        config_error: BaseException | None = None
        if STORE is not None:
            original_prepare_stage = STORE._prepare_stage

            def change_config_after_staging(*args, **kwargs):
                nonlocal config_changed
                prepared = original_prepare_stage(*args, **kwargs)
                config_path.write_bytes(config_raw + b" ")
                config_changed = True
                return prepared

            STORE._prepare_stage = change_config_after_staging
            try:
                config_rc, _, config_error = store_install(config_home, config_source)
            finally:
                STORE._prepare_stage = original_prepare_stage
        config_final_absent = not config_target.exists() and not config_target.is_symlink()
        config_wrapper_count = len(tuple(config_stage.iterdir()))
        config_path.write_bytes(config_raw)
        config_before_inspect = fingerprint(config_stage)
        config_inspect_before = cli(
            config_home,
            "experiment",
            "inspect",
            "first-experiment",
        )
        config_after_inspect = fingerprint(config_stage)
        config_retry = cli(
            config_home,
            "experiment",
            "install",
            str(config_source),
        )
        config_retry_value = json_object(config_retry)
        config_inspect_after = cli(
            config_home,
            "experiment",
            "inspect",
            "first-experiment",
        )
        check(
            "IST-CONFIG-001",
            config_changed
            and config_rc == 125
            and config_error is not None
            and config_final_absent
            and config_wrapper_count == 1
            and config_inspect_before.returncode == 1
            and config_before_inspect == config_after_inspect
            and config_retry.returncode == 0
            and isinstance(config_retry_value, dict)
            and config_retry_value.get("changed") is True
            and config_inspect_after.returncode == 0
            and not tuple(config_stage.iterdir()),
            "configuration drift before publication is uncertain and its owned residue is restartable",
            (
                f"changed={config_changed} install={config_rc}/{config_error!r} "
                f"final_absent={config_final_absent} wrappers={config_wrapper_count} "
                f"inspect={config_inspect_before.returncode}/"
                f"{config_before_inspect != config_after_inspect} "
                f"retry={config_retry.returncode}/{config_retry_value!r}/"
                f"{config_inspect_after.returncode}"
            ),
        )

        reader_home = new_home(root, "reader-tamper-home")
        reader_install = cli(
            reader_home,
            "experiment",
            "install",
            str(direct_source),
        )
        reader_envelope = reader_home / "experiments" / "first-experiment"
        reader_failures: list[str] = []
        reader_paths = (
            "artifact/experiment.cue",
            "records/decision.json",
            "records/plan.json",
            "records/provenance.json",
            "records/install.json",
        )
        if reader_install.returncode == 0:
            for index, relative in enumerate(reader_paths):
                path = reader_envelope / relative
                raw = path.read_bytes()
                link = root / f"reader-hardlink-{index}"
                os.link(path, link)
                linked_rc, _, linked_error = store_inspect(
                    reader_home,
                    "first-experiment",
                )
                link.unlink()
                restored_link_rc, _, restored_link_error = store_inspect(
                    reader_home,
                    "first-experiment",
                )
                path.chmod(0o600)
                path.write_bytes(bytes((raw[0] ^ 1,)) + raw[1:])
                path.chmod(0o400)
                corrupt_before_retry = fingerprint(reader_envelope)
                corrupt_rc, _, corrupt_error = store_inspect(
                    reader_home,
                    "first-experiment",
                )
                retry_rc: int | None = 125
                retry_error: BaseException | None = RuntimeError("not receipt")
                retry_unchanged = True
                if relative == "records/install.json":
                    retry_rc, _, retry_error = store_install(reader_home, direct_source)
                    retry_unchanged = corrupt_before_retry == fingerprint(reader_envelope)
                path.chmod(0o600)
                path.write_bytes(raw)
                path.chmod(0o400)
                restored_rc, _, restored_error = store_inspect(
                    reader_home,
                    "first-experiment",
                )
                if not (
                    linked_rc == 125
                    and linked_error is not None
                    and restored_link_rc == 0
                    and restored_link_error is None
                    and corrupt_rc == 125
                    and corrupt_error is not None
                    and (
                        relative != "records/install.json"
                        or (retry_rc == 125 and retry_error is not None and retry_unchanged)
                    )
                    and restored_rc == 0
                    and restored_error is None
                ):
                    reader_failures.append(
                        f"{relative}:link={linked_rc}/{restored_link_rc}:"
                        f"corrupt={corrupt_rc}:retry={retry_rc}/{retry_unchanged}:"
                        f"restore={restored_rc}"
                    )
        check(
            "IST-READ-001",
            reader_install.returncode == 0 and not reader_failures,
            "every stored byte record is safe-opened, digest-bound, and non-overwritable",
            f"install={reader_install.returncode} failures={reader_failures[:5]!r}",
        )

        fault_source = source_directory(
            root,
            "fault-matrix-source",
            requested_name="fault-experiment",
        )
        fault_data = (fault_source / "experiment.cue").read_bytes()
        fault_fixture = FaultFixtureExperiment(fault_data, "fault-experiment")
        fault_failures: list[str] = []
        fault_counts: dict[str, int] = {}
        primitives = ("open", "write", "chmod", "fsync", "rename_noreplace")
        if STORE is not None:
            original_fault_loader = STORE._experiment_module
            STORE._experiment_module = lambda: fault_fixture
            try:
                for primitive in primitives:
                    baseline_home = new_home(root, f"fault-{primitive}-baseline-home")
                    if primitive == "rename_noreplace":
                        owner = STORE
                        attribute = "_rename_noreplace"
                    else:
                        owner = STORE.os
                        attribute = primitive
                    original_primitive = getattr(owner, attribute)
                    observed_calls = 0

                    def observe_primitive(*args, _original=original_primitive, **kwargs):
                        nonlocal observed_calls
                        observed_calls += 1
                        return _original(*args, **kwargs)

                    setattr(owner, attribute, observe_primitive)
                    try:
                        baseline_rc, baseline_value, baseline_error = store_install(
                            baseline_home,
                            fault_source,
                        )
                    finally:
                        setattr(owner, attribute, original_primitive)
                    fault_counts[primitive] = observed_calls
                    if not (
                        baseline_rc == 0
                        and isinstance(baseline_value, dict)
                        and baseline_error is None
                        and observed_calls > 0
                    ):
                        fault_failures.append(
                            f"{primitive}:baseline={baseline_rc}/{baseline_error!r}/"
                            f"calls={observed_calls}"
                        )
                        continue
                    for ordinal in range(1, observed_calls + 1):
                        injected_home = new_home(
                            root,
                            f"fault-{primitive}-{ordinal:02d}-home",
                        )
                        injected_calls = 0
                        injected_hit = False

                        def inject_primitive(*args, _original=original_primitive, **kwargs):
                            nonlocal injected_calls, injected_hit
                            injected_calls += 1
                            if injected_calls == ordinal:
                                injected_hit = True
                                raise OSError(errno.EIO, f"injected {primitive} failure")
                            return _original(*args, **kwargs)

                        setattr(owner, attribute, inject_primitive)
                        try:
                            injected_rc, injected_value, injected_error = store_install(
                                injected_home,
                                fault_source,
                            )
                        finally:
                            setattr(owner, attribute, original_primitive)
                        before_retry_rc, _, _ = store_inspect(
                            injected_home,
                            "fault-experiment",
                        )
                        retry_rc, retry_value, retry_error = store_install(
                            injected_home,
                            fault_source,
                        )
                        final_rc, _, final_error = store_inspect(
                            injected_home,
                            "fault-experiment",
                        )
                        staging_empty = not tuple(
                            (injected_home / "experiments" / ".staging").iterdir()
                        )
                        if not (
                            injected_hit
                            and injected_rc == 125
                            and injected_value is None
                            and injected_error is not None
                            and before_retry_rc in (0, 1, 125)
                            and retry_rc == 0
                            and isinstance(retry_value, dict)
                            and retry_error is None
                            and final_rc == 0
                            and final_error is None
                            and staging_empty
                        ):
                            fault_failures.append(
                                f"{primitive}[{ordinal}/{observed_calls}]:"
                                f"hit={injected_hit}:first={injected_rc}/{injected_error!r}:"
                                f"before={before_retry_rc}:retry={retry_rc}/{retry_error!r}:"
                                f"final={final_rc}/{final_error!r}:empty={staging_empty}"
                            )
            finally:
                STORE._experiment_module = original_fault_loader
        check(
            "IST-FAULT-001",
            STORE is not None
            and set(fault_counts) == set(primitives)
            and all(count > 0 for count in fault_counts.values())
            and not fault_failures,
            "every store open/write/chmod/fsync/rename failure is uncertain and restartable",
            f"counts={fault_counts!r} failures={fault_failures[:8]!r}",
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
        "IST-PROV-001",
        "IST-PREFLIGHT-001",
        "IST-SNAPSHOT-001",
        "IST-CONFIG-001",
        "IST-READ-001",
        "IST-FAULT-001",
    ]
    if OBSERVED != expected:
        print(f"INFRA install state assertion identity drift: {OBSERVED!r}", file=sys.stderr)
        return 125
    print(f"SUMMARY assertions=16 expected=16 failures={FAILURES} infra={INFRA}")
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
            f"SUMMARY assertions={len(OBSERVED)} expected=16 failures={FAILURES} infra=1"
        )
        raise SystemExit(125)
