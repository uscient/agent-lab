#!/usr/bin/env python3
"""Verified, durable operator-local image-name catalog."""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
import ctypes
import errno
import fcntl
import hashlib
from importlib.util import module_from_spec, spec_from_file_location
import json
import os
from pathlib import Path
import re
import stat
import sys
from typing import Callable, Iterator, NoReturn, Sequence


ENTRY_API = "agent-lab.local-image-entry/v0alpha1"
SNAPSHOT_API = "agent-lab.local-image-snapshot/v0alpha1"
CURRENT_API = "agent-lab.local-image-current/v0alpha1"
INTENT_API = "agent-lab.local-image-intent/v0alpha1"
ENTRY_DOMAIN = b"agent-lab.local-image-entry.v1\0"
SNAPSHOT_DOMAIN = b"agent-lab.local-image-snapshot.v1\0"
OPERATION_WRAPPER = "image-catalog-operation"
CLEANUP_WRAPPER = "image-catalog-cleanup"
LOCK_PRISTINE = b"agent-lab.image-catalog-lock/v0alpha1\n"
LOCK_INITIALIZED = LOCK_PRISTINE + b"initialized\n"
LOCK_SCHEMA = "agent-lab.image-catalog-lock/v0alpha1"
SAFE_COMPONENT = re.compile(r"^[a-z][a-z0-9-]{0,47}$")
SHA256 = re.compile(r"^sha256:[0-9a-f]{64}$")
HEX_FILE = re.compile(r"^[0-9a-f]{64}\.json$")
FaultHook = Callable[[str], None]


class CatalogError(Exception):
    """Base class for classified catalog failures."""


class CatalogReject(CatalogError):
    """Stable invalid input, unknown name, conflict, or capacity refusal."""

    exit_code = 1


class CatalogInfrastructure(CatalogError):
    """Unsafe, corrupt, changing, or uncertain catalog state."""

    exit_code = 125


@dataclass(frozen=True)
class CatalogLimits:
    names: int = 256
    entries: int = 512
    snapshots: int = 512
    entry_bytes: int = 65_536
    snapshot_bytes: int = 262_144
    catalog_bytes: int = 67_108_864
    stage_entries: int = 16
    stage_bytes: int = 2_097_152


@dataclass(frozen=True)
class HomeAuthority:
    home: Path
    images: Path
    staging: Path
    state: Path
    locks: Path
    lock: Path
    lock_device: int
    lock_inode: int


@dataclass(frozen=True)
class CatalogState:
    root: Path | None
    revision: int
    snapshot_digest: str | None
    previous_snapshot_digest: str | None
    records: dict[str, dict[str, object]]
    entries: dict[str, dict[str, object]]
    snapshots: dict[str, dict[str, object]]
    physical_names: frozenset[str]
    generations: dict[tuple[str, int], str]
    physical_bytes: int


@dataclass(frozen=True)
class StageState:
    path: Path
    intent: dict[str, object]


def canonical(value: object) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=True,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("ascii")


def record_digest(domain: bytes, value: object) -> str:
    return "sha256:" + hashlib.sha256(domain + canonical(value)).hexdigest()


def _image_reference_module():
    path = Path(__file__).resolve().with_name("image_reference.py")
    spec = spec_from_file_location("agent_lab_catalog_image_reference", path)
    if spec is None or spec.loader is None:
        raise ImportError("shared image-reference grammar cannot be loaded")
    module = module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


_IMAGE_REFERENCE = _image_reference_module()
image_name = _IMAGE_REFERENCE.valid_image_name
oci_subject = _IMAGE_REFERENCE.valid_oci_subject
valid_image_name = image_name
valid_oci_subject = oci_subject


def _is_digest(value: object) -> bool:
    return isinstance(value, str) and SHA256.fullmatch(value) is not None


def _reject(message: str) -> NoReturn:
    raise CatalogReject(message)


def _infra(message: str, error: BaseException | None = None) -> NoReturn:
    if error is None:
        raise CatalogInfrastructure(message)
    raise CatalogInfrastructure(message) from error


def _fault(hook: FaultHook | None, point: str) -> None:
    if hook is not None:
        hook(point)


def _directory_flags() -> int:
    return (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )


def _verify_directory(path: Path, *, mode: int = 0o700) -> os.stat_result:
    try:
        metadata = path.lstat()
    except OSError as error:
        _infra("required catalog directory is unavailable", error)
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or stat.S_IMODE(metadata.st_mode) != mode
    ):
        _infra("catalog directory metadata is unsafe")
    try:
        descriptor = os.open(path, _directory_flags())
    except OSError as error:
        _infra("catalog directory cannot be opened safely", error)
    try:
        opened = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
        _infra("catalog directory identity changed")
    return opened


def _verify_absolute_directory_chain(path: Path) -> None:
    if not path.is_absolute() or path == Path(path.anchor):
        _infra("Agent Lab home path is unsafe")
    flags = _directory_flags()
    try:
        descriptor = os.open(path.anchor, flags)
    except OSError as error:
        _infra("Agent Lab home root cannot be opened", error)
    try:
        for component in path.parts[1:]:
            child = os.open(component, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
    except FileNotFoundError:
        os.close(descriptor)
        _reject("Agent Lab home is not initialized")
    except OSError as error:
        os.close(descriptor)
        _infra("Agent Lab home path contains a symlink or non-directory", error)
    else:
        os.close(descriptor)


def _file_identity(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_uid,
        stat.S_IMODE(metadata.st_mode),
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _read_file(path: Path, maximum: int, purpose: str) -> bytes:
    try:
        lexical = path.lstat()
    except OSError as error:
        _infra(f"{purpose} is unavailable", error)
    if (
        not stat.S_ISREG(lexical.st_mode)
        or stat.S_ISLNK(lexical.st_mode)
        or lexical.st_uid != os.getuid()
        or stat.S_IMODE(lexical.st_mode) != 0o600
        or lexical.st_nlink != 1
        or lexical.st_size > maximum
    ):
        _infra(f"{purpose} metadata is unsafe or over-bound")
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        _infra(f"{purpose} cannot be opened safely", error)
    try:
        before = os.fstat(descriptor)
        if _file_identity(before) != _file_identity(lexical):
            _infra(f"{purpose} identity changed before read")
        chunks: list[bytes] = []
        remaining = maximum + 1
        while remaining:
            chunk = os.read(descriptor, min(65_536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        after = os.fstat(descriptor)
    except OSError as error:
        _infra(f"{purpose} could not be read", error)
    finally:
        os.close(descriptor)
    try:
        final = path.lstat()
    except OSError as error:
        _infra(f"{purpose} could not be reverified", error)
    if (
        len(data) > maximum
        or len(data) != after.st_size
        or _file_identity(before) != _file_identity(after)
        or _file_identity(after) != _file_identity(final)
    ):
        _infra(f"{purpose} changed while being read")
    return data


def _pairs(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON key")
        value[key] = item
    return value


def _canonical_json(data: bytes, purpose: str) -> dict[str, object]:
    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=_pairs)
    except (RecursionError, UnicodeError, ValueError, json.JSONDecodeError) as error:
        _infra(f"{purpose} is malformed", error)
    if not isinstance(value, dict) or data != canonical(value) + b"\n":
        _infra(f"{purpose} is not one canonical closed object")
    return value


def _load_home(home: Path) -> HomeAuthority:
    _verify_absolute_directory_chain(home)
    _verify_directory(home)
    config_path = home / "config.json"
    receipt_path = home / "home.json"
    config_raw = _read_file(config_path, 65_536, "Agent Lab configuration")
    receipt_raw = _read_file(receipt_path, 65_536, "Agent Lab home receipt")
    config = _canonical_json(config_raw, "Agent Lab configuration")
    receipt = _canonical_json(receipt_raw, "Agent Lab home receipt")
    if set(config) != {"apiVersion", "paths"} or config.get("apiVersion") != "agent-lab.config/v0alpha1":
        _infra("Agent Lab configuration schema is not closed")
    paths = config.get("paths")
    if (
        not isinstance(paths, dict)
        or set(paths) != {"experiments", "images", "cache", "state"}
        or len(set(paths.values())) != 4
        or any(not isinstance(item, str) or SAFE_COMPONENT.fullmatch(item) is None for item in paths.values())
    ):
        _infra("Agent Lab configuration paths are unsafe")
    digest = "sha256:" + hashlib.sha256(canonical(config)).hexdigest()
    lock_records = receipt.get("locks")
    if (
        set(receipt) != {"apiVersion", "configDigest", "locks", "paths"}
        or receipt.get("apiVersion") != "agent-lab.home/v0alpha1"
        or receipt.get("configDigest") != digest
        or receipt.get("paths") != paths
        or not isinstance(lock_records, dict)
        or set(lock_records) != {"experiments", "imageCatalog"}
    ):
        _infra("Agent Lab configuration does not match its home receipt")
    images = home / str(paths["images"])
    state = home / str(paths["state"])
    staging = images / ".staging"
    locks = state / "locks"
    for path in (images, state, staging, locks):
        _verify_directory(path)
    lock = locks / "image-catalog.lock"
    lock_record = lock_records.get("imageCatalog")
    expected_lock_path = f"{paths['state']}/locks/image-catalog.lock"
    if (
        not isinstance(lock_record, dict)
        or set(lock_record) != {"device", "inode", "path", "schema"}
        or lock_record.get("path") != expected_lock_path
        or lock_record.get("schema") != LOCK_SCHEMA
        or not isinstance(lock_record.get("device"), int)
        or isinstance(lock_record.get("device"), bool)
        or not isinstance(lock_record.get("inode"), int)
        or isinstance(lock_record.get("inode"), bool)
    ):
        _infra("catalog lock authority is absent from the home receipt")
    try:
        lock_metadata = lock.lstat()
    except OSError as error:
        _infra("catalog lock is unavailable", error)
    if (
        lock_metadata.st_dev != lock_record["device"]
        or lock_metadata.st_ino != lock_record["inode"]
    ):
        _infra("catalog lock identity does not match the home receipt")
    return HomeAuthority(
        home,
        images,
        staging,
        state,
        locks,
        lock,
        int(lock_record["device"]),
        int(lock_record["inode"]),
    )


@contextmanager
def _catalog_lock(authority: HomeAuthority, *, exclusive: bool) -> Iterator[int]:
    path = authority.lock
    try:
        lexical = path.lstat()
    except OSError as error:
        _infra("catalog lock is unavailable", error)
    if (
        not stat.S_ISREG(lexical.st_mode)
        or stat.S_ISLNK(lexical.st_mode)
        or lexical.st_uid != os.getuid()
        or stat.S_IMODE(lexical.st_mode) != 0o600
        or lexical.st_nlink != 1
        or lexical.st_size > len(LOCK_INITIALIZED)
        or (lexical.st_dev, lexical.st_ino)
        != (authority.lock_device, authority.lock_inode)
    ):
        _infra("catalog lock metadata is unsafe")
    try:
        descriptor = os.open(
            path,
            os.O_RDWR
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_NONBLOCK", 0),
        )
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != os.getuid()
            or stat.S_IMODE(opened.st_mode) != 0o600
            or opened.st_nlink != 1
            or opened.st_size > len(LOCK_INITIALIZED)
            or (opened.st_dev, opened.st_ino)
            != (authority.lock_device, authority.lock_inode)
        ):
            raise OSError("lock identity changed")
        fcntl.flock(descriptor, fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)
        current = path.lstat()
        held = os.fstat(descriptor)
        expected_identity = (authority.lock_device, authority.lock_inode)
        if (
            not stat.S_ISREG(current.st_mode)
            or current.st_uid != os.getuid()
            or stat.S_IMODE(current.st_mode) != 0o600
            or current.st_nlink != 1
            or current.st_size > len(LOCK_INITIALIZED)
            or not stat.S_ISREG(held.st_mode)
            or held.st_uid != os.getuid()
            or stat.S_IMODE(held.st_mode) != 0o600
            or held.st_nlink != 1
            or held.st_size > len(LOCK_INITIALIZED)
            or (held.st_dev, held.st_ino) != expected_identity
            or (current.st_dev, current.st_ino) != expected_identity
        ):
            raise OSError("lock path was replaced")
    except OSError as error:
        try:
            os.close(descriptor)
        except (NameError, OSError):
            pass
        _infra("catalog lock cannot be held safely", error)
    try:
        yield descriptor
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)
        except OSError as error:
            _infra("catalog lock could not be released", error)


def _lock_bytes(descriptor: int) -> bytes:
    try:
        os.lseek(descriptor, 0, os.SEEK_SET)
        data = os.read(descriptor, len(LOCK_INITIALIZED) + 1)
        os.lseek(descriptor, 0, os.SEEK_SET)
    except OSError as error:
        _infra("catalog lock marker cannot be read", error)
    if data not in (LOCK_PRISTINE, LOCK_INITIALIZED):
        _infra("catalog lock marker is malformed")
    return data


def _set_lock_marker(descriptor: int, fault: FaultHook | None = None) -> None:
    current = _lock_bytes(descriptor)
    try:
        if current == LOCK_PRISTINE:
            os.lseek(descriptor, 0, os.SEEK_END)
            _fault(fault, "catalog marker.before_write")
            written = os.write(descriptor, b"initialized\n")
            if written != len(b"initialized\n"):
                raise OSError("catalog marker write was partial")
            _fault(fault, "catalog marker.after_write")
        _fault(fault, "catalog marker.before_fsync")
        os.fsync(descriptor)
        _fault(fault, "catalog marker.after_fsync")
        os.lseek(descriptor, 0, os.SEEK_SET)
    except OSError as error:
        _infra("catalog initialization marker could not be persisted", error)
    if _lock_bytes(descriptor) != LOCK_INITIALIZED:
        _infra("catalog initialization marker could not be verified")


def _write_all(descriptor: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise OSError("write made no progress")
        view = view[written:]


def _directory_names(path: Path, purpose: str, maximum: int) -> tuple[str, ...]:
    _verify_directory(path)
    try:
        before = path.lstat()
        names_list: list[str] = []
        with os.scandir(path) as entries:
            for entry in entries:
                names_list.append(entry.name)
                if len(names_list) > maximum:
                    _infra(f"{purpose} exceeds its fixed entry bound")
        names = tuple(sorted(names_list, key=os.fsencode))
        after = path.lstat()
    except (OSError, UnicodeError) as error:
        _infra(f"{purpose} cannot be enumerated", error)
    if (before.st_dev, before.st_ino, before.st_mtime_ns, before.st_ctime_ns) != (
        after.st_dev,
        after.st_ino,
        after.st_mtime_ns,
        after.st_ctime_ns,
    ):
        _infra(f"{purpose} changed while being enumerated")
    return names


def _entry_schema(value: dict[str, object]) -> None:
    expected = {
        "apiVersion",
        "generation",
        "name",
        "previousEntryDigest",
        "state",
        "subject",
        "subjectDigest",
    }
    if set(value) != expected or value.get("apiVersion") != ENTRY_API:
        _infra("local image entry schema is not closed")
    name = value.get("name")
    generation = value.get("generation")
    state = value.get("state")
    previous = value.get("previousEntryDigest")
    subject = value.get("subject")
    subject_digest = value.get("subjectDigest")
    if (
        not image_name(name)
        or not isinstance(name, str)
        or name.startswith("agent-lab.")
        or not oci_subject(subject)
        or not isinstance(subject, str)
        or subject_digest != subject.rsplit("@", 1)[1]
    ):
        _infra("local image entry contains an invalid binding")
    if state == "active":
        if generation != 1 or isinstance(generation, bool) or previous is not None:
            _infra("active local image entry generation is invalid")
    elif state == "removed":
        if generation != 2 or isinstance(generation, bool) or not _is_digest(previous):
            _infra("removed local image entry generation is invalid")
    else:
        _infra("local image entry state is unknown")


def _snapshot_schema(value: dict[str, object]) -> None:
    if (
        set(value) != {
            "apiVersion",
            "previousSnapshotDigest",
            "records",
            "revision",
        }
        or value.get("apiVersion") != SNAPSHOT_API
    ):
        _infra("local image snapshot schema is not closed")
    revision = value.get("revision")
    previous = value.get("previousSnapshotDigest")
    records = value.get("records")
    if (
        not isinstance(revision, int)
        or isinstance(revision, bool)
        or revision < 1
        or (revision == 1 and previous is not None)
        or (revision > 1 and not _is_digest(previous))
        or not isinstance(records, dict)
        or len(records) > 256
    ):
        _infra("local image snapshot values are invalid")
    if tuple(records) != tuple(sorted(records, key=lambda item: item.encode("ascii", "strict"))):
        _infra("local image snapshot records are not byte-sorted")
    for name, projection in records.items():
        if (
            not image_name(name)
            or name.startswith("agent-lab.")
            or not isinstance(projection, dict)
            or set(projection) != {"entryDigest", "generation", "state"}
            or not _is_digest(projection.get("entryDigest"))
            or projection.get("generation") not in (1, 2)
            or isinstance(projection.get("generation"), bool)
            or projection.get("state") not in ("active", "removed")
        ):
            _infra("local image snapshot record projection is invalid")


def _current_schema(value: dict[str, object]) -> str:
    if (
        set(value) != {"apiVersion", "snapshotDigest"}
        or value.get("apiVersion") != CURRENT_API
        or not _is_digest(value.get("snapshotDigest"))
    ):
        _infra("local image current pointer schema is not closed")
    digest = value["snapshotDigest"]
    assert isinstance(digest, str)
    return digest


def _intent_schema(value: dict[str, object]) -> None:
    expected = {
        "apiVersion",
        "baseSnapshotDigest",
        "bootstrap",
        "candidateEntryDigest",
        "candidateSnapshotDigest",
        "entryPreexisting",
        "expectedEntryDigest",
        "kind",
        "name",
        "snapshotPreexisting",
        "subject",
    }
    if set(value) != expected or value.get("apiVersion") != INTENT_API:
        _infra("catalog staging intent schema is not closed")
    bootstrap = value.get("bootstrap")
    kind = value.get("kind")
    base = value.get("baseSnapshotDigest")
    expected_entry = value.get("expectedEntryDigest")
    if (
        not isinstance(bootstrap, bool)
        or kind not in ("add", "remove")
        or not image_name(value.get("name"))
        or str(value.get("name")).startswith("agent-lab.")
        or not oci_subject(value.get("subject"))
        or not _is_digest(value.get("candidateEntryDigest"))
        or not _is_digest(value.get("candidateSnapshotDigest"))
        or not isinstance(value.get("entryPreexisting"), bool)
        or not isinstance(value.get("snapshotPreexisting"), bool)
        or (bootstrap and base is not None)
        or (not bootstrap and not _is_digest(base))
        or (kind == "add" and expected_entry is not None)
        or (kind == "remove" and not _is_digest(expected_entry))
    ):
        _infra("catalog staging intent values are invalid")


def _cleanup_state(authority: HomeAuthority, limits: CatalogLimits) -> Path | None:
    names = _directory_names(authority.staging, "catalog staging root", 1)
    if not names or names == (OPERATION_WRAPPER,):
        return None
    if names != (CLEANUP_WRAPPER,):
        _infra("catalog staging root contains an unknown wrapper")
    cleanup = authority.staging / CLEANUP_WRAPPER
    _verify_directory(cleanup)
    entry_count = 0
    byte_count = 0
    pending = [cleanup]
    while pending:
        parent = pending.pop()
        remaining = limits.stage_entries - entry_count
        for name in _directory_names(parent, "catalog cleanup residue", remaining):
            item = parent / name
            relative = str(item.relative_to(cleanup))
            parts = item.relative_to(cleanup).parts
            directory_allowed = relative in {
                "payload",
                "payload/catalog",
                "payload/catalog/entries",
                "payload/catalog/snapshots",
            }
            file_allowed = relative in {
                "intent.json",
                "payload/catalog/current.json",
                "payload/catalog/current.next",
                "payload/entry.json",
                "payload/snapshot.json",
                "payload/current.json",
                "payload/current.next",
            }
            if (
                len(parts) == 4
                and parts[:3] in {
                    ("payload", "catalog", "entries"),
                    ("payload", "catalog", "snapshots"),
                }
                and HEX_FILE.fullmatch(parts[3]) is not None
            ):
                file_allowed = True
            if not directory_allowed and not file_allowed:
                _infra("catalog cleanup residue contains an unknown entry")
            try:
                metadata = item.lstat()
            except OSError as error:
                _infra("catalog cleanup residue cannot be inspected", error)
            entry_count += 1
            if metadata.st_uid != os.getuid() or stat.S_ISLNK(metadata.st_mode):
                _infra("catalog cleanup residue metadata is unsafe")
            if stat.S_ISDIR(metadata.st_mode):
                if not directory_allowed or stat.S_IMODE(metadata.st_mode) != 0o700:
                    _infra("catalog cleanup residue directory mode is unsafe")
                pending.append(item)
            elif stat.S_ISREG(metadata.st_mode):
                if (
                    not file_allowed
                    or stat.S_IMODE(metadata.st_mode) != 0o600
                    or metadata.st_nlink != 1
                ):
                    _infra("catalog cleanup residue file metadata is unsafe")
                byte_count += metadata.st_size
            else:
                _infra("catalog cleanup residue type is unsafe")
    if entry_count > limits.stage_entries or byte_count > limits.stage_bytes:
        _infra("catalog cleanup residue exceeds its fixed bound")
    intent_path = cleanup / "intent.json"
    try:
        intent_path.lstat()
    except FileNotFoundError:
        pass
    except OSError as error:
        _infra("catalog cleanup intent cannot be inspected", error)
    else:
        intent = _canonical_json(
            _read_file(intent_path, 65_536, "catalog cleanup intent"),
            "catalog cleanup intent",
        )
        _intent_schema(intent)
    return cleanup


def _stage_state(
    authority: HomeAuthority,
    limits: CatalogLimits,
) -> StageState | None:
    if _cleanup_state(authority, limits) is not None:
        return None
    names = _directory_names(authority.staging, "catalog staging root", 1)
    if not names:
        return None
    if names != (OPERATION_WRAPPER,):
        _infra("catalog staging root contains an unknown wrapper")
    wrapper = authority.staging / OPERATION_WRAPPER
    _verify_directory(wrapper)
    wrapper_names = _directory_names(wrapper, "catalog operation wrapper", 2)
    if "intent.json" not in wrapper_names or any(name not in {"intent.json", "payload"} for name in wrapper_names):
        _infra("catalog operation wrapper is incomplete or unknown")
    intent = _canonical_json(
        _read_file(wrapper / "intent.json", 65_536, "catalog operation intent"),
        "catalog operation intent",
    )
    _intent_schema(intent)
    entry_count = 1
    byte_count = (wrapper / "intent.json").lstat().st_size
    payload = wrapper / "payload"
    if payload.exists() or payload.is_symlink():
        _verify_directory(payload)
        allowed: set[str]
        if intent["bootstrap"]:
            allowed = {
                "catalog",
                "catalog/current.json",
                "catalog/current.next",
                "catalog/entries",
                f"catalog/entries/{str(intent['candidateEntryDigest'])[7:]}.json",
                "catalog/snapshots",
                f"catalog/snapshots/{str(intent['candidateSnapshotDigest'])[7:]}.json",
            }
        else:
            allowed = {"entry.json", "snapshot.json", "current.json", "current.next"}
        pending = [payload]
        while pending:
            parent = pending.pop()
            remaining = limits.stage_entries - entry_count
            for name in _directory_names(parent, "catalog staging payload", remaining):
                item = parent / name
                relative = str(item.relative_to(payload))
                if relative not in allowed:
                    _infra("catalog staging payload contains an unknown entry")
                try:
                    metadata = item.lstat()
                except OSError as error:
                    _infra("catalog staging payload cannot be inspected", error)
                entry_count += 1
                if metadata.st_uid != os.getuid() or stat.S_ISLNK(metadata.st_mode):
                    _infra("catalog staging payload metadata is unsafe")
                if stat.S_ISDIR(metadata.st_mode):
                    if stat.S_IMODE(metadata.st_mode) != 0o700:
                        _infra("catalog staging directory mode is unsafe")
                    pending.append(item)
                elif stat.S_ISREG(metadata.st_mode):
                    if stat.S_IMODE(metadata.st_mode) != 0o600 or metadata.st_nlink != 1:
                        _infra("catalog staging file metadata is unsafe")
                    byte_count += metadata.st_size
                else:
                    _infra("catalog staging payload type is unsafe")
    if entry_count > limits.stage_entries or byte_count > limits.stage_bytes:
        _infra("catalog staging state exceeds its fixed bound")
    return StageState(wrapper, intent)


def _public_record(entry: dict[str, object], entry_digest: str) -> dict[str, object]:
    return {
        "entryDigest": entry_digest,
        "generation": entry["generation"],
        "name": entry["name"],
        "previousEntryDigest": entry["previousEntryDigest"],
        "state": entry["state"],
        "subject": entry["subject"],
    }


def _projection(entry: dict[str, object], entry_digest: str) -> dict[str, object]:
    return {
        "entryDigest": entry_digest,
        "generation": entry["generation"],
        "state": entry["state"],
    }


def _validate_transition(
    previous: dict[str, object] | None,
    current: dict[str, object],
    entries: dict[str, dict[str, object]],
) -> None:
    records = current["records"]
    assert isinstance(records, dict)
    if previous is None:
        if current["revision"] != 1 or len(records) != 1:
            _infra("catalog genesis snapshot is invalid")
        only_name = next(iter(records))
        projection = records[only_name]
        assert isinstance(projection, dict)
        entry = entries[str(projection["entryDigest"])]
        if entry["state"] != "active" or entry["generation"] != 1:
            _infra("catalog genesis entry is invalid")
        return
    previous_records = previous["records"]
    assert isinstance(previous_records, dict)
    if current["revision"] != int(previous["revision"]) + 1:
        _infra("catalog snapshot revision chain is not monotonic")
    changed = sorted(set(previous_records) | set(records))
    changed = [name for name in changed if previous_records.get(name) != records.get(name)]
    if len(changed) != 1:
        _infra("catalog snapshot does not contain one valid transition")
    name = changed[0]
    before = previous_records.get(name)
    after = records.get(name)
    if not isinstance(after, dict):
        _infra("catalog transition deleted a logical name")
    entry = entries[str(after["entryDigest"])]
    if before is None:
        if entry["state"] != "active" or entry["generation"] != 1 or entry["previousEntryDigest"] is not None:
            _infra("catalog add transition is invalid")
        return
    if not isinstance(before, dict):
        _infra("catalog previous projection is invalid")
    if (
        before.get("state") != "active"
        or before.get("generation") != 1
        or entry["state"] != "removed"
        or entry["generation"] != 2
        or entry["previousEntryDigest"] != before.get("entryDigest")
    ):
        _infra("catalog removal transition is invalid")
    prior_entry = entries.get(str(before.get("entryDigest")))
    if prior_entry is None or prior_entry["subject"] != entry["subject"]:
        _infra("catalog tombstone changed its immutable subject")


def _load_catalog(
    authority: HomeAuthority,
    lock_descriptor: int,
    limits: CatalogLimits,
    *,
    inspect_stage: bool = True,
) -> CatalogState:
    stage = _stage_state(authority, limits) if inspect_stage else None
    marker = _lock_bytes(lock_descriptor)
    image_names = _directory_names(authority.images, "effective images directory", 2)
    allowed_images = {".staging", "catalog"}
    if any(name not in allowed_images for name in image_names):
        _infra("effective images directory contains unknown catalog state")
    root = authority.images / "catalog"
    try:
        root_metadata = root.lstat()
    except FileNotFoundError:
        if marker == LOCK_INITIALIZED and not (
            stage is not None and bool(stage.intent.get("bootstrap"))
        ):
            _infra("an initialized image catalog is missing")
        if stage is not None and not bool(stage.intent.get("bootstrap")):
            _infra("non-bootstrap catalog stage has no committed base")
        empty = CatalogState(
            None,
            0,
            None,
            None,
            {},
            {},
            {},
            frozenset(),
            {},
            0,
        )
        if stage is not None:
            _verify_staged_candidate(stage, empty, limits)
            if marker == LOCK_INITIALIZED:
                _complete_bootstrap_stage(stage)
        return empty
    except OSError as error:
        _infra("image catalog cannot be inspected", error)
    if not stat.S_ISDIR(root_metadata.st_mode) or stat.S_ISLNK(root_metadata.st_mode):
        _infra("image catalog path is unsafe")
    if marker != LOCK_INITIALIZED:
        _infra("image catalog exists without durable initialization authority")
    _verify_directory(root)
    root_names = _directory_names(root, "image catalog", 3)
    if set(root_names) != {"current.json", "entries", "snapshots"}:
        _infra("image catalog layout is incomplete or unknown")
    entries_root = root / "entries"
    snapshots_root = root / "snapshots"
    entry_names = _directory_names(entries_root, "image entry history", limits.entries)
    snapshot_names = _directory_names(snapshots_root, "image snapshot history", limits.snapshots)
    if (
        len(entry_names) > limits.entries
        or len(snapshot_names) > limits.snapshots
        or any(HEX_FILE.fullmatch(name) is None for name in entry_names)
        or any(HEX_FILE.fullmatch(name) is None for name in snapshot_names)
    ):
        _infra("physical image catalog history exceeds or violates its fixed shape")
    physical_bytes = 0
    for path in [root / "current.json", *[entries_root / name for name in entry_names], *[snapshots_root / name for name in snapshot_names]]:
        try:
            metadata = path.lstat()
        except OSError as error:
            _infra("physical image catalog inventory changed", error)
        physical_bytes += metadata.st_size
    if physical_bytes > limits.catalog_bytes:
        _infra("physical image catalog exceeds its fixed byte bound")

    entries: dict[str, dict[str, object]] = {}
    for name in entry_names:
        path = entries_root / name
        value = _canonical_json(
            _read_file(path, limits.entry_bytes, "local image entry record"),
            "local image entry record",
        )
        _entry_schema(value)
        digest = record_digest(ENTRY_DOMAIN, value)
        if name != f"{digest[7:]}.json" or digest in entries:
            _infra("local image entry filename does not bind its bytes")
        entries[digest] = value

    generations: dict[tuple[str, int], str] = {}
    physical_names: set[str] = set()
    for entry_digest, entry in entries.items():
        name = str(entry["name"])
        generation = int(entry["generation"])
        physical_names.add(name)
        key = (name, generation)
        existing = generations.get(key)
        if existing is not None and existing != entry_digest:
            _infra("local image history contains conflicting physical generations")
        generations[key] = entry_digest
    if len(physical_names) > limits.names:
        _infra("physical local image history exceeds its fixed name bound")
    for entry in entries.values():
        if entry["state"] != "removed":
            continue
        predecessor = entries.get(str(entry["previousEntryDigest"]))
        if (
            predecessor is None
            or predecessor["state"] != "active"
            or predecessor["generation"] != 1
            or predecessor["name"] != entry["name"]
            or predecessor["subject"] != entry["subject"]
        ):
            _infra("unreachable local image tombstone history is invalid")

    snapshots: dict[str, dict[str, object]] = {}
    for name in snapshot_names:
        path = snapshots_root / name
        value = _canonical_json(
            _read_file(path, limits.snapshot_bytes, "local image snapshot record"),
            "local image snapshot record",
        )
        _snapshot_schema(value)
        digest = record_digest(SNAPSHOT_DOMAIN, value)
        if name != f"{digest[7:]}.json" or digest in snapshots:
            _infra("local image snapshot filename does not bind its bytes")
        snapshots[digest] = value

    genesis = [
        snapshot_digest
        for snapshot_digest, snapshot in snapshots.items()
        if snapshot["previousSnapshotDigest"] is None
    ]
    if len(genesis) != 1:
        _infra("local image snapshot history does not have one physical genesis")

    for snapshot_digest, snapshot in snapshots.items():
        records = snapshot["records"]
        assert isinstance(records, dict)
        for name, projection in records.items():
            assert isinstance(projection, dict)
            entry_digest = str(projection["entryDigest"])
            entry = entries.get(entry_digest)
            if (
                entry is None
                or entry["name"] != name
                or projection != _projection(entry, entry_digest)
            ):
                _infra("local image snapshot references invalid entry history")
        previous_digest = snapshot["previousSnapshotDigest"]
        previous = snapshots.get(str(previous_digest)) if previous_digest is not None else None
        if previous_digest is not None and previous is None:
            _infra("local image snapshot predecessor is missing")
        _validate_transition(previous, snapshot, entries)

    pointer = _canonical_json(
        _read_file(root / "current.json", 65_536, "local image current pointer"),
        "local image current pointer",
    )
    current_digest = _current_schema(pointer)
    current = snapshots.get(current_digest)
    if current is None:
        _infra("local image current pointer references missing history")
    seen: set[str] = set()
    cursor_digest: str | None = current_digest
    while cursor_digest is not None:
        if cursor_digest in seen:
            _infra("local image snapshot history contains a cycle")
        seen.add(cursor_digest)
        cursor = snapshots.get(cursor_digest)
        if cursor is None:
            _infra("local image snapshot history is incomplete")
        previous = cursor["previousSnapshotDigest"]
        cursor_digest = str(previous) if previous is not None else None

    records: dict[str, dict[str, object]] = {}
    current_records = current["records"]
    assert isinstance(current_records, dict)
    if len(current_records) > limits.names:
        _infra("logical image catalog exceeds its fixed name bound")
    for name, projection in current_records.items():
        assert isinstance(projection, dict)
        digest = str(projection["entryDigest"])
        records[name] = _public_record(entries[digest], digest)
    if (
        entry_names != _directory_names(entries_root, "image entry history", limits.entries)
        or snapshot_names != _directory_names(snapshots_root, "image snapshot history", limits.snapshots)
        or root_names != _directory_names(root, "image catalog", 3)
    ):
        _infra("image catalog changed during verification")
    result = CatalogState(
        root,
        int(current["revision"]),
        current_digest,
        current["previousSnapshotDigest"] if isinstance(current["previousSnapshotDigest"], str) else None,
        records,
        entries,
        snapshots,
        frozenset(physical_names),
        generations,
        physical_bytes,
    )
    if stage is not None:
        _verify_staged_candidate(stage, result, limits)
    return result


def _write_file(path: Path, data: bytes, purpose: str, fault: FaultHook | None = None) -> None:
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    descriptor = -1
    try:
        descriptor = os.open(path, flags, 0o600)
        _write_all(descriptor, data)
        _fault(fault, f"{purpose}.before_fsync")
        os.fsync(descriptor)
        _fault(fault, f"{purpose}.after_fsync")
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) != 0o600
            or metadata.st_nlink != 1
            or metadata.st_size != len(data)
        ):
            raise OSError("published file metadata is unsafe")
    except OSError as error:
        _infra(f"{purpose} could not be persisted", error)
    finally:
        if descriptor >= 0:
            try:
                os.close(descriptor)
            except OSError as error:
                _infra(f"{purpose} descriptor could not be closed", error)


def _fsync_directory(path: Path, purpose: str, fault: FaultHook | None = None) -> None:
    descriptor = -1
    try:
        descriptor = os.open(path, _directory_flags())
        _fault(fault, f"{purpose}.before_fsync")
        os.fsync(descriptor)
        _fault(fault, f"{purpose}.after_fsync")
    except OSError as error:
        _infra(f"{purpose} directory durability is uncertain", error)
    finally:
        if descriptor >= 0:
            try:
                os.close(descriptor)
            except OSError as error:
                _infra(f"{purpose} directory descriptor could not be closed", error)


def _mkdir(path: Path) -> None:
    try:
        path.mkdir(mode=0o700)
    except OSError as error:
        _infra("catalog staging directory could not be created", error)
    _verify_directory(path)


def _rename_noreplace(source: Path, target: Path) -> None:
    try:
        library = ctypes.CDLL(None, use_errno=True)
        function = library.renameat2
    except (AttributeError, OSError) as error:
        _infra("Linux no-replace rename is unavailable", error)
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    result = function(
        -100,
        os.fsencode(source),
        -100,
        os.fsencode(target),
        1,
    )
    if result != 0:
        code = ctypes.get_errno()
        _infra("catalog no-replace publication failed", OSError(code, os.strerror(code)))


def _remove_owned_tree(path: Path, fault: FaultHook | None = None) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return
    except OSError as error:
        _infra("catalog staging cleanup cannot inspect its target", error)
    if stat.S_ISLNK(metadata.st_mode) or metadata.st_uid != os.getuid():
        _infra("catalog staging cleanup target is unsafe")
    if stat.S_ISREG(metadata.st_mode):
        if metadata.st_nlink != 1 or stat.S_IMODE(metadata.st_mode) != 0o600:
            _infra("catalog staging cleanup file is unsafe")
        try:
            path.unlink()
            _fault(fault, "catalog staging cleanup.after_unlink")
        except OSError as error:
            _infra("catalog staging file could not be cleaned", error)
        return
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o700:
        _infra("catalog staging cleanup type is unsafe")
    try:
        children = tuple(path.iterdir())
    except OSError as error:
        _infra("catalog staging cleanup cannot enumerate its target", error)
    for child in sorted(
        children,
        key=lambda item: (item.name == "intent.json", os.fsencode(item.name)),
    ):
        _remove_owned_tree(child, fault)
    try:
        path.rmdir()
        _fault(fault, "catalog staging cleanup.after_rmdir")
    except OSError as error:
        _infra("catalog staging directory could not be cleaned", error)


def _cleanup_stage(
    authority: HomeAuthority,
    stage: StageState | None = None,
    fault: FaultHook | None = None,
) -> None:
    path = authority.staging / OPERATION_WRAPPER
    cleanup = authority.staging / CLEANUP_WRAPPER
    if stage is not None and stage.path != path:
        _infra("catalog staging cleanup target changed")
    _fault(fault, "catalog staging cleanup.before_remove")
    _fault(fault, "catalog staging cleanup handoff.before_rename")
    try:
        _rename_noreplace(path, cleanup)
    except OSError as error:
        _infra("catalog staging cleanup handoff is uncertain", error)
    _fault(fault, "catalog staging cleanup handoff.after_rename")
    _fsync_directory(authority.staging, "catalog staging cleanup handoff", fault)
    _fault(fault, "catalog staging cleanup.after_remove")
    _remove_owned_tree(cleanup, fault)
    _fsync_directory(authority.staging, "catalog staging cleanup", fault)


def _finish_cleanup(
    authority: HomeAuthority,
    cleanup: Path,
    fault: FaultHook | None = None,
) -> None:
    expected = authority.staging / CLEANUP_WRAPPER
    if cleanup != expected:
        _infra("catalog cleanup residue target changed")
    _remove_owned_tree(cleanup, fault)
    _fsync_directory(authority.staging, "catalog staging cleanup", fault)


def _read_current_digest(authority: HomeAuthority) -> str | None:
    root = authority.images / "catalog"
    try:
        metadata = root.lstat()
    except FileNotFoundError:
        return None
    except OSError as error:
        _infra("catalog commit state cannot be inspected", error)
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        _infra("catalog commit state is unsafe")
    pointer = _canonical_json(
        _read_file(root / "current.json", 65_536, "local image current pointer"),
        "local image current pointer",
    )
    return _current_schema(pointer)


def _complete_bootstrap_stage(stage: StageState) -> Path:
    intent = stage.intent
    catalog = stage.path / "payload" / "catalog"
    entry_name = f"{str(intent['candidateEntryDigest'])[7:]}.json"
    snapshot_name = f"{str(intent['candidateSnapshotDigest'])[7:]}.json"
    if (
        _directory_names(stage.path / "payload", "catalog bootstrap payload", 1)
        != ("catalog",)
        or _directory_names(catalog, "catalog bootstrap candidate", 3)
        != ("current.json", "entries", "snapshots")
        or _directory_names(catalog / "entries", "catalog bootstrap entries", 1)
        != (entry_name,)
        or _directory_names(catalog / "snapshots", "catalog bootstrap snapshots", 1)
        != (snapshot_name,)
    ):
        _infra("initialized bootstrap stage is incomplete")
    return catalog


def _reconcile(authority: HomeAuthority, lock_descriptor: int, limits: CatalogLimits) -> None:
    cleanup = _cleanup_state(authority, limits)
    if cleanup is not None:
        _finish_cleanup(authority, cleanup)
        return
    stage = _stage_state(authority, limits)
    if stage is None:
        _fsync_directory(authority.staging, "catalog empty staging recovery")
        return
    intent = stage.intent
    candidate = str(intent["candidateSnapshotDigest"])
    base_value = intent["baseSnapshotDigest"]
    base = str(base_value) if base_value is not None else None
    current = _read_current_digest(authority)
    if current not in (base, candidate):
        _infra("catalog staged operation cannot be reconciled with current state")
    if current is None:
        state = CatalogState(
            None,
            0,
            None,
            None,
            {},
            {},
            {},
            frozenset(),
            {},
            0,
        )
    else:
        state = _load_catalog(authority, lock_descriptor, limits, inspect_stage=False)
    _verify_staged_candidate(stage, state, limits)
    if current == candidate:
        if bool(intent["bootstrap"]):
            _set_lock_marker(lock_descriptor)
            _fsync_directory(authority.images, "catalog bootstrap recovery parent")
        else:
            if state.root is None:
                _infra("committed catalog mutation has no final catalog")
            _fsync_directory(state.root, "catalog current pointer recovery")
        verified = _load_catalog(authority, lock_descriptor, limits, inspect_stage=False)
        if verified.snapshot_digest != candidate:
            _infra("committed catalog recovery could not be verified")
        _cleanup_stage(authority, stage)
        return
    if bool(intent["bootstrap"]):
        if current is not None:
            _infra("catalog bootstrap stage conflicts with a final catalog")
        if _lock_bytes(lock_descriptor) == LOCK_INITIALIZED:
            _set_lock_marker(lock_descriptor)
            catalog = _complete_bootstrap_stage(stage)
            _rename_noreplace(catalog, authority.images / "catalog")
            _fsync_directory(authority.images, "catalog bootstrap recovery parent")
            verified = _load_catalog(authority, lock_descriptor, limits, inspect_stage=False)
            if verified.snapshot_digest != candidate:
                _infra("recovered catalog bootstrap could not be verified")
            _cleanup_stage(authority, stage)
            return
    # Verified immutable orphans are safe and bounded. Retain them rather than
    # treating caller-controlled intent flags as deletion authority.
    _cleanup_stage(authority, stage)


def _candidate_values(
    state: CatalogState,
    *,
    kind: str,
    name: str,
    subject: str,
    expected_entry_digest: str | None,
    limits: CatalogLimits,
) -> tuple[dict[str, object], str, dict[str, object], str, dict[str, object]]:
    prior = state.records.get(name)
    if kind == "add":
        if prior is not None:
            raise AssertionError("add candidate requested for an existing name")
        if len(state.records) >= limits.names:
            _reject("catalog has reached its fixed logical-name capacity")
        entry = {
            "apiVersion": ENTRY_API,
            "generation": 1,
            "name": name,
            "previousEntryDigest": None,
            "state": "active",
            "subject": subject,
            "subjectDigest": subject.rsplit("@", 1)[1],
        }
    else:
        if prior is None:
            raise AssertionError("remove candidate requested for an unknown name")
        entry = {
            "apiVersion": ENTRY_API,
            "generation": 2,
            "name": name,
            "previousEntryDigest": expected_entry_digest,
            "state": "removed",
            "subject": prior["subject"],
            "subjectDigest": str(prior["subject"]).rsplit("@", 1)[1],
        }
    entry_digest = record_digest(ENTRY_DOMAIN, entry)
    generation = int(entry["generation"])
    existing_generation = state.generations.get((name, generation))
    if existing_generation is not None and existing_generation != entry_digest:
        _reject("catalog physical history already contains a conflicting generation")
    if name not in state.physical_names and len(state.physical_names) >= limits.names:
        _reject("catalog has reached its fixed physical-name capacity")
    projections: dict[str, dict[str, object]] = {}
    for existing_name in sorted(state.records, key=lambda item: item.encode("ascii")):
        record = state.records[existing_name]
        projections[existing_name] = {
            "entryDigest": record["entryDigest"],
            "generation": record["generation"],
            "state": record["state"],
        }
    projections[name] = _projection(entry, entry_digest)
    projections = {
        item: projections[item]
        for item in sorted(projections, key=lambda value: value.encode("ascii"))
    }
    snapshot = {
        "apiVersion": SNAPSHOT_API,
        "previousSnapshotDigest": state.snapshot_digest,
        "records": projections,
        "revision": state.revision + 1,
    }
    snapshot_digest = record_digest(SNAPSHOT_DOMAIN, snapshot)
    pointer = {"apiVersion": CURRENT_API, "snapshotDigest": snapshot_digest}
    entry_bytes = canonical(entry) + b"\n"
    snapshot_bytes = canonical(snapshot) + b"\n"
    pointer_bytes = canonical(pointer) + b"\n"
    if len(entry_bytes) > limits.entry_bytes or len(snapshot_bytes) > limits.snapshot_bytes:
        _reject("catalog mutation exceeds its fixed record bound")
    new_entry = entry_digest not in state.entries
    new_snapshot = snapshot_digest not in state.snapshots
    if len(state.entries) + int(new_entry) > limits.entries or len(state.snapshots) + int(new_snapshot) > limits.snapshots:
        _reject("catalog mutation exceeds its fixed history bound")
    prospective = state.physical_bytes + int(new_entry) * len(entry_bytes) + int(new_snapshot) * len(snapshot_bytes)
    if state.root is None:
        prospective += len(pointer_bytes)
    if prospective > limits.catalog_bytes:
        _reject("catalog mutation exceeds its fixed physical byte bound")
    intent = {
        "apiVersion": INTENT_API,
        "baseSnapshotDigest": state.snapshot_digest,
        "bootstrap": state.root is None,
        "candidateEntryDigest": entry_digest,
        "candidateSnapshotDigest": snapshot_digest,
        "entryPreexisting": not new_entry,
        "expectedEntryDigest": expected_entry_digest,
        "kind": kind,
        "name": name,
        "snapshotPreexisting": not new_snapshot,
        "subject": subject,
    }
    _intent_schema(intent)
    return entry, entry_digest, snapshot, snapshot_digest, intent


def _state_at_snapshot(state: CatalogState, snapshot_digest: str | None) -> CatalogState:
    if snapshot_digest is None:
        return CatalogState(
            None,
            0,
            None,
            None,
            {},
            state.entries,
            state.snapshots,
            state.physical_names,
            state.generations,
            state.physical_bytes,
        )
    snapshot = state.snapshots.get(snapshot_digest)
    if snapshot is None:
        _infra("catalog staging intent names an unavailable base snapshot")
    projections = snapshot["records"]
    assert isinstance(projections, dict)
    records: dict[str, dict[str, object]] = {}
    for name, projection in projections.items():
        assert isinstance(projection, dict)
        entry_digest = str(projection["entryDigest"])
        entry = state.entries.get(entry_digest)
        if entry is None:
            _infra("catalog staging base references missing entry history")
        records[name] = _public_record(entry, entry_digest)
    previous = snapshot["previousSnapshotDigest"]
    return CatalogState(
        state.root,
        int(snapshot["revision"]),
        snapshot_digest,
        str(previous) if previous is not None else None,
        records,
        state.entries,
        state.snapshots,
        state.physical_names,
        state.generations,
        state.physical_bytes,
    )


def _verify_optional_stage_file(path: Path, expected: bytes, maximum: int, purpose: str) -> bool:
    try:
        path.lstat()
    except FileNotFoundError:
        return False
    except OSError as error:
        _infra(f"{purpose} cannot be inspected", error)
    if _read_file(path, maximum, purpose) != expected:
        _infra(f"{purpose} does not match its durable intent")
    return True


def _verify_staged_candidate(
    stage: StageState,
    physical_state: CatalogState,
    limits: CatalogLimits,
) -> tuple[dict[str, object], str, dict[str, object], str]:
    intent = stage.intent
    base_value = intent["baseSnapshotDigest"]
    base_digest = str(base_value) if base_value is not None else None
    base = _state_at_snapshot(physical_state, base_digest)
    try:
        entry, entry_digest, snapshot, snapshot_digest, expected_intent = _candidate_values(
            base,
            kind=str(intent["kind"]),
            name=str(intent["name"]),
            subject=str(intent["subject"]),
            expected_entry_digest=(
                str(intent["expectedEntryDigest"])
                if intent["expectedEntryDigest"] is not None
                else None
            ),
            limits=limits,
        )
    except (AssertionError, CatalogReject) as error:
        _infra("catalog staging intent is not a valid operation from its base", error)
    semantic_fields = set(expected_intent) - {"entryPreexisting", "snapshotPreexisting"}
    if any(intent[field] != expected_intent[field] for field in semantic_fields):
        _infra("catalog staging intent does not bind its deterministic candidate")
    if bool(intent["entryPreexisting"]) and entry_digest not in physical_state.entries:
        _infra("catalog staging intent claims unavailable preexisting entry history")
    if bool(intent["snapshotPreexisting"]) and snapshot_digest not in physical_state.snapshots:
        _infra("catalog staging intent claims unavailable preexisting snapshot history")
    current_digest = physical_state.snapshot_digest
    if current_digest not in (base_digest, snapshot_digest):
        _infra("catalog staged operation does not match the physical commit phase")

    entry_bytes = canonical(entry) + b"\n"
    snapshot_bytes = canonical(snapshot) + b"\n"
    pointer_bytes = canonical(
        {"apiVersion": CURRENT_API, "snapshotDigest": snapshot_digest}
    ) + b"\n"
    payload = stage.path / "payload"
    try:
        payload.lstat()
    except FileNotFoundError:
        final_entry = entry_digest in physical_state.entries
        final_snapshot = snapshot_digest in physical_state.snapshots
        if current_digest == snapshot_digest:
            if not final_entry or not final_snapshot:
                _infra("committed catalog stage is missing its immutable candidate history")
        elif final_entry or final_snapshot:
            _infra("uncommitted catalog stage lost its candidate publication evidence")
        return entry, entry_digest, snapshot, snapshot_digest
    except OSError as error:
        _infra("catalog staging payload cannot be inspected", error)
    if bool(intent["bootstrap"]):
        catalog = payload / "catalog"
        try:
            catalog.lstat()
        except FileNotFoundError:
            if _directory_names(payload, "catalog bootstrap payload", 1):
                _infra("catalog bootstrap payload lost its candidate directory")
            final_entry = entry_digest in physical_state.entries
            final_snapshot = snapshot_digest in physical_state.snapshots
            if current_digest == snapshot_digest:
                if not final_entry or not final_snapshot:
                    _infra("committed bootstrap stage is missing immutable history")
            elif final_entry or final_snapshot:
                _infra("uncommitted bootstrap stage contains final candidate history")
            return entry, entry_digest, snapshot, snapshot_digest
        except OSError as error:
            _infra("catalog bootstrap candidate cannot be inspected", error)
        if current_digest == snapshot_digest:
            _infra("committed bootstrap stage retained a second candidate catalog")
        catalog_names = set(_directory_names(catalog, "catalog bootstrap candidate", 3))
        entries_present = "entries" in catalog_names
        snapshots_present = "snapshots" in catalog_names
        current_present = "current.json" in catalog_names
        next_present = "current.next" in catalog_names
        if snapshots_present and not entries_present:
            _infra("catalog bootstrap stage skipped its entry-directory phase")
        if current_present and next_present:
            _infra("catalog bootstrap stage contains conflicting pointer phases")
        staged_entry = False
        staged_snapshot = False
        if entries_present:
            staged_entry = _verify_optional_stage_file(
                catalog / "entries" / f"{entry_digest[7:]}.json",
                entry_bytes,
                limits.entry_bytes,
                "catalog staged entry",
            )
        if snapshots_present:
            staged_snapshot = _verify_optional_stage_file(
                catalog / "snapshots" / f"{snapshot_digest[7:]}.json",
                snapshot_bytes,
                limits.snapshot_bytes,
                "catalog staged snapshot",
            )
        if staged_snapshot and not staged_entry:
            _infra("catalog bootstrap stage skipped its entry-record phase")
        staged_pointer = False
        for name in ("current.json", "current.next"):
            staged_pointer = (
                _verify_optional_stage_file(
                    catalog / name,
                    pointer_bytes,
                    65_536,
                    "catalog staged pointer",
                )
                or staged_pointer
            )
        if staged_pointer and not (staged_entry and staged_snapshot):
            _infra("catalog bootstrap pointer lacks complete candidate records")
    else:
        staged_entry = _verify_optional_stage_file(
            payload / "entry.json",
            entry_bytes,
            limits.entry_bytes,
            "catalog staged entry",
        )
        staged_snapshot = _verify_optional_stage_file(
            payload / "snapshot.json",
            snapshot_bytes,
            limits.snapshot_bytes,
            "catalog staged snapshot",
        )
        current_present = _verify_optional_stage_file(
            payload / "current.json",
            pointer_bytes,
            65_536,
            "catalog staged pointer",
        )
        next_present = _verify_optional_stage_file(
            payload / "current.next",
            pointer_bytes,
            65_536,
            "catalog staged pointer",
        )
        if current_present and next_present:
            _infra("catalog mutation stage contains conflicting pointer phases")
        staged_pointer = current_present or next_present
        final_entry = entry_digest in physical_state.entries
        final_snapshot = snapshot_digest in physical_state.snapshots
        if staged_snapshot and not (staged_entry or final_entry):
            _infra("catalog staged snapshot lacks candidate entry evidence")
        if staged_pointer and not (
            (staged_entry or final_entry) and (staged_snapshot or final_snapshot)
        ):
            _infra("catalog staged pointer lacks complete candidate record evidence")
        if current_digest == snapshot_digest:
            if staged_pointer or not final_entry or not final_snapshot:
                _infra("committed catalog stage has an impossible publication shape")
        else:
            if (final_entry or final_snapshot) and not staged_pointer:
                _infra("uncommitted catalog stage lost its durable pointer evidence")
    return entry, entry_digest, snapshot, snapshot_digest


def _prepare_stage(
    authority: HomeAuthority,
    entry: dict[str, object],
    entry_digest: str,
    snapshot: dict[str, object],
    snapshot_digest: str,
    intent: dict[str, object],
    limits: CatalogLimits,
    fault: FaultHook | None,
) -> StageState:
    wrapper = authority.staging / OPERATION_WRAPPER
    payload = wrapper / "payload"
    try:
        _fault(fault, "catalog wrapper.before_create")
        _mkdir(wrapper)
        _fault(fault, "catalog wrapper.after_create")
        _write_file(wrapper / "intent.json", canonical(intent) + b"\n", "catalog intent", fault)
        _fsync_directory(wrapper, "catalog intent wrapper", fault)
        _fsync_directory(authority.staging, "catalog intent publication", fault)
        _mkdir(payload)
        if bool(intent["bootstrap"]):
            catalog = payload / "catalog"
            entries = catalog / "entries"
            snapshots = catalog / "snapshots"
            _mkdir(catalog)
            _mkdir(entries)
            _mkdir(snapshots)
            _write_file(
                entries / f"{entry_digest[7:]}.json",
                canonical(entry) + b"\n",
                "catalog staged entry",
                fault,
            )
            _write_file(
                snapshots / f"{snapshot_digest[7:]}.json",
                canonical(snapshot) + b"\n",
                "catalog staged snapshot",
                fault,
            )
            pointer = {"apiVersion": CURRENT_API, "snapshotDigest": snapshot_digest}
            _write_file(catalog / "current.next", canonical(pointer) + b"\n", "catalog staged pointer", fault)
            _fault(fault, "catalog staged pointer.before_replace")
            os.replace(catalog / "current.next", catalog / "current.json")
            _fault(fault, "catalog staged pointer.after_replace")
            _fsync_directory(entries, "catalog staged entries", fault)
            _fsync_directory(snapshots, "catalog staged snapshots", fault)
            _fsync_directory(catalog, "catalog staged root", fault)
        else:
            _write_file(payload / "entry.json", canonical(entry) + b"\n", "catalog staged entry", fault)
            _write_file(payload / "snapshot.json", canonical(snapshot) + b"\n", "catalog staged snapshot", fault)
            pointer = {"apiVersion": CURRENT_API, "snapshotDigest": snapshot_digest}
            _write_file(payload / "current.next", canonical(pointer) + b"\n", "catalog staged pointer", fault)
            _fault(fault, "catalog staged pointer.before_replace")
            os.replace(payload / "current.next", payload / "current.json")
            _fault(fault, "catalog staged pointer.after_replace")
        _fsync_directory(payload, "catalog staged payload", fault)
        _fsync_directory(wrapper, "catalog staged wrapper", fault)
        _fsync_directory(authority.staging, "catalog staged operation", fault)
    except CatalogInfrastructure:
        raise
    except OSError as error:
        _infra("catalog operation could not be staged", error)
    stage = _stage_state(authority, limits)
    if stage is None:
        _infra("catalog operation stage disappeared")
    return stage


def _publish_record(source: Path, target: Path, maximum: int, purpose: str, fault: FaultHook | None) -> None:
    data = _read_file(source, maximum, purpose)
    try:
        target.lstat()
    except FileNotFoundError:
        _fault(fault, f"{purpose}.before_noreplace")
        _rename_noreplace(source, target)
        _fault(fault, f"{purpose}.after_noreplace")
    except OSError as error:
        _infra(f"{purpose} final path cannot be inspected", error)
    else:
        if _read_file(target, maximum, purpose) != data:
            _infra(f"{purpose} conflicts with existing immutable bytes")
        return
    if _read_file(target, maximum, purpose) != data:
        _infra(f"{purpose} no-replace publication changed its immutable bytes")


def _publish_candidate(
    authority: HomeAuthority,
    lock_descriptor: int,
    state: CatalogState,
    stage: StageState,
    limits: CatalogLimits,
    fault: FaultHook | None,
) -> None:
    intent = stage.intent
    candidate = str(intent["candidateSnapshotDigest"])
    payload = stage.path / "payload"
    committed = False
    try:
        if bool(intent["bootstrap"]):
            _set_lock_marker(lock_descriptor, fault)
            _fault(fault, "bootstrap.before_rename")
            _rename_noreplace(payload / "catalog", authority.images / "catalog")
            committed = True
            _fault(fault, "bootstrap.after_rename")
            _fsync_directory(authority.images, "catalog bootstrap parent", fault)
        else:
            assert state.root is not None
            root = state.root
            entries = root / "entries"
            snapshots = root / "snapshots"
            _publish_record(
                payload / "entry.json",
                entries / f"{str(intent['candidateEntryDigest'])[7:]}.json",
                limits.entry_bytes,
                "catalog immutable entry",
                fault,
            )
            _fsync_directory(entries, "catalog immutable entry history", fault)
            _publish_record(
                payload / "snapshot.json",
                snapshots / f"{candidate[7:]}.json",
                limits.snapshot_bytes,
                "catalog immutable snapshot",
                fault,
            )
            _fsync_directory(snapshots, "catalog immutable snapshot history", fault)
            if _read_current_digest(authority) != state.snapshot_digest:
                _infra("catalog current pointer changed before publication")
            _fault(fault, "pointer.before_replace")
            os.replace(payload / "current.json", root / "current.json")
            committed = True
            _fault(fault, "pointer.after_replace")
            _fsync_directory(root, "catalog current pointer", fault)
        verified = _load_catalog(authority, lock_descriptor, limits, inspect_stage=False)
        if verified.snapshot_digest != candidate:
            _infra("catalog publication could not be verified")
        _cleanup_stage(authority, stage, fault)
    except CatalogInfrastructure:
        if not committed:
            try:
                _reconcile(authority, lock_descriptor, limits)
            except CatalogInfrastructure:
                pass
        raise
    except OSError as error:
        if not committed:
            try:
                _reconcile(authority, lock_descriptor, limits)
            except CatalogInfrastructure:
                pass
        _infra("catalog publication is uncertain", error)


def _classified(operation: Callable[[], object]) -> object:
    try:
        return operation()
    except (CatalogReject, CatalogInfrastructure):
        raise
    except (
        AssertionError,
        KeyError,
        OSError,
        RecursionError,
        TypeError,
        ValueError,
        json.JSONDecodeError,
    ) as error:
        _infra("catalog operation encountered unverified state", error)


def add_image(
    home: Path,
    name: str,
    subject: str,
    *,
    fault: FaultHook | None = None,
    limits: CatalogLimits = CatalogLimits(),
) -> dict[str, object]:
    """Create a generation-one mapping, or observe its exact idempotent retry."""

    def operation() -> dict[str, object]:
        if sys.platform != "linux":
            _infra("local image catalog mutations require Linux")
        if not image_name(name) or name.startswith("agent-lab.") or not oci_subject(subject):
            _reject("mapping is invalid or reserved")
        authority = _load_home(home)
        with _catalog_lock(authority, exclusive=True) as lock_descriptor:
            _reconcile(authority, lock_descriptor, limits)
            state = _load_catalog(authority, lock_descriptor, limits)
            prior = state.records.get(name)
            if prior is not None:
                if prior["state"] == "active" and prior["subject"] == subject:
                    return {
                        "changed": False,
                        "entryDigest": prior["entryDigest"],
                        "generation": 1,
                    }
                _reject("name already exists or is tombstoned")
            entry, entry_digest, snapshot, snapshot_digest, intent = _candidate_values(
                state,
                kind="add",
                name=name,
                subject=subject,
                expected_entry_digest=None,
                limits=limits,
            )
            stage = _prepare_stage(
                authority,
                entry,
                entry_digest,
                snapshot,
                snapshot_digest,
                intent,
                limits,
                fault,
            )
            _publish_candidate(authority, lock_descriptor, state, stage, limits, fault)
            return {"changed": True, "entryDigest": entry_digest, "generation": 1}

    result = _classified(operation)
    assert isinstance(result, dict)
    return result


def remove_image(
    home: Path,
    name: str,
    expected_entry_digest: str,
    *,
    fault: FaultHook | None = None,
    limits: CatalogLimits = CatalogLimits(),
) -> dict[str, object]:
    """Publish the one permitted generation-two CAS tombstone."""

    def operation() -> dict[str, object]:
        if sys.platform != "linux":
            _infra("local image catalog mutations require Linux")
        if not image_name(name) or name.startswith("agent-lab.") or not _is_digest(expected_entry_digest):
            _reject("remove request is invalid or reserved")
        authority = _load_home(home)
        with _catalog_lock(authority, exclusive=True) as lock_descriptor:
            _reconcile(authority, lock_descriptor, limits)
            state = _load_catalog(authority, lock_descriptor, limits)
            prior = state.records.get(name)
            if prior is None:
                _reject("name is unknown")
            if prior["state"] == "removed":
                if prior["previousEntryDigest"] == expected_entry_digest:
                    return {
                        "changed": False,
                        "entryDigest": prior["entryDigest"],
                        "generation": 2,
                        "state": "removed",
                    }
                _reject("remove compare-and-swap conflict")
            if prior["entryDigest"] != expected_entry_digest:
                _reject("remove compare-and-swap conflict")
            subject = prior["subject"]
            assert isinstance(subject, str)
            entry, entry_digest, snapshot, snapshot_digest, intent = _candidate_values(
                state,
                kind="remove",
                name=name,
                subject=subject,
                expected_entry_digest=expected_entry_digest,
                limits=limits,
            )
            stage = _prepare_stage(
                authority,
                entry,
                entry_digest,
                snapshot,
                snapshot_digest,
                intent,
                limits,
                fault,
            )
            _publish_candidate(authority, lock_descriptor, state, stage, limits, fault)
            return {
                "changed": True,
                "entryDigest": entry_digest,
                "generation": 2,
                "state": "removed",
            }

    result = _classified(operation)
    assert isinstance(result, dict)
    return result


def list_images(
    home: Path,
    *,
    include_removed: bool = False,
    limits: CatalogLimits = CatalogLimits(),
) -> list[dict[str, object]]:
    """Return a canonical byte-sorted held view without repair or initialization."""

    def operation() -> list[dict[str, object]]:
        authority = _load_home(home)
        with _catalog_lock(authority, exclusive=False) as lock_descriptor:
            state = _load_catalog(authority, lock_descriptor, limits)
            return [
                dict(state.records[name])
                for name in sorted(state.records, key=lambda item: item.encode("ascii"))
                if include_removed or state.records[name]["state"] == "active"
            ]

    result = _classified(operation)
    assert isinstance(result, list)
    return result


def inspect_image(
    home: Path,
    name: str,
    *,
    limits: CatalogLimits = CatalogLimits(),
) -> dict[str, object]:
    """Return one exact active/tombstoned record without repair."""

    def operation() -> dict[str, object]:
        if not image_name(name) or name.startswith("agent-lab."):
            _reject("name is invalid or reserved")
        authority = _load_home(home)
        with _catalog_lock(authority, exclusive=False) as lock_descriptor:
            state = _load_catalog(authority, lock_descriptor, limits)
            record = state.records.get(name)
            if record is None:
                _reject("name is unknown")
            return dict(record)

    result = _classified(operation)
    assert isinstance(result, dict)
    return result


@contextmanager
def hold_local_image_entries(
    home: Path,
    dependencies: Sequence[dict[str, object]],
    *,
    limits: CatalogLimits = CatalogLimits(),
    fault: FaultHook | None = None,
) -> Iterator[dict[str, object]]:
    """Hold one verified snapshot while exact active dependencies are consumed."""

    try:
        requested = tuple(dependencies)
    except (TypeError, ValueError) as error:
        _infra("selected local image dependencies are malformed", error)

    expected: dict[str, dict[str, object]] = {}
    for dependency in requested:
        if not isinstance(dependency, dict) or set(dependency) != {
            "entryDigest",
            "generation",
            "name",
            "subject",
        }:
            _infra("selected local image dependency schema is not closed")
        name = dependency.get("name")
        entry_digest = dependency.get("entryDigest")
        generation = dependency.get("generation")
        subject = dependency.get("subject")
        if (
            not isinstance(name, str)
            or not image_name(name)
            or name.startswith("agent-lab.")
            or not _is_digest(entry_digest)
            or type(generation) is not int
            or generation != 1
            or not isinstance(subject, str)
            or not oci_subject(subject)
        ):
            _infra("selected local image dependency binding is invalid")
        prior = expected.get(name)
        if prior is not None and prior != dependency:
            _infra("selected local image dependencies contradict one another")
        expected[name] = dict(dependency)

    if not expected:
        yield {"catalog": None, "records": {}}
        return

    authority = _load_home(home)
    with _catalog_lock(authority, exclusive=False) as lock_descriptor:
        _fault(fault, "experiment catalog lock.after_acquire")
        state = _load_catalog(authority, lock_descriptor, limits)
        selected: dict[str, dict[str, object]] = {}
        for name in sorted(expected, key=lambda item: item.encode("ascii")):
            record = state.records.get(name)
            if record is None or record["state"] != "active":
                _reject("selected local image dependency is unknown or inactive")
            dependency = expected[name]
            if any(
                record[field] != dependency[field]
                for field in ("name", "entryDigest", "generation", "subject")
            ):
                _reject("selected local image dependency has drifted")
            selected[name] = dict(record)
        if state.snapshot_digest is None or state.revision < 1:
            _infra("selected local image dependencies have no committed snapshot")
        yield {
            "catalog": {
                "revision": state.revision,
                "snapshotDigest": state.snapshot_digest,
            },
            "records": selected,
        }


def resolve_local_images(
    home: Path,
    names: Sequence[str],
    *,
    limits: CatalogLimits = CatalogLimits(),
) -> dict[str, object]:
    """Resolve every selected local name from one verified held snapshot."""

    def operation() -> dict[str, object]:
        requested = tuple(names)
        if (
            not requested
            or len(set(requested)) != len(requested)
            or any(not image_name(name) or name.startswith("agent-lab.") for name in requested)
        ):
            _reject("local image selection is invalid")
        authority = _load_home(home)
        with _catalog_lock(authority, exclusive=False) as lock_descriptor:
            state = _load_catalog(authority, lock_descriptor, limits)
            selected: dict[str, dict[str, object]] = {}
            for name in sorted(requested, key=lambda item: item.encode("ascii")):
                record = state.records.get(name)
                if record is None or record["state"] != "active":
                    _reject("references an unknown or removed local image name")
                selected[name] = dict(record)
            if state.snapshot_digest is None or state.revision < 1:
                _infra("local image resolution has no committed snapshot")
            return {
                "catalog": {
                    "revision": state.revision,
                    "snapshotDigest": state.snapshot_digest,
                },
                "records": selected,
            }

    result = _classified(operation)
    assert isinstance(result, dict)
    return result
