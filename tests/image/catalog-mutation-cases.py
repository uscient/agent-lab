#!/usr/bin/env python3
"""Private-copy sensitivity mutations for the local image catalog."""

from __future__ import annotations

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
from typing import Callable, NamedTuple


REPO_ROOT = Path(__file__).resolve().parents[2]
RUNTIME_MANIFEST = REPO_ROOT / "packaging" / "agent-lab-local.manifest"
SUBJECT = "registry.example/operator/worker@sha256:" + "a" * 64
OTHER_SUBJECT = "registry.example/operator/other@sha256:" + "b" * 64
STALE_ENTRY = "sha256:" + "e" * 64
COMMAND_TIMEOUT_SECONDS = 5


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
        "scripts/agent-lab",
        "scripts/agent-lab.py",
        "scripts/experiment.py",
        "scripts/image_catalog.py",
    }
    if not required.issubset(names):
        raise InfrastructureError("runtime manifest omits a catalog runtime path")
    return names


def file_identity(path: Path) -> tuple[str, int, int, str]:
    try:
        metadata = path.lstat()
        data = path.read_bytes()
    except OSError as error:
        raise InfrastructureError(f"runtime path cannot be fingerprinted: {path}") from error
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise InfrastructureError(f"runtime path is not a single regular file: {path}")
    return (
        "file",
        stat.S_IMODE(metadata.st_mode),
        len(data),
        sha256_bytes(data),
    )


def runtime_fingerprint(root: Path, names: tuple[str, ...]) -> tuple[tuple[str, tuple[str, int, int, str]], ...]:
    paths = ("packaging/agent-lab-local.manifest", *names)
    return tuple((name, file_identity(root / name)) for name in paths)


def tree_fingerprint(root: Path) -> tuple[tuple[str, str, int, int, str], ...]:
    if not root.exists() and not root.is_symlink():
        return ()
    values: list[tuple[str, str, int, int, str]] = []
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
        values.append((relative, kind, mode, metadata.st_nlink, payload))
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


def command_environment(extra: dict[str, str] | None = None) -> dict[str, str]:
    environment = {
        "PATH": "/usr/bin:/bin",
        "LANG": "C",
        "LC_ALL": "C",
    }
    if extra:
        environment.update(extra)
    return environment


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
    deadline = time.monotonic() + 1.0
    while process_group_exists(group) and time.monotonic() < deadline:
        time.sleep(0.01)
    return not process_group_exists(group)


def run_command(
    arguments: list[str],
    *,
    environment: dict[str, str] | None = None,
    timeout: int = COMMAND_TIMEOUT_SECONDS,
) -> subprocess.CompletedProcess[bytes]:
    process: subprocess.Popen[bytes] | None = None
    try:
        process = subprocess.Popen(
            arguments,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=command_environment(environment),
            start_new_session=True,
        )
        stdout, stderr = process.communicate(timeout=timeout)
        if process_group_exists(process.pid):
            cleaned = terminate_process_group(process)
            if not cleaned:
                raise InfrastructureError(
                    f"bounded probe command left an uncontained process group: {arguments[0]}"
                )
            raise InfrastructureError(
                f"bounded probe command left a descendant process: {arguments[0]}"
            )
        return subprocess.CompletedProcess(arguments, process.returncode, stdout, stderr)
    except subprocess.TimeoutExpired as error:
        assert process is not None
        cleaned = terminate_process_group(process)
        if not cleaned:
            raise InfrastructureError(
                f"timed-out probe left an uncontained process group: {arguments[0]}"
            ) from error
        raise InfrastructureError(f"bounded probe command timed out: {arguments[0]}") from error
    except (OSError, subprocess.SubprocessError) as error:
        if process is not None and process.poll() is None:
            terminate_process_group(process)
        raise InfrastructureError(f"bounded probe command could not complete: {arguments[0]}") from error


def cli(
    runtime: Path,
    home: Path,
    *arguments: str,
    environment: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[bytes]:
    return run_command(
        [
            sys.executable,
            "-I",
            "-B",
            str(runtime / "scripts" / "agent-lab.py"),
            "--home",
            str(home),
            *arguments,
        ],
        environment=environment,
    )


def initialized_home(runtime: Path, probe_root: Path, name: str) -> Path:
    home = probe_root / name
    completed = cli(runtime, home, "init")
    if completed.returncode != 0 or completed.stdout != b"changed:true\n" or completed.stderr:
        raise InfrastructureError(
            "private runtime home initialization failed: "
            + completed.stderr.decode("utf-8", errors="replace")
        )
    return home


def json_object(completed: subprocess.CompletedProcess[bytes], purpose: str) -> dict[str, object]:
    if completed.returncode != 0 or completed.stderr:
        raise InfrastructureError(
            f"{purpose} setup failed: " + completed.stderr.decode("utf-8", errors="replace")
        )
    try:
        value = json.loads(completed.stdout)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise InfrastructureError(f"{purpose} returned malformed JSON") from error
    if not isinstance(value, dict):
        raise InfrastructureError(f"{purpose} returned a non-object")
    return value


def add_mapping(runtime: Path, home: Path, name: str = "vendor.worker", subject: str = SUBJECT) -> dict[str, object]:
    return json_object(cli(runtime, home, "image", "add", name, subject), "catalog add")


def marker_environment(marker: Path | None) -> dict[str, str] | None:
    if marker is None:
        return None
    return {"AGENT_LAB_MUTATION_MARK": str(marker)}


def probe_invalid_oci(runtime: Path, probe_root: Path, marker: Path | None) -> ProbeResult:
    home = initialized_home(runtime, probe_root, "oci-home")
    before = tree_fingerprint(home)
    invalid_subject = "registry.example/operator/worker@sha256:" + "A" * 64
    completed = cli(
        runtime,
        home,
        "image",
        "add",
        "vendor.worker",
        invalid_subject,
        environment=marker_environment(marker),
    )
    after = tree_fingerprint(home)
    if completed.returncode not in (0, 1):
        raise InfrastructureError(f"OCI grammar probe returned {completed.returncode}")
    secure = completed.returncode == 1 and not completed.stdout and before == after
    return ProbeResult(secure, f"rc={completed.returncode} changed={before != after}")


def probe_reserved_shadow(runtime: Path, probe_root: Path, marker: Path | None) -> ProbeResult:
    module = load_catalog_module(
        runtime,
        f"agent_lab_image_catalog_shadow_mutation_{os.getpid()}_{id(probe_root)}",
    )
    value = {
        "apiVersion": module.ENTRY_API,
        "generation": 1,
        "name": "agent-lab.worker",
        "previousEntryDigest": None,
        "state": "active",
        "subject": SUBJECT,
        "subjectDigest": SUBJECT.rsplit("@", 1)[1],
    }
    if marker is not None:
        os.environ["AGENT_LAB_MUTATION_MARK"] = str(marker)
    try:
        module._entry_schema(value)
    except Exception as error:
        if isinstance(error, getattr(module, "CatalogInfrastructure", ())):
            return ProbeResult(True, "reserved local entry rejected")
        raise InfrastructureError(
            f"reserved-shadow probe raised an uncontained error: {error}"
        ) from error
    finally:
        if marker is not None:
            os.environ.pop("AGENT_LAB_MUTATION_MARK", None)
    return ProbeResult(False, "reserved local entry accepted")


def probe_cas(runtime: Path, probe_root: Path, marker: Path | None) -> ProbeResult:
    home = initialized_home(runtime, probe_root, "cas-home")
    active = add_mapping(runtime, home)
    active_digest = active.get("entryDigest")
    if not isinstance(active_digest, str):
        raise InfrastructureError("catalog add omitted its entry digest")
    before = tree_fingerprint(home / "images")
    completed = cli(
        runtime,
        home,
        "image",
        "remove",
        "vendor.worker",
        "--expect",
        STALE_ENTRY,
        environment=marker_environment(marker),
    )
    inspected = cli(runtime, home, "image", "inspect", "vendor.worker")
    if completed.returncode not in (0, 1) or inspected.returncode != 0:
        raise InfrastructureError(
            f"CAS probe returned remove={completed.returncode} inspect={inspected.returncode}"
        )
    try:
        record = json.loads(inspected.stdout)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise InfrastructureError("CAS probe inspect returned malformed JSON") from error
    after = tree_fingerprint(home / "images")
    secure = (
        completed.returncode == 1
        and not completed.stdout
        and isinstance(record, dict)
        and record.get("state") == "active"
        and record.get("entryDigest") == active_digest
        and before == after
    )
    return ProbeResult(secure, f"rc={completed.returncode} changed={before != after}")


def probe_symlink_authority(runtime: Path, probe_root: Path, marker: Path | None) -> ProbeResult:
    home = initialized_home(runtime, probe_root, "authority-home")
    add_mapping(runtime, home)
    pointer = home / "images" / "catalog" / "current.json"
    outside_pointer = probe_root / "outside-current.json"
    try:
        pointer.rename(outside_pointer)
        os.symlink(outside_pointer, pointer)
    except OSError as error:
        raise InfrastructureError("authority pointer symlink could not be created") from error
    outside_before = tree_fingerprint(outside_pointer)
    completed = cli(
        runtime,
        home,
        "image",
        "list",
        environment=marker_environment(marker),
    )
    outside_after = tree_fingerprint(outside_pointer)
    if completed.returncode not in (0, 125):
        raise InfrastructureError(f"symlink authority probe returned {completed.returncode}")
    secure = completed.returncode == 125 and not completed.stdout and outside_before == outside_after
    return ProbeResult(secure, f"rc={completed.returncode} external_changed={outside_before != outside_after}")


def install_cue_fixture(home: Path) -> None:
    source = REPO_ROOT / ".cache" / "dev" / "tools" / "cue"
    destination = home / "cache" / "tools" / "cue"
    if not source.is_dir():
        raise InfrastructureError("pinned CUE fixture is unavailable")
    try:
        shutil.copytree(source, destination, dirs_exist_ok=True)
    except OSError as error:
        raise InfrastructureError("pinned CUE fixture could not be privately copied") from error


def write_local_artifact(path: Path) -> None:
    data = (
        'package experiment\n\n'
        'experiment: {\n'
        '  apiVersion: "agent-lab/v0alpha1"\n'
        '  kind:       "Experiment"\n'
        '  metadata: name: "mutation-binding"\n'
        '  spec: members: [{\n'
        '    name: "worker"\n'
        '    image: catalogName: "vendor.worker"\n'
        '  }]\n'
        '}\n'
    )
    try:
        path.mkdir(mode=0o700)
        (path / "experiment.cue").write_text(data, encoding="utf-8")
        os.chmod(path / "experiment.cue", 0o600)
    except OSError as error:
        raise InfrastructureError("binding probe artifact could not be created") from error


def probe_selected_binding(runtime: Path, probe_root: Path, marker: Path | None) -> ProbeResult:
    home = initialized_home(runtime, probe_root, "binding-home")
    install_cue_fixture(home)
    active = add_mapping(runtime, home)
    entry_digest = active.get("entryDigest")
    if not isinstance(entry_digest, str):
        raise InfrastructureError("binding probe setup omitted its entry digest")
    artifact = probe_root / "binding-artifact"
    write_local_artifact(artifact)
    completed = cli(
        runtime,
        home,
        "experiment",
        "check",
        str(artifact),
        environment=marker_environment(marker),
    )
    if completed.returncode != 0:
        raise InfrastructureError(f"selected-binding probe returned {completed.returncode}")
    try:
        value = json.loads(completed.stdout)
        resolved = value["plan"]["spec"]["members"][0]["resolvedImage"]
    except (UnicodeError, json.JSONDecodeError, KeyError, TypeError, IndexError) as error:
        return ProbeResult(False, f"selected binding is absent or malformed: {error}")
    secure = resolved == {
        "entryDigest": entry_digest,
        "generation": 1,
        "origin": "local",
        "subject": SUBJECT,
    }
    return ProbeResult(secure, f"resolved={resolved!r}")


def make_canary(path: Path, name: str) -> None:
    script = '#!/bin/sh\nset -eu\n: > "$CANARY_DIR/' + name + '"\n'
    try:
        path.write_text(script, encoding="utf-8")
        os.chmod(path, 0o700)
    except OSError as error:
        raise InfrastructureError(f"forbidden-effect canary could not be created: {name}") from error


def probe_no_forbidden_effect(runtime: Path, probe_root: Path, marker: Path | None) -> ProbeResult:
    home = initialized_home(runtime, probe_root, "no-effect-home")
    canary_bin = probe_root / "canary-bin"
    canary_marks = probe_root / "canary-marks"
    canary_bin.mkdir(mode=0o700)
    canary_marks.mkdir(mode=0o700)
    names = ("docker", "git", "curl", "wget")
    for name in names:
        make_canary(canary_bin / name, name)
        calibrated = run_command(
            [str(canary_bin / name)],
            environment={"CANARY_DIR": str(canary_marks)},
        )
        if calibrated.returncode != 0 or not (canary_marks / name).is_file():
            raise InfrastructureError(f"forbidden-effect canary did not calibrate: {name}")
    for path in canary_marks.iterdir():
        path.unlink()
    environment = {
        "PATH": f"{canary_bin}:/usr/bin:/bin",
        "CANARY_DIR": str(canary_marks),
    }
    if marker is not None:
        environment["AGENT_LAB_MUTATION_MARK"] = str(marker)
    completed = cli(
        runtime,
        home,
        "image",
        "add",
        "vendor.worker",
        SUBJECT,
        environment=environment,
    )
    if completed.returncode != 0:
        raise InfrastructureError(f"no-effect probe catalog add returned {completed.returncode}")
    fired = tuple(sorted(path.name for path in canary_marks.iterdir()))
    return ProbeResult(not fired, f"forbidden_effects={fired!r}")


def probe_no_admission_authority(
    runtime: Path,
    probe_root: Path,
    marker: Path | None,
) -> ProbeResult:
    home = initialized_home(runtime, probe_root, "no-admission-authority-home")
    completed = cli(
        runtime,
        home,
        "image",
        "add",
        "vendor.worker",
        SUBJECT,
        environment=marker_environment(marker),
    )
    result = json_object(completed, "catalog admission-boundary probe")
    secure = (
        set(result) == {"changed", "entryDigest", "generation"}
        and result.get("changed") is True
        and type(result.get("generation")) is int
        and result.get("generation") == 1
        and isinstance(result.get("entryDigest"), str)
    )
    return ProbeResult(secure, f"result_keys={tuple(sorted(result))!r}")


def probe_unknown_staging(runtime: Path, probe_root: Path, marker: Path | None) -> ProbeResult:
    home = initialized_home(runtime, probe_root, "staging-home")
    wrapper = home / "images" / ".staging" / "foreign-wrapper"
    try:
        wrapper.mkdir(mode=0o700)
        (wrapper / "unknown").write_bytes(b"foreign\n")
        os.chmod(wrapper / "unknown", 0o600)
    except OSError as error:
        raise InfrastructureError("unknown staging fixture could not be created") from error
    before = tree_fingerprint(wrapper)
    completed = cli(
        runtime,
        home,
        "image",
        "add",
        "vendor.worker",
        SUBJECT,
        environment=marker_environment(marker),
    )
    after = tree_fingerprint(wrapper)
    if completed.returncode not in (0, 125):
        raise InfrastructureError(f"unknown-staging probe returned {completed.returncode}")
    secure = (
        completed.returncode == 125
        and not completed.stdout
        and before == after
        and not (home / "images" / "catalog").exists()
    )
    return ProbeResult(secure, f"rc={completed.returncode} foreign_changed={before != after}")


def load_catalog_module(runtime: Path, name: str):
    path = runtime / "scripts" / "image_catalog.py"
    spec = spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise InfrastructureError("private catalog module cannot be loaded")
    module = module_from_spec(spec)
    sys.modules[name] = module
    previous = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec.loader.exec_module(module)
    except (ImportError, OSError, SyntaxError) as error:
        raise InfrastructureError("private catalog module import failed") from error
    finally:
        sys.dont_write_bytecode = previous
    return module


def probe_durability(runtime: Path, probe_root: Path, marker: Path | None) -> ProbeResult:
    """Verify immutable record files are synced before current-pointer publication."""

    home = initialized_home(runtime, probe_root, "durability-home")
    add_mapping(runtime, home)
    module = load_catalog_module(runtime, f"agent_lab_image_catalog_mutation_{os.getpid()}_{id(runtime)}")
    events: list[tuple[str, str]] = []
    original_fsync = module.os.fsync
    original_replace = module.os.replace

    def observed_fsync(descriptor: int) -> None:
        try:
            target = os.readlink(f"/proc/self/fd/{descriptor}")
        except OSError:
            target = f"fd:{descriptor}"
        events.append(("fsync", target))
        original_fsync(descriptor)

    def observed_replace(source: os.PathLike[str] | str, target: os.PathLike[str] | str) -> None:
        events.append(("replace", os.fspath(target)))
        original_replace(source, target)

    module.os.fsync = observed_fsync
    module.os.replace = observed_replace
    if marker is not None:
        os.environ["AGENT_LAB_MUTATION_MARK"] = str(marker)
    try:
        module.add_image(home, "vendor.second", OTHER_SUBJECT)
    except Exception as error:
        if isinstance(error, getattr(module, "CatalogReject", ())):
            raise InfrastructureError(f"durability probe was rejected: {error}") from error
        if isinstance(error, getattr(module, "CatalogInfrastructure", ())):
            raise InfrastructureError(f"durability probe returned infrastructure failure: {error}") from error
        raise InfrastructureError(f"durability probe raised an uncontained error: {error}") from error
    finally:
        module.os.fsync = original_fsync
        module.os.replace = original_replace
        if marker is not None:
            os.environ.pop("AGENT_LAB_MUTATION_MARK", None)

    pointer_indexes = [
        index
        for index, event in enumerate(events)
        if event[0] == "replace"
        and Path(event[1]) == home / "images" / "catalog" / "current.json"
    ]
    entry_syncs = [
        index
        for index, event in enumerate(events)
        if event[0] == "fsync" and event[1].endswith("/payload/entry.json")
    ]
    snapshot_syncs = [
        index
        for index, event in enumerate(events)
        if event[0] == "fsync" and event[1].endswith("/payload/snapshot.json")
    ]
    secure = (
        len(pointer_indexes) == 1
        and bool(entry_syncs)
        and bool(snapshot_syncs)
        and max(entry_syncs) < pointer_indexes[0]
        and max(snapshot_syncs) < pointer_indexes[0]
    )
    return ProbeResult(
        secure,
        f"entry_syncs={entry_syncs} snapshot_syncs={snapshot_syncs} pointer={pointer_indexes}",
    )


def probe_atomic_publication(runtime: Path, probe_root: Path, marker: Path | None) -> ProbeResult:
    """Reject a producer that can expose a partial digest-addressed final record."""

    home = initialized_home(runtime, probe_root, "atomic-publication-home")
    add_mapping(runtime, home)
    environment = {"AGENT_LAB_MUTATION_MARK": str(marker)} if marker is not None else None
    attempted = cli(
        runtime,
        home,
        "image",
        "add",
        "vendor.second",
        OTHER_SUBJECT,
        environment=environment,
    )
    observed = cli(runtime, home, "image", "list")
    try:
        records = json.loads(observed.stdout) if observed.returncode == 0 else []
    except json.JSONDecodeError:
        records = []
    secure = (
        attempted.returncode == 0
        and observed.returncode == 0
        and [record.get("name") for record in records] == ["vendor.second", "vendor.worker"]
    )
    return ProbeResult(
        secure,
        f"add_rc={attempted.returncode} list_rc={observed.returncode} records={records!r}",
    )


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
    if mutated.count(mutation.new) != 1 or mutated == source:
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


# Each source rewrite must match exactly once in the copied runtime. The marker write proves the
# altered branch executed; it is confined to the mutation's temporary directory.
MUTATIONS: tuple[Mutation, ...] = (
    Mutation(
        "M-CAT-OCI-001",
        "scripts/image_reference.py",
        '        and OCI_SUBJECT.fullmatch(value) is not None\n',
        (
            '        and (\n'
            '            __import__("pathlib").Path(\n'
            '                __import__("os").environ["AGENT_LAB_MUTATION_MARK"]\n'
            '            ).touch()\n'
            '            or OCI_SUBJECT.fullmatch(value.lower()) is not None\n'
            '        )\n'
        ),
        probe_invalid_oci,
        "the invalid-OCI oracle detects an uppercase digest admitted by the shared parser",
    ),
    Mutation(
        "M-CAT-SHADOW-001",
        "scripts/image_catalog.py",
        (
            '        or not isinstance(name, str)\n'
            '        or name.startswith("agent-lab.")\n'
            '        or not oci_subject(subject)\n'
        ),
        (
            '        or not isinstance(name, str)\n'
            '        or (\n'
            '            name.startswith("agent-lab.")\n'
            '            and Path(os.environ["AGENT_LAB_MUTATION_MARK"]).touch() is not None\n'
            '        )\n'
            '        or not oci_subject(subject)\n'
        ),
        probe_reserved_shadow,
        "the reserved-name oracle detects a local agent-lab.* entry admitted by its closed schema",
    ),
    Mutation(
        "M-CAT-CAS-001",
        "scripts/image_catalog.py",
        (
            '            if prior["entryDigest"] != expected_entry_digest:\n'
            '                _reject("remove compare-and-swap conflict")\n'
            '            subject = prior["subject"]\n'
            '            assert isinstance(subject, str)\n'
            '            entry, entry_digest, snapshot, snapshot_digest, intent = _candidate_values(\n'
            '                state,\n'
            '                kind="remove",\n'
            '                name=name,\n'
            '                subject=subject,\n'
            '                expected_entry_digest=expected_entry_digest,\n'
            '                limits=limits,\n'
            '            )\n'
        ),
        (
            '            Path(os.environ["AGENT_LAB_MUTATION_MARK"]).touch()\n'
            '            subject = prior["subject"]\n'
            '            assert isinstance(subject, str)\n'
            '            entry, entry_digest, snapshot, snapshot_digest, intent = _candidate_values(\n'
            '                state,\n'
            '                kind="remove",\n'
            '                name=name,\n'
            '                subject=subject,\n'
            '                expected_entry_digest=str(prior["entryDigest"]),\n'
            '                limits=limits,\n'
            '            )\n'
        ),
        probe_cas,
        "the stale-token oracle detects removal with a substituted CAS token",
    ),
    Mutation(
        "M-CAT-AUTH-001",
        "scripts/image_catalog.py",
        (
            'def _read_file(path: Path, maximum: int, purpose: str) -> bytes:\n'
            '    try:\n'
            '        lexical = path.lstat()\n'
        ),
        (
            'def _read_file(path: Path, maximum: int, purpose: str) -> bytes:\n'
            '    if purpose == "local image current pointer" and path.is_symlink():\n'
            '        Path(os.environ["AGENT_LAB_MUTATION_MARK"]).touch()\n'
            '        return path.read_bytes()\n'
            '    try:\n'
            '        lexical = path.lstat()\n'
        ),
        probe_symlink_authority,
        "the authority oracle detects a followed current-pointer symlink",
    ),
    Mutation(
        "M-RES-BIND-001",
        "scripts/experiment.py",
        '                "entryDigest": record["entryDigest"],\n',
        (
            '                "entryDigest": (\n'
            '                    Path(os.environ["AGENT_LAB_MUTATION_MARK"]).touch()\n'
            '                    or "sha256:" + "0" * 64\n'
            '                ),\n'
        ),
        probe_selected_binding,
        "the plan-binding oracle detects substitution of the selected entry digest",
    ),
    Mutation(
        "M-CAT-NOEF-001",
        "scripts/agent-lab.py",
        '            result = catalog.add_image(home, argv[1], argv[2])\n',
        (
            '            Path(os.environ["AGENT_LAB_MUTATION_MARK"]).touch()\n'
            '            subprocess.run(("docker",), check=False)\n'
            '            result = catalog.add_image(home, argv[1], argv[2])\n'
        ),
        probe_no_forbidden_effect,
        "the calibrated no-effect oracle detects an injected Engine command",
    ),
    Mutation(
        "M-CAT-ADMIT-001",
        "scripts/image_catalog.py",
        '            return {"changed": True, "entryDigest": entry_digest, "generation": 1}\n',
        (
            '            Path(os.environ["AGENT_LAB_MUTATION_MARK"]).touch()\n'
            '            return {\n'
            '                "admitted": True,\n'
            '                "changed": True,\n'
            '                "entryDigest": entry_digest,\n'
            '                "generation": 1,\n'
            '            }\n'
        ),
        probe_no_admission_authority,
        "the result-schema oracle detects catalog membership presented as admission authority",
    ),
    Mutation(
        "M-CAT-ATOM-001",
        "scripts/image_catalog.py",
        (
            '        _fault(fault, f"{purpose}.before_noreplace")\n'
            '        _rename_noreplace(source, target)\n'
            '        _fault(fault, f"{purpose}.after_noreplace")\n'
        ),
        (
            '        _fault(fault, f"{purpose}.before_noreplace")\n'
            '        Path(os.environ["AGENT_LAB_MUTATION_MARK"]).touch()\n'
            '        descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)\n'
            '        try:\n'
            '            _write_all(descriptor, data[: max(1, len(data) // 2)])\n'
            '        finally:\n'
            '            os.close(descriptor)\n'
            '        _fault(fault, f"{purpose}.after_noreplace")\n'
        ),
        probe_atomic_publication,
        "the atomicity oracle detects a partial digest-addressed final record",
    ),
    Mutation(
        "M-CAT-DUR-001",
        "scripts/image_catalog.py",
        (
            '        _write_all(descriptor, data)\n'
            '        _fault(fault, f"{purpose}.before_fsync")\n'
            '        os.fsync(descriptor)\n'
            '        _fault(fault, f"{purpose}.after_fsync")\n'
            '        metadata = os.fstat(descriptor)\n'
        ),
        (
            '        _write_all(descriptor, data)\n'
            '        mutation_marker = os.environ.get("AGENT_LAB_MUTATION_MARK")\n'
            '        if mutation_marker is not None:\n'
            '            Path(mutation_marker).touch()\n'
            '        _fault(fault, f"{purpose}.before_fsync")\n'
            '        _fault(fault, f"{purpose}.after_fsync")\n'
            '        metadata = os.fstat(descriptor)\n'
        ),
        probe_durability,
        "the durability oracle detects publication without immutable-file fsync",
    ),
    Mutation(
        "M-CAT-STAGE-001",
        "scripts/image_catalog.py",
        (
            '    if names != (CLEANUP_WRAPPER,):\n'
            '        _infra("catalog staging root contains an unknown wrapper")\n'
            '    cleanup = authority.staging / CLEANUP_WRAPPER\n'
        ),
        (
            '    if names != (CLEANUP_WRAPPER,):\n'
            '        Path(os.environ["AGENT_LAB_MUTATION_MARK"]).touch()\n'
            '        for name in names:\n'
            '            _remove_owned_tree(authority.staging / name)\n'
            '        _fsync_directory(authority.staging, "catalog staging root")\n'
            '        return None\n'
            '    cleanup = authority.staging / CLEANUP_WRAPPER\n'
        ),
        probe_unknown_staging,
        "the staging oracle detects broad deletion of an unknown wrapper",
    ),
)


def execute_mutation(root: Path, names: tuple[str, ...], mutation: Mutation) -> tuple[bool, str]:
    runtime = root / "runtime"
    copy_runtime(runtime, names)
    copied = runtime_fingerprint(runtime, names)
    copied_tree = tree_fingerprint(runtime)
    pristine = mutation.probe(runtime, root / "pristine", None)
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
    result = mutation.probe(runtime, root / "mutant", marker)
    if not marker.is_file():
        raise InfrastructureError(f"{mutation.assertion} did not prove its mutated path was reached")
    if runtime_fingerprint(runtime, names) != mutated:
        raise InfrastructureError(f"{mutation.assertion} mutant probe changed its runtime copy")
    if tree_fingerprint(runtime) != mutated_tree:
        raise InfrastructureError(f"{mutation.assertion} mutant probe changed runtime topology")
    return not result.secure, result.detail


def main() -> int:
    try:
        names = manifest_paths()
        shared_before = runtime_fingerprint(REPO_ROOT, names)
        if not MUTATIONS:
            raise InfrastructureError("catalog mutation declarations are unavailable")
        expected = (
            "M-CAT-OCI-001",
            "M-CAT-SHADOW-001",
            "M-CAT-CAS-001",
            "M-CAT-AUTH-001",
            "M-RES-BIND-001",
            "M-CAT-NOEF-001",
            "M-CAT-ADMIT-001",
            "M-CAT-ATOM-001",
            "M-CAT-DUR-001",
            "M-CAT-STAGE-001",
        )
        if tuple(mutation.assertion for mutation in MUTATIONS) != expected:
            raise InfrastructureError("catalog mutation assertion identity drift")

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
                cleanup_error: OSError | None = None
                try:
                    shutil.rmtree(temporary)
                except OSError as error:
                    cleanup_error = error
                if runtime_fingerprint(REPO_ROOT, names) != shared_before:
                    raise InfrastructureError(
                        f"{mutation.assertion} changed the shared checkout runtime fingerprint"
                    )
                if cleanup_error is not None:
                    raise InfrastructureError(
                        f"{mutation.assertion} private mutation cleanup is uncertain"
                    ) from cleanup_error
                if temporary.exists() or temporary.is_symlink():
                    raise InfrastructureError(
                        f"{mutation.assertion} private mutation cleanup was incomplete"
                    )
        if tuple(observed) != expected:
            raise InfrastructureError("catalog mutation execution identity drift")
        print(f"SUMMARY assertions=10 expected=10 failures={failures} infra=0")
        return 0 if failures == 0 else 1
    except InfrastructureError as error:
        print(f"INFRA catalog mutation evidence: {error}", file=sys.stderr)
        return 125


if __name__ == "__main__":
    raise SystemExit(main())
