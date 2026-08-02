#!/usr/bin/env python3
"""Private-copy sensitivity mutations for the local Experiment store."""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
import hashlib
from importlib.util import module_from_spec, spec_from_file_location
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from typing import Callable, Iterator, NamedTuple


REPO_ROOT = Path(__file__).resolve().parents[2]
RUNTIME_MANIFEST = REPO_ROOT / "packaging" / "agent-lab-local.manifest"
COMMAND_TIMEOUT_SECONDS = 5
SOURCE_DOMAIN = b"agent-lab.experiment-tree.v1\0"
PLAN_DOMAIN = b"agent-lab.experiment-plan.v1\0"
SUBJECT = "registry.example/team/worker@sha256:" + "a" * 64
AUTHORIZATION_DIGEST = "sha256:" + "c" * 64
CONTRACT_DIGEST = "sha256:" + "d" * 64
MUTATION_KEYS = (
    "AGENT_LAB_MUTATION_DECISION",
    "AGENT_LAB_MUTATION_MARK",
    "AGENT_LAB_MUTATION_NAME",
    "AGENT_LAB_MUTATION_SOURCE",
)


class InfrastructureError(Exception):
    """The mutation or its isolated evidence could not be proved."""


class ProbeResult(NamedTuple):
    secure: bool
    detail: str


Probe = Callable[[Path, Path, Path | None], ProbeResult]


@dataclass(frozen=True)
class Mutation:
    assertion: str
    path: str
    old: str
    new: str
    probe: Probe
    message: str


class Snapshot(NamedTuple):
    data: bytes
    digest: str


class Resolution(NamedTuple):
    plan: dict[str, object]
    bundled_catalog: dict[str, object] | None
    local_catalog: dict[str, object] | None


class PlanFixture(NamedTuple):
    plan: dict[str, object]
    local_catalog: dict[str, object] | None


class FixtureInvalidManifest(Exception):
    """The synthetic manifest is outside the declared fixture set."""


class FixtureInfrastructure(Exception):
    """The synthetic planning fixture could not establish a result."""


def canonical(value: object) -> bytes:
    return json.dumps(
        value,
        allow_nan=False,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("ascii")


def digest(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def source_digest(data: bytes) -> str:
    name = b"experiment.cue"
    value = hashlib.sha256(SOURCE_DOMAIN)
    value.update(len(name).to_bytes(4, "big"))
    value.update(name)
    value.update(len(data).to_bytes(8, "big"))
    value.update(data)
    return "sha256:" + value.hexdigest()


def artifact_bytes(command: str) -> bytes:
    return (
        "package experiment\n\n"
        "experiment: {\n"
        '\tapiVersion: "agent-lab/v0alpha1"\n'
        '\tkind: "Experiment"\n'
        '\tmetadata: name: "mutation-store"\n'
        "\tspec: members: [{\n"
        '\t\tname: "worker"\n'
        f'\t\timage: digestRef: "{SUBJECT}"\n'
        f'\t\tcommand: ["{command}"]\n'
        "\t}]\n"
        "}\n"
    ).encode("ascii")


def requested_plan(
    name: str,
    command: str,
    *,
    local_record: dict[str, object] | None = None,
) -> dict[str, object]:
    if local_record is None:
        requested = {"digestRef": SUBJECT}
        resolved = {"origin": "direct", "subject": SUBJECT}
    else:
        requested = {"catalogName": "vendor.worker"}
        resolved = {
            "entryDigest": local_record["entryDigest"],
            "generation": local_record["generation"],
            "origin": "local",
            "subject": local_record["subject"],
        }
    return {
        "apiVersion": "agent-lab.request/v0alpha1",
        "contract": {
            "digest": CONTRACT_DIGEST,
            "name": "agent-lab.experiment",
            "version": "v0alpha1",
        },
        "kind": "RequestedExperimentPlan",
        "metadata": {"requestedName": name},
        "spec": {
            "members": [
                {
                    "command": [command],
                    "name": "worker",
                    "requestedSelector": requested,
                    "resolvedImage": resolved,
                    "resourceClass": "small",
                }
            ]
        },
    }


def decision_for(
    plan: dict[str, object],
    snapshot_digest: str,
    verdict: str,
) -> dict[str, object]:
    plan_digest = digest(PLAN_DOMAIN + canonical(plan))
    requested_name = plan["metadata"]["requestedName"]  # type: ignore[index]
    return {
        "action": "experiment.install",
        "apiVersion": "agent-lab.authorization/v0alpha1",
        "binding": {
            "authorizationDigest": AUTHORIZATION_DIGEST,
            "contractDigest": CONTRACT_DIGEST,
            "planDigest": plan_digest,
            "sourceDigest": snapshot_digest,
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
            "requestedName": requested_name,
            "type": "AgentLab::RequestedExperimentPlan",
        },
        "verdict": verdict,
    }


class FixtureExperiment:
    InvalidManifest = FixtureInvalidManifest
    InfrastructureError = FixtureInfrastructure

    def __init__(
        self,
        fixtures: dict[bytes, PlanFixture],
        *,
        verdict: str = "permit",
        after_authorize: Callable[[], None] | None = None,
    ) -> None:
        self.fixtures = fixtures
        self.verdict = verdict
        self.after_authorize = after_authorize
        self.authorize_calls = 0

    def read_directory_snapshot(self, source: str) -> Snapshot:
        try:
            data = (Path(source) / "experiment.cue").read_bytes()
        except OSError as error:
            raise FixtureInfrastructure("fixture source cannot be read") from error
        if data not in self.fixtures:
            raise FixtureInvalidManifest("fixture source is unknown")
        return Snapshot(data, source_digest(data))

    def authored_manifest(self, snapshot: Snapshot) -> bytes:
        return snapshot.data

    def cue_plan_with_evidence(self, manifest: object) -> Resolution:
        if not isinstance(manifest, bytes) or manifest not in self.fixtures:
            raise FixtureInvalidManifest("fixture manifest is unknown")
        fixture = self.fixtures[manifest]
        return Resolution(fixture.plan, None, fixture.local_catalog)

    def authorize_plan(
        self,
        plan: dict[str, object],
        snapshot_digest: str,
    ) -> tuple[dict[str, object], int]:
        self.authorize_calls += 1
        decision = decision_for(plan, snapshot_digest, self.verdict)
        if self.after_authorize is not None:
            self.after_authorize()
        return decision, 0 if self.verdict == "permit" else 1

    def verify_trusted_inputs(
        self,
        plan: dict[str, object],
        decision: dict[str, object],
    ) -> None:
        if not isinstance(plan, dict) or not isinstance(decision, dict):
            raise FixtureInfrastructure("fixture trusted inputs are malformed")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def manifest_paths() -> tuple[str, ...]:
    try:
        raw = RUNTIME_MANIFEST.read_bytes()
        text = raw.decode("utf-8")
    except (OSError, UnicodeError) as error:
        raise InfrastructureError("runtime manifest cannot be read exactly") from error
    if not text.endswith("\n"):
        raise InfrastructureError("runtime manifest lacks its final newline")
    names = tuple(line for line in text.splitlines() if line)
    if not names or len(names) != len(set(names)) or names != tuple(sorted(names)):
        raise InfrastructureError("runtime manifest is empty, duplicated, or unordered")
    for name in names:
        path = Path(name)
        if path.is_absolute() or ".." in path.parts or str(path) != name:
            raise InfrastructureError(f"runtime manifest path is unsafe: {name}")
    required = {
        "scripts/agent-lab.py",
        "scripts/experiment.py",
        "scripts/experiment_store.py",
        "scripts/image_catalog.py",
        "scripts/image_reference.py",
    }
    if not required.issubset(names):
        raise InfrastructureError("runtime manifest omits an Experiment store runtime path")
    return names


def file_identity(path: Path) -> tuple[str, int, int, str]:
    try:
        metadata = path.lstat()
        data = path.read_bytes()
    except OSError as error:
        raise InfrastructureError(f"runtime path cannot be fingerprinted: {path}") from error
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise InfrastructureError(f"runtime path is not a single regular file: {path}")
    return ("file", stat.S_IMODE(metadata.st_mode), len(data), sha256_bytes(data))


def runtime_fingerprint(
    root: Path,
    names: tuple[str, ...],
) -> tuple[tuple[str, tuple[str, int, int, str]], ...]:
    paths = ("packaging/agent-lab-local.manifest", *names)
    return tuple((name, file_identity(root / name)) for name in paths)


def tree_fingerprint(root: Path) -> tuple[tuple[object, ...], ...]:
    if not root.exists() and not root.is_symlink():
        return ()
    values: list[tuple[object, ...]] = []
    pending = [root]
    while pending:
        path = pending.pop()
        try:
            metadata = path.lstat()
        except OSError as error:
            raise InfrastructureError(f"probe state cannot be fingerprinted: {path}") from error
        relative = "." if path == root else path.relative_to(root).as_posix()
        mode = stat.S_IMODE(metadata.st_mode)
        if stat.S_ISDIR(metadata.st_mode):
            kind = "directory"
            payload = ""
            try:
                pending.extend(sorted(path.iterdir(), reverse=True))
            except OSError as error:
                raise InfrastructureError(f"probe directory cannot be listed: {path}") from error
        elif stat.S_ISREG(metadata.st_mode):
            kind = "file"
            try:
                payload = sha256_bytes(path.read_bytes())
            except OSError as error:
                raise InfrastructureError(f"probe file cannot be read: {path}") from error
        elif stat.S_ISLNK(metadata.st_mode):
            kind = "symlink"
            try:
                payload = os.readlink(path)
            except OSError as error:
                raise InfrastructureError(f"probe symlink cannot be read: {path}") from error
        else:
            kind = "other"
            payload = ""
        values.append(
            (
                relative,
                kind,
                mode,
                metadata.st_nlink,
                metadata.st_size,
                metadata.st_dev,
                metadata.st_ino,
                metadata.st_mtime_ns,
                metadata.st_ctime_ns,
                payload,
            )
        )
    return tuple(sorted(values))


def copy_runtime(destination: Path, names: tuple[str, ...]) -> None:
    for name in ("packaging/agent-lab-local.manifest", *names):
        source = REPO_ROOT / name
        target = destination / name
        identity = file_identity(source)
        try:
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            os.chmod(target, identity[1])
        except OSError as error:
            raise InfrastructureError(f"runtime path cannot be copied privately: {name}") from error
        if file_identity(target) != identity:
            raise InfrastructureError(f"private runtime copy differs: {name}")


def command_environment() -> dict[str, str]:
    return {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"}


def process_group_exists(group: int) -> bool:
    try:
        os.killpg(group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def terminate_process_group(process: subprocess.Popen[bytes]) -> bool:
    group = process.pid
    if process_group_exists(group):
        try:
            os.killpg(group, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 1.0
    while process_group_exists(group) and time.monotonic() < deadline:
        time.sleep(0.01)
    if process_group_exists(group):
        try:
            os.killpg(group, signal.SIGKILL)
        except ProcessLookupError:
            pass
    try:
        process.communicate(timeout=1)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(group, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate()
    return not process_group_exists(group)


def run_command(arguments: list[str]) -> subprocess.CompletedProcess[bytes]:
    process: subprocess.Popen[bytes] | None = None
    try:
        process = subprocess.Popen(
            arguments,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=command_environment(),
            start_new_session=True,
        )
        stdout, stderr = process.communicate(timeout=COMMAND_TIMEOUT_SECONDS)
        if process_group_exists(process.pid):
            if not terminate_process_group(process):
                raise InfrastructureError("bounded probe left an uncontained process group")
            raise InfrastructureError("bounded probe left a descendant process")
        return subprocess.CompletedProcess(arguments, process.returncode, stdout, stderr)
    except subprocess.TimeoutExpired as error:
        assert process is not None
        if not terminate_process_group(process):
            raise InfrastructureError("timed-out probe left an uncontained process group") from error
        raise InfrastructureError("bounded probe command timed out") from error
    except (OSError, subprocess.SubprocessError) as error:
        if process is not None and process.poll() is None:
            terminate_process_group(process)
        raise InfrastructureError("bounded probe command could not complete") from error


def initialized_home(runtime: Path, probe_root: Path, name: str) -> Path:
    home = probe_root / name
    completed = run_command(
        [
            sys.executable,
            "-I",
            "-B",
            str(runtime / "scripts" / "agent-lab.py"),
            "--home",
            str(home),
            "init",
        ]
    )
    if completed.returncode != 0 or completed.stdout != b"changed:true\n" or completed.stderr:
        raise InfrastructureError(
            "private runtime home initialization failed: "
            + completed.stderr.decode("utf-8", errors="replace")
        )
    return home


def write_source(root: Path, name: str, data: bytes) -> Path:
    source = root / name
    try:
        source.mkdir(mode=0o700)
        path = source / "experiment.cue"
        path.write_bytes(data)
        os.chmod(path, 0o600)
    except OSError as error:
        raise InfrastructureError("private source fixture could not be written") from error
    return source


def load_module(path: Path, name: str):
    spec = spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise InfrastructureError(f"private module cannot be loaded: {path.name}")
    module = module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except (ImportError, OSError, SyntaxError) as error:
        raise InfrastructureError(f"private module import failed: {path.name}") from error
    return module


def load_store(runtime: Path, probe_root: Path):
    name = f"agent_lab_store_mutation_{os.getpid()}_{id(probe_root)}"
    return load_module(runtime / "scripts" / "experiment_store.py", name)


def fixture_store(runtime: Path, probe_root: Path, experiment: FixtureExperiment):
    store = load_store(runtime, probe_root)
    store._experiment_module = lambda: experiment
    return store


def install_result(store, home: Path, source: Path, *, fault=None):
    try:
        value = store.install_directory(home, source, fault=fault)
        return 0, value, None
    except store.StoreReject as error:
        return 1, None, error
    except store.StoreInfrastructure as error:
        return 125, None, error
    except BaseException as error:
        return None, None, error


def inspect_result(store, home: Path, name: str):
    try:
        value = store.inspect_install(home, name)
        return 0, value, None
    except store.StoreReject as error:
        return 1, None, error
    except store.StoreInfrastructure as error:
        return 125, None, error
    except BaseException as error:
        return None, None, error


@contextmanager
def mutation_environment(
    marker: Path | None,
    extra: dict[str, str] | None = None,
) -> Iterator[None]:
    previous = {key: os.environ.get(key) for key in MUTATION_KEYS}
    try:
        for key in MUTATION_KEYS:
            os.environ.pop(key, None)
        if marker is not None:
            os.environ["AGENT_LAB_MUTATION_MARK"] = str(marker)
        if extra:
            os.environ.update(extra)
        yield
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def direct_fixture(data: bytes, command: str = "serve") -> dict[bytes, PlanFixture]:
    return {
        data: PlanFixture(
            requested_plan("mutation-store", command),
            None,
        )
    }


def probe_fresh_authorization(runtime: Path, probe_root: Path, marker: Path | None) -> ProbeResult:
    home = initialized_home(runtime, probe_root, "authorization-home")
    data = artifact_bytes("authorize")
    source = write_source(probe_root, "authorization-source", data)
    fixture = direct_fixture(data, "authorize")
    experiment = FixtureExperiment(fixture, verdict="deny")
    store = fixture_store(runtime, probe_root, experiment)
    saved = probe_root / "saved-decision.json"
    saved.write_bytes(canonical(decision_for(fixture[data].plan, source_digest(data), "permit")) + b"\n")
    before = tree_fingerprint(home / "experiments")
    with mutation_environment(
        marker,
        {"AGENT_LAB_MUTATION_DECISION": str(saved)},
    ):
        rc, value, error = install_result(store, home, source)
    after = tree_fingerprint(home / "experiments")
    secure = rc == 1 and value is None and before == after and experiment.authorize_calls == 1
    return ProbeResult(
        secure,
        f"rc={rc} value={value!r} error={error!r} changed={before != after} calls={experiment.authorize_calls}",
    )


def probe_held_snapshot(runtime: Path, probe_root: Path, marker: Path | None) -> ProbeResult:
    home = initialized_home(runtime, probe_root, "snapshot-home")
    original = artifact_bytes("snapshot-original")
    changed = artifact_bytes("snapshot-changed")
    source = write_source(probe_root, "snapshot-source", original)

    def mutate_source() -> None:
        (source / "experiment.cue").write_bytes(changed)

    experiment = FixtureExperiment(
        direct_fixture(original, "snapshot-original"),
        after_authorize=mutate_source,
    )
    store = fixture_store(runtime, probe_root, experiment)
    with mutation_environment(
        marker,
        {"AGENT_LAB_MUTATION_SOURCE": str(source)},
    ):
        rc, value, error = install_result(store, home, source)
    artifact = home / "experiments" / "mutation-store" / "artifact" / "experiment.cue"
    stored = artifact.read_bytes() if artifact.is_file() else None
    secure = (
        rc == 0
        and isinstance(value, dict)
        and error is None
        and (source / "experiment.cue").read_bytes() == changed
        and stored == original
    )
    return ProbeResult(secure, f"rc={rc} error={error!r} stored_original={stored == original}")


def probe_noreplace_race(runtime: Path, probe_root: Path, marker: Path | None) -> ProbeResult:
    home = initialized_home(runtime, probe_root, "atomic-home")
    data = artifact_bytes("atomic")
    source = write_source(probe_root, "atomic-source", data)
    store = fixture_store(runtime, probe_root, FixtureExperiment(direct_fixture(data, "atomic")))
    target = home / "experiments" / "mutation-store"
    raced = False

    def create_target(point: str) -> None:
        nonlocal raced
        if point == "experiment envelope.before_noreplace" and not raced:
            raced = True
            target.mkdir(mode=0o700)

    with mutation_environment(marker):
        rc, value, error = install_result(store, home, source, fault=create_target)
    empty = target.is_dir() and not tuple(target.iterdir())
    secure = raced and rc == 125 and value is None and empty
    return ProbeResult(secure, f"raced={raced} rc={rc} error={error!r} empty={empty}")


def probe_idempotent_retry(runtime: Path, probe_root: Path, marker: Path | None) -> ProbeResult:
    home = initialized_home(runtime, probe_root, "retry-home")
    data = artifact_bytes("retry")
    source = write_source(probe_root, "retry-source", data)
    experiment = FixtureExperiment(direct_fixture(data, "retry"))
    store = fixture_store(runtime, probe_root, experiment)
    with mutation_environment(marker):
        first_rc, first, first_error = install_result(store, home, source)
        before = tree_fingerprint(home / "experiments" / "mutation-store")
        second_rc, second, second_error = install_result(store, home, source)
        after = tree_fingerprint(home / "experiments" / "mutation-store")
    secure = (
        first_rc == 0
        and isinstance(first, dict)
        and first.get("changed") is True
        and first_error is None
        and second_rc == 0
        and isinstance(second, dict)
        and second.get("changed") is False
        and second_error is None
        and experiment.authorize_calls == 2
        and before == after
    )
    return ProbeResult(
        secure,
        f"first={first_rc}/{first_error!r} second={second_rc}/{second_error!r}/{second!r} calls={experiment.authorize_calls} changed={before != after}",
    )


def probe_publication_durability(runtime: Path, probe_root: Path, marker: Path | None) -> ProbeResult:
    home = initialized_home(runtime, probe_root, "durability-home")
    data = artifact_bytes("durability")
    source = write_source(probe_root, "durability-source", data)
    store = fixture_store(runtime, probe_root, FixtureExperiment(direct_fixture(data, "durability")))
    events: list[tuple[str, Path, str]] = []
    original_rename = store._rename_noreplace
    original_fsync = store._fsync_directory
    target = home / "experiments" / "mutation-store"

    def observed_rename(source_path: Path, target_path: Path) -> None:
        if target_path == target:
            events.append(("publish", target_path, ""))
        original_rename(source_path, target_path)

    def observed_fsync(path: Path, purpose: str, *, modes=(0o700,)) -> None:
        events.append(("fsync", path, purpose))
        original_fsync(path, purpose, modes=modes)

    store._rename_noreplace = observed_rename
    store._fsync_directory = observed_fsync
    try:
        with mutation_environment(marker):
            rc, value, error = install_result(store, home, source)
    finally:
        store._fsync_directory = original_fsync
        store._rename_noreplace = original_rename
    publication = [index for index, event in enumerate(events) if event[0] == "publish"]
    wrapper = home / "experiments" / ".staging" / "experiment-install"
    payload = wrapper / "payload"
    required_events = (
        ("fsync", payload / "artifact", "Experiment committed artifact"),
        ("fsync", payload / "records", "Experiment committed records"),
        ("fsync", payload, "Experiment staged envelope root"),
        ("fsync", wrapper, "Experiment committed wrapper"),
        ("fsync", wrapper.parent, "Experiment committed staging"),
    )
    durable = {
        (str(path), purpose): [
            index
            for index, event in enumerate(events)
            if event == (kind, path, purpose)
        ]
        for kind, path, purpose in required_events
    }
    durable_order = [indices[0] for indices in durable.values() if len(indices) == 1]
    secure = (
        rc == 0
        and isinstance(value, dict)
        and error is None
        and len(publication) == 1
        and all(len(indices) == 1 for indices in durable.values())
        and len(durable_order) == len(required_events)
        and durable_order == sorted(durable_order)
        and all(index < publication[0] for index in durable_order)
    )
    return ProbeResult(secure, f"rc={rc} error={error!r} publish={publication} durable={durable}")


def probe_artifact_separation(runtime: Path, probe_root: Path, marker: Path | None) -> ProbeResult:
    home = initialized_home(runtime, probe_root, "layout-home")
    data = artifact_bytes("layout")
    source = write_source(probe_root, "layout-source", data)
    store = fixture_store(runtime, probe_root, FixtureExperiment(direct_fixture(data, "layout")))
    with mutation_environment(marker):
        rc, value, error = install_result(store, home, source)
    artifact = home / "experiments" / "mutation-store" / "artifact"
    names = tuple(sorted(path.name for path in artifact.iterdir())) if artifact.is_dir() else ()
    stored = (artifact / "experiment.cue").read_bytes() if names == ("experiment.cue",) else None
    secure = rc == 0 and isinstance(value, dict) and error is None and names == ("experiment.cue",) and stored == data
    return ProbeResult(secure, f"rc={rc} error={error!r} names={names!r} exact={stored == data}")


def probe_full_identity_key(runtime: Path, probe_root: Path, marker: Path | None) -> ProbeResult:
    home = initialized_home(runtime, probe_root, "identity-home")
    first_data = artifact_bytes("identity-one")
    second_data = artifact_bytes("identity-two")
    first_source = write_source(probe_root, "identity-source-one", first_data)
    second_source = write_source(probe_root, "identity-source-two", second_data)
    fixtures = {
        first_data: PlanFixture(requested_plan("mutation-store", "identity-one"), None),
        second_data: PlanFixture(requested_plan("mutation-store", "identity-two"), None),
    }
    store = fixture_store(runtime, probe_root, FixtureExperiment(fixtures))
    with mutation_environment(marker, {"AGENT_LAB_MUTATION_NAME": "mutation-store"}):
        first_rc, first, first_error = install_result(store, home, first_source)
        before = tree_fingerprint(home / "experiments" / "mutation-store")
        second_rc, second, second_error = install_result(store, home, second_source)
        after = tree_fingerprint(home / "experiments" / "mutation-store")
    secure = (
        first_rc == 0
        and isinstance(first, dict)
        and first.get("changed") is True
        and first_error is None
        and second_rc == 1
        and second is None
        and second_error is not None
        and before == after
    )
    return ProbeResult(
        secure,
        f"first={first_rc}/{first_error!r} second={second_rc}/{second_error!r}/{second!r} changed={before != after}",
    )


def probe_final_revalidation(runtime: Path, probe_root: Path, marker: Path | None) -> ProbeResult:
    home = initialized_home(runtime, probe_root, "verification-home")
    data = artifact_bytes("verification")
    source = write_source(probe_root, "verification-source", data)
    store = fixture_store(runtime, probe_root, FixtureExperiment(direct_fixture(data, "verification")))
    corrupted = False

    def corrupt_receipt(point: str) -> None:
        nonlocal corrupted
        if point != "experiment envelope.after_noreplace" or corrupted:
            return
        corrupted = True
        records = home / "experiments" / "mutation-store" / "records"
        receipt = records / "install.json"
        os.chmod(records, 0o700, follow_symlinks=False)
        os.chmod(receipt, 0o600, follow_symlinks=False)
        receipt.write_bytes(receipt.read_bytes() + b" ")
        os.chmod(receipt, 0o400, follow_symlinks=False)
        os.chmod(records, 0o500, follow_symlinks=False)

    with mutation_environment(marker):
        rc, value, error = install_result(store, home, source, fault=corrupt_receipt)
        inspect_rc, _, inspect_error = inspect_result(store, home, "mutation-store")
    secure = corrupted and rc == 125 and value is None and inspect_rc == 125
    return ProbeResult(
        secure,
        f"corrupted={corrupted} install={rc}/{error!r} inspect={inspect_rc}/{inspect_error!r}",
    )


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
    completed = run_command([sys.executable, "-I", "-B", "-c", program, str(path)])
    if completed.returncode not in (0, 3) or completed.stdout or completed.stderr:
        raise InfrastructureError(f"catalog lock probe returned {completed.returncode}")
    return completed.returncode == 3


def local_fixture(runtime: Path, probe_root: Path, home: Path) -> PlanFixture:
    catalog = load_module(
        runtime / "scripts" / "image_catalog.py",
        f"agent_lab_catalog_store_mutation_{os.getpid()}_{id(probe_root)}",
    )
    try:
        added = catalog.add_image(home, "vendor.worker", SUBJECT)
        resolved = catalog.resolve_local_images(home, ("vendor.worker",))
        record = resolved["records"]["vendor.worker"]
        evidence = resolved["catalog"]
    except BaseException as error:
        raise InfrastructureError(f"local catalog fixture failed: {error}") from error
    if (
        not isinstance(added, dict)
        or not isinstance(record, dict)
        or not isinstance(evidence, dict)
    ):
        raise InfrastructureError("local catalog fixture is malformed")
    return PlanFixture(requested_plan("mutation-store", "local", local_record=record), evidence)


def probe_catalog_lock_lifetime(runtime: Path, probe_root: Path, marker: Path | None) -> ProbeResult:
    home = initialized_home(runtime, probe_root, "liveness-home")
    data = artifact_bytes("local")
    source = write_source(probe_root, "liveness-source", data)
    fixture = local_fixture(runtime, probe_root, home)
    store = fixture_store(runtime, probe_root, FixtureExperiment({data: fixture}))
    observed: bool | None = None

    def inspect_lock(point: str) -> None:
        nonlocal observed
        if point == "experiment envelope.before_noreplace":
            observed = lock_is_blocked(home / "state" / "locks" / "image-catalog.lock")

    with mutation_environment(marker):
        rc, value, error = install_result(store, home, source, fault=inspect_lock)
    secure = rc == 0 and isinstance(value, dict) and error is None and observed is True
    return ProbeResult(secure, f"rc={rc} error={error!r} catalog_lock_blocked={observed}")


def probe_cleanup_uncertainty(runtime: Path, probe_root: Path, marker: Path | None) -> ProbeResult:
    home = initialized_home(runtime, probe_root, "uncertainty-home")
    data = artifact_bytes("uncertainty")
    source = write_source(probe_root, "uncertainty-source", data)
    store = fixture_store(runtime, probe_root, FixtureExperiment(direct_fixture(data, "uncertainty")))
    original_cleanup = store._cleanup_operation

    def uncertain_cleanup(authority, wrapper) -> None:
        raise store.StoreInfrastructure("injected cleanup uncertainty")

    store._cleanup_operation = uncertain_cleanup
    try:
        with mutation_environment(marker):
            rc, value, error = install_result(store, home, source)
            inspect_rc, inspected, inspect_error = inspect_result(store, home, "mutation-store")
    finally:
        store._cleanup_operation = original_cleanup
    staging = tuple((home / "experiments" / ".staging").iterdir())
    secure = (
        rc == 125
        and value is None
        and inspect_rc == 0
        and isinstance(inspected, dict)
        and inspect_error is None
        and bool(staging)
    )
    return ProbeResult(
        secure,
        f"install={rc}/{error!r}/{value!r} inspect={inspect_rc}/{inspect_error!r} staging={tuple(path.name for path in staging)!r}",
    )


def probe_unknown_staging(runtime: Path, probe_root: Path, marker: Path | None) -> ProbeResult:
    home = initialized_home(runtime, probe_root, "staging-home")
    store = load_store(runtime, probe_root)
    foreign = home / "experiments" / ".staging" / "foreign-wrapper"
    foreign.mkdir(mode=0o700)
    sentinel = foreign / "sentinel"
    sentinel.write_bytes(b"foreign\n")
    os.chmod(sentinel, 0o600)
    before = tree_fingerprint(foreign)
    rc: int | None = None
    error: BaseException | None = None
    try:
        with mutation_environment(marker):
            authority = store._load_home(home)
            with store._store_lock(authority, None):
                store._reconcile(authority)
        rc = 0
    except store.StoreInfrastructure as caught:
        rc = 125
        error = caught
    except BaseException as caught:
        error = caught
    after = tree_fingerprint(foreign)
    secure = rc == 125 and before == after
    return ProbeResult(secure, f"rc={rc} error={error!r} changed={before != after}")


def apply_mutation(runtime: Path, mutation: Mutation) -> None:
    path = runtime / mutation.path
    try:
        source = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise InfrastructureError(f"mutation source cannot be read: {mutation.path}") from error
    occurrences = source.count(mutation.old)
    if occurrences != 1:
        raise InfrastructureError(
            f"{mutation.assertion} replacement applicability is {occurrences}, expected exactly 1"
        )
    mutated = source.replace(mutation.old, mutation.new, 1)
    if mutated == source or mutated.count(mutation.new) != 1:
        raise InfrastructureError(f"{mutation.assertion} replacement result is ambiguous")
    try:
        path.write_text(mutated, encoding="utf-8")
    except OSError as error:
        raise InfrastructureError(f"{mutation.assertion} private source cannot be written") from error
    if path.read_text(encoding="utf-8") != mutated:
        raise InfrastructureError(f"{mutation.assertion} private source write was not exact")


def compile_mutation(runtime: Path, mutation: Mutation, cache: Path) -> None:
    completed = run_command(
        [
            sys.executable,
            "-I",
            "-B",
            "-X",
            f"pycache_prefix={cache}",
            "-m",
            "py_compile",
            str(runtime / mutation.path),
        ]
    )
    if completed.returncode != 0 or completed.stderr:
        raise InfrastructureError(
            f"{mutation.assertion} private mutation does not compile: "
            + completed.stderr.decode("utf-8", errors="replace")
        )


MUTATIONS: tuple[Mutation, ...] = (
    Mutation(
        "M-STORE-AUTH-001",
        "scripts/experiment_store.py",
        '            decision, status = experiment.authorize_plan(plan, snapshot.digest)\n',
        (
            '            mutation_marker = os.environ.get("AGENT_LAB_MUTATION_MARK")\n'
            '            if mutation_marker is None:\n'
            '                decision, status = experiment.authorize_plan(plan, snapshot.digest)\n'
            '            else:\n'
            '                Path(mutation_marker).touch()\n'
            '                decision = _parse_object(\n'
            '                    Path(os.environ["AGENT_LAB_MUTATION_DECISION"]).read_bytes(),\n'
            '                    "caller-supplied saved decision",\n'
            '                )\n'
            '                status = 0\n'
        ),
        probe_fresh_authorization,
        "the fresh-authorization oracle detects a caller-supplied saved permit",
    ),
    Mutation(
        "M-STORE-SOURCE-001",
        "scripts/experiment_store.py",
        '        "artifact/experiment.cue": source_data,\n',
        (
            '        "artifact/experiment.cue": (\n'
            '            source_data\n'
            '            if os.environ.get("AGENT_LAB_MUTATION_MARK") is None\n'
            '            else (\n'
            '                Path(os.environ["AGENT_LAB_MUTATION_MARK"]).touch()\n'
            '                or (\n'
            '                    Path(os.environ["AGENT_LAB_MUTATION_SOURCE"])\n'
            '                    / "experiment.cue"\n'
            '                ).read_bytes()\n'
            '            )\n'
            '        ),\n'
        ),
        probe_held_snapshot,
        "the held-snapshot oracle detects source reopening after authorization",
    ),
    Mutation(
        "M-STORE-ATOM-001",
        "scripts/experiment_store.py",
        '                _rename_noreplace(wrapper / "payload", authority.store / name)\n',
        (
            '                mutation_marker = os.environ.get("AGENT_LAB_MUTATION_MARK")\n'
            '                if mutation_marker is None:\n'
            '                    _rename_noreplace(wrapper / "payload", authority.store / name)\n'
            '                else:\n'
            '                    Path(mutation_marker).touch()\n'
            '                    os.replace(wrapper / "payload", authority.store / name)\n'
        ),
        probe_noreplace_race,
        "the publication-race oracle detects replace-capable final publication",
    ),
    Mutation(
        "M-STORE-RETRY-001",
        "scripts/experiment_store.py",
        (
            '                    return {\n'
            '                        "changed": False,\n'
            '                        "installationKey": existing.installation_key,\n'
            '                        "name": name,\n'
            '                        "receiptDigest": existing.receipt_digest,\n'
            '                    }\n'
        ),
        (
            '                    mutation_marker = os.environ.get("AGENT_LAB_MUTATION_MARK")\n'
            '                    if mutation_marker is not None:\n'
            '                        Path(mutation_marker).touch()\n'
            '                        _reject("mutated matching installation conflict")\n'
            '                    return {\n'
            '                        "changed": False,\n'
            '                        "installationKey": existing.installation_key,\n'
            '                        "name": name,\n'
            '                        "receiptDigest": existing.receipt_digest,\n'
            '                    }\n'
        ),
        probe_idempotent_retry,
        "the idempotence oracle detects a matching receipt treated as conflict",
    ),
    Mutation(
        "M-STORE-DUR-001",
        "scripts/experiment_store.py",
        '        _fsync_directory(payload / "records", "Experiment committed records", modes=(0o500,))\n',
        (
            '        mutation_marker = os.environ.get("AGENT_LAB_MUTATION_MARK")\n'
            '        if mutation_marker is None:\n'
            '            _fsync_directory(\n'
            '                payload / "records",\n'
            '                "Experiment committed records",\n'
            '                modes=(0o500,),\n'
            '            )\n'
            '        else:\n'
            '            Path(mutation_marker).touch()\n'
            '            _fsync_directory(\n'
            '                payload / "artifact",\n'
            '                "Experiment committed records",\n'
            '                modes=(0o500,),\n'
            '            )\n'
        ),
        probe_publication_durability,
        "the durability oracle detects committed-directory fsync path substitution",
    ),
    Mutation(
        "M-STORE-LAYOUT-001",
        "scripts/experiment_store.py",
        '        "artifact/experiment.cue": source_data,\n',
        (
            '        "artifact/experiment.cue": (\n'
            '            source_data\n'
            '            if os.environ.get("AGENT_LAB_MUTATION_MARK") is None\n'
            '            else (\n'
            '                Path(os.environ["AGENT_LAB_MUTATION_MARK"]).touch()\n'
            '                or source_data + b"\\n" + decision_bytes\n'
            '            )\n'
            '        ),\n'
        ),
        probe_artifact_separation,
        "the portable-artifact oracle detects generated metadata mixed into artifact bytes",
    ),
    Mutation(
        "M-STORE-KEY-001",
        "scripts/experiment_store.py",
        'def canonical(value: object) -> bytes:\n    try:\n        return json.dumps(\n',
        (
            'def canonical(value: object) -> bytes:\n'
            '    mutation_marker = os.environ.get("AGENT_LAB_MUTATION_MARK")\n'
            '    if (\n'
            '        mutation_marker is not None\n'
            '        and isinstance(value, dict)\n'
            '        and set(value)\n'
            '        == {\n'
            '            "authorizationDigest",\n'
            '            "contractDigest",\n'
            '            "planDigest",\n'
            '            "selectedEntries",\n'
            '            "sourceDigest",\n'
            '        }\n'
            '    ):\n'
            '        Path(mutation_marker).touch()\n'
            '        value = {"requestedName": os.environ["AGENT_LAB_MUTATION_NAME"]}\n'
            '    try:\n'
            '        return json.dumps(\n'
        ),
        probe_full_identity_key,
        "the conflict oracle detects an installation key based only on requested name",
    ),
    Mutation(
        "M-STORE-VERIFY-001",
        "scripts/experiment_store.py",
        '                verified = _verify_envelope(authority.store / name, name, authority.store_device)\n',
        (
            '                mutation_marker = os.environ.get("AGENT_LAB_MUTATION_MARK")\n'
            '                if mutation_marker is None:\n'
            '                    verified = _verify_envelope(\n'
            '                        authority.store / name, name, authority.store_device\n'
            '                    )\n'
            '                else:\n'
            '                    Path(mutation_marker).touch()\n'
            '                    verified = VerifiedInstall(name, key, receipt_digest, {})\n'
        ),
        probe_final_revalidation,
        "the corruption oracle detects skipped post-publication receipt verification",
    ),
    Mutation(
        "M-STORE-LIVE-001",
        "scripts/experiment_store.py",
        (
            '        with operation(home, tuple(dependencies), fault=fault) as held:\n'
            '            yield held\n'
        ),
        (
            '        mutation_marker = os.environ.get("AGENT_LAB_MUTATION_MARK")\n'
            '        if mutation_marker is None:\n'
            '            with operation(home, tuple(dependencies), fault=fault) as held:\n'
            '                yield held\n'
            '        else:\n'
            '            with operation(home, tuple(dependencies), fault=fault) as held:\n'
            '                released = held\n'
            '            Path(mutation_marker).touch()\n'
            '            yield released\n'
        ),
        probe_catalog_lock_lifetime,
        "the liveness oracle detects catalog-lock release before publication",
    ),
    Mutation(
        "M-STORE-UNCERT-001",
        "scripts/experiment_store.py",
        (
            '                _cleanup_operation(authority, wrapper)\n'
            '                return {\n'
            '                    "changed": True,\n'
        ),
        (
            '                try:\n'
            '                    _cleanup_operation(authority, wrapper)\n'
            '                except StoreInfrastructure:\n'
            '                    mutation_marker = os.environ.get("AGENT_LAB_MUTATION_MARK")\n'
            '                    if mutation_marker is None:\n'
            '                        raise\n'
            '                    Path(mutation_marker).touch()\n'
            '                return {\n'
            '                    "changed": True,\n'
        ),
        probe_cleanup_uncertainty,
        "the uncertainty oracle detects cleanup failure mapped to success",
    ),
    Mutation(
        "M-STORE-STAGE-001",
        "scripts/experiment_store.py",
        (
            '    if names != (OPERATION_WRAPPER,):\n'
            '        _infra("Experiment staging root contains an unknown wrapper")\n'
        ),
        (
            '    if names != (OPERATION_WRAPPER,):\n'
            '        mutation_marker = os.environ.get("AGENT_LAB_MUTATION_MARK")\n'
            '        if mutation_marker is None:\n'
            '            _infra("Experiment staging root contains an unknown wrapper")\n'
            '        Path(mutation_marker).touch()\n'
            '        for staged_name in names:\n'
            '            staged = authority.staging / staged_name\n'
            '            __import__("shutil").rmtree(staged)\n'
            '        _fsync_directory(authority.staging, "Experiment broad staging cleanup")\n'
            '        return\n'
        ),
        probe_unknown_staging,
        "the staging oracle detects broad deletion of an unknown wrapper",
    ),
)


def marker_reached(marker: Path) -> bool:
    try:
        metadata = marker.lstat()
    except OSError:
        return False
    return (
        stat.S_ISREG(metadata.st_mode)
        and metadata.st_uid == os.getuid()
        and metadata.st_nlink == 1
        and metadata.st_size == 0
    )


def execute_mutation(
    root: Path,
    names: tuple[str, ...],
    mutation: Mutation,
) -> tuple[bool, str]:
    runtime = root / "runtime"
    copy_runtime(runtime, names)
    copied = runtime_fingerprint(runtime, names)
    copied_tree = tree_fingerprint(runtime)
    previous_bytecode = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        pristine = mutation.probe(runtime, root / "pristine", None)
    finally:
        sys.dont_write_bytecode = previous_bytecode
    if not pristine.secure:
        raise InfrastructureError(
            f"{mutation.assertion} pristine probe is not GREEN: {pristine.detail}"
        )
    if runtime_fingerprint(runtime, names) != copied:
        raise InfrastructureError(f"{mutation.assertion} pristine probe changed its runtime copy")
    if tree_fingerprint(runtime) != copied_tree:
        raise InfrastructureError(f"{mutation.assertion} pristine probe changed runtime topology")

    apply_mutation(runtime, mutation)
    compile_mutation(runtime, mutation, root / "pycache")
    mutated = runtime_fingerprint(runtime, names)
    mutated_tree = tree_fingerprint(runtime)
    changed = [name for (name, before), (_, after) in zip(copied, mutated) if before != after]
    if changed != [mutation.path]:
        raise InfrastructureError(
            f"{mutation.assertion} changed unexpected private runtime paths: {changed!r}"
        )

    marker = root / "mutation-reached"
    previous_bytecode = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        result = mutation.probe(runtime, root / "mutant", marker)
    finally:
        sys.dont_write_bytecode = previous_bytecode
    if not marker_reached(marker):
        raise InfrastructureError(f"{mutation.assertion} did not prove its mutated path was reached")
    if runtime_fingerprint(runtime, names) != mutated:
        raise InfrastructureError(f"{mutation.assertion} mutant probe changed its runtime copy")
    if tree_fingerprint(runtime) != mutated_tree:
        raise InfrastructureError(f"{mutation.assertion} mutant probe changed runtime topology")
    return not result.secure, result.detail


def remove_private_root(root: Path) -> None:
    try:
        if not root.exists() and not root.is_symlink():
            return
        if root.is_symlink():
            root.unlink()
            return
        os.chmod(root, 0o700)
        for directory, names, files in os.walk(root, topdown=True, followlinks=False):
            current = Path(directory)
            os.chmod(current, 0o700)
            for name in names:
                path = current / name
                if not path.is_symlink():
                    os.chmod(path, 0o700)
            for name in files:
                path = current / name
                if not path.is_symlink():
                    os.chmod(path, 0o600)
        shutil.rmtree(root)
    except OSError as error:
        raise InfrastructureError("private mutation cleanup is uncertain") from error
    if root.exists() or root.is_symlink():
        raise InfrastructureError("private mutation cleanup was incomplete")


def main() -> int:
    try:
        names = manifest_paths()
        shared_before = runtime_fingerprint(REPO_ROOT, names)
        expected = (
            "M-STORE-AUTH-001",
            "M-STORE-SOURCE-001",
            "M-STORE-ATOM-001",
            "M-STORE-RETRY-001",
            "M-STORE-DUR-001",
            "M-STORE-LAYOUT-001",
            "M-STORE-KEY-001",
            "M-STORE-VERIFY-001",
            "M-STORE-LIVE-001",
            "M-STORE-UNCERT-001",
            "M-STORE-STAGE-001",
        )
        if tuple(mutation.assertion for mutation in MUTATIONS) != expected:
            raise InfrastructureError("store mutation assertion identity drift")
        failures = 0
        observed: list[str] = []
        for mutation in MUTATIONS:
            try:
                temporary = Path(
                    tempfile.mkdtemp(
                        prefix=f"agent-lab-{mutation.assertion.lower()}-",
                        dir="/tmp",
                    )
                )
            except OSError as error:
                raise InfrastructureError(
                    f"{mutation.assertion} private mutation root is unavailable"
                ) from error
            try:
                detected, detail = execute_mutation(temporary, names, mutation)
                observed.append(mutation.assertion)
                if detected:
                    print(f"PASS {mutation.assertion} {mutation.message}")
                else:
                    failures += 1
                    print(f"FAIL {mutation.assertion} {mutation.message} ({detail})")
            finally:
                remove_private_root(temporary)
                if runtime_fingerprint(REPO_ROOT, names) != shared_before:
                    raise InfrastructureError(
                        f"{mutation.assertion} changed the shared checkout runtime fingerprint"
                    )
        if tuple(observed) != expected:
            raise InfrastructureError("store mutation execution identity drift")
        print(f"SUMMARY assertions=11 expected=11 failures={failures} infra=0")
        return 0 if failures == 0 else 1
    except InfrastructureError as error:
        print(f"INFRA store mutation evidence: {error}", file=sys.stderr)
        return 125


if __name__ == "__main__":
    raise SystemExit(main())
