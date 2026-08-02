#!/usr/bin/env python3
"""Private-runtime integrity cases for Experiment installation boundaries."""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
import errno
from importlib.util import module_from_spec, spec_from_file_location
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time
from typing import Callable, Iterator, NamedTuple


REPO_ROOT = Path(__file__).resolve().parents[2]
SUPPORT_PATH = REPO_ROOT / "tests" / "experiment" / "install-mutation-cases.py"
CUE_TOOLS = REPO_ROOT / ".cache" / "dev" / "tools" / "cue"
CEDAR_TOOLS = REPO_ROOT / ".cache" / "dev" / "tools" / "cedar"
BUNDLED_CATALOG_DOMAIN = b"agent-lab.experiment-image-catalog.v1\0"
PLAN_DOMAIN = b"agent-lab.experiment-plan.v1\0"
PUBLIC_TIMEOUT_SECONDS = 2.0
RACE_TIMEOUT_SECONDS = 0.75


def load_support():
    spec = spec_from_file_location("agent_lab_install_integrity_support", SUPPORT_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("install mutation support cannot be loaded")
    module = module_from_spec(spec)
    sys.modules[spec.name] = module
    previous = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = previous
    return module


try:
    SUPPORT = load_support()
    SUPPORT_ERROR: BaseException | None = None
except BaseException as error:
    SUPPORT = None
    SUPPORT_ERROR = error


if SUPPORT is None:
    class SupportInfrastructure(Exception):
        """Fallback type used only when the private support module cannot load."""
else:
    SupportInfrastructure = SUPPORT.InfrastructureError


class IntegrityInfrastructure(Exception):
    """The harness could not establish bounded, isolated evidence."""


class Result(NamedTuple):
    secure: bool
    detail: str


Probe = Callable[[Path, Path, tuple[str, ...]], Result]


@dataclass(frozen=True)
class Assertion:
    identity: str
    probe: Probe
    message: str


class CommandResult(NamedTuple):
    returncode: int | None
    stdout: bytes
    stderr: bytes
    timed_out: bool


def support():
    if SUPPORT is None:
        raise IntegrityInfrastructure(f"install mutation support is unavailable: {SUPPORT_ERROR}")
    return SUPPORT


def canonical(value: object) -> bytes:
    return json.dumps(
        value,
        allow_nan=False,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("ascii")


def digest(domain: bytes, value: object) -> str:
    import hashlib

    return "sha256:" + hashlib.sha256(domain + canonical(value)).hexdigest()


def load_private_module(path: Path, name: str):
    helper = support()
    previous = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        return helper.load_module(path, name)
    finally:
        sys.dont_write_bytecode = previous


def private_runtime(root: Path, names: tuple[str, ...]) -> Path:
    runtime = root / "runtime"
    support().copy_runtime(runtime, names)
    return runtime


@contextmanager
def tool_environment() -> Iterator[None]:
    keys = ("AGENT_LAB_CUE_TOOL_DIR", "AGENT_LAB_CEDAR_TOOL_DIR")
    previous = {key: os.environ.get(key) for key in keys}
    os.environ["AGENT_LAB_CUE_TOOL_DIR"] = str(CUE_TOOLS)
    os.environ["AGENT_LAB_CEDAR_TOOL_DIR"] = str(CEDAR_TOOLS)
    try:
        yield
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def actual_install(store, home: Path, source: Path, *, fault=None):
    try:
        value = store.install_directory(home, source, fault=fault)
        return 0, value, None
    except store.StoreReject as error:
        return 1, None, error
    except store.StoreInfrastructure as error:
        return 125, None, error
    except BaseException as error:
        return None, None, error


def direct_source(root: Path, name: str, command: str) -> Path:
    return support().write_source(root, name, support().artifact_bytes(command))


def bundled_source(root: Path) -> Path:
    data = (
        "package experiment\n\n"
        "experiment: {\n"
        '\tapiVersion: "agent-lab/v0alpha1"\n'
        '\tkind: "Experiment"\n'
        '\tmetadata: name: "bundled-integrity"\n'
        "\tspec: members: [{\n"
        '\t\tname: "worker"\n'
        '\t\timage: catalogName: "agent-lab.worker"\n'
        '\t\tcommand: ["serve"]\n'
        "\t}]\n"
        "}\n"
    ).encode("ascii")
    return support().write_source(root, "bundled-source", data)


def runtime_unchanged(
    runtime: Path,
    names: tuple[str, ...],
    expected: tuple[object, ...],
    purpose: str,
) -> None:
    if support().runtime_fingerprint(runtime, names) != expected:
        raise IntegrityInfrastructure(f"{purpose} changed its private runtime")


def probe_cleanup_parent_swap(root: Path, runtime: Path, names: tuple[str, ...]) -> Result:
    store = load_private_module(
        runtime / "scripts" / "experiment_store.py",
        f"agent_lab_integrity_cleanup_{os.getpid()}_{id(root)}",
    )
    runtime_before = support().runtime_fingerprint(runtime, names)
    cleanup = root / "cleanup"
    payload = cleanup / "payload"
    artifact = payload / "artifact"
    artifact.mkdir(mode=0o700, parents=True)
    os.chmod(cleanup, 0o700)
    os.chmod(payload, 0o700)
    inside = artifact / "experiment.cue"
    inside.write_bytes(b"inside\n")
    os.chmod(inside, 0o400)
    outside = root / "outside"
    outside.mkdir(mode=0o700)
    canary = outside / "experiment.cue"
    canary.write_bytes(b"outside-canary\n")
    os.chmod(canary, 0o400)
    parked = root / "parked-artifact"
    outside_before = support().tree_fingerprint(outside)
    original_names = store._directory_names
    swapped = False

    def swap_parent(path: Path, purpose: str, maximum: int):
        nonlocal swapped
        found = original_names(path, purpose, maximum)
        if path == artifact and not swapped:
            artifact.rename(parked)
            os.symlink(outside, artifact)
            swapped = True
        return found

    store._directory_names = swap_parent
    outcome: int | None = None
    error: BaseException | None = None
    try:
        store._remove_tree(cleanup, cleanup)
        outcome = 0
    except store.StoreInfrastructure as caught:
        outcome = 125
        error = caught
    except BaseException as caught:
        error = caught
    finally:
        store._directory_names = original_names
    outside_after = support().tree_fingerprint(outside)

    mode_cleanup = root / "mode-cleanup"
    mode_payload = mode_cleanup / "payload"
    mode_artifact = mode_payload / "artifact"
    mode_artifact.mkdir(mode=0o700, parents=True)
    os.chmod(mode_cleanup, 0o700)
    os.chmod(mode_payload, 0o700)
    mode_canary = mode_artifact / "experiment.cue"
    mode_canary.write_bytes(b"mode-race-canary\n")
    os.chmod(mode_canary, 0o400)
    payload_identity = mode_payload.stat()
    original_open = store.os.open
    mode_changed = False

    def change_mode_before_open(path, flags, mode=0o777, *, dir_fd=None):
        nonlocal mode_changed
        if path == "artifact" and dir_fd is not None and not mode_changed:
            parent = os.fstat(dir_fd)
            if (parent.st_dev, parent.st_ino) == (
                payload_identity.st_dev,
                payload_identity.st_ino,
            ):
                os.chmod(mode_artifact, 0o777)
                mode_changed = True
        return original_open(path, flags, mode, dir_fd=dir_fd)

    store.os.open = change_mode_before_open
    mode_outcome: int | None = None
    mode_error: BaseException | None = None
    try:
        store._remove_tree(mode_cleanup, mode_cleanup)
        mode_outcome = 0
    except store.StoreInfrastructure as caught:
        mode_outcome = 125
        mode_error = caught
    except BaseException as caught:
        mode_error = caught
    finally:
        store.os.open = original_open

    runtime_unchanged(runtime, names, runtime_before, "cleanup parent-swap probe")
    mode_canary_preserved = (
        mode_canary.is_file()
        and mode_canary.read_bytes() == b"mode-race-canary\n"
    )
    secure = (
        swapped
        and outcome == 125
        and outside_before == outside_after
        and mode_changed
        and mode_outcome == 125
        and mode_canary_preserved
    )
    return Result(
        secure,
        (
            f"swapped={swapped} outcome={outcome} error={error!r} "
            f"outside_changed={outside_before != outside_after} mode_changed={mode_changed} "
            f"mode_outcome={mode_outcome} mode_error={mode_error!r} "
            f"mode_canary_preserved={mode_canary_preserved}"
        ),
    )


def probe_contract_drift(root: Path, runtime: Path, names: tuple[str, ...]) -> Result:
    home = support().initialized_home(runtime, root, "contract-home")
    source = direct_source(root, "contract-source", "contract")
    store = load_private_module(
        runtime / "scripts" / "experiment_store.py",
        f"agent_lab_integrity_contract_{os.getpid()}_{id(root)}",
    )
    contract = runtime / "contracts" / "experiment" / "v0alpha1" / "schema.cue"
    original = contract.read_bytes()
    mutated = original.replace(b"strings.MaxRunes(63)", b"strings.MaxRunes(62)", 1)
    if mutated == original or len(mutated) != len(original):
        raise IntegrityInfrastructure("trusted contract mutation is not exactly applicable")
    runtime_before = support().runtime_fingerprint(runtime, names)
    store_before = support().tree_fingerprint(home / "experiments")
    reached = False

    def mutate_contract(point: str) -> None:
        nonlocal reached
        if point == "experiment store lock.after_acquire" and not reached:
            contract.write_bytes(mutated)
            reached = True

    try:
        with tool_environment():
            rc, value, error = actual_install(store, home, source, fault=mutate_contract)
    finally:
        contract.write_bytes(original)
    store_after = support().tree_fingerprint(home / "experiments")
    runtime_unchanged(runtime, names, runtime_before, "trusted contract drift probe")
    final = home / "experiments" / "mutation-store"
    secure = (
        reached
        and rc == 125
        and value is None
        and isinstance(error, store.StoreInfrastructure)
        and not final.exists()
        and store_before == store_after
    )
    return Result(
        secure,
        f"reached={reached} rc={rc} error={error!r} final={final.exists()} store_changed={store_before != store_after}",
    )


def probe_bundled_provenance(root: Path, runtime: Path, names: tuple[str, ...]) -> Result:
    catalog = {
        "apiVersion": "agent-lab.experiment-images/v0alpha1",
        "entries": [{"name": "agent-lab.worker", "subject": support().SUBJECT}],
    }
    catalog_path = runtime / "catalog" / "experiment-images" / "v0alpha1.json"
    catalog_path.write_bytes(canonical(catalog) + b"\n")
    expected = digest(BUNDLED_CATALOG_DOMAIN, catalog)
    runtime_before = support().runtime_fingerprint(runtime, names)
    home = support().initialized_home(runtime, root, "bundled-home")
    source = bundled_source(root)
    store = load_private_module(
        runtime / "scripts" / "experiment_store.py",
        f"agent_lab_integrity_bundle_{os.getpid()}_{id(root)}",
    )
    with tool_environment():
        rc, value, error = actual_install(store, home, source)
    provenance_path = (
        home
        / "experiments"
        / "bundled-integrity"
        / "records"
        / "provenance.json"
    )
    try:
        provenance = json.loads(provenance_path.read_bytes()) if provenance_path.is_file() else None
    except (OSError, UnicodeError, json.JSONDecodeError):
        provenance = None
    runtime_unchanged(runtime, names, runtime_before, "bundled provenance probe")
    expected_catalog = {"bundled": {"snapshotDigest": expected}}
    secure = (
        rc == 0
        and isinstance(value, dict)
        and error is None
        and isinstance(provenance, dict)
        and provenance.get("catalog") == expected_catalog
    )
    return Result(
        secure,
        f"rc={rc} error={error!r} expected={expected_catalog!r} stored={None if not isinstance(provenance, dict) else provenance.get('catalog')!r}",
    )


def descriptor_open(descriptor: int) -> bool:
    try:
        os.fstat(descriptor)
    except OSError as error:
        if error.errno == errno.EBADF:
            return False
        raise
    return True


def probe_unlock_failure(root: Path, runtime: Path, names: tuple[str, ...]) -> Result:
    home = support().initialized_home(runtime, root, "unlock-home")
    first_data = support().artifact_bytes("unlock-one")
    second_data = support().artifact_bytes("unlock-two")
    first_source = support().write_source(root, "unlock-source-one", first_data)
    second_source = support().write_source(root, "unlock-source-two", second_data)
    fixtures = {
        first_data: support().PlanFixture(
            support().requested_plan("mutation-store", "unlock-one"),
            None,
        ),
        second_data: support().PlanFixture(
            support().requested_plan("mutation-store", "unlock-two"),
            None,
        ),
    }
    experiment = support().FixtureExperiment(fixtures)
    store = support().fixture_store(runtime, root, experiment)
    runtime_before = support().runtime_fingerprint(runtime, names)
    first_rc, _, first_error = support().install_result(store, home, first_source)
    original_flock = store.fcntl.flock
    unlock_descriptor: int | None = None

    def fail_unlock(descriptor: int, operation: int) -> None:
        nonlocal unlock_descriptor
        if operation == store.fcntl.LOCK_UN:
            unlock_descriptor = descriptor
            raise OSError("injected LOCK_UN failure")
        original_flock(descriptor, operation)

    descriptors_before = set(os.listdir("/proc/self/fd"))
    store.fcntl.flock = fail_unlock
    try:
        rc, value, error = support().install_result(store, home, second_source)
    finally:
        store.fcntl.flock = original_flock
    leaked = unlock_descriptor is not None and descriptor_open(unlock_descriptor)
    descriptors_after = set(os.listdir("/proc/self/fd"))
    secure = (
        first_rc == 0
        and first_error is None
        and rc == 125
        and value is None
        and isinstance(error, store.StoreInfrastructure)
        and unlock_descriptor is not None
        and not leaked
        and descriptors_before == descriptors_after
    )
    if leaked and unlock_descriptor is not None:
        os.close(unlock_descriptor)
    descriptors_clean = set(os.listdir("/proc/self/fd"))
    if descriptors_clean != descriptors_before:
        raise IntegrityInfrastructure("unlock probe could not restore its descriptor set")
    runtime_unchanged(runtime, names, runtime_before, "lock release probe")
    return Result(
        secure,
        f"first={first_rc}/{first_error!r} conflict={rc}/{error!r}/{value!r} unlock_fd={unlock_descriptor} leaked={leaked} fd_delta={sorted(descriptors_after - descriptors_before)!r}",
    )


def probe_snapshot_race(root: Path, runtime: Path, names: tuple[str, ...]) -> Result:
    experiment = load_private_module(
        runtime / "scripts" / "experiment.py",
        f"agent_lab_integrity_snapshot_{os.getpid()}_{id(root)}",
    )
    runtime_before = support().runtime_fingerprint(runtime, names)
    original = support().artifact_bytes("snapshot-one")
    changed = support().artifact_bytes("snapshot-two")
    if len(original) != len(changed) or original == changed:
        raise IntegrityInfrastructure("same-size source mutation fixture is invalid")
    source = support().write_source(root, "snapshot-race-source", original)
    path = source / "experiment.cue"
    before = path.stat()
    original_read = experiment.os.read
    reached = False

    def mutate_after_first_read(descriptor: int, maximum: int) -> bytes:
        nonlocal reached
        data = original_read(descriptor, maximum)
        try:
            target = os.readlink(f"/proc/self/fd/{descriptor}")
        except OSError:
            target = ""
        if data and target == str(path) and not reached:
            path.write_bytes(changed)
            os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
            reached = True
        return data

    experiment.os.read = mutate_after_first_read
    outcome: int | None = None
    error: BaseException | None = None
    try:
        experiment.read_directory_snapshot(str(source))
        outcome = 0
    except experiment.InfrastructureError as caught:
        outcome = 125
        error = caught
    except experiment.InvalidManifest as caught:
        outcome = 1
        error = caught
    except BaseException as caught:
        error = caught
    finally:
        experiment.os.read = original_read
    runtime_unchanged(runtime, names, runtime_before, "source snapshot race probe")
    secure = reached and outcome == 125 and isinstance(error, experiment.InfrastructureError)
    return Result(secure, f"reached={reached} outcome={outcome} error={error!r}")


def terminate(process: subprocess.Popen[bytes]) -> tuple[bytes, bytes]:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        return process.communicate(timeout=0.25)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        return process.communicate(timeout=1)


def bounded_public(
    runtime: Path,
    home: Path,
    source: Path,
    *,
    environment: dict[str, str] | None = None,
    timeout: float = PUBLIC_TIMEOUT_SECONDS,
) -> CommandResult:
    env = {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"}
    if environment:
        env.update(environment)
    process = subprocess.Popen(
        [
            sys.executable,
            "-I",
            "-B",
            str(runtime / "scripts" / "agent-lab.py"),
            "--home",
            str(home),
            "experiment",
            "install",
            str(source),
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout)
        if support().process_group_exists(process.pid):
            terminate(process)
            raise IntegrityInfrastructure("public preflight left a descendant process")
        return CommandResult(process.returncode, stdout, stderr, False)
    except subprocess.TimeoutExpired:
        stdout, stderr = terminate(process)
        if support().process_group_exists(process.pid):
            raise IntegrityInfrastructure("timed-out public preflight left a process group")
        return CommandResult(None, stdout, stderr, True)


def instrument_preflight(runtime: Path) -> None:
    path = runtime / "scripts" / "agent-lab.py"
    source = path.read_text(encoding="utf-8")
    old = (
        "    if not home_authority_metadata_safe(lexical):\n"
        '        raise RuntimeError("home authority files are unsafe")\n'
        "    flags = (\n"
    )
    new = (
        "    if not home_authority_metadata_safe(lexical):\n"
        '        raise RuntimeError("home authority files are unsafe")\n'
        '    integrity_ready = os.environ.get("AGENT_LAB_IIN_PREFLIGHT_READY")\n'
        '    if integrity_ready is not None:\n'
        '        Path(integrity_ready).touch()\n'
        '        integrity_release = Path(os.environ["AGENT_LAB_IIN_PREFLIGHT_RELEASE"])\n'
        '        integrity_deadline = __import__("time").monotonic() + 2.0\n'
        '        while (\n'
        '            not integrity_release.exists()\n'
        '            and __import__("time").monotonic() < integrity_deadline\n'
        '        ):\n'
        '            __import__("time").sleep(0.005)\n'
        '        if not integrity_release.exists():\n'
        '            raise RuntimeError("integrity preflight release is unavailable")\n'
        "    flags = (\n"
    )
    if source.count(old) != 1:
        raise IntegrityInfrastructure("public preflight instrumentation is not exactly applicable")
    path.write_text(source.replace(old, new, 1), encoding="utf-8")
    cache = runtime.parent / "preflight-pycache"
    completed = support().run_command(
        [
            sys.executable,
            "-I",
            "-B",
            "-X",
            f"pycache_prefix={cache}",
            "-m",
            "py_compile",
            str(path),
        ]
    )
    if completed.returncode != 0 or completed.stderr:
        raise IntegrityInfrastructure("instrumented public preflight does not compile")


def restore_authority(path: Path, parked: Path) -> None:
    try:
        if path.is_symlink() or stat.S_ISFIFO(path.lstat().st_mode) or path.is_file():
            path.unlink()
        parked.rename(path)
    except OSError as error:
        raise IntegrityInfrastructure("public preflight authority fixture could not be restored") from error


def wait_for_file(path: Path, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.is_file():
            return True
        time.sleep(0.005)
    return False


def race_fifo_public(runtime: Path, home: Path, source: Path, root: Path) -> CommandResult:
    ready = root / "race-ready"
    release = root / "race-release"
    path = home / "config.json"
    parked = home / "config.parked"
    env = {
        "PATH": "/usr/bin:/bin",
        "LANG": "C",
        "LC_ALL": "C",
        "AGENT_LAB_IIN_PREFLIGHT_READY": str(ready),
        "AGENT_LAB_IIN_PREFLIGHT_RELEASE": str(release),
    }
    process = subprocess.Popen(
        [
            sys.executable,
            "-I",
            "-B",
            str(runtime / "scripts" / "agent-lab.py"),
            "--home",
            str(home),
            "experiment",
            "install",
            str(source),
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        start_new_session=True,
    )
    if not wait_for_file(ready, 1.0):
        terminate(process)
        raise IntegrityInfrastructure("public preflight race did not reach its read boundary")
    path.rename(parked)
    os.mkfifo(path, mode=0o600)
    release.touch()
    try:
        try:
            stdout, stderr = process.communicate(timeout=RACE_TIMEOUT_SECONDS)
            result = CommandResult(process.returncode, stdout, stderr, False)
        except subprocess.TimeoutExpired:
            stdout, stderr = terminate(process)
            if support().process_group_exists(process.pid):
                raise IntegrityInfrastructure("racing public preflight left a process group")
            result = CommandResult(None, stdout, stderr, True)
    finally:
        restore_authority(path, parked)
    return result


def probe_public_preflight(root: Path, runtime: Path, names: tuple[str, ...]) -> Result:
    instrument_preflight(runtime)
    runtime_before = support().runtime_fingerprint(runtime, names)
    source = direct_source(root, "preflight-source", "preflight")
    source_before = support().tree_fingerprint(source)
    observations: dict[str, CommandResult] = {}
    state_checks: dict[str, bool] = {}

    symlink_home = support().initialized_home(runtime, root, "symlink-home")
    symlink_before = support().tree_fingerprint(symlink_home / "experiments")
    symlink_path = symlink_home / "config.json"
    symlink_parked = symlink_home / "config.parked"
    symlink_path.rename(symlink_parked)
    os.symlink(symlink_parked, symlink_path)
    try:
        observations["symlink"] = bounded_public(runtime, symlink_home, source)
    finally:
        restore_authority(symlink_path, symlink_parked)
    state_checks["symlink"] = symlink_before == support().tree_fingerprint(
        symlink_home / "experiments"
    )

    fifo_home = support().initialized_home(runtime, root, "fifo-home")
    fifo_before = support().tree_fingerprint(fifo_home / "experiments")
    fifo_path = fifo_home / "home.json"
    fifo_parked = fifo_home / "home.parked"
    fifo_path.rename(fifo_parked)
    os.mkfifo(fifo_path, mode=0o600)
    try:
        observations["fifo"] = bounded_public(runtime, fifo_home, source)
    finally:
        restore_authority(fifo_path, fifo_parked)
    state_checks["fifo"] = fifo_before == support().tree_fingerprint(
        fifo_home / "experiments"
    )

    bound_home = support().initialized_home(runtime, root, "bound-home")
    bound_before = support().tree_fingerprint(bound_home / "experiments")
    bound_path = bound_home / "config.json"
    bound_raw = bound_path.read_bytes()
    bound_path.write_bytes(b"{" + b" " * 1_048_577 + b"}\n")
    os.chmod(bound_path, 0o600)
    try:
        observations["over-bound"] = bounded_public(runtime, bound_home, source)
    finally:
        bound_path.write_bytes(bound_raw)
        os.chmod(bound_path, 0o600)
    state_checks["over-bound"] = bound_before == support().tree_fingerprint(
        bound_home / "experiments"
    )

    race_home = support().initialized_home(runtime, root, "race-home")
    race_before = support().tree_fingerprint(race_home / "experiments")
    observations["race"] = race_fifo_public(runtime, race_home, source, root)
    state_checks["race"] = race_before == support().tree_fingerprint(
        race_home / "experiments"
    )

    source_after = support().tree_fingerprint(source)
    runtime_unchanged(runtime, names, runtime_before, "public preflight probe")
    clean_results = all(
        observation.returncode == 125
        and not observation.timed_out
        and not observation.stdout
        for observation in observations.values()
    )
    secure = clean_results and all(state_checks.values()) and source_before == source_after
    rendered = {
        key: (value.returncode, value.timed_out, value.stderr.decode("utf-8", errors="replace").strip())
        for key, value in observations.items()
    }
    return Result(
        secure,
        f"results={rendered!r} state={state_checks!r} source_changed={source_before != source_after}",
    )


def probe_plan_identity(root: Path, runtime: Path, names: tuple[str, ...]) -> Result:
    home = support().initialized_home(runtime, root, "plan-home")
    source = direct_source(root, "plan-source", "plan")
    store = load_private_module(
        runtime / "scripts" / "experiment_store.py",
        f"agent_lab_integrity_plan_{os.getpid()}_{id(root)}",
    )
    runtime_before = support().runtime_fingerprint(runtime, names)
    with tool_environment():
        rc, value, error = actual_install(store, home, source)
    records = home / "experiments" / "mutation-store" / "records"
    try:
        plan = json.loads((records / "plan.json").read_bytes())
        decision = json.loads((records / "decision.json").read_bytes())
        receipt = json.loads((records / "install.json").read_bytes())
    except (OSError, UnicodeError, json.JSONDecodeError):
        plan = decision = receipt = None
    runtime_unchanged(runtime, names, runtime_before, "plan identity probe")
    expected = digest(PLAN_DOMAIN, plan) if isinstance(plan, dict) else None
    decision_digest = None
    receipt_digest = None
    identity_digest = None
    if isinstance(decision, dict):
        binding = decision.get("binding")
        if isinstance(binding, dict):
            decision_digest = binding.get("planDigest")
    if isinstance(receipt, dict):
        record_map = receipt.get("records")
        if isinstance(record_map, dict):
            plan_record = record_map.get("records/plan.json")
            if isinstance(plan_record, dict):
                receipt_digest = plan_record.get("digest")
        identity = receipt.get("identity")
        if isinstance(identity, dict):
            identity_digest = identity.get("planDigest")
    secure = (
        rc == 0
        and isinstance(value, dict)
        and error is None
        and expected is not None
        and decision_digest == expected
        and receipt_digest == expected
        and identity_digest == expected
    )
    return Result(
        secure,
        f"rc={rc} error={error!r} expected={expected!r} decision={decision_digest!r} receipt={receipt_digest!r} identity={identity_digest!r}",
    )


ASSERTIONS: tuple[Assertion, ...] = (
    Assertion(
        "IIN-CLEAN-001",
        probe_cleanup_parent_swap,
        "cleanup preserves data across parent-swap and directory-metadata races",
    ),
    Assertion(
        "IIN-CONTRACT-001",
        probe_contract_drift,
        "trusted contract drift at store-lock acquisition fails before store effect",
    ),
    Assertion(
        "IIN-BUNDLE-001",
        probe_bundled_provenance,
        "bundled catalog provenance binds the independently framed snapshot identity",
    ),
    Assertion(
        "IIN-LOCK-001",
        probe_unlock_failure,
        "unlock failure dominates conflict and closes the store-lock descriptor",
    ),
    Assertion(
        "IIN-SNAPSHOT-001",
        probe_snapshot_race,
        "same-size source drift with restored mtime is snapshot uncertainty",
    ),
    Assertion(
        "IIN-PREFLIGHT-001",
        probe_public_preflight,
        "public home preflight rejects unsafe and racing authority files within bounds",
    ),
    Assertion(
        "IIN-PLAN-001",
        probe_plan_identity,
        "decision and receipt bind the independently domain-separated plan identity",
    ),
)


def main() -> int:
    try:
        helper = support()
        if not CUE_TOOLS.is_dir() or not CEDAR_TOOLS.is_dir():
            raise IntegrityInfrastructure("pinned CUE or Cedar fixtures are unavailable")
        names = helper.manifest_paths()
        shared_before = helper.runtime_fingerprint(REPO_ROOT, names)
        expected = (
            "IIN-CLEAN-001",
            "IIN-CONTRACT-001",
            "IIN-BUNDLE-001",
            "IIN-LOCK-001",
            "IIN-SNAPSHOT-001",
            "IIN-PREFLIGHT-001",
            "IIN-PLAN-001",
        )
        if tuple(assertion.identity for assertion in ASSERTIONS) != expected:
            raise IntegrityInfrastructure("install integrity assertion identity drift")
        failures = 0
        observed: list[str] = []
        previous_bytecode = sys.dont_write_bytecode
        sys.dont_write_bytecode = True
        try:
            for assertion in ASSERTIONS:
                try:
                    temporary = Path(
                        tempfile.mkdtemp(
                            prefix=f"agent-lab-{assertion.identity.lower()}-",
                            dir="/tmp",
                        )
                    )
                except OSError as error:
                    raise IntegrityInfrastructure(
                        f"{assertion.identity} private root is unavailable"
                    ) from error
                try:
                    runtime = private_runtime(temporary, names)
                    result = assertion.probe(temporary, runtime, names)
                    observed.append(assertion.identity)
                    if result.secure:
                        print(f"PASS {assertion.identity} {assertion.message}")
                    else:
                        failures += 1
                        print(
                            f"FAIL {assertion.identity} {assertion.message} ({result.detail})"
                        )
                finally:
                    helper.remove_private_root(temporary)
                    if helper.runtime_fingerprint(REPO_ROOT, names) != shared_before:
                        raise IntegrityInfrastructure(
                            f"{assertion.identity} changed the shared runtime fingerprint"
                        )
        finally:
            sys.dont_write_bytecode = previous_bytecode
        if tuple(observed) != expected:
            raise IntegrityInfrastructure("install integrity execution identity drift")
        print(f"SUMMARY assertions=7 expected=7 failures={failures} infra=0")
        return 0 if failures == 0 else 1
    except (IntegrityInfrastructure, SupportInfrastructure) as error:
        print(f"INFRA install integrity evidence: {error}", file=sys.stderr)
        return 125


if __name__ == "__main__":
    raise SystemExit(main())
