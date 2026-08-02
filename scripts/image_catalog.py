#!/usr/bin/env python3
"""Verified, durable operator-local image-name catalog."""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
import ctypes
import errno
import fcntl
import hashlib
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
LOCK_MARKER = b"catalog:v0alpha1\n"
SAFE_COMPONENT = re.compile(r"^[a-z][a-z0-9-]{0,47}$")
IMAGE_COMPONENT = re.compile(r"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$")
SHA256 = re.compile(r"^sha256:[0-9a-f]{64}$")
OCI_SUBJECT = re.compile(
    r"^([a-z0-9]+([.-][a-z0-9]+)*"
    r"(:(?:[1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|"
    r"65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5]))?/)?"
    r"[a-z0-9]+([._-][a-z0-9]+)*"
    r"(/[a-z0-9]+([._-][a-z0-9]+)*)*"
    r"@sha256:[0-9a-f]{64}$"
)
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


@dataclass(frozen=True)
class CatalogState:
    root: Path | None
    revision: int
    snapshot_digest: str | None
    previous_snapshot_digest: str | None
    records: dict[str, dict[str, object]]
    entries: dict[str, dict[str, object]]
    snapshots: dict[str, dict[str, object]]
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


def image_name(value: object) -> bool:
    if not isinstance(value, str) or not value.isascii():
        return False
    encoded = value.encode("ascii")
    parts = value.split(".")
    return (
        len(encoded) <= 63
        and len(parts) == 2
        and all(1 <= len(part.encode("ascii")) <= 31 for part in parts)
        and all(IMAGE_COMPONENT.fullmatch(part) is not None for part in parts)
    )


def oci_subject(value: object) -> bool:
    return (
        isinstance(value, str)
        and value.isascii()
        and 1 <= len(value.encode("ascii")) <= 255
        and OCI_SUBJECT.fullmatch(value) is not None
    )


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
    except (UnicodeError, ValueError, json.JSONDecodeError) as error:
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
    if (
        set(receipt) != {"apiVersion", "configDigest", "paths"}
        or receipt.get("apiVersion") != "agent-lab.home/v0alpha1"
        or receipt.get("configDigest") != digest
        or receipt.get("paths") != paths
    ):
        _infra("Agent Lab configuration does not match its home receipt")
    images = home / str(paths["images"])
    state = home / str(paths["state"])
    staging = images / ".staging"
    locks = state / "locks"
    for path in (images, state, staging, locks):
        _verify_directory(path)
    lock = locks / "image-catalog.lock"
    return HomeAuthority(home, images, staging, state, locks, lock)


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
        or lexical.st_size > len(LOCK_MARKER)
    ):
        _infra("catalog lock metadata is unsafe")
    try:
        descriptor = os.open(
            path,
            os.O_RDWR | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
        )
        opened = os.fstat(descriptor)
        if _file_identity(opened) != _file_identity(lexical):
            raise OSError("lock identity changed")
        fcntl.flock(descriptor, fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)
        current = path.lstat()
        held = os.fstat(descriptor)
        if (held.st_dev, held.st_ino) != (current.st_dev, current.st_ino):
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
        data = os.read(descriptor, len(LOCK_MARKER) + 1)
        os.lseek(descriptor, 0, os.SEEK_SET)
    except OSError as error:
        _infra("catalog lock marker cannot be read", error)
    if data not in (b"", LOCK_MARKER):
        _infra("catalog lock marker is malformed")
    return data


def _set_lock_marker(descriptor: int) -> None:
    try:
        os.lseek(descriptor, 0, os.SEEK_SET)
        os.ftruncate(descriptor, 0)
        _write_all(descriptor, LOCK_MARKER)
        os.fsync(descriptor)
        os.lseek(descriptor, 0, os.SEEK_SET)
    except OSError as error:
        _infra("catalog initialization marker could not be persisted", error)


def _write_all(descriptor: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise OSError("write made no progress")
        view = view[written:]


def _directory_names(path: Path, purpose: str) -> tuple[str, ...]:
    _verify_directory(path)
    try:
        before = path.lstat()
        names = tuple(sorted(os.listdir(path), key=os.fsencode))
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


def _stage_state(authority: HomeAuthority, limits: CatalogLimits) -> StageState | None:
    names = _directory_names(authority.staging, "catalog staging root")
    if not names:
        return None
    if names != (OPERATION_WRAPPER,):
        _infra("catalog staging root contains an unknown wrapper")
    wrapper = authority.staging / OPERATION_WRAPPER
    _verify_directory(wrapper)
    wrapper_names = _directory_names(wrapper, "catalog operation wrapper")
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
        try:
            descendants = sorted(payload.rglob("*"), key=lambda item: os.fsencode(str(item.relative_to(payload))))
        except OSError as error:
            _infra("catalog staging payload cannot be enumerated", error)
        for item in descendants:
            relative = str(item.relative_to(payload))
            if relative not in allowed:
                _infra("catalog staging payload contains an unknown entry")
            metadata = item.lstat()
            entry_count += 1
            if metadata.st_uid != os.getuid() or stat.S_ISLNK(metadata.st_mode):
                _infra("catalog staging payload metadata is unsafe")
            if stat.S_ISDIR(metadata.st_mode):
                if stat.S_IMODE(metadata.st_mode) != 0o700:
                    _infra("catalog staging directory mode is unsafe")
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
    image_names = _directory_names(authority.images, "effective images directory")
    allowed_images = {".staging", "catalog"}
    if any(name not in allowed_images for name in image_names):
        _infra("effective images directory contains unknown catalog state")
    root = authority.images / "catalog"
    try:
        root_metadata = root.lstat()
    except FileNotFoundError:
        if marker == LOCK_MARKER:
            _infra("an initialized image catalog is missing")
        if stage is not None and not bool(stage.intent.get("bootstrap")):
            _infra("non-bootstrap catalog stage has no committed base")
        return CatalogState(None, 0, None, None, {}, {}, {}, 0)
    except OSError as error:
        _infra("image catalog cannot be inspected", error)
    if not stat.S_ISDIR(root_metadata.st_mode) or stat.S_ISLNK(root_metadata.st_mode):
        _infra("image catalog path is unsafe")
    _verify_directory(root)
    root_names = _directory_names(root, "image catalog")
    if set(root_names) != {"current.json", "entries", "snapshots"}:
        _infra("image catalog layout is incomplete or unknown")
    entries_root = root / "entries"
    snapshots_root = root / "snapshots"
    entry_names = _directory_names(entries_root, "image entry history")
    snapshot_names = _directory_names(snapshots_root, "image snapshot history")
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
        entry_names != _directory_names(entries_root, "image entry history")
        or snapshot_names != _directory_names(snapshots_root, "image snapshot history")
        or root_names != _directory_names(root, "image catalog")
    ):
        _infra("image catalog changed during verification")
    return CatalogState(
        root,
        int(current["revision"]),
        current_digest,
        current["previousSnapshotDigest"] if isinstance(current["previousSnapshotDigest"], str) else None,
        records,
        entries,
        snapshots,
        physical_bytes,
    )


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


def _remove_owned_tree(path: Path) -> None:
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
        except OSError as error:
            _infra("catalog staging file could not be cleaned", error)
        return
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o700:
        _infra("catalog staging cleanup type is unsafe")
    try:
        children = tuple(path.iterdir())
    except OSError as error:
        _infra("catalog staging cleanup cannot enumerate its target", error)
    for child in sorted(children, key=lambda item: os.fsencode(item.name)):
        _remove_owned_tree(child)
    try:
        path.rmdir()
    except OSError as error:
        _infra("catalog staging directory could not be cleaned", error)


def _cleanup_stage(authority: HomeAuthority, stage: StageState | None = None) -> None:
    path = authority.staging / OPERATION_WRAPPER
    if stage is not None and stage.path != path:
        _infra("catalog staging cleanup target changed")
    _remove_owned_tree(path)
    _fsync_directory(authority.staging, "catalog staging cleanup")


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


def _remove_uncommitted_record(path: Path, preexisting: bool) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return
    except OSError as error:
        _infra("uncommitted catalog record cannot be inspected", error)
    if preexisting:
        return
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or stat.S_IMODE(metadata.st_mode) != 0o600
        or metadata.st_nlink != 1
    ):
        _infra("uncommitted catalog record metadata is unsafe")
    try:
        path.unlink()
    except OSError as error:
        _infra("uncommitted catalog record could not be reconciled", error)


def _reconcile(authority: HomeAuthority, lock_descriptor: int, limits: CatalogLimits) -> None:
    stage = _stage_state(authority, limits)
    if stage is None:
        return
    intent = stage.intent
    candidate = str(intent["candidateSnapshotDigest"])
    base_value = intent["baseSnapshotDigest"]
    base = str(base_value) if base_value is not None else None
    current = _read_current_digest(authority)
    if current == candidate:
        _load_catalog(authority, lock_descriptor, limits, inspect_stage=False)
        if _lock_bytes(lock_descriptor) == b"":
            _set_lock_marker(lock_descriptor)
        _cleanup_stage(authority, stage)
        return
    if current != base:
        _infra("catalog staged operation cannot be reconciled with current state")
    if bool(intent["bootstrap"]):
        if current is not None:
            _infra("catalog bootstrap stage conflicts with a final catalog")
    else:
        root = authority.images / "catalog"
        entries = root / "entries"
        snapshots = root / "snapshots"
        _remove_uncommitted_record(
            entries / f"{str(intent['candidateEntryDigest'])[7:]}.json",
            bool(intent["entryPreexisting"]),
        )
        _remove_uncommitted_record(
            snapshots / f"{candidate[7:]}.json",
            bool(intent["snapshotPreexisting"]),
        )
        _fsync_directory(entries, "catalog reconciled entry history")
        _fsync_directory(snapshots, "catalog reconciled snapshot history")
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


def _prepare_stage(
    authority: HomeAuthority,
    entry: dict[str, object],
    entry_digest: str,
    snapshot: dict[str, object],
    snapshot_digest: str,
    intent: dict[str, object],
    fault: FaultHook | None,
) -> StageState:
    wrapper = authority.staging / OPERATION_WRAPPER
    payload = wrapper / "payload"
    try:
        _mkdir(wrapper)
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
            os.replace(catalog / "current.next", catalog / "current.json")
            _fsync_directory(entries, "catalog staged entries", fault)
            _fsync_directory(snapshots, "catalog staged snapshots", fault)
            _fsync_directory(catalog, "catalog staged root", fault)
        else:
            _write_file(payload / "entry.json", canonical(entry) + b"\n", "catalog staged entry", fault)
            _write_file(payload / "snapshot.json", canonical(snapshot) + b"\n", "catalog staged snapshot", fault)
            pointer = {"apiVersion": CURRENT_API, "snapshotDigest": snapshot_digest}
            _write_file(payload / "current.next", canonical(pointer) + b"\n", "catalog staged pointer", fault)
            os.replace(payload / "current.next", payload / "current.json")
        _fsync_directory(payload, "catalog staged payload", fault)
        _fsync_directory(wrapper, "catalog staged wrapper", fault)
        _fsync_directory(authority.staging, "catalog staged operation", fault)
    except CatalogInfrastructure:
        try:
            _remove_owned_tree(wrapper)
            _fsync_directory(authority.staging, "catalog failed-stage cleanup")
        except CatalogInfrastructure:
            pass
        raise
    except OSError as error:
        try:
            _remove_owned_tree(wrapper)
            _fsync_directory(authority.staging, "catalog failed-stage cleanup")
        except CatalogInfrastructure:
            pass
        _infra("catalog operation could not be staged", error)
    stage = _stage_state(authority, CatalogLimits())
    if stage is None:
        _infra("catalog operation stage disappeared")
    return stage


def _publish_record(source: Path, target: Path, maximum: int, purpose: str, fault: FaultHook | None) -> None:
    data = _read_file(source, maximum, purpose)
    try:
        target.lstat()
    except FileNotFoundError:
        _write_file(target, data, purpose, fault)
    except OSError as error:
        _infra(f"{purpose} final path cannot be inspected", error)
    else:
        if _read_file(target, maximum, purpose) != data:
            _infra(f"{purpose} conflicts with existing immutable bytes")


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
            _fault(fault, "bootstrap.before_rename")
            _rename_noreplace(payload / "catalog", authority.images / "catalog")
            committed = True
            _fault(fault, "bootstrap.after_rename")
            _fsync_directory(authority.images, "catalog bootstrap parent", fault)
            _set_lock_marker(lock_descriptor)
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
        _cleanup_stage(authority, stage)
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
    except (AssertionError, KeyError, OSError, TypeError, ValueError, json.JSONDecodeError) as error:
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


@contextmanager
def hold_live_bindings(
    home: Path,
    bindings: Sequence[dict[str, object]],
    *,
    limits: CatalogLimits = CatalogLimits(),
) -> Iterator[dict[str, object]]:
    """Hold the shared catalog lock while PR4 publishes a selected plan."""

    authority = _load_home(home)
    with _catalog_lock(authority, exclusive=False) as lock_descriptor:
        state = _load_catalog(authority, lock_descriptor, limits)
        for binding in bindings:
            name = binding.get("name")
            expected = binding.get("entryDigest")
            record = state.records.get(str(name))
            if record is None or record["state"] != "active" or record["entryDigest"] != expected:
                _reject("selected local image entry is no longer active")
        if state.snapshot_digest is None:
            _infra("selected local image snapshot is unavailable")
        yield {"revision": state.revision, "snapshotDigest": state.snapshot_digest}
