#!/usr/bin/env python3
"""Adversarial local image-catalog filesystem and durability cases."""

from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import hashlib
from importlib.util import module_from_spec, spec_from_file_location
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import time


REPO_ROOT = Path(__file__).resolve().parents[2]
AGENT_LAB = REPO_ROOT / "scripts" / "agent-lab"
AGENT_LAB_MODULE = REPO_ROOT / "scripts" / "agent-lab.py"
CATALOG_MODULE = REPO_ROOT / "scripts" / "image_catalog.py"
SUBJECT = "registry.example/operator/worker@sha256:" + "a" * 64
OTHER_SUBJECT = "registry.example/operator/other@sha256:" + "b" * 64
THIRD_SUBJECT = "registry.example/operator/third@sha256:" + "c" * 64
ENTRY_DOMAIN = b"agent-lab.local-image-entry.v1\0"
SNAPSHOT_DOMAIN = b"agent-lab.local-image-snapshot.v1\0"


def canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"), sort_keys=True).encode()


def digest(domain: bytes, value: object) -> str:
    return "sha256:" + hashlib.sha256(domain + canonical(value)).hexdigest()


def load_module():
    spec = spec_from_file_location("agent_lab_catalog_state", AGENT_LAB_MODULE)
    if spec is None or spec.loader is None:
        raise RuntimeError("Agent Lab application module cannot be loaded")
    module = module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


MODULE = load_module()


def load_catalog_module():
    spec = spec_from_file_location("agent_lab_catalog_contract", CATALOG_MODULE)
    if spec is None or spec.loader is None:
        raise RuntimeError("Agent Lab catalog module cannot be loaded")
    module = module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


CATALOG = load_catalog_module()
FAILURES = 0
OBSERVED: list[str] = []
CLI_CALLS = 0


def check(assertion: str, condition: bool, message: str, detail: str = "") -> None:
    global FAILURES
    OBSERVED.append(assertion)
    if condition:
        print(f"PASS {assertion} {message}")
    else:
        FAILURES += 1
        suffix = f" ({detail})" if detail else ""
        print(f"FAIL {assertion} {message}{suffix}")


def cli(home: Path, *arguments: str, timeout: float = 5.0) -> subprocess.CompletedProcess[bytes]:
    global CLI_CALLS
    CLI_CALLS += 1
    environment = {
        "PATH": "/usr/bin:/bin",
        "LANG": "C",
        "LC_ALL": "C",
    }
    return subprocess.run(
        [str(AGENT_LAB), "--home", str(home), *arguments],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        timeout=timeout,
        check=False,
    )


def module_image(home: Path, *arguments: str) -> tuple[int | None, str, str, BaseException | None]:
    output = io.StringIO()
    errors = io.StringIO()
    try:
        with redirect_stdout(output), redirect_stderr(errors):
            result = MODULE.image_command(home, list(arguments))
        return result, output.getvalue(), errors.getvalue(), None
    except BaseException as error:  # The assertion records an uncontained production fault as RED.
        return None, output.getvalue(), errors.getvalue(), error


def module_main(home: Path, arguments: list[str], output: io.TextIOBase | None = None) -> tuple[int | None, BaseException | None]:
    stream = output if output is not None else io.StringIO()
    errors = io.StringIO()
    try:
        with redirect_stdout(stream), redirect_stderr(errors):
            result = MODULE.main(["--home", str(home), *arguments])
        return result, None
    except BaseException as error:  # The assertion records an uncontained production fault as RED.
        return None, error


def new_home(root: Path, name: str) -> Path:
    home = root / name
    completed = cli(home, "init")
    if completed.returncode != 0:
        raise RuntimeError(f"temporary home init failed: {completed.stderr.decode(errors='replace')}")
    return home


def add(home: Path, name: str = "vendor.worker", subject: str = SUBJECT) -> dict[str, object]:
    completed = cli(home, "image", "add", name, subject)
    if completed.returncode != 0:
        raise RuntimeError(f"catalog setup add failed: {completed.stderr.decode(errors='replace')}")
    value = json.loads(completed.stdout)
    if not isinstance(value, dict):
        raise RuntimeError("catalog setup add returned a non-object")
    return value


def matrix_home(root: Path, name: str) -> tuple[Path, str | None]:
    home = root / name
    output = io.StringIO()
    errors = io.StringIO()
    error: BaseException | None = None
    returncode: int | None = None
    try:
        with redirect_stdout(output), redirect_stderr(errors):
            returncode = MODULE.main(["--home", str(home), "init"])
    except BaseException as caught:  # Setup faults must remain matrix failures.
        error = caught
    if returncode != 0 or error is not None or errors.getvalue():
        return home, (
            f"init={returncode}:error={type(error).__name__ if error else 'none'}:"
            f"stderr={errors.getvalue()!r}"
        )
    return home, None


def matrix_add(home: Path, name: str, subject: str) -> str | None:
    returncode, output, errors, error = module_image(home, "add", name, subject)
    try:
        value = json.loads(output) if returncode == 0 and error is None else None
    except json.JSONDecodeError:
        value = None
    if errors or not isinstance(value, dict) or value.get("changed") is not True:
        return (
            f"add={returncode}:error={type(error).__name__ if error else 'none'}:"
            f"stderr={errors!r}:value={value!r}"
        )
    return None


def current_snapshot(home: Path) -> tuple[Path, dict[str, object], str]:
    root = home / "images" / "catalog"
    pointer = json.loads((root / "current.json").read_bytes())
    snapshot_digest = pointer["snapshotDigest"]
    path = root / "snapshots" / f"{snapshot_digest[7:]}.json"
    value = json.loads(path.read_bytes())
    return path, value, snapshot_digest


def stored_active_names(home: Path) -> list[str] | None:
    try:
        root = home / "images" / "catalog"
        pointer_raw = (root / "current.json").read_bytes()
        pointer = json.loads(pointer_raw)
        if (
            not isinstance(pointer, dict)
            or set(pointer) != {"apiVersion", "snapshotDigest"}
            or pointer.get("apiVersion") != "agent-lab.local-image-current/v0alpha1"
            or pointer_raw != canonical(pointer) + b"\n"
        ):
            return None
        snapshot_digest = pointer.get("snapshotDigest")
        if (
            not isinstance(snapshot_digest, str)
            or not snapshot_digest.startswith("sha256:")
            or len(snapshot_digest) != 71
            or any(character not in "0123456789abcdef" for character in snapshot_digest[7:])
        ):
            return None
        snapshot_raw = (root / "snapshots" / f"{snapshot_digest[7:]}.json").read_bytes()
        snapshot = json.loads(snapshot_raw)
        if (
            not isinstance(snapshot, dict)
            or set(snapshot)
            != {"apiVersion", "previousSnapshotDigest", "records", "revision"}
            or snapshot.get("apiVersion") != "agent-lab.local-image-snapshot/v0alpha1"
            or snapshot_raw != canonical(snapshot) + b"\n"
            or digest(SNAPSHOT_DOMAIN, snapshot) != snapshot_digest
            or not isinstance(snapshot.get("revision"), int)
            or isinstance(snapshot.get("revision"), bool)
            or int(snapshot["revision"]) < 1
        ):
            return None
        records = snapshot.get("records")
        if not isinstance(records, dict):
            return None
        active: list[str] = []
        for name, projection in records.items():
            if (
                not isinstance(name, str)
                or not isinstance(projection, dict)
                or set(projection) != {"entryDigest", "generation", "state"}
            ):
                return None
            entry_digest = projection.get("entryDigest")
            if (
                not isinstance(entry_digest, str)
                or not entry_digest.startswith("sha256:")
                or len(entry_digest) != 71
                or any(character not in "0123456789abcdef" for character in entry_digest[7:])
            ):
                return None
            entry_raw = (root / "entries" / f"{entry_digest[7:]}.json").read_bytes()
            entry = json.loads(entry_raw)
            if (
                not isinstance(entry, dict)
                or set(entry)
                != {
                    "apiVersion",
                    "generation",
                    "name",
                    "previousEntryDigest",
                    "state",
                    "subject",
                    "subjectDigest",
                }
                or entry.get("apiVersion") != "agent-lab.local-image-entry/v0alpha1"
                or entry_raw != canonical(entry) + b"\n"
                or digest(ENTRY_DOMAIN, entry) != entry_digest
                or entry.get("name") != name
                or entry.get("generation") != projection.get("generation")
                or entry.get("state") != projection.get("state")
                or not isinstance(entry.get("generation"), int)
                or isinstance(entry.get("generation"), bool)
                or int(entry["generation"]) < 1
                or entry.get("state") not in ("active", "removed")
                or not isinstance(entry.get("subject"), str)
                or entry.get("subjectDigest") != str(entry["subject"]).rsplit("@", 1)[-1]
            ):
                return None
            if entry.get("state") == "active":
                active.append(name)
        return sorted(active, key=lambda item: item.encode("ascii"))
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
        return None


def stored_oracle_sensitivity(home: Path, expected: list[str]) -> bool:
    try:
        snapshot_path, snapshot, _snapshot_digest = current_snapshot(home)
        original = snapshot_path.read_bytes()
        mutated = dict(snapshot)
        revision = mutated.get("revision")
        if not isinstance(revision, int) or isinstance(revision, bool):
            return False
        mutated["revision"] = revision + 1
        snapshot_path.write_bytes(canonical(mutated) + b"\n")
        rejected = stored_active_names(home) is None
        snapshot_path.write_bytes(original)
        return rejected and stored_active_names(home) == expected
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
        return False


def fingerprint(root: Path) -> tuple[tuple[str, str, int, int, str], ...]:
    if not root.exists() and not root.is_symlink():
        return ()
    records: list[tuple[str, str, int, int, str]] = []
    paths = [root, *sorted(root.rglob("*"), key=lambda item: os.fsencode(str(item.relative_to(root))))]
    for path in paths:
        metadata = path.lstat()
        relative = "." if path == root else str(path.relative_to(root))
        if stat.S_ISLNK(metadata.st_mode):
            kind = "l"
            identity = os.readlink(path)
        elif stat.S_ISREG(metadata.st_mode):
            kind = "f"
            identity = hashlib.sha256(path.read_bytes()).hexdigest()
        elif stat.S_ISDIR(metadata.st_mode):
            kind = "d"
            identity = ""
        else:
            kind = "o"
            identity = ""
        records.append((relative, kind, stat.S_IMODE(metadata.st_mode), metadata.st_nlink, identity))
    return tuple(records)


def write_record(root: Path, domain: bytes, value: dict[str, object]) -> Path:
    record_digest = digest(domain, value)
    path = root / f"{record_digest[7:]}.json"
    path.write_bytes(canonical(value) + b"\n")
    path.chmod(0o600)
    return path


def hard_exit_add(
    home: Path,
    name: str,
    subject: str,
    point: str,
    *,
    limits=None,
) -> int:
    pid = os.fork()
    if pid == 0:
        def stop_at(observed: str) -> None:
            if observed == point:
                os._exit(99)

        try:
            keyword = {} if limits is None else {"limits": limits}
            CATALOG.add_image(home, name, subject, fault=stop_at, **keyword)
        except BaseException:
            os._exit(98)
        os._exit(97)
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        waited, status = os.waitpid(pid, os.WNOHANG)
        if waited == pid:
            return os.waitstatus_to_exitcode(status)
        time.sleep(0.01)
    os.kill(pid, 9)
    os.waitpid(pid, 0)
    return 124


class BrokenOutput(io.StringIO):
    def write(self, value: str) -> int:
        raise OSError("injected result-output failure")


class HardExitOutput(io.StringIO):
    def __init__(self, point: str) -> None:
        super().__init__()
        self.point = point

    def write(self, value: str) -> int:
        if self.point == "result.before_write":
            os._exit(99)
        written = super().write(value)
        if self.point == "result.after_write":
            os._exit(99)
        return written


def hard_exit_result(home: Path, point: str) -> int:
    pid = os.fork()
    if pid == 0:
        output = HardExitOutput(point)
        try:
            with redirect_stdout(output), redirect_stderr(io.StringIO()):
                MODULE.main(["--home", str(home), "image", "add", "vendor.worker", SUBJECT])
        except BaseException:
            os._exit(98)
        os._exit(97)
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        waited, status = os.waitpid(pid, os.WNOHANG)
        if waited == pid:
            return os.waitstatus_to_exitcode(status)
        time.sleep(0.01)
    os.kill(pid, 9)
    os.waitpid(pid, 0)
    return 124


def hard_exit_cleanup(
    home: Path,
    name: str,
    subject: str,
    operation: str,
) -> int:
    pid = os.fork()
    if pid == 0:
        original_unlink = Path.unlink
        original_rmdir = Path.rmdir

        def stop_after_unlink(path: Path, *args, **kwargs) -> None:
            original_unlink(path, *args, **kwargs)
            if path.name == "intent.json":
                os._exit(99)

        def stop_after_rmdir(path: Path, *args, **kwargs) -> None:
            original_rmdir(path, *args, **kwargs)
            if path.name == "payload":
                os._exit(99)

        if operation == "intent-unlink":
            Path.unlink = stop_after_unlink
        elif operation == "payload-rmdir":
            Path.rmdir = stop_after_rmdir
        else:
            os._exit(96)
        try:
            CATALOG.add_image(home, name, subject)
        except BaseException:
            os._exit(98)
        os._exit(97)
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        waited, status = os.waitpid(pid, os.WNOHANG)
        if waited == pid:
            return os.waitstatus_to_exitcode(status)
        time.sleep(0.01)
    os.kill(pid, 9)
    os.waitpid(pid, 0)
    return 124


def catalog_add_result(home: Path, name: str, subject: str, *, limits=None):
    keyword = {} if limits is None else {"limits": limits}
    try:
        return 0, CATALOG.add_image(home, name, subject, **keyword), None
    except CATALOG.CatalogReject as error:
        return 1, None, error
    except CATALOG.CatalogInfrastructure as error:
        return 125, None, error
    except BaseException as error:  # The assertion records an uncontained production fault as RED.
        return None, None, error


def traced_catalog_add(home: Path, name: str, subject: str):
    targets: list[str] = []
    original_fsync = CATALOG.os.fsync

    def record_fsync(descriptor: int) -> None:
        try:
            targets.append(os.readlink(f"/proc/self/fd/{descriptor}"))
        except OSError:
            targets.append("<unresolved>")
        original_fsync(descriptor)

    CATALOG.os.fsync = record_fsync
    try:
        rc, value, error = catalog_add_result(home, name, subject)
    finally:
        CATALOG.os.fsync = original_fsync
    return rc, value, error, targets


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="agent-lab-catalog-state-") as directory:
        root = Path(directory)

        missing_home = new_home(root, "missing-home")
        add(missing_home)
        committed = missing_home / "images" / "catalog"
        saved_catalog = root / "saved-committed-catalog"
        committed.rename(saved_catalog)
        completed = cli(missing_home, "image", "list")
        check(
            "CAT-STATE-001",
            completed.returncode == 125 and completed.stdout == b"" and not committed.exists(),
            "a missing previously committed catalog is infrastructure uncertainty, not empty",
            f"rc={completed.returncode} stdout={completed.stdout!r}",
        )

        history_home = new_home(root, "history-home")
        add(history_home)
        entries = history_home / "images" / "catalog" / "entries"
        entries.rename(root / "removed-entry-history")
        completed = cli(history_home, "image", "list")
        check(
            "CAT-STATE-002",
            completed.returncode == 125 and completed.stdout == b"",
            "missing immutable entry history fails closed",
            f"rc={completed.returncode} stdout={completed.stdout!r}",
        )

        canonical_home = new_home(root, "canonical-home")
        add(canonical_home)
        snapshot_path, snapshot, _ = current_snapshot(canonical_home)
        snapshot_path.write_text(json.dumps(snapshot, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        completed = cli(canonical_home, "image", "list")
        check(
            "CAT-STATE-003",
            completed.returncode == 125,
            "noncanonical snapshot bytes fail closed even when semantic digest fields match",
            f"rc={completed.returncode}",
        )

        corrupt_home = new_home(root, "corrupt-home")
        add(corrupt_home)
        _, snapshot, _ = current_snapshot(corrupt_home)
        records = snapshot.get("records")
        if not isinstance(records, dict) or not isinstance(records.get("vendor.worker"), dict):
            raise RuntimeError("catalog setup snapshot has an unexpected shape")
        records["vendor.worker"]["state"] = "future"
        corrupt_digest = digest(SNAPSHOT_DOMAIN, snapshot)
        corrupt_path = corrupt_home / "images" / "catalog" / "snapshots" / f"{corrupt_digest[7:]}.json"
        corrupt_path.write_bytes(canonical(snapshot) + b"\n")
        (corrupt_home / "images" / "catalog" / "current.json").write_bytes(
            canonical(
                {
                    "apiVersion": "agent-lab.local-image-current/v0alpha1",
                    "snapshotDigest": corrupt_digest,
                }
            )
            + b"\n"
        )
        completed = cli(corrupt_home, "image", "list")
        check(
            "CAT-STATE-004",
            completed.returncode == 125 and completed.stdout == b"",
            "closed record validation rejects an unknown state even under a recomputed snapshot digest",
            f"rc={completed.returncode} stdout={completed.stdout!r}",
        )

        mode_home = new_home(root, "mode-home")
        add(mode_home)
        current = mode_home / "images" / "catalog" / "current.json"
        current.chmod(0o644)
        completed = cli(mode_home, "image", "list")
        check(
            "CAT-STATE-005",
            completed.returncode == 125,
            "wrong catalog record mode fails closed",
            f"rc={completed.returncode}",
        )

        link_count_home = new_home(root, "link-count-home")
        add(link_count_home)
        current = link_count_home / "images" / "catalog" / "current.json"
        os.link(current, root / "second-current-link")
        completed = cli(link_count_home, "image", "list")
        check(
            "CAT-STATE-006",
            completed.returncode == 125,
            "multiply linked catalog authority fails closed",
            f"rc={completed.returncode}",
        )

        source_home = new_home(root, "symlink-source-home")
        add(source_home)
        outside_catalog = root / "outside-catalog"
        (source_home / "images" / "catalog").rename(outside_catalog)
        symlink_home = new_home(root, "symlink-home")
        os.symlink(outside_catalog, symlink_home / "images" / "catalog")
        before = fingerprint(outside_catalog)
        completed = cli(symlink_home, "image", "add", "vendor.second", OTHER_SUBJECT)
        after = fingerprint(outside_catalog)
        check(
            "CAT-STATE-007",
            completed.returncode == 125 and before == after,
            "a symlinked initialized catalog is refused before external target mutation",
            f"rc={completed.returncode} target_changed={before != after}",
        )

        lock_home = new_home(root, "lock-home")
        add(lock_home)
        lock_path = lock_home / "state" / "locks" / "image-catalog.lock"
        saved_lock = root / "saved-image-catalog.lock"
        lock_path.rename(saved_lock)
        os.symlink(saved_lock, lock_path)
        completed = cli(lock_home, "image", "list")
        check(
            "CAT-STATE-008",
            completed.returncode == 125,
            "replacement or symlink of the stable catalog lock fails closed",
            f"rc={completed.returncode}",
        )

        staging_home = new_home(root, "staging-home")
        foreign_wrapper = staging_home / "images" / ".staging" / "foreign-wrapper"
        (foreign_wrapper / "payload").mkdir(parents=True)
        (foreign_wrapper / "intent.json").write_text('{"owner":"foreign"}\n', encoding="utf-8")
        before = fingerprint(foreign_wrapper)
        completed = cli(staging_home, "image", "add", "vendor.worker", SUBJECT)
        after = fingerprint(foreign_wrapper)
        unsafe_cleanup_home = new_home(root, "unsafe-cleanup-home")
        unsafe_cleanup = (
            unsafe_cleanup_home / "images" / ".staging" / "image-catalog-cleanup"
        )
        unsafe_cleanup.mkdir(mode=0o700)
        (unsafe_cleanup / "payload").write_bytes(b"not-a-directory\n")
        (unsafe_cleanup / "payload").chmod(0o600)
        cleanup_before = fingerprint(unsafe_cleanup)
        cleanup_read = cli(unsafe_cleanup_home, "image", "list")
        cleanup_retry = cli(
            unsafe_cleanup_home,
            "image",
            "add",
            "vendor.worker",
            SUBJECT,
        )
        cleanup_after = fingerprint(unsafe_cleanup)
        check(
            "CAT-STATE-009",
            completed.returncode == 125
            and before == after
            and not (staging_home / "images" / "catalog").exists()
            and cleanup_read.returncode == 125
            and cleanup_read.stdout == b""
            and cleanup_retry.returncode == 125
            and cleanup_retry.stdout == b""
            and cleanup_before == cleanup_after,
            "unknown or unsafe staging ownership is preserved and blocks reads and mutation",
            (
                f"rc={completed.returncode} wrapper_changed={before != after} "
                f"cleanup_read={cleanup_read.returncode} cleanup_retry={cleanup_retry.returncode} "
                f"cleanup_changed={cleanup_before != cleanup_after}"
            ),
        )

        pristine_home = new_home(root, "pristine-home")
        before = fingerprint(pristine_home / "images")
        completed = cli(pristine_home, "image", "list")
        after = fingerprint(pristine_home / "images")
        check(
            "CAT-STATE-010",
            completed.returncode == 0 and completed.stdout == b"[]\n" and before == after,
            "pristine read returns canonical empty without initialization or cleanup",
            f"rc={completed.returncode} changed={before != after} stdout={completed.stdout!r}",
        )

        schema_home = new_home(root, "schema-home")
        add(schema_home)
        entry_paths = list((schema_home / "images" / "catalog" / "entries").glob("*.json"))
        snapshot_paths = list((schema_home / "images" / "catalog" / "snapshots").glob("*.json"))
        schema_ok = len(entry_paths) == 1 and len(snapshot_paths) == 1
        for path in [*entry_paths, *snapshot_paths]:
            raw = path.read_bytes()
            try:
                value = json.loads(raw)
            except (UnicodeError, json.JSONDecodeError):
                schema_ok = False
                continue
            api_version = value.get("apiVersion") if isinstance(value, dict) else None
            schema_ok = (
                schema_ok
                and isinstance(api_version, str)
                and api_version.startswith("agent-lab.")
                and api_version.endswith("/v0alpha1")
                and raw == canonical(value) + b"\n"
            )
        check(
            "CAT-STATE-011",
            schema_ok,
            "immutable entry and snapshot records carry closed versioned canonical schemas",
        )

        truncated_home = new_home(root, "truncated-home")
        add(truncated_home)
        current = truncated_home / "images" / "catalog" / "current.json"
        current.write_bytes(b'{"snapshotDigest":')
        before = current.read_bytes()
        completed = cli(truncated_home, "image", "inspect", "vendor.worker")
        check(
            "CAT-STATE-012",
            completed.returncode == 125 and completed.stdout == b"" and current.read_bytes() == before,
            "truncated authority is infrastructure uncertainty and read-only commands do not repair it",
            f"rc={completed.returncode}",
        )

        orphan_home = new_home(root, "orphan-history-home")
        add(orphan_home)
        orphan_entry = {
            "apiVersion": "agent-lab.local-image-entry/v0alpha1",
            "generation": 2,
            "name": "orphan.image",
            "previousEntryDigest": "sha256:" + "e" * 64,
            "state": "removed",
            "subject": OTHER_SUBJECT,
            "subjectDigest": OTHER_SUBJECT.rsplit("@", 1)[1],
        }
        orphan_path = write_record(
            orphan_home / "images" / "catalog" / "entries",
            ENTRY_DOMAIN,
            orphan_entry,
        )
        before = orphan_path.read_bytes()
        completed = cli(orphan_home, "image", "list", "--all")
        check(
            "CAT-STATE-013",
            completed.returncode == 125 and completed.stdout == b"" and orphan_path.read_bytes() == before,
            "malformed unreachable tombstone history fails closed without repair",
            f"rc={completed.returncode}",
        )

        conflict_home = new_home(root, "conflicting-history-home")
        add(conflict_home)
        conflicting_entry = {
            "apiVersion": "agent-lab.local-image-entry/v0alpha1",
            "generation": 1,
            "name": "vendor.worker",
            "previousEntryDigest": None,
            "state": "active",
            "subject": OTHER_SUBJECT,
            "subjectDigest": OTHER_SUBJECT.rsplit("@", 1)[1],
        }
        conflict_path = write_record(
            conflict_home / "images" / "catalog" / "entries",
            ENTRY_DOMAIN,
            conflicting_entry,
        )
        before = conflict_path.read_bytes()
        completed = cli(conflict_home, "image", "list", "--all")
        check(
            "CAT-STATE-014",
            completed.returncode == 125 and completed.stdout == b"" and conflict_path.read_bytes() == before,
            "conflicting unreachable generation history fails closed without repair",
            f"rc={completed.returncode}",
        )

        marker_home = new_home(root, "marker-home")
        add(marker_home)
        marker_lock = marker_home / "state" / "locks" / "image-catalog.lock"
        marker_lock.write_bytes(b"")
        truncated = cli(marker_home, "image", "list")
        moved_catalog = root / "marker-moved-catalog"
        (marker_home / "images" / "catalog").rename(moved_catalog)
        missing = cli(marker_home, "image", "list")
        check(
            "CAT-STATE-015",
            truncated.returncode == 125
            and missing.returncode == 125
            and truncated.stdout == b""
            and missing.stdout == b"",
            "truncated initialization evidence never turns an existing or lost catalog into pristine state",
            f"truncated_rc={truncated.returncode} missing_rc={missing.returncode}",
        )

        replacement_home = new_home(root, "replacement-home")
        add(replacement_home)
        replacement_lock = replacement_home / "state" / "locks" / "image-catalog.lock"
        lock_bytes = replacement_lock.read_bytes()
        replacement_lock.rename(root / "original-image-catalog.lock")
        replacement_lock.write_bytes(lock_bytes)
        replacement_lock.chmod(0o600)
        completed = cli(replacement_home, "image", "list")
        check(
            "CAT-STATE-016",
            completed.returncode == 125 and completed.stdout == b"",
            "the immutable home receipt detects a pre-invocation stable-lock replacement",
            f"rc={completed.returncode}",
        )

        split_home = new_home(root, "split-lock-home")
        original_flock = CATALOG.fcntl.flock
        split_rejected = False
        split_replaced = False

        def replace_after_flock(descriptor: int, operation: int) -> None:
            nonlocal split_replaced
            original_flock(descriptor, operation)
            if operation in (CATALOG.fcntl.LOCK_SH, CATALOG.fcntl.LOCK_EX) and not split_replaced:
                path = split_home / "state" / "locks" / "image-catalog.lock"
                data = path.read_bytes()
                path.rename(root / "split-original-image-catalog.lock")
                path.write_bytes(data)
                path.chmod(0o600)
                split_replaced = True

        CATALOG.fcntl.flock = replace_after_flock
        try:
            CATALOG.list_images(split_home)
        except CATALOG.CatalogInfrastructure:
            split_rejected = True
        finally:
            CATALOG.fcntl.flock = original_flock

        transition_home = new_home(root, "marker-transition-home")
        transition_authority = CATALOG._load_home(transition_home)
        transition_lock = transition_home / "state" / "locks" / "image-catalog.lock"
        original_open = CATALOG.os.open
        transition_observed = None
        transitioned = False

        def append_marker_before_open(path, flags, *args, **kwargs):
            nonlocal transitioned
            if Path(path) == transition_lock and flags & os.O_RDWR and not transitioned:
                marker_descriptor = original_open(
                    path,
                    os.O_WRONLY | os.O_APPEND | getattr(os, "O_CLOEXEC", 0),
                )
                try:
                    os.write(marker_descriptor, b"initialized\n")
                    os.fsync(marker_descriptor)
                finally:
                    os.close(marker_descriptor)
                transitioned = True
            return original_open(path, flags, *args, **kwargs)

        CATALOG.os.open = append_marker_before_open
        try:
            with CATALOG._catalog_lock(transition_authority, exclusive=False) as descriptor:
                transition_observed = CATALOG._lock_bytes(descriptor)
        finally:
            CATALOG.os.open = original_open
        check(
            "CAT-STATE-018",
            split_rejected
            and split_replaced
            and transitioned
            and transition_observed == CATALOG.LOCK_INITIALIZED,
            "post-acquisition replacement is rejected while a valid same-inode marker transition is accepted",
        )

        nested_home = new_home(root, "nested-json-home")
        add(nested_home)
        nested_current = nested_home / "images" / "catalog" / "current.json"
        nested_current.write_bytes(b"[" * 30_000 + b"0" + b"]" * 30_000 + b"\n")
        completed = cli(nested_home, "image", "list")
        check(
            "CAT-STATE-017",
            completed.returncode == 125
            and completed.stdout == b""
            and b"Traceback" not in completed.stderr,
            "bounded deeply nested JSON is classified as infrastructure uncertainty without traceback",
            f"rc={completed.returncode} stderr={completed.stderr[-120:]!r}",
        )

        names_home = new_home(root, "names-bound-home")
        names_ok = True
        for index in range(256):
            rc, _, _, error = module_image(names_home, "add", f"v{index:03d}.image", SUBJECT)
            if rc != 0 or error is not None:
                names_ok = False
                break
        before = fingerprint(names_home / "images" / "catalog")
        rc, _, _, error = module_image(names_home, "add", "v256.image", SUBJECT)
        after = fingerprint(names_home / "images" / "catalog")
        check(
            "CAT-BOUND-001",
            names_ok and rc == 1 and error is None and before == after,
            "the 257th logical name is a stable refusal with no publication",
            f"setup_ok={names_ok} rc={rc} error={error!r} changed={before != after}",
        )

        bytes_home = new_home(root, "bytes-bound-home")
        add(bytes_home)
        orphan = bytes_home / "images" / "catalog" / "entries" / ("f" * 64 + ".json")
        with orphan.open("wb") as stream:
            stream.truncate(67_108_865)
        before = orphan.stat().st_size
        completed = cli(bytes_home, "image", "list")
        check(
            "CAT-BOUND-002",
            completed.returncode == 125 and orphan.exists() and orphan.stat().st_size == before,
            "over-bound physical catalog state fails closed without broad deletion",
            f"rc={completed.returncode}",
        )

        physical_limit_home = new_home(root, "physical-name-limit-home")
        physical_limits = CATALOG.CatalogLimits(names=2)
        catalog_add_result(
            physical_limit_home,
            "vendor.first",
            SUBJECT,
            limits=physical_limits,
        )
        child_rc = hard_exit_add(
            physical_limit_home,
            "vendor.orphan",
            OTHER_SUBJECT,
            "catalog immutable entry.after_noreplace",
            limits=physical_limits,
        )
        before = fingerprint(physical_limit_home / "images" / "catalog")
        third_rc, _, third_error = catalog_add_result(
            physical_limit_home,
            "vendor.third",
            THIRD_SUBJECT,
            limits=physical_limits,
        )
        after = fingerprint(physical_limit_home / "images" / "catalog")
        observed = cli(physical_limit_home, "image", "list")
        check(
            "CAT-BOUND-003",
            child_rc == 99
            and third_rc == 1
            and isinstance(third_error, CATALOG.CatalogReject)
            and before == after
            and observed.returncode == 0
            and [item.get("name") for item in json.loads(observed.stdout)] == ["vendor.first"],
            "a valid unreachable orphan consumes physical-name capacity before new publication",
            (
                f"child_rc={child_rc} third_rc={third_rc} error={third_error!r} "
                f"changed={before != after} list_rc={observed.returncode}"
            ),
        )

        orphan_conflict_home = new_home(root, "orphan-generation-conflict-home")
        add(orphan_conflict_home, "vendor.first", SUBJECT)
        child_rc = hard_exit_add(
            orphan_conflict_home,
            "vendor.orphan",
            OTHER_SUBJECT,
            "catalog immutable entry.after_noreplace",
        )
        before = fingerprint(orphan_conflict_home / "images" / "catalog")
        conflict_rc, _, conflict_error = catalog_add_result(
            orphan_conflict_home,
            "vendor.orphan",
            THIRD_SUBJECT,
        )
        after = fingerprint(orphan_conflict_home / "images" / "catalog")
        observed = cli(orphan_conflict_home, "image", "list")
        check(
            "CAT-BOUND-004",
            child_rc == 99
            and conflict_rc == 1
            and isinstance(conflict_error, CATALOG.CatalogReject)
            and before == after
            and observed.returncode == 0
            and [item.get("name") for item in json.loads(observed.stdout)] == ["vendor.first"],
            "a conflicting generation-one orphan is rejected before immutable publication",
            (
                f"child_rc={child_rc} conflict_rc={conflict_rc} error={conflict_error!r} "
                f"changed={before != after} list_rc={observed.returncode}"
            ),
        )

        fsync_home = new_home(root, "fsync-home")
        original_fsync = MODULE.os.fsync
        record_fsync_failed = False

        def fail_first_fsync(descriptor: int) -> None:
            nonlocal record_fsync_failed
            target = os.readlink(f"/proc/self/fd/{descriptor}")
            if not record_fsync_failed and "/payload/catalog/entries/" in target:
                record_fsync_failed = True
                raise OSError("injected fsync failure")
            original_fsync(descriptor)

        MODULE.os.fsync = fail_first_fsync
        try:
            first_rc, _, _, first_error = module_image(fsync_home, "add", "vendor.worker", SUBJECT)
        finally:
            MODULE.os.fsync = original_fsync
        retry = cli(fsync_home, "image", "add", "vendor.worker", SUBJECT)
        staged = list((fsync_home / "images" / ".staging").iterdir())
        check(
            "CAT-CRASH-001",
            first_rc == 125
            and first_error is None
            and record_fsync_failed
            and retry.returncode == 0
            and json.loads(retry.stdout).get("changed") is True
            and not staged,
            "staged immutable-record fsync failure is contained and retry reconciles safely",
            f"first_rc={first_rc} error={first_error!r} retry_rc={retry.returncode} staged={len(staged)}",
        )

        replace_home = new_home(root, "replace-home")
        add(replace_home)
        original_replace = MODULE.os.replace
        replace_calls = 0

        def fail_pointer_replace(source: os.PathLike[str] | str, target: os.PathLike[str] | str) -> None:
            nonlocal replace_calls
            final_pointer = replace_home / "images" / "catalog" / "current.json"
            if Path(target) == final_pointer:
                replace_calls += 1
                if replace_calls == 1:
                    raise OSError("injected pointer publication failure")
            original_replace(source, target)

        MODULE.os.replace = fail_pointer_replace
        try:
            first_rc, _, _, first_error = module_image(
                replace_home,
                "add",
                "vendor.second",
                OTHER_SUBJECT,
            )
        finally:
            MODULE.os.replace = original_replace
        retry = cli(replace_home, "image", "add", "vendor.second", OTHER_SUBJECT)
        staged = list((replace_home / "images" / ".staging").iterdir())
        check(
            "CAT-CRASH-002",
            first_rc == 125
            and first_error is None
            and retry.returncode == 0
            and json.loads(retry.stdout).get("changed") is True
            and not staged,
            "pointer publication failure leaves an uncommitted operation that retry proves and reconciles",
            f"first_rc={first_rc} error={first_error!r} retry_rc={retry.returncode} staged={len(staged)}",
        )

        result_home = new_home(root, "result-home")
        first_rc, first_error = module_main(
            result_home,
            ["image", "add", "vendor.worker", SUBJECT],
            BrokenOutput(),
        )
        retry = cli(result_home, "image", "add", "vendor.worker", SUBJECT)
        retry_value = json.loads(retry.stdout) if retry.returncode == 0 else {}
        result_exit_codes: list[int] = []
        result_retries: list[dict[str, object]] = []
        for index, point in enumerate(("result.before_write", "result.after_write")):
            hard_exit_home = new_home(root, f"result-hard-exit-{index}")
            result_exit_codes.append(hard_exit_result(hard_exit_home, point))
            completed = cli(hard_exit_home, "image", "add", "vendor.worker", SUBJECT)
            result_retries.append(json.loads(completed.stdout) if completed.returncode == 0 else {})
        check(
            "CAT-CRASH-003",
            first_rc == 125
            and first_error is None
            and retry.returncode == 0
            and retry_value.get("changed") is False
            and result_exit_codes == [99, 99]
            and [value.get("changed") for value in result_retries] == [False, False],
            "failures and hard exits before or after result write retry as committed idempotent state",
            (
                f"first_rc={first_rc} error={first_error!r} retry_rc={retry.returncode} "
                f"retry={retry_value!r} exits={result_exit_codes!r} hard_retries={result_retries!r}"
            ),
        )

        forged_home = new_home(root, "forged-stage-home")
        victim = add(forged_home)
        _, _, base_digest = current_snapshot(forged_home)
        victim_digest = victim.get("entryDigest")
        if not isinstance(victim_digest, str):
            raise RuntimeError("catalog setup add omitted the active entry digest")
        wrapper = forged_home / "images" / ".staging" / "image-catalog-operation"
        wrapper.mkdir(mode=0o700)
        forged_intent = {
            "apiVersion": "agent-lab.local-image-intent/v0alpha1",
            "baseSnapshotDigest": base_digest,
            "bootstrap": False,
            "candidateEntryDigest": victim_digest,
            "candidateSnapshotDigest": "sha256:" + "f" * 64,
            "entryPreexisting": False,
            "expectedEntryDigest": None,
            "kind": "add",
            "name": "vendor.second",
            "snapshotPreexisting": True,
            "subject": OTHER_SUBJECT,
        }
        intent_path = wrapper / "intent.json"
        intent_path.write_bytes(canonical(forged_intent) + b"\n")
        intent_path.chmod(0o600)
        before = fingerprint(forged_home / "images")
        completed = cli(forged_home, "image", "add", "vendor.third", OTHER_SUBJECT)
        after = fingerprint(forged_home / "images")
        observed = cli(forged_home, "image", "list")
        check(
            "CAT-CRASH-004",
            completed.returncode == 125
            and completed.stdout == b""
            and before == after
            and observed.returncode == 125
            and observed.stdout == b"",
            "unproven staged intent cannot delete committed immutable history or its own evidence",
            (
                f"rc={completed.returncode} changed={before != after} "
                f"list_rc={observed.returncode}"
            ),
        )

        atomic_home = new_home(root, "atomic-record-home")
        add(atomic_home)
        exit_code = hard_exit_add(
            atomic_home,
            "vendor.second",
            OTHER_SUBJECT,
            "catalog immutable entry.before_noreplace",
        )
        observed = cli(atomic_home, "image", "list")
        observed_value = json.loads(observed.stdout) if observed.returncode == 0 else []
        retry = cli(atomic_home, "image", "add", "vendor.second", OTHER_SUBJECT)
        check(
            "CAT-CRASH-005",
            exit_code == 99
            and observed.returncode == 0
            and [item.get("name") for item in observed_value] == ["vendor.worker"]
            and retry.returncode == 0
            and json.loads(retry.stdout).get("changed") is True,
            "hard exit at immutable-record no-replace publication exposes the old complete view and retries",
            (
                f"child_rc={exit_code} list_rc={observed.returncode} "
                f"list={observed_value!r} retry_rc={retry.returncode}"
            ),
        )

        bootstrap_points = (
            "catalog intent.before_fsync",
            "catalog intent.after_fsync",
            "catalog intent wrapper.before_fsync",
            "catalog intent wrapper.after_fsync",
            "catalog intent publication.before_fsync",
            "catalog intent publication.after_fsync",
            "catalog staged entry.before_fsync",
            "catalog staged entry.after_fsync",
            "catalog staged snapshot.before_fsync",
            "catalog staged snapshot.after_fsync",
            "catalog staged pointer.before_fsync",
            "catalog staged pointer.after_fsync",
            "catalog staged pointer.before_replace",
            "catalog staged pointer.after_replace",
            "catalog staged entries.before_fsync",
            "catalog staged entries.after_fsync",
            "catalog staged snapshots.before_fsync",
            "catalog staged snapshots.after_fsync",
            "catalog staged root.before_fsync",
            "catalog staged root.after_fsync",
            "catalog staged payload.before_fsync",
            "catalog staged payload.after_fsync",
            "catalog staged wrapper.before_fsync",
            "catalog staged wrapper.after_fsync",
            "catalog staged operation.before_fsync",
            "catalog staged operation.after_fsync",
            "catalog marker.before_write",
            "catalog marker.after_write",
            "catalog marker.before_fsync",
            "catalog marker.after_fsync",
            "bootstrap.before_rename",
            "bootstrap.after_rename",
            "catalog bootstrap parent.before_fsync",
            "catalog bootstrap parent.after_fsync",
            "catalog staging cleanup.before_remove",
            "catalog staging cleanup handoff.before_rename",
            "catalog staging cleanup handoff.after_rename",
            "catalog staging cleanup handoff.before_fsync",
            "catalog staging cleanup handoff.after_fsync",
            "catalog staging cleanup.after_remove",
            "catalog staging cleanup.after_unlink",
            "catalog staging cleanup.after_rmdir",
            "catalog staging cleanup.before_fsync",
            "catalog staging cleanup.after_fsync",
        )
        later_points = (
            "catalog intent.before_fsync",
            "catalog intent.after_fsync",
            "catalog intent wrapper.before_fsync",
            "catalog intent wrapper.after_fsync",
            "catalog intent publication.before_fsync",
            "catalog intent publication.after_fsync",
            "catalog staged entry.before_fsync",
            "catalog staged entry.after_fsync",
            "catalog staged snapshot.before_fsync",
            "catalog staged snapshot.after_fsync",
            "catalog staged pointer.before_fsync",
            "catalog staged pointer.after_fsync",
            "catalog staged pointer.before_replace",
            "catalog staged pointer.after_replace",
            "catalog staged payload.before_fsync",
            "catalog staged payload.after_fsync",
            "catalog staged wrapper.before_fsync",
            "catalog staged wrapper.after_fsync",
            "catalog staged operation.before_fsync",
            "catalog staged operation.after_fsync",
            "catalog immutable entry.before_noreplace",
            "catalog immutable entry.after_noreplace",
            "catalog immutable entry history.before_fsync",
            "catalog immutable entry history.after_fsync",
            "catalog immutable snapshot.before_noreplace",
            "catalog immutable snapshot.after_noreplace",
            "catalog immutable snapshot history.before_fsync",
            "catalog immutable snapshot history.after_fsync",
            "pointer.before_replace",
            "pointer.after_replace",
            "catalog current pointer.before_fsync",
            "catalog current pointer.after_fsync",
            "catalog staging cleanup.before_remove",
            "catalog staging cleanup handoff.before_rename",
            "catalog staging cleanup handoff.after_rename",
            "catalog staging cleanup handoff.before_fsync",
            "catalog staging cleanup handoff.after_fsync",
            "catalog staging cleanup.after_remove",
            "catalog staging cleanup.after_unlink",
            "catalog staging cleanup.after_rmdir",
            "catalog staging cleanup.before_fsync",
            "catalog staging cleanup.after_fsync",
        )
        matrix_failures: list[str] = []
        matrix_oracle_home: Path | None = None
        matrix_cli_start = CLI_CALLS
        for index, point in enumerate(bootstrap_points):
            home, setup_error = matrix_home(root, f"bootstrap-crash-{index:02d}")
            if setup_error is not None:
                matrix_failures.append(f"bootstrap:{point}:setup:{setup_error}")
                continue
            child_rc = hard_exit_add(home, "vendor.worker", SUBJECT, point)
            before_retry = cli(home, "image", "list")
            retry = cli(home, "image", "add", "vendor.worker", SUBJECT)
            try:
                before_records = json.loads(before_retry.stdout) if before_retry.returncode == 0 else None
                retry_value = json.loads(retry.stdout) if retry.returncode == 0 else None
            except json.JSONDecodeError:
                before_records = retry_value = None
            final_names = stored_active_names(home)
            if final_names == ["vendor.worker"]:
                matrix_oracle_home = home
            if not (
                child_rc == 99
                and before_retry.returncode == 0
                and isinstance(before_records, list)
                and len(before_records) in (0, 1)
                and retry.returncode == 0
                and isinstance(retry_value, dict)
                and retry_value.get("changed") in (True, False)
                and final_names == ["vendor.worker"]
                and not tuple((home / "images" / ".staging").iterdir())
            ):
                matrix_failures.append(
                    f"bootstrap:{point}:child={child_rc}:before={before_retry.returncode}:"
                    f"retry={retry.returncode}:final={final_names!r}"
                )
        for index, point in enumerate(later_points):
            home, setup_error = matrix_home(root, f"later-crash-{index:02d}")
            if setup_error is None:
                setup_error = matrix_add(home, "vendor.worker", SUBJECT)
            if setup_error is not None:
                matrix_failures.append(f"later:{point}:setup:{setup_error}")
                continue
            child_rc = hard_exit_add(home, "vendor.second", OTHER_SUBJECT, point)
            before_retry = cli(home, "image", "list")
            retry = cli(home, "image", "add", "vendor.second", OTHER_SUBJECT)
            try:
                before_records = json.loads(before_retry.stdout) if before_retry.returncode == 0 else None
                retry_value = json.loads(retry.stdout) if retry.returncode == 0 else None
            except json.JSONDecodeError:
                before_records = retry_value = None
            before_names = (
                [record.get("name") for record in before_records]
                if isinstance(before_records, list)
                else None
            )
            final_names = stored_active_names(home)
            if final_names == ["vendor.second", "vendor.worker"]:
                matrix_oracle_home = home
            if not (
                child_rc == 99
                and before_retry.returncode == 0
                and before_names in (["vendor.worker"], ["vendor.second", "vendor.worker"])
                and retry.returncode == 0
                and isinstance(retry_value, dict)
                and retry_value.get("changed") in (True, False)
                and final_names == ["vendor.second", "vendor.worker"]
                and not tuple((home / "images" / ".staging").iterdir())
            ):
                matrix_failures.append(
                    f"later:{point}:child={child_rc}:before={before_retry.returncode}:"
                    f"retry={retry.returncode}:final={final_names!r}"
                )
        matrix_cli_calls = CLI_CALLS - matrix_cli_start
        expected_matrix_cli_calls = 2 * (len(bootstrap_points) + len(later_points))
        if matrix_cli_calls != expected_matrix_cli_calls:
            matrix_failures.append(
                f"cli-calls:{matrix_cli_calls}:expected={expected_matrix_cli_calls}"
            )
        if matrix_oracle_home is None or not stored_oracle_sensitivity(
            matrix_oracle_home, ["vendor.second", "vendor.worker"]
        ):
            matrix_failures.append("stored-oracle-sensitivity")
        check(
            "CAT-CRASH-006",
            not matrix_failures,
            "hard exits around every emitted stage, record, pointer, marker, and parent-fsync seam preserve old/new views and retry",
            "; ".join(matrix_failures[:5]),
        )

        preintent_home = new_home(root, "preintent-crash-home")
        add(preintent_home)
        child_rc = hard_exit_add(
            preintent_home,
            "vendor.second",
            OTHER_SUBJECT,
            "catalog wrapper.after_create",
        )
        before_retry = cli(preintent_home, "image", "list")
        stage_before = fingerprint(preintent_home / "images" / ".staging")
        retry = cli(preintent_home, "image", "add", "vendor.second", OTHER_SUBJECT)
        stage_after = fingerprint(preintent_home / "images" / ".staging")
        pristine_preintent_home = new_home(root, "pristine-preintent-crash-home")
        pristine_child_rc = hard_exit_add(
            pristine_preintent_home,
            "vendor.worker",
            SUBJECT,
            "catalog wrapper.after_create",
        )
        pristine_before = fingerprint(pristine_preintent_home / "images" / ".staging")
        pristine_list = cli(pristine_preintent_home, "image", "list")
        pristine_retry = cli(
            pristine_preintent_home,
            "image",
            "add",
            "vendor.worker",
            SUBJECT,
        )
        pristine_after = fingerprint(pristine_preintent_home / "images" / ".staging")
        check(
            "CAT-CRASH-007",
            child_rc == 99
            and before_retry.returncode == 125
            and retry.returncode == 125
            and retry.stdout == b""
            and stage_before == stage_after
            and pristine_child_rc == 99
            and pristine_list.returncode == 125
            and pristine_retry.returncode == 125
            and pristine_before == pristine_after,
            "a pre-intent hard exit blocks reads and mutation without deleting residue",
            (
                f"child_rc={child_rc} list_rc={before_retry.returncode} "
                f"retry_rc={retry.returncode} changed={stage_before != stage_after} "
                f"pristine_child={pristine_child_rc} pristine_list={pristine_list.returncode} "
                f"pristine_retry={pristine_retry.returncode}"
            ),
        )

        phase_home = new_home(root, "bootstrap-phase-home")
        child_rc = hard_exit_add(
            phase_home,
            "vendor.worker",
            SUBJECT,
            "catalog marker.after_fsync",
        )
        staged_catalog = (
            phase_home
            / "images"
            / ".staging"
            / "image-catalog-operation"
            / "payload"
            / "catalog"
        )
        shutil.copyfile(staged_catalog / "current.json", staged_catalog / "current.next")
        (staged_catalog / "current.next").chmod(0o600)
        before = fingerprint(phase_home / "images")
        retry = cli(phase_home, "image", "add", "vendor.worker", SUBJECT)
        after = fingerprint(phase_home / "images")

        marker_phase_home = new_home(root, "initialized-incomplete-bootstrap-home")
        marker_child = hard_exit_add(
            marker_phase_home,
            "vendor.worker",
            SUBJECT,
            "catalog marker.after_fsync",
        )
        marker_payload = (
            marker_phase_home
            / "images"
            / ".staging"
            / "image-catalog-operation"
            / "payload"
        )
        shutil.rmtree(marker_payload)
        marker_before = fingerprint(marker_phase_home / "images")
        marker_read = cli(marker_phase_home, "image", "list")
        marker_retry = cli(marker_phase_home, "image", "add", "vendor.worker", SUBJECT)
        marker_after = fingerprint(marker_phase_home / "images")
        check(
            "CAT-CRASH-008",
            child_rc == 99
            and retry.returncode == 125
            and retry.stdout == b""
            and before == after
            and not (phase_home / "images" / "catalog").exists()
            and marker_child == 99
            and marker_read.returncode == 125
            and marker_read.stdout == b""
            and marker_retry.returncode == 125
            and marker_retry.stdout == b""
            and marker_before == marker_after
            and not (marker_phase_home / "images" / "catalog").exists(),
            "phase-inconsistent bootstrap staging remains inert and cannot become committed authority",
            (
                f"child_rc={child_rc} retry_rc={retry.returncode} changed={before != after} "
                f"marker_child={marker_child} marker_read={marker_read.returncode} "
                f"marker_retry={marker_retry.returncode} marker_changed={marker_before != marker_after}"
            ),
        )

        incomplete_home = new_home(root, "incomplete-later-phase-home")
        add(incomplete_home)
        child_rc = hard_exit_add(
            incomplete_home,
            "vendor.second",
            OTHER_SUBJECT,
            "catalog staged pointer.after_replace",
        )
        incomplete_payload = (
            incomplete_home
            / "images"
            / ".staging"
            / "image-catalog-operation"
            / "payload"
        )
        (incomplete_payload / "entry.json").unlink()
        (incomplete_payload / "snapshot.json").unlink()
        before = fingerprint(incomplete_home / "images")
        retry = cli(incomplete_home, "image", "add", "vendor.second", OTHER_SUBJECT)
        after = fingerprint(incomplete_home / "images")
        check(
            "CAT-CRASH-009",
            child_rc == 99
            and retry.returncode == 125
            and retry.stdout == b""
            and before == after,
            "a later stage cannot claim a pointer phase without candidate record evidence",
            f"child_rc={child_rc} retry_rc={retry.returncode} changed={before != after}",
        )

        marker_durable_home = new_home(root, "marker-durable-recovery-home")
        marker_child = hard_exit_add(
            marker_durable_home,
            "vendor.worker",
            SUBJECT,
            "catalog marker.after_write",
        )
        marker_rc, marker_value, marker_error, marker_targets = traced_catalog_add(
            marker_durable_home,
            "vendor.worker",
            SUBJECT,
        )
        marker_lock_target = str(marker_durable_home / "state" / "locks" / "image-catalog.lock")
        marker_images_target = str(marker_durable_home / "images")

        bootstrap_durable_home = new_home(root, "bootstrap-durable-recovery-home")
        bootstrap_child = hard_exit_add(
            bootstrap_durable_home,
            "vendor.worker",
            SUBJECT,
            "bootstrap.after_rename",
        )
        bootstrap_rc, bootstrap_value, bootstrap_error, bootstrap_targets = traced_catalog_add(
            bootstrap_durable_home,
            "vendor.worker",
            SUBJECT,
        )

        pointer_durable_home = new_home(root, "pointer-durable-recovery-home")
        add(pointer_durable_home)
        pointer_child = hard_exit_add(
            pointer_durable_home,
            "vendor.second",
            OTHER_SUBJECT,
            "pointer.after_replace",
        )
        pointer_rc, pointer_value, pointer_error, pointer_targets = traced_catalog_add(
            pointer_durable_home,
            "vendor.second",
            OTHER_SUBJECT,
        )

        cleanup_durable_home = new_home(root, "cleanup-durable-recovery-home")
        add(cleanup_durable_home)
        cleanup_rc, cleanup_value, cleanup_error, cleanup_targets = traced_catalog_add(
            cleanup_durable_home,
            "vendor.worker",
            SUBJECT,
        )
        marker_ordered = (
            marker_lock_target in marker_targets
            and marker_images_target in marker_targets
            and marker_targets.index(marker_lock_target) < marker_targets.index(marker_images_target)
        )
        check(
            "CAT-CRASH-010",
            marker_child == 99
            and marker_rc == 0
            and isinstance(marker_value, dict)
            and marker_value.get("changed") is False
            and marker_error is None
            and marker_ordered
            and bootstrap_child == 99
            and bootstrap_rc == 0
            and isinstance(bootstrap_value, dict)
            and bootstrap_value.get("changed") is False
            and bootstrap_error is None
            and str(bootstrap_durable_home / "images") in bootstrap_targets
            and pointer_child == 99
            and pointer_rc == 0
            and isinstance(pointer_value, dict)
            and pointer_value.get("changed") is False
            and pointer_error is None
            and str(pointer_durable_home / "images" / "catalog") in pointer_targets
            and cleanup_rc == 0
            and isinstance(cleanup_value, dict)
            and cleanup_value.get("changed") is False
            and cleanup_error is None
            and str(cleanup_durable_home / "images" / ".staging") in cleanup_targets,
            "recovery completes marker, commit-parent, and cleanup-root durability before success",
            (
                f"marker=({marker_child},{marker_rc},{marker_targets!r}) "
                f"bootstrap=({bootstrap_child},{bootstrap_rc},{bootstrap_targets!r}) "
                f"pointer=({pointer_child},{pointer_rc},{pointer_targets!r}) "
                f"cleanup=({cleanup_rc},{cleanup_targets!r})"
            ),
        )

        cleanup_unlink_home = new_home(root, "cleanup-intent-unlink-home")
        add(cleanup_unlink_home)
        committed_child = hard_exit_add(
            cleanup_unlink_home,
            "vendor.second",
            OTHER_SUBJECT,
            "pointer.after_replace",
        )
        unlink_child = hard_exit_cleanup(
            cleanup_unlink_home,
            "vendor.second",
            OTHER_SUBJECT,
            "intent-unlink",
        )
        unlink_read = cli(cleanup_unlink_home, "image", "list")
        unlink_retry = cli(
            cleanup_unlink_home,
            "image",
            "add",
            "vendor.second",
            OTHER_SUBJECT,
        )

        cleanup_rmdir_home = new_home(root, "cleanup-payload-rmdir-home")
        add(cleanup_rmdir_home)
        orphan_child = hard_exit_add(
            cleanup_rmdir_home,
            "vendor.second",
            OTHER_SUBJECT,
            "catalog immutable entry.after_noreplace",
        )
        rmdir_child = hard_exit_cleanup(
            cleanup_rmdir_home,
            "vendor.third",
            THIRD_SUBJECT,
            "payload-rmdir",
        )
        rmdir_read = cli(cleanup_rmdir_home, "image", "list")
        rmdir_retry = cli(
            cleanup_rmdir_home,
            "image",
            "add",
            "vendor.third",
            THIRD_SUBJECT,
        )
        check(
            "CAT-CRASH-011",
            committed_child == 99
            and unlink_child == 99
            and unlink_read.returncode == 0
            and [item.get("name") for item in json.loads(unlink_read.stdout)]
            == ["vendor.second", "vendor.worker"]
            and unlink_retry.returncode == 0
            and json.loads(unlink_retry.stdout).get("changed") is False
            and not tuple((cleanup_unlink_home / "images" / ".staging").iterdir())
            and orphan_child == 99
            and rmdir_child == 99
            and rmdir_read.returncode == 0
            and [item.get("name") for item in json.loads(rmdir_read.stdout)]
            == ["vendor.worker"]
            and rmdir_retry.returncode == 0
            and json.loads(rmdir_retry.stdout).get("changed") is True
            and not tuple((cleanup_rmdir_home / "images" / ".staging").iterdir()),
            "cleanup remains restartable across internal intent-unlink and payload-rmdir crashes",
            (
                f"committed={committed_child} unlink={unlink_child} "
                f"unlink_read={unlink_read.returncode} unlink_retry={unlink_retry.returncode} "
                f"orphan={orphan_child} rmdir={rmdir_child} "
                f"rmdir_read={rmdir_read.returncode} rmdir_retry={rmdir_retry.returncode}"
            ),
        )

        platform_home = new_home(root, "platform-home")
        before = fingerprint(platform_home)
        original_platform = MODULE.sys.platform
        MODULE.sys.platform = "darwin"
        try:
            platform_rc, platform_error = module_main(
                platform_home,
                ["image", "add", "vendor.worker", SUBJECT],
            )
        finally:
            MODULE.sys.platform = original_platform
        after = fingerprint(platform_home)
        check(
            "CAT-PLAT-001",
            platform_rc == 125 and platform_error is None and before == after,
            "an injected non-Linux host refuses mutation before opening catalog state",
            f"rc={platform_rc} error={platform_error!r} changed={before != after}",
        )

    expected = [
        "CAT-STATE-001",
        "CAT-STATE-002",
        "CAT-STATE-003",
        "CAT-STATE-004",
        "CAT-STATE-005",
        "CAT-STATE-006",
        "CAT-STATE-007",
        "CAT-STATE-008",
        "CAT-STATE-009",
        "CAT-STATE-010",
        "CAT-STATE-011",
        "CAT-STATE-012",
        "CAT-STATE-013",
        "CAT-STATE-014",
        "CAT-STATE-015",
        "CAT-STATE-016",
        "CAT-STATE-018",
        "CAT-STATE-017",
        "CAT-BOUND-001",
        "CAT-BOUND-002",
        "CAT-BOUND-003",
        "CAT-BOUND-004",
        "CAT-CRASH-001",
        "CAT-CRASH-002",
        "CAT-CRASH-003",
        "CAT-CRASH-004",
        "CAT-CRASH-005",
        "CAT-CRASH-006",
        "CAT-CRASH-007",
        "CAT-CRASH-008",
        "CAT-CRASH-009",
        "CAT-CRASH-010",
        "CAT-CRASH-011",
        "CAT-PLAT-001",
    ]
    if OBSERVED != expected:
        print(f"INFRA catalog state assertion identity drift: {OBSERVED!r}", file=sys.stderr)
        return 125
    print(f"SUMMARY assertions=34 expected=34 failures={FAILURES} infra=0")
    return 0 if FAILURES == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
