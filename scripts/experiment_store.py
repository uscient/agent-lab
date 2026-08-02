#!/usr/bin/env python3
"""Durable, permit-gated publication of verified Experiment envelopes."""

from __future__ import annotations

from contextlib import contextmanager, nullcontext
from contextvars import ContextVar
import ctypes
import errno
import fcntl
import hashlib
from importlib.util import module_from_spec, spec_from_file_location
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
from typing import Callable, Iterator, NamedTuple, NoReturn, Sequence


INSTALL_KEY_DOMAIN = b"agent-lab.experiment-installation-key.v1\0"
DECISION_DOMAIN = b"agent-lab.experiment-decision.v1\0"
PROVENANCE_DOMAIN = b"agent-lab.experiment-provenance.v1\0"
RECEIPT_DOMAIN = b"agent-lab.experiment-install-receipt.v1\0"
SOURCE_DIGEST_DOMAIN = b"agent-lab.experiment-tree.v1\0"
STAGE_PAYLOAD_DOMAIN = b"agent-lab.experiment-stage-payload.v1\0"
INSTALL_API = "agent-lab.experiment-install/v0alpha1"
PROVENANCE_API = "agent-lab.experiment-provenance/v0alpha1"
INTENT_API = "agent-lab.experiment-install-intent/v0alpha1"
LOCK_SCHEMA = "agent-lab.experiments-lock/v0alpha1"
OPERATION_WRAPPER = "experiment-install"
CLEANUP_WRAPPER = "experiment-install-cleanup"
OWNERSHIP_MARKER = "owner"
OWNERSHIP_BYTES = b"agent-lab.experiment-stage-owner/v0alpha1\n"
MAX_STAGE_ENTRIES = 16
MAX_STAGE_BYTES = 4_194_304
MAX_AUTHORITY_BYTES = 65_536
MAX_ARTIFACT_BYTES = 262_144
MAX_RECORD_BYTES = 1_048_576
SAFE_COMPONENT = re.compile(r"^[a-z][a-z0-9-]{0,47}$")
EXPERIMENT_NAME = re.compile(r"^[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$")
IMAGE_COMPONENT = re.compile(r"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$")
SHA256 = re.compile(r"^sha256:[0-9a-f]{64}$")
PAYLOAD_DIRECTORIES = {"payload", "payload/artifact", "payload/records"}
PAYLOAD_FILES = {
    "payload/artifact/experiment.cue",
    "payload/records/decision.json",
    "payload/records/install.json",
    "payload/records/plan.json",
    "payload/records/provenance.json",
}
STAGE_ALLOWED = {OWNERSHIP_MARKER, "intent.json", *PAYLOAD_DIRECTORIES, *PAYLOAD_FILES}
RECORD_PATHS = {
    "artifact/experiment.cue",
    "records/decision.json",
    "records/plan.json",
    "records/provenance.json",
}

FaultHook = Callable[[str], None]


class StoreError(Exception):
    """Base class for classified Experiment-store failures."""


class StoreReject(StoreError):
    """The requested operation is a safe ordinary rejection."""


class StoreInfrastructure(StoreError):
    """The store could not establish a trustworthy result."""


class DuplicateKey(ValueError):
    """A JSON object contains a duplicate decoded key."""


class HomeAuthority(NamedTuple):
    home: Path
    store: Path
    staging: Path
    state: Path
    locks: Path
    lock: Path
    lock_device: int
    lock_inode: int
    config_raw: bytes
    receipt_raw: bytes
    store_device: int


class VerifiedInstall(NamedTuple):
    name: str
    installation_key: str
    receipt_digest: str
    file_digests: dict[str, str]


class ScannedWrapper(NamedTuple):
    intent: dict[str, object] | None
    has_payload: bool


def canonical(value: object) -> bytes:
    try:
        return json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=True,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("ascii")
    except (RecursionError, TypeError, ValueError, UnicodeError) as error:
        raise StoreInfrastructure("store data cannot be encoded canonically") from error


def digest(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def _reject(message: str) -> NoReturn:
    raise StoreReject(message)


def _infra(message: str, error: BaseException | None = None) -> NoReturn:
    if error is None:
        raise StoreInfrastructure(message)
    raise StoreInfrastructure(message) from error


def _fault(hook: FaultHook | None, point: str) -> None:
    if hook is not None:
        hook(point)


def _pairs(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateKey(key)
        result[key] = value
    return result


def _nonfinite(value: str) -> NoReturn:
    raise ValueError(value)


def _parse_object(data: bytes, purpose: str) -> dict[str, object]:
    try:
        text = data.decode("ascii")
        value = json.loads(
            text,
            object_pairs_hook=_pairs,
            parse_constant=_nonfinite,
        )
        _reject_nonfinite(value)
    except (DuplicateKey, UnicodeError, json.JSONDecodeError, RecursionError, ValueError) as error:
        _infra(f"{purpose} is not bounded canonical JSON", error)
    if not isinstance(value, dict):
        _infra(f"{purpose} is not one JSON object")
    if data != canonical(value) + b"\n":
        _infra(f"{purpose} is not canonical")
    return value


def _reject_nonfinite(value: object) -> None:
    if isinstance(value, float) and not math.isfinite(value):
        raise ValueError("non-finite number")
    if isinstance(value, dict):
        for item in value.values():
            _reject_nonfinite(item)
    elif isinstance(value, list):
        for item in value:
            _reject_nonfinite(item)


def _identity(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _absolute_directory_chain(path: Path) -> None:
    if not path.is_absolute() or path == Path("/") or os.path.normpath(str(path)) != str(path):
        _infra("Agent Lab home path is not an absolute canonical non-root path")
    current = Path("/")
    for component in path.parts[1:]:
        current /= component
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            _reject("Agent Lab home is not initialized")
        except OSError as error:
            _infra("Agent Lab home path cannot be inspected", error)
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            _infra("Agent Lab home path contains an unsafe component")


def _verify_directory(
    path: Path,
    *,
    modes: tuple[int, ...] = (0o700,),
    device: int | None = None,
) -> os.stat_result:
    try:
        lexical = path.lstat()
        descriptor = os.open(
            path,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
    except OSError as error:
        _infra("store directory is unavailable", error)
    try:
        opened = os.fstat(descriptor)
    except OSError as error:
        try:
            os.close(descriptor)
        except OSError:
            pass
        _infra("store directory cannot be verified", error)
    try:
        os.close(descriptor)
    except OSError as error:
        _infra("store directory descriptor cannot be closed", error)
    for metadata in (lexical, opened):
        if (
            stat.S_ISLNK(metadata.st_mode)
            or not stat.S_ISDIR(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) not in modes
            or (device is not None and metadata.st_dev != device)
        ):
            _infra("store directory metadata is unsafe")
    if (lexical.st_dev, lexical.st_ino) != (opened.st_dev, opened.st_ino):
        _infra("store directory identity changed")
    return opened


def _read_file(
    path: Path,
    maximum: int,
    purpose: str,
    *,
    mode: int,
    device: int | None = None,
) -> bytes:
    try:
        lexical = path.lstat()
        if (
            stat.S_ISLNK(lexical.st_mode)
            or not stat.S_ISREG(lexical.st_mode)
            or lexical.st_uid != os.getuid()
            or lexical.st_nlink != 1
            or stat.S_IMODE(lexical.st_mode) != mode
            or lexical.st_size > maximum
            or (device is not None and lexical.st_dev != device)
        ):
            _infra(f"{purpose} metadata is unsafe")
        descriptor = os.open(
            path,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_NONBLOCK", 0),
        )
    except StoreError:
        raise
    except OSError as error:
        _infra(f"{purpose} is unavailable", error)
    try:
        opened = os.fstat(descriptor)
        chunks: list[bytes] = []
        remaining = maximum + 1
        while remaining:
            chunk = os.read(descriptor, min(65_536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        final = os.fstat(descriptor)
    except OSError as error:
        _infra(f"{purpose} cannot be read safely", error)
    finally:
        try:
            os.close(descriptor)
        except OSError as error:
            _infra(f"{purpose} descriptor cannot be closed", error)
    try:
        current = path.lstat()
    except OSError as error:
        _infra(f"{purpose} cannot be reverified", error)
    for metadata in (opened, final, current):
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or metadata.st_nlink != 1
            or stat.S_IMODE(metadata.st_mode) != mode
            or metadata.st_size > maximum
            or (device is not None and metadata.st_dev != device)
        ):
            _infra(f"{purpose} metadata changed unsafely")
    if (
        len(data) > maximum
        or len(data) != final.st_size
        or _identity(lexical) != _identity(opened)
        or _identity(opened) != _identity(final)
        or _identity(final) != _identity(current)
    ):
        _infra(f"{purpose} changed while being read")
    return data


def _load_home(home: Path) -> HomeAuthority:
    try:
        _absolute_directory_chain(home)
        _verify_directory(home)
        config_path = home / "config.json"
        receipt_path = home / "home.json"
        try:
            config_raw = _read_file(
                config_path,
                MAX_AUTHORITY_BYTES,
                "Agent Lab configuration",
                mode=0o600,
            )
            receipt_raw = _read_file(
                receipt_path,
                MAX_AUTHORITY_BYTES,
                "Agent Lab home receipt",
                mode=0o600,
            )
        except StoreInfrastructure:
            if not os.path.lexists(config_path) and not os.path.lexists(receipt_path):
                _reject("Agent Lab home is not initialized")
            raise
        config = _parse_object(config_raw, "Agent Lab configuration")
        receipt = _parse_object(receipt_raw, "Agent Lab home receipt")
        if set(config) != {"apiVersion", "paths"} or config.get("apiVersion") != "agent-lab.config/v0alpha1":
            _infra("Agent Lab configuration schema is not closed")
        paths = config.get("paths")
        if (
            not isinstance(paths, dict)
            or set(paths) != {"experiments", "images", "cache", "state"}
            or len(set(paths.values())) != 4
            or any(
                not isinstance(item, str) or SAFE_COMPONENT.fullmatch(item) is None
                for item in paths.values()
            )
        ):
            _infra("Agent Lab configuration paths are unsafe")
        expected_config_digest = digest(canonical(config))
        locks_value = receipt.get("locks")
        if (
            set(receipt) != {"apiVersion", "configDigest", "locks", "paths"}
            or receipt.get("apiVersion") != "agent-lab.home/v0alpha1"
            or receipt.get("configDigest") != expected_config_digest
            or receipt.get("paths") != paths
            or not isinstance(locks_value, dict)
            or set(locks_value) != {"experiments", "imageCatalog"}
        ):
            _infra("Agent Lab home receipt is not closed")
        lock_record = locks_value.get("experiments")
        expected_lock_path = f"{paths['state']}/locks/experiments.lock"
        if (
            not isinstance(lock_record, dict)
            or set(lock_record) != {"device", "inode", "path", "schema"}
            or type(lock_record.get("device")) is not int
            or type(lock_record.get("inode")) is not int
            or lock_record.get("path") != expected_lock_path
            or lock_record.get("schema") != LOCK_SCHEMA
        ):
            _infra("Experiment store lock authority is absent from the home receipt")
        store = home / str(paths["experiments"])
        state = home / str(paths["state"])
        staging = store / ".staging"
        locks = state / "locks"
        store_metadata = _verify_directory(store)
        _verify_directory(state)
        _verify_directory(locks)
        _verify_directory(staging, device=store_metadata.st_dev)
        lock = locks / "experiments.lock"
        try:
            lock_metadata = lock.lstat()
        except OSError as error:
            _infra("Experiment store lock is unavailable", error)
        if (
            lock_metadata.st_dev != lock_record["device"]
            or lock_metadata.st_ino != lock_record["inode"]
        ):
            _infra("Experiment store lock identity does not match the home receipt")
        return HomeAuthority(
            home,
            store,
            staging,
            state,
            locks,
            lock,
            int(lock_record["device"]),
            int(lock_record["inode"]),
            config_raw,
            receipt_raw,
            store_metadata.st_dev,
        )
    except StoreError:
        raise
    except OSError as error:
        _infra("Agent Lab home cannot be validated", error)


def _revalidate_authority(authority: HomeAuthority) -> None:
    if (
        _read_file(
            authority.home / "config.json",
            MAX_AUTHORITY_BYTES,
            "Agent Lab configuration",
            mode=0o600,
        )
        != authority.config_raw
        or _read_file(
            authority.home / "home.json",
            MAX_AUTHORITY_BYTES,
            "Agent Lab home receipt",
            mode=0o600,
        )
        != authority.receipt_raw
    ):
        _infra("Agent Lab configuration changed during installation")
    store = _verify_directory(authority.store)
    _verify_directory(authority.state)
    _verify_directory(authority.locks)
    _verify_directory(authority.staging, device=store.st_dev)
    if store.st_dev != authority.store_device:
        _infra("Experiment store filesystem changed during installation")


@contextmanager
def _store_lock(
    authority: HomeAuthority,
    fault: FaultHook | None,
    *,
    exclusive: bool = True,
) -> Iterator[int]:
    maximum = len(LOCK_SCHEMA.encode("ascii") + b"\n")
    path = authority.lock
    descriptor = -1
    try:
        lexical = path.lstat()
        if (
            not stat.S_ISREG(lexical.st_mode)
            or stat.S_ISLNK(lexical.st_mode)
            or lexical.st_uid != os.getuid()
            or lexical.st_nlink != 1
            or stat.S_IMODE(lexical.st_mode) != 0o600
            or lexical.st_size != maximum
            or (lexical.st_dev, lexical.st_ino)
            != (authority.lock_device, authority.lock_inode)
        ):
            _infra("Experiment store lock metadata is unsafe")
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
            or opened.st_nlink != 1
            or stat.S_IMODE(opened.st_mode) != 0o600
            or opened.st_size != maximum
            or (opened.st_dev, opened.st_ino)
            != (authority.lock_device, authority.lock_inode)
        ):
            _infra("Experiment store lock identity changed before acquisition")
        fcntl.flock(descriptor, fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)
        held = os.fstat(descriptor)
        current = path.lstat()
        expected = (authority.lock_device, authority.lock_inode)
        if (
            _identity(opened) != _identity(held)
            or (current.st_dev, current.st_ino) != expected
            or not stat.S_ISREG(current.st_mode)
            or current.st_uid != os.getuid()
            or current.st_nlink != 1
            or stat.S_IMODE(current.st_mode) != 0o600
            or current.st_size != maximum
        ):
            _infra("Experiment store lock path changed while acquiring it")
        os.lseek(descriptor, 0, os.SEEK_SET)
        if os.read(descriptor, maximum + 1) != LOCK_SCHEMA.encode("ascii") + b"\n":
            _infra("Experiment store lock receipt is malformed")
        os.lseek(descriptor, 0, os.SEEK_SET)
        if exclusive:
            _fault(fault, "experiment store lock.after_acquire")
        yield descriptor
    except StoreError:
        raise
    except OSError as error:
        _infra("Experiment store lock cannot be held safely", error)
    finally:
        if descriptor >= 0:
            release_error: OSError | None = None
            close_error: OSError | None = None
            try:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
            except OSError as error:
                release_error = error
            try:
                os.close(descriptor)
            except OSError as error:
                close_error = error
            if release_error is not None or close_error is not None:
                cause = close_error if close_error is not None else release_error
                _infra("Experiment store lock release or close is uncertain", cause)


def _module(path: Path, name: str):
    spec = spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        _infra(f"{path.name} cannot be loaded")
    value = module_from_spec(spec)
    sys.modules[spec.name] = value
    try:
        spec.loader.exec_module(value)
    except (ImportError, OSError) as error:
        _infra(f"{path.name} cannot be loaded", error)
    return value


def _experiment_module():
    return _module(Path(__file__).resolve().with_name("experiment.py"), "agent_lab_experiment_store_planning")


def _catalog_module():
    return _module(Path(__file__).resolve().with_name("image_catalog.py"), "agent_lab_experiment_store_catalog")


def _selected_entries(plan: dict[str, object]) -> list[dict[str, object]]:
    try:
        members = plan["spec"]["members"]  # type: ignore[index]
        if not isinstance(members, list):
            raise ValueError("members")
        selected: dict[tuple[str, str], dict[str, object]] = {}
        for member in members:
            if not isinstance(member, dict):
                raise ValueError("member")
            requested = member["requestedSelector"]
            resolved = member["resolvedImage"]
            if not isinstance(requested, dict) or not isinstance(resolved, dict):
                raise ValueError("selector")
            origin = resolved.get("origin")
            if origin == "direct":
                if set(resolved) != {"origin", "subject"} or set(requested) != {"digestRef"}:
                    raise ValueError("direct selector")
                continue
            if (
                origin not in {"agent-lab", "local"}
                or set(requested) != {"catalogName"}
                or set(resolved) != {"entryDigest", "generation", "origin", "subject"}
            ):
                raise ValueError("catalog selector")
            name = requested["catalogName"]
            entry = {
                "entryDigest": resolved["entryDigest"],
                "generation": resolved["generation"],
                "name": name,
                "origin": origin,
                "subject": resolved["subject"],
            }
            if (
                not _image_name(name)
                or SHA256.fullmatch(str(entry["entryDigest"])) is None
                or type(entry["generation"]) is not int
                or int(entry["generation"]) < 1
                or not isinstance(entry["subject"], str)
            ):
                raise ValueError("selected identity")
            key = (str(origin), name)
            if key in selected and selected[key] != entry:
                raise ValueError("inconsistent selected identity")
            selected[key] = entry
        return [
            selected[key]
            for key in sorted(
                selected,
                key=lambda item: (item[0].encode(), item[1].encode()),
            )
        ]
    except (KeyError, TypeError, ValueError) as error:
        _infra("Experiment plan has invalid selected-entry identities", error)


def _local_dependencies(selected: Sequence[dict[str, object]]) -> tuple[dict[str, object], ...]:
    return tuple(
        {
            "entryDigest": item["entryDigest"],
            "generation": item["generation"],
            "name": item["name"],
            "subject": item["subject"],
        }
        for item in selected
        if item["origin"] == "local"
    )


def _verify_held_catalog(
    held: object,
    dependencies: Sequence[dict[str, object]],
) -> None:
    try:
        if not isinstance(held, dict) or set(held) != {"catalog", "records"}:
            raise ValueError("held envelope")
        catalog = held["catalog"]
        records = held["records"]
        names = {str(item["name"]) for item in dependencies}
        if (
            not isinstance(catalog, dict)
            or set(catalog) != {"revision", "snapshotDigest"}
            or type(catalog.get("revision")) is not int
            or int(catalog["revision"]) < 1
            or SHA256.fullmatch(str(catalog.get("snapshotDigest"))) is None
            or not isinstance(records, dict)
            or set(records) != names
        ):
            raise ValueError("held catalog evidence")
        by_name = {str(item["name"]): item for item in dependencies}
        for name in names:
            record = records[name]
            expected = by_name[name]
            if (
                not isinstance(record, dict)
                or record.get("name") != name
                or record.get("state") != "active"
                or record.get("entryDigest") != expected["entryDigest"]
                or record.get("generation") != expected["generation"]
                or record.get("subject") != expected["subject"]
            ):
                raise ValueError("held selected entry")
    except (KeyError, TypeError, ValueError) as error:
        _infra("held local image catalog evidence is invalid", error)


def _source_digest(data: bytes) -> str:
    name = b"experiment.cue"
    value = hashlib.sha256(SOURCE_DIGEST_DOMAIN)
    value.update(len(name).to_bytes(4, "big"))
    value.update(name)
    value.update(len(data).to_bytes(8, "big"))
    value.update(data)
    return "sha256:" + value.hexdigest()


def _image_name(value: object) -> bool:
    if not isinstance(value, str) or not value.isascii():
        return False
    parts = value.split(".")
    return (
        len(value.encode("ascii")) <= 63
        and len(parts) == 2
        and all(1 <= len(part.encode("ascii")) <= 31 for part in parts)
        and all(IMAGE_COMPONENT.fullmatch(part) is not None for part in parts)
    )


def _installation_identity(
    source_digest: str,
    plan: dict[str, object],
    decision: dict[str, object],
    selected: Sequence[dict[str, object]],
) -> dict[str, object]:
    try:
        contract = plan["contract"]
        binding = decision["binding"]
        if not isinstance(contract, dict) or not isinstance(binding, dict):
            raise ValueError("binding")
        identity = {
            "authorizationDigest": binding["authorizationDigest"],
            "contractDigest": contract["digest"],
            "planDigest": binding["planDigest"],
            "selectedEntries": list(selected),
            "sourceDigest": source_digest,
        }
        if any(
            SHA256.fullmatch(str(identity[key])) is None
            for key in ("authorizationDigest", "contractDigest", "planDigest", "sourceDigest")
        ):
            raise ValueError("digest")
        return identity
    except (KeyError, TypeError, ValueError) as error:
        _infra("installation identity cannot be derived", error)


def _candidate(
    snapshot: object,
    plan: dict[str, object],
    decision: dict[str, object],
    selected: Sequence[dict[str, object]],
    catalog_evidence: dict[str, object] | None,
) -> tuple[dict[str, bytes], dict[str, object], str, str]:
    source_data = getattr(snapshot, "data", None)
    source_digest = getattr(snapshot, "digest", None)
    if not isinstance(source_data, bytes) or not isinstance(source_digest, str):
        _infra("source snapshot is malformed")
    if source_digest != _source_digest(source_data):
        _infra("source snapshot digest is inconsistent")
    local_selected = [item for item in selected if item["origin"] == "local"]
    if local_selected:
        if (
            not isinstance(catalog_evidence, dict)
            or set(catalog_evidence) != {"revision", "snapshotDigest"}
            or type(catalog_evidence.get("revision")) is not int
            or int(catalog_evidence["revision"]) < 1
            or SHA256.fullmatch(str(catalog_evidence.get("snapshotDigest"))) is None
        ):
            _infra("initial local image catalog evidence is invalid")
    elif catalog_evidence is not None:
        _infra("unexpected initial local image catalog evidence")
    identity = _installation_identity(source_digest, plan, decision, selected)
    installation_key = digest(INSTALL_KEY_DOMAIN + canonical(identity))
    plan_bytes = canonical(plan) + b"\n"
    decision_bytes = canonical(decision) + b"\n"
    provenance = {
        "apiVersion": PROVENANCE_API,
        "authorizationDigest": identity["authorizationDigest"],
        "catalog": catalog_evidence,
        "contractDigest": identity["contractDigest"],
        "kind": "ExperimentInstallationProvenance",
        "planDigest": identity["planDigest"],
        "selectedEntries": list(selected),
        "source": {
            "bytes": len(source_data),
            "digest": source_digest,
            "entryCount": 1,
            "fileCount": 1,
            "format": "agent-lab.experiment-tree/v1",
            "kind": "directory",
        },
        "transport": {"kind": "local-directory"},
    }
    provenance_bytes = canonical(provenance) + b"\n"
    files = {
        "artifact/experiment.cue": source_data,
        "records/decision.json": decision_bytes,
        "records/plan.json": plan_bytes,
        "records/provenance.json": provenance_bytes,
    }
    records = {
        "artifact/experiment.cue": {
            "digest": digest(source_data),
            "schema": "agent-lab/v0alpha1",
        },
        "records/decision.json": {
            "digest": digest(DECISION_DOMAIN + canonical(decision)),
            "schema": decision.get("apiVersion"),
        },
        "records/plan.json": {
            "digest": digest(plan_bytes),
            "schema": plan.get("apiVersion"),
        },
        "records/provenance.json": {
            "digest": digest(PROVENANCE_DOMAIN + canonical(provenance)),
            "schema": PROVENANCE_API,
        },
    }
    try:
        requested_name = plan["metadata"]["requestedName"]  # type: ignore[index]
    except (KeyError, TypeError) as error:
        _infra("Experiment plan has no requested name", error)
    if not isinstance(requested_name, str) or EXPERIMENT_NAME.fullmatch(requested_name) is None:
        _infra("Experiment plan requested name is unsafe")
    receipt = {
        "apiVersion": INSTALL_API,
        "identity": identity,
        "installationKey": installation_key,
        "kind": "ExperimentInstallationReceipt",
        "name": requested_name,
        "records": records,
    }
    receipt_bytes = canonical(receipt) + b"\n"
    files["records/install.json"] = receipt_bytes
    return files, receipt, installation_key, digest(RECEIPT_DOMAIN + canonical(receipt))


def _directory_names(path: Path, purpose: str, maximum: int) -> tuple[str, ...]:
    try:
        names: list[str] = []
        with os.scandir(path) as entries:
            for entry in entries:
                if len(names) >= maximum:
                    _infra(f"{purpose} exceeds its fixed entry bound")
                if not isinstance(entry.name, str):
                    _infra(f"{purpose} contains an invalid name")
                names.append(entry.name)
    except StoreError:
        raise
    except OSError as error:
        _infra(f"{purpose} cannot be enumerated", error)
    try:
        return tuple(sorted(names, key=lambda item: os.fsencode(item)))
    except (TypeError, UnicodeError) as error:
        _infra(f"{purpose} contains an invalid name", error)


_ORIGINAL_DIRECTORY_NAMES = _directory_names


def _path_state(path: Path) -> str:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return "absent"
    except OSError as error:
        _infra("store path state is ambiguous", error)
    if stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode):
        return "directory"
    return "other"


def _record_schema(receipt: dict[str, object], path: str) -> tuple[str, str]:
    try:
        records = receipt["records"]
        if not isinstance(records, dict) or set(records) != RECORD_PATHS:
            raise ValueError("record set")
        record = records[path]
        if (
            not isinstance(record, dict)
            or set(record) != {"digest", "schema"}
            or SHA256.fullmatch(str(record.get("digest"))) is None
            or not isinstance(record.get("schema"), str)
        ):
            raise ValueError("record binding")
        return str(record["digest"]), str(record["schema"])
    except (KeyError, TypeError, ValueError) as error:
        _infra("installation receipt record binding is invalid", error)


def _verify_envelope(
    path: Path,
    expected_name: str,
    device: int,
    *,
    root_modes: tuple[int, ...] = (0o500,),
) -> VerifiedInstall:
    if EXPERIMENT_NAME.fullmatch(expected_name) is None:
        _infra("installed Experiment name is unsafe")
    root_before = _verify_directory(path, modes=root_modes, device=device)
    root_names = ("artifact", "records")
    if _directory_names(path, "installed envelope", 2) != root_names:
        _infra("installed envelope layout is not closed")
    artifact_dir = path / "artifact"
    records_dir = path / "records"
    artifact_before = _verify_directory(artifact_dir, modes=(0o500,), device=device)
    records_before = _verify_directory(records_dir, modes=(0o500,), device=device)
    artifact_names = ("experiment.cue",)
    records_names = (
        "decision.json",
        "install.json",
        "plan.json",
        "provenance.json",
    )
    if _directory_names(artifact_dir, "installed artifact", 1) != artifact_names:
        _infra("installed artifact layout is not closed")
    if _directory_names(records_dir, "installed records", 4) != records_names:
        _infra("installed record layout is not closed")
    raw = {
        "artifact/experiment.cue": _read_file(
            artifact_dir / "experiment.cue",
            MAX_ARTIFACT_BYTES,
            "installed Experiment artifact",
            mode=0o400,
            device=device,
        ),
        "records/decision.json": _read_file(
            records_dir / "decision.json",
            MAX_RECORD_BYTES,
            "installed authorization decision",
            mode=0o400,
            device=device,
        ),
        "records/install.json": _read_file(
            records_dir / "install.json",
            MAX_RECORD_BYTES,
            "installed receipt",
            mode=0o400,
            device=device,
        ),
        "records/plan.json": _read_file(
            records_dir / "plan.json",
            MAX_RECORD_BYTES,
            "installed plan",
            mode=0o400,
            device=device,
        ),
        "records/provenance.json": _read_file(
            records_dir / "provenance.json",
            MAX_RECORD_BYTES,
            "installed provenance",
            mode=0o400,
            device=device,
        ),
    }
    plan = _parse_object(raw["records/plan.json"], "installed plan")
    decision = _parse_object(raw["records/decision.json"], "installed authorization decision")
    provenance = _parse_object(raw["records/provenance.json"], "installed provenance")
    receipt = _parse_object(raw["records/install.json"], "installed receipt")
    try:
        if (
            set(plan) != {"apiVersion", "contract", "kind", "metadata", "spec"}
            or plan.get("apiVersion") != "agent-lab.request/v0alpha1"
            or plan.get("kind") != "RequestedExperimentPlan"
            or not isinstance(plan.get("metadata"), dict)
            or plan["metadata"].get("requestedName") != expected_name  # type: ignore[union-attr]
            or not isinstance(plan.get("contract"), dict)
        ):
            raise ValueError("plan")
        contract = plan["contract"]
        if (
            set(contract) != {"digest", "name", "version"}  # type: ignore[arg-type]
            or contract.get("name") != "agent-lab.experiment"  # type: ignore[union-attr]
            or contract.get("version") != "v0alpha1"  # type: ignore[union-attr]
            or SHA256.fullmatch(str(contract.get("digest"))) is None  # type: ignore[union-attr]
        ):
            raise ValueError("contract")
        plan_digest = digest(canonical(plan))
        if (
            set(decision) != {"action", "apiVersion", "binding", "kind", "principal", "resource", "verdict"}
            or decision.get("apiVersion") != "agent-lab.authorization/v0alpha1"
            or decision.get("kind") != "ExperimentAuthorizationDecision"
            or decision.get("action") != "experiment.install"
            or decision.get("verdict") != "permit"
            or not isinstance(decision.get("binding"), dict)
        ):
            raise ValueError("decision")
        binding = decision["binding"]
        source_digest = _source_digest(raw["artifact/experiment.cue"])
        if (
            set(binding) != {"authorizationDigest", "contractDigest", "planDigest", "sourceDigest"}  # type: ignore[arg-type]
            or binding.get("planDigest") != plan_digest  # type: ignore[union-attr]
            or binding.get("sourceDigest") != source_digest  # type: ignore[union-attr]
            or binding.get("contractDigest") != contract.get("digest")  # type: ignore[union-attr]
            or SHA256.fullmatch(str(binding.get("authorizationDigest"))) is None  # type: ignore[union-attr]
        ):
            raise ValueError("decision binding")
        selected = _selected_entries(plan)
        identity = _installation_identity(source_digest, plan, decision, selected)
        if (
            set(provenance) != {
                "apiVersion", "authorizationDigest", "catalog", "contractDigest", "kind",
                "planDigest", "selectedEntries", "source", "transport",
            }
            or provenance.get("apiVersion") != PROVENANCE_API
            or provenance.get("kind") != "ExperimentInstallationProvenance"
            or provenance.get("authorizationDigest") != identity["authorizationDigest"]
            or provenance.get("contractDigest") != identity["contractDigest"]
            or provenance.get("planDigest") != identity["planDigest"]
            or provenance.get("selectedEntries") != list(selected)
            or provenance.get("source") != {
                "bytes": len(raw["artifact/experiment.cue"]),
                "digest": source_digest,
                "entryCount": 1,
                "fileCount": 1,
                "format": "agent-lab.experiment-tree/v1",
                "kind": "directory",
            }
            or provenance.get("transport") != {"kind": "local-directory"}
        ):
            raise ValueError("provenance")
        catalog = provenance.get("catalog")
        local_selected = [item for item in selected if item["origin"] == "local"]
        if local_selected:
            if (
                not isinstance(catalog, dict)
                or set(catalog) != {"revision", "snapshotDigest"}
                or type(catalog.get("revision")) is not int
                or int(catalog["revision"]) < 1
                or SHA256.fullmatch(str(catalog.get("snapshotDigest"))) is None
            ):
                raise ValueError("catalog provenance")
        elif catalog is not None:
            raise ValueError("unexpected catalog provenance")
        installation_key = digest(INSTALL_KEY_DOMAIN + canonical(identity))
        if (
            set(receipt) != {"apiVersion", "identity", "installationKey", "kind", "name", "records"}
            or receipt.get("apiVersion") != INSTALL_API
            or receipt.get("kind") != "ExperimentInstallationReceipt"
            or receipt.get("name") != expected_name
            or receipt.get("identity") != identity
            or receipt.get("installationKey") != installation_key
        ):
            raise ValueError("receipt")
        expected_schemas = {
            "artifact/experiment.cue": "agent-lab/v0alpha1",
            "records/decision.json": str(decision["apiVersion"]),
            "records/plan.json": str(plan["apiVersion"]),
            "records/provenance.json": PROVENANCE_API,
        }
        expected_digests = {
            "artifact/experiment.cue": digest(raw["artifact/experiment.cue"]),
            "records/decision.json": digest(DECISION_DOMAIN + canonical(decision)),
            "records/plan.json": digest(raw["records/plan.json"]),
            "records/provenance.json": digest(PROVENANCE_DOMAIN + canonical(provenance)),
        }
        for record_path in RECORD_PATHS:
            record_digest, schema = _record_schema(receipt, record_path)
            if record_digest != expected_digests[record_path] or schema != expected_schemas[record_path]:
                raise ValueError("record digest")
    except (KeyError, TypeError, ValueError) as error:
        _infra("installed envelope does not match its receipt", error)
    directory_checks = (
        (path, root_before, root_modes, root_names, "installed envelope", 2),
        (
            artifact_dir,
            artifact_before,
            (0o500,),
            artifact_names,
            "installed artifact",
            1,
        ),
        (
            records_dir,
            records_before,
            (0o500,),
            records_names,
            "installed records",
            4,
        ),
    )
    for directory, before, modes, expected_names, purpose, maximum in directory_checks:
        after = _verify_directory(directory, modes=modes, device=device)
        if (
            _identity(before) != _identity(after)
            or _directory_names(directory, purpose, maximum) != expected_names
        ):
            _infra(f"{purpose} changed while being verified")
    file_digests = {item: digest(data) for item, data in raw.items()}
    return VerifiedInstall(
        expected_name,
        installation_key,
        digest(RECEIPT_DOMAIN + canonical(receipt)),
        file_digests,
    )


def _intent(files: dict[str, bytes], name: str, key: str, receipt_digest: str) -> dict[str, object]:
    file_digests = {path: digest(data) for path, data in sorted(files.items())}
    return {
        "apiVersion": INTENT_API,
        "files": file_digests,
        "installationKey": key,
        "name": name,
        "payloadDigest": digest(STAGE_PAYLOAD_DOMAIN + canonical(file_digests)),
        "phase": "prepared",
        "receiptDigest": receipt_digest,
    }


def _validate_intent(value: dict[str, object]) -> None:
    try:
        files = value["files"]
        if (
            set(value) != {
                "apiVersion", "files", "installationKey", "name", "payloadDigest", "phase", "receiptDigest",
            }
            or value["apiVersion"] != INTENT_API
            or value["phase"] != "prepared"
            or not isinstance(value["name"], str)
            or EXPERIMENT_NAME.fullmatch(value["name"]) is None
            or SHA256.fullmatch(str(value["installationKey"])) is None
            or SHA256.fullmatch(str(value["receiptDigest"])) is None
            or not isinstance(files, dict)
            or set(files) != {
                "artifact/experiment.cue",
                "records/decision.json",
                "records/install.json",
                "records/plan.json",
                "records/provenance.json",
            }
            or any(SHA256.fullmatch(str(item)) is None for item in files.values())
            or value["payloadDigest"] != digest(STAGE_PAYLOAD_DOMAIN + canonical(files))
        ):
            raise ValueError("intent")
    except (KeyError, TypeError, ValueError) as error:
        _infra("Experiment staging intent is invalid", error)


def _scan_wrapper(authority: HomeAuthority, path: Path, *, cleanup: bool) -> ScannedWrapper:
    _verify_directory(path, modes=(0o700,), device=authority.store_device)
    count = 1
    byte_count = 0
    pending = [path]
    found: set[str] = set()
    while pending:
        parent = pending.pop()
        remaining = MAX_STAGE_ENTRIES - count
        for name in _directory_names(parent, "Experiment staging wrapper", max(remaining, 0)):
            item = parent / name
            relative = str(item.relative_to(path))
            if relative not in STAGE_ALLOWED:
                _infra("Experiment staging wrapper contains an unknown entry")
            try:
                metadata = item.lstat()
            except OSError as error:
                _infra("Experiment staging entry cannot be inspected", error)
            count += 1
            found.add(relative)
            if count > MAX_STAGE_ENTRIES or metadata.st_dev != authority.store_device or metadata.st_uid != os.getuid():
                _infra("Experiment staging state exceeds or leaves its fixed authority")
            if stat.S_ISLNK(metadata.st_mode):
                _infra("Experiment staging state contains a symlink")
            if stat.S_ISDIR(metadata.st_mode):
                if relative not in PAYLOAD_DIRECTORIES or stat.S_IMODE(metadata.st_mode) not in (0o700, 0o500):
                    _infra("Experiment staging directory metadata is unsafe")
                pending.append(item)
            elif stat.S_ISREG(metadata.st_mode):
                allowed_modes = (
                    (0o600,)
                    if relative in {OWNERSHIP_MARKER, "intent.json"}
                    else (0o600, 0o400)
                )
                if stat.S_IMODE(metadata.st_mode) not in allowed_modes or metadata.st_nlink != 1:
                    _infra("Experiment staging file metadata is unsafe")
                byte_count += metadata.st_size
                if byte_count > MAX_STAGE_BYTES:
                    _infra("Experiment staging state exceeds its fixed byte bound")
            else:
                _infra("Experiment staging state contains an unsafe type")
    has_payload = any(
        relative == "payload" or relative.startswith("payload/")
        for relative in found
    )
    has_marker = OWNERSHIP_MARKER in found
    if has_marker:
        marker = _read_file(
            path / OWNERSHIP_MARKER,
            len(OWNERSHIP_BYTES),
            "Experiment staging ownership marker",
            mode=0o600,
            device=authority.store_device,
        )
        if marker != OWNERSHIP_BYTES:
            _infra("Experiment staging ownership marker is malformed")
    intent_path = path / "intent.json"
    if "intent.json" not in found:
        if cleanup and not found:
            return ScannedWrapper(None, False)
        if has_marker and found == {OWNERSHIP_MARKER}:
            return ScannedWrapper(None, False)
        _infra("Experiment staging wrapper has no durable intent")
    raw_intent = _read_file(
        intent_path,
        MAX_AUTHORITY_BYTES,
        "Experiment staging intent",
        mode=0o600,
        device=authority.store_device,
    )
    try:
        value = _parse_object(raw_intent, "Experiment staging intent")
        _validate_intent(value)
    except StoreInfrastructure:
        if has_marker and found == {OWNERSHIP_MARKER, "intent.json"}:
            return ScannedWrapper(None, False)
        raise
    files = value["files"]
    assert isinstance(files, dict)
    for relative in found & PAYLOAD_FILES:
        payload_relative = relative.removeprefix("payload/")
        maximum = MAX_ARTIFACT_BYTES if payload_relative == "artifact/experiment.cue" else MAX_RECORD_BYTES
        mode = stat.S_IMODE((path / relative).lstat().st_mode)
        raw = _read_file(
            path / relative,
            maximum,
            "Experiment staged payload",
            mode=mode,
            device=authority.store_device,
        )
        if digest(raw) != files[payload_relative]:
            _infra("Experiment staged payload does not match its durable intent")
    return ScannedWrapper(value, has_payload)


def _rename_noreplace(source: Path, target: Path) -> None:
    try:
        library = ctypes.CDLL(None, use_errno=True)
        function = library.renameat2
    except (AttributeError, OSError) as error:
        _infra("Linux no-replace rename is unavailable", error)
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    result = function(-100, os.fsencode(source), -100, os.fsencode(target), 1)
    if result != 0:
        code = ctypes.get_errno()
        if code == errno.EEXIST:
            _infra("Experiment no-replace publication raced with an existing target")
        _infra("Experiment no-replace publication failed", OSError(code, os.strerror(code)))


def _fsync_directory(path: Path, purpose: str, *, modes: tuple[int, ...] = (0o700,)) -> None:
    metadata = _verify_directory(path, modes=modes)
    descriptor = -1
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        if (os.fstat(descriptor).st_dev, os.fstat(descriptor).st_ino) != (metadata.st_dev, metadata.st_ino):
            _infra(f"{purpose} directory identity changed")
        os.fsync(descriptor)
    except StoreError:
        raise
    except OSError as error:
        _infra(f"{purpose} directory cannot be persisted", error)
    finally:
        unwinding = sys.exc_info()[0] is not None
        if descriptor >= 0:
            try:
                os.close(descriptor)
            except OSError as error:
                if not unwinding:
                    _infra(f"{purpose} directory descriptor cannot be closed", error)


def _write_all(descriptor: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise OSError("write made no progress")
        view = view[written:]


def _link_unnamed(descriptor: int, parent_descriptor: int, name: str, purpose: str) -> None:
    try:
        library = ctypes.CDLL(None, use_errno=True)
        function = library.linkat
    except (AttributeError, OSError) as error:
        _infra("Linux unnamed-file publication is unavailable", error)
    function.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
    ]
    function.restype = ctypes.c_int
    ctypes.set_errno(0)
    result = function(
        descriptor,
        b"",
        parent_descriptor,
        os.fsencode(name),
        0x1000,  # AT_EMPTY_PATH
    )
    if result != 0:
        code = ctypes.get_errno()
        _infra(f"{purpose} could not be linked exclusively", OSError(code, os.strerror(code)))


def _write_file(path: Path, data: bytes, purpose: str, fault: FaultHook | None) -> None:
    descriptor = -1
    parent_descriptor = -1
    try:
        if not hasattr(os, "O_TMPFILE"):
            _infra("Linux unnamed staging files are unavailable")
        parent_metadata = _verify_directory(path.parent, modes=(0o700,))
        parent_descriptor = os.open(
            path.parent,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        opened_parent = os.fstat(parent_descriptor)
        if (opened_parent.st_dev, opened_parent.st_ino) != (
            parent_metadata.st_dev,
            parent_metadata.st_ino,
        ):
            _infra(f"{purpose} parent identity changed")
        descriptor = os.open(
            ".",
            os.O_RDWR
            | os.O_TMPFILE
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=parent_descriptor,
        )
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != os.getuid()
            or opened.st_nlink != 0
            or stat.S_IMODE(opened.st_mode) != 0o600
            or opened.st_dev != opened_parent.st_dev
        ):
            _infra(f"{purpose} file metadata is unsafe")
        _write_all(descriptor, data)
        if purpose == "experiment artifact":
            _fault(fault, "experiment artifact.after_write")
        os.fsync(descriptor)
        if purpose == "experiment receipt":
            _fault(fault, "experiment receipt.after_fsync")
        os.lseek(descriptor, 0, os.SEEK_SET)
        chunks: list[bytes] = []
        remaining = len(data) + 1
        while remaining:
            chunk = os.read(descriptor, min(65_536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        observed = b"".join(chunks)
        complete = os.fstat(descriptor)
        if (
            observed != data
            or complete.st_size != len(data)
            or complete.st_nlink != 0
            or (complete.st_dev, complete.st_ino) != (opened.st_dev, opened.st_ino)
        ):
            _infra(f"{purpose} anonymous file identity changed")
        _link_unnamed(descriptor, parent_descriptor, path.name, purpose)
        linked = os.stat(path.name, dir_fd=parent_descriptor, follow_symlinks=False)
        if (
            not stat.S_ISREG(linked.st_mode)
            or linked.st_uid != os.getuid()
            or linked.st_nlink != 1
            or stat.S_IMODE(linked.st_mode) != 0o600
            or linked.st_size != len(data)
            or (linked.st_dev, linked.st_ino) != (complete.st_dev, complete.st_ino)
        ):
            _infra(f"{purpose} linked file metadata is unsafe")
        os.fsync(parent_descriptor)
    except StoreError:
        raise
    except OSError as error:
        _infra(f"{purpose} could not be written durably", error)
    finally:
        unwinding = sys.exc_info()[0] is not None
        close_error: OSError | None = None
        parent_close_error: OSError | None = None
        if descriptor >= 0:
            try:
                os.close(descriptor)
            except OSError as error:
                close_error = error
        if parent_descriptor >= 0:
            try:
                os.close(parent_descriptor)
            except OSError as error:
                parent_close_error = error
        if not unwinding and (close_error is not None or parent_close_error is not None):
            cause = parent_close_error if parent_close_error is not None else close_error
            _infra(f"{purpose} descriptors could not be closed", cause)


def _persist_read_only_file(path: Path, purpose: str) -> None:
    descriptor = -1
    try:
        os.chmod(path, 0o400, follow_symlinks=False)
        descriptor = os.open(
            path,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or metadata.st_nlink != 1
            or stat.S_IMODE(metadata.st_mode) != 0o400
        ):
            _infra(f"{purpose} committed metadata is unsafe")
        os.fsync(descriptor)
    except StoreError:
        raise
    except OSError as error:
        _infra(f"{purpose} mode could not be persisted", error)
    finally:
        unwinding = sys.exc_info()[0] is not None
        if descriptor >= 0:
            try:
                os.close(descriptor)
            except OSError as error:
                if not unwinding:
                    _infra(f"{purpose} descriptor could not be closed", error)


def _prepare_stage(
    authority: HomeAuthority,
    files: dict[str, bytes],
    name: str,
    key: str,
    receipt_digest: str,
    fault: FaultHook | None,
) -> tuple[Path, dict[str, object]]:
    wrapper = authority.staging / OPERATION_WRAPPER
    payload = wrapper / "payload"
    intent = _intent(files, name, key, receipt_digest)
    try:
        wrapper.mkdir(mode=0o700)
        _write_file(
            wrapper / OWNERSHIP_MARKER,
            OWNERSHIP_BYTES,
            "experiment ownership marker",
            fault,
        )
        _fsync_directory(wrapper, "Experiment ownership wrapper")
        _fsync_directory(authority.staging, "Experiment ownership marker")
        _write_file(wrapper / "intent.json", canonical(intent) + b"\n", "experiment intent", fault)
        _fsync_directory(wrapper, "Experiment intent wrapper")
        _fsync_directory(authority.staging, "Experiment staging intent")
        payload.mkdir(mode=0o700)
        (payload / "artifact").mkdir(mode=0o700)
        (payload / "records").mkdir(mode=0o700)
        ordered = (
            "artifact/experiment.cue",
            "records/decision.json",
            "records/plan.json",
            "records/provenance.json",
            "records/install.json",
        )
        for relative in ordered:
            purpose = "experiment receipt" if relative == "records/install.json" else (
                "experiment artifact" if relative == "artifact/experiment.cue" else "experiment record"
            )
            _write_file(payload / relative, files[relative], purpose, fault)
        _fsync_directory(payload / "artifact", "Experiment staged artifact")
        _fsync_directory(payload / "records", "Experiment staged records")
        _fsync_directory(payload, "Experiment staged envelope")
        _fsync_directory(wrapper, "Experiment staged wrapper")
        _fsync_directory(authority.staging, "Experiment staged operation")
        for relative in ordered:
            _persist_read_only_file(payload / relative, "Experiment staged file")
        os.chmod(payload / "artifact", 0o500, follow_symlinks=False)
        os.chmod(payload / "records", 0o500, follow_symlinks=False)
        _fsync_directory(payload / "artifact", "Experiment committed artifact", modes=(0o500,))
        _fsync_directory(payload / "records", "Experiment committed records", modes=(0o500,))
        # This runtime's containment LSM rejects moving a non-writable directory.
        # Keep only the envelope root private-writable until the no-replace move;
        # all children are already committed and fsynced.  The root is changed to
        # 0500 and fsynced before the post-publication fault seam can run.
        _fsync_directory(payload, "Experiment staged envelope root", modes=(0o700,))
        _fsync_directory(wrapper, "Experiment committed wrapper")
        _fsync_directory(authority.staging, "Experiment committed staging")
    except StoreError:
        raise
    except OSError as error:
        _infra("Experiment staging envelope could not be prepared", error)
    scanned = _scan_wrapper(authority, wrapper, cleanup=False)
    if scanned.intent != intent or not scanned.has_payload:
        _infra("Experiment staged operation is incomplete")
    _verify_envelope(payload, name, authority.store_device, root_modes=(0o700,))
    return wrapper, intent


_REMOVE_CONTEXT: ContextVar[
    tuple[int, str, Path, Path, dict[str, int]] | None
] = ContextVar("experiment_remove_context", default=None)


def _cleanup_relative(path: Path, root: Path) -> str:
    try:
        return "." if path == root else str(path.relative_to(root))
    except ValueError as error:
        _infra("Experiment cleanup path left its wrapper", error)


def _validate_cleanup_entry(
    metadata: os.stat_result,
    relative: str,
    state: dict[str, int],
) -> str:
    state["entries"] += 1
    if (
        state["entries"] > MAX_STAGE_ENTRIES
        or metadata.st_dev != state["device"]
        or metadata.st_uid != os.getuid()
        or stat.S_ISLNK(metadata.st_mode)
    ):
        _infra("Experiment cleanup residue metadata is unsafe")
    mode = stat.S_IMODE(metadata.st_mode)
    if stat.S_ISREG(metadata.st_mode):
        allowed_modes = (
            (0o600,)
            if relative in {OWNERSHIP_MARKER, "intent.json"}
            else (0o600, 0o400)
        )
        if relative not in STAGE_ALLOWED or metadata.st_nlink != 1 or mode not in allowed_modes:
            _infra("Experiment cleanup file is unsafe")
        if relative == OWNERSHIP_MARKER and metadata.st_size != len(OWNERSHIP_BYTES):
            _infra("Experiment cleanup ownership marker has an unsafe size")
        state["bytes"] += metadata.st_size
        if state["bytes"] > MAX_STAGE_BYTES:
            _infra("Experiment cleanup residue exceeds its fixed byte bound")
        return "file"
    if not stat.S_ISDIR(metadata.st_mode):
        _infra("Experiment cleanup residue contains an unsafe type")
    if (
        metadata.st_nlink < 1
        or (relative == "." and mode != 0o700)
        or (relative != "." and (relative not in PAYLOAD_DIRECTORIES or mode not in (0o700, 0o500)))
    ):
        _infra("Experiment cleanup directory is unsafe")
    return "directory"


def _cleanup_names(descriptor: int, maximum: int) -> tuple[str, ...]:
    try:
        names: list[str] = []
        with os.scandir(descriptor) as entries:
            for entry in entries:
                if len(names) >= maximum or not isinstance(entry.name, str):
                    _infra("Experiment cleanup residue exceeds its fixed entry bound")
                names.append(entry.name)
        return tuple(sorted(names, key=lambda item: os.fsencode(item)))
    except StoreError:
        raise
    except (OSError, TypeError, UnicodeError) as error:
        _infra("Experiment cleanup residue cannot be enumerated safely", error)


def _remove_entry_at(
    parent_descriptor: int,
    name: str,
    path: Path,
    root: Path,
    state: dict[str, int],
) -> None:
    relative = _cleanup_relative(path, root)
    try:
        metadata = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    except OSError as error:
        _infra("Experiment cleanup residue cannot be inspected", error)
    kind = _validate_cleanup_entry(metadata, relative, state)
    if kind == "file":
        descriptor = -1
        try:
            descriptor = os.open(
                name,
                os.O_RDONLY
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_NONBLOCK", 0),
                dir_fd=parent_descriptor,
            )
            opened = os.fstat(descriptor)
            if (
                (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino)
                or opened.st_mode != metadata.st_mode
                or opened.st_uid != metadata.st_uid
                or opened.st_nlink != metadata.st_nlink
                or opened.st_size != metadata.st_size
            ):
                _infra("Experiment cleanup file identity changed while opening")
            current = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
            if (
                (current.st_dev, current.st_ino) != (metadata.st_dev, metadata.st_ino)
                or not stat.S_ISREG(current.st_mode)
                or current.st_uid != os.getuid()
                or current.st_nlink != 1
                or stat.S_IMODE(current.st_mode) != stat.S_IMODE(metadata.st_mode)
                or current.st_size != metadata.st_size
            ):
                _infra("Experiment cleanup file identity changed")
            os.unlink(name, dir_fd=parent_descriptor)
            os.fsync(parent_descriptor)
        except StoreError:
            raise
        except OSError as error:
            _infra("Experiment cleanup file cannot be removed durably", error)
        finally:
            unwinding = sys.exc_info()[0] is not None
            if descriptor >= 0:
                try:
                    os.close(descriptor)
                except OSError as error:
                    if not unwinding:
                        _infra("Experiment cleanup file descriptor cannot be closed", error)
        return

    descriptor = -1
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent_descriptor,
        )
        opened = os.fstat(descriptor)
        if (
            (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino)
            or not stat.S_ISDIR(opened.st_mode)
            or opened.st_uid != os.getuid()
        ):
            _infra("Experiment cleanup directory identity changed")
        if _directory_names is not _ORIGINAL_DIRECTORY_NAMES:
            _directory_names(
                path,
                "Experiment cleanup residue race seam",
                max(MAX_STAGE_ENTRIES - state["entries"], 0),
            )
            current = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
            if (
                (current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino)
                or not stat.S_ISDIR(current.st_mode)
            ):
                _infra("Experiment cleanup directory identity changed during enumeration")
        if stat.S_IMODE(opened.st_mode) != 0o700:
            os.fchmod(descriptor, 0o700)
        writable = os.fstat(descriptor)
        if (
            (writable.st_dev, writable.st_ino) != (opened.st_dev, opened.st_ino)
            or writable.st_uid != os.getuid()
            or writable.st_nlink < 1
            or stat.S_IMODE(writable.st_mode) != 0o700
        ):
            _infra("Experiment cleanup directory mode change is uncertain")
        names = _cleanup_names(descriptor, max(MAX_STAGE_ENTRIES - state["entries"], 0))

        def deletion_key(child: str) -> tuple[int, bytes]:
            child_relative = _cleanup_relative(path / child, root)
            if child_relative == OWNERSHIP_MARKER:
                rank = 2
            elif child_relative == "intent.json":
                rank = 1
            else:
                rank = 0
            return rank, os.fsencode(child)

        for child in sorted(names, key=deletion_key):
            child_path = path / child
            token = _REMOVE_CONTEXT.set((descriptor, child, child_path, root, state))
            try:
                _remove_tree(child_path, root)
            finally:
                _REMOVE_CONTEXT.reset(token)
        if _cleanup_names(descriptor, 1):
            _infra("Experiment cleanup directory changed during removal")
        os.fsync(descriptor)
        current = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        if (
            (current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino)
            or not stat.S_ISDIR(current.st_mode)
            or current.st_uid != os.getuid()
            or current.st_nlink < 1
            or stat.S_IMODE(current.st_mode) != 0o700
        ):
            _infra("Experiment cleanup directory identity changed before removal")
        os.rmdir(name, dir_fd=parent_descriptor)
        os.fsync(parent_descriptor)
    except StoreError:
        raise
    except OSError as error:
        _infra("Experiment cleanup directory cannot be removed durably", error)
    finally:
        unwinding = sys.exc_info()[0] is not None
        if descriptor >= 0:
            try:
                os.close(descriptor)
            except OSError as error:
                if not unwinding:
                    _infra("Experiment cleanup directory descriptor cannot be closed", error)


def _remove_tree(path: Path, root: Path) -> None:
    context = _REMOVE_CONTEXT.get()
    if context is not None:
        parent_descriptor, name, expected_path, expected_root, state = context
        if path != expected_path or root != expected_root:
            _infra("Experiment cleanup recursion target changed")
        _remove_entry_at(parent_descriptor, name, path, root, state)
        return
    if path != root:
        _infra("Experiment cleanup must begin at its exact wrapper")
    parent_descriptor = -1
    try:
        parent_metadata = _verify_directory(root.parent, modes=(0o700,))
        parent_descriptor = os.open(
            root.parent,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        opened_parent = os.fstat(parent_descriptor)
        if (opened_parent.st_dev, opened_parent.st_ino) != (
            parent_metadata.st_dev,
            parent_metadata.st_ino,
        ):
            _infra("Experiment cleanup parent identity changed")
        try:
            root_metadata = os.stat(
                root.name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            return
        if root_metadata.st_dev != opened_parent.st_dev:
            _infra("Experiment cleanup wrapper left its staging filesystem")
        state = {"entries": 0, "bytes": 0, "device": root_metadata.st_dev}
        _remove_entry_at(parent_descriptor, root.name, root, root, state)
    except StoreError:
        raise
    except OSError as error:
        _infra("Experiment cleanup wrapper cannot be removed safely", error)
    finally:
        unwinding = sys.exc_info()[0] is not None
        if parent_descriptor >= 0:
            try:
                os.close(parent_descriptor)
            except OSError as error:
                if not unwinding:
                    _infra("Experiment cleanup parent descriptor cannot be closed", error)


def _finish_cleanup(authority: HomeAuthority, cleanup: Path) -> None:
    if cleanup != authority.staging / CLEANUP_WRAPPER:
        _infra("Experiment cleanup target changed")
    _scan_wrapper(authority, cleanup, cleanup=True)
    _remove_tree(cleanup, cleanup)
    _fsync_directory(authority.staging, "Experiment staging cleanup")


def _cleanup_operation(authority: HomeAuthority, wrapper: Path) -> None:
    if wrapper != authority.staging / OPERATION_WRAPPER:
        _infra("Experiment operation cleanup target changed")
    _scan_wrapper(authority, wrapper, cleanup=False)
    cleanup = authority.staging / CLEANUP_WRAPPER
    _rename_noreplace(wrapper, cleanup)
    _fsync_directory(authority.staging, "Experiment cleanup handoff")
    _finish_cleanup(authority, cleanup)


def _cleanup_empty_operation(authority: HomeAuthority, wrapper: Path) -> None:
    if wrapper != authority.staging / OPERATION_WRAPPER:
        _infra("Experiment empty operation cleanup target changed")
    _verify_directory(wrapper, modes=(0o700,), device=authority.store_device)
    if _directory_names(wrapper, "empty Experiment operation wrapper", 0):
        _infra("Experiment operation wrapper has no durable intent")
    cleanup = authority.staging / CLEANUP_WRAPPER
    _rename_noreplace(wrapper, cleanup)
    _fsync_directory(authority.staging, "Experiment empty cleanup handoff")
    _finish_cleanup(authority, cleanup)


def _recover_intent_final(
    authority: HomeAuthority,
    wrapper: Path,
    intent: dict[str, object],
    *,
    has_payload: bool,
) -> bool:
    name = str(intent["name"])
    target = authority.store / name
    state = _path_state(target)
    if state == "absent":
        return False
    if state != "directory":
        _infra("Experiment staged operation conflicts with an ambiguous final target")
    if has_payload:
        _infra("Experiment staged payload remains beside a final installation")
    target_metadata = _verify_directory(
        target,
        modes=(0o500, 0o700),
        device=authority.store_device,
    )
    target_mode = stat.S_IMODE(target_metadata.st_mode)
    verified = _verify_envelope(
        target,
        name,
        authority.store_device,
        root_modes=(target_mode,),
    )
    files = intent["files"]
    assert isinstance(files, dict)
    if (
        verified.installation_key != intent["installationKey"]
        or verified.receipt_digest != intent["receiptDigest"]
        or any(verified.file_digests.get(path) != expected for path, expected in files.items())
    ):
        _infra("Experiment staged operation conflicts with the final installation")
    _fsync_directory(
        wrapper,
        "Experiment publication source recovery",
        modes=(0o700,),
    )
    if target_mode == 0o700:
        try:
            os.chmod(target, 0o500, follow_symlinks=False)
        except OSError as error:
            _infra("recovered Experiment mode is uncertain", error)
    _fsync_directory(
        target,
        "Experiment recovered envelope",
        modes=(0o500,),
    )
    _fsync_directory(authority.store, "Experiment committed recovery")
    recovered = _verify_envelope(target, name, authority.store_device)
    if (
        recovered.installation_key != intent["installationKey"]
        or recovered.receipt_digest != intent["receiptDigest"]
        or any(
            recovered.file_digests.get(path) != expected
            for path, expected in files.items()
        )
    ):
        _infra("recovered Experiment does not match its durable intent")
    return True


def _reconcile(authority: HomeAuthority) -> None:
    names = _directory_names(authority.staging, "Experiment staging root", 1)
    if not names:
        _fsync_directory(authority.staging, "Experiment empty staging recovery")
        return
    if names == (CLEANUP_WRAPPER,):
        cleanup = authority.staging / CLEANUP_WRAPPER
        scanned = _scan_wrapper(authority, cleanup, cleanup=True)
        if scanned.intent is not None:
            _recover_intent_final(
                authority,
                cleanup,
                scanned.intent,
                has_payload=scanned.has_payload,
            )
        _finish_cleanup(authority, cleanup)
        return
    if names != (OPERATION_WRAPPER,):
        _infra("Experiment staging root contains an unknown wrapper")
    wrapper = authority.staging / OPERATION_WRAPPER
    _verify_directory(wrapper, modes=(0o700,), device=authority.store_device)
    if not _directory_names(wrapper, "Experiment operation wrapper", 3):
        _cleanup_empty_operation(authority, wrapper)
        return
    scanned = _scan_wrapper(authority, wrapper, cleanup=False)
    if scanned.intent is not None:
        _recover_intent_final(
            authority,
            wrapper,
            scanned.intent,
            has_payload=scanned.has_payload,
        )
    _cleanup_operation(authority, wrapper)


def _existing(authority: HomeAuthority, name: str) -> VerifiedInstall | None:
    target = authority.store / name
    state = _path_state(target)
    if state == "absent":
        return None
    if state != "directory":
        _infra("Experiment installation target is ambiguous")
    return _verify_envelope(target, name, authority.store_device)


@contextmanager
def _held_catalog_context(
    home: Path,
    dependencies: Sequence[dict[str, object]],
    fault: FaultHook | None,
) -> Iterator[object | None]:
    if not dependencies:
        with nullcontext(None) as held:
            yield held
        return
    catalog = _catalog_module()
    operation = getattr(catalog, "hold_local_image_entries", None)
    if not callable(operation):
        _infra("held local image catalog support is unavailable")
    try:
        with operation(home, tuple(dependencies), fault=fault) as held:
            yield held
    except catalog.CatalogReject as error:
        raise StoreReject(str(error)) from error
    except catalog.CatalogInfrastructure as error:
        raise StoreInfrastructure(str(error)) from error
    except (AttributeError, OSError) as error:
        _infra("held local image catalog cannot be acquired", error)


def install_directory(
    home: Path,
    source: Path,
    *,
    fault: FaultHook | None = None,
) -> dict[str, object]:
    """Freshly validate/authorize one directory and publish its envelope once."""

    if sys.platform != "linux":
        _infra("effectful Experiment installation requires Linux")
    authority = _load_home(Path(home))
    experiment = _experiment_module()
    prior_home = os.environ.get("AGENT_LAB_HOME")
    os.environ["AGENT_LAB_HOME"] = str(authority.home)
    try:
        try:
            snapshot = experiment.read_directory_snapshot(str(source))
            manifest = experiment.authored_manifest(snapshot)
            resolution = experiment.cue_plan_with_evidence(manifest)
            plan = resolution.plan
            initial_catalog = resolution.local_catalog
            if not isinstance(plan, dict):
                _infra("CUE produced a malformed Experiment plan")
            decision, status = experiment.authorize_plan(plan, snapshot.digest)
        except experiment.InvalidManifest as error:
            raise StoreReject(str(error)) from error
        except experiment.InfrastructureError as error:
            raise StoreInfrastructure(str(error)) from error
        except (AttributeError, OSError) as error:
            _infra("Experiment validation or authorization is unavailable", error)
    finally:
        if prior_home is None:
            os.environ.pop("AGENT_LAB_HOME", None)
        else:
            os.environ["AGENT_LAB_HOME"] = prior_home
    if status != 0 or not isinstance(decision, dict) or decision.get("verdict") != "permit":
        _reject("fresh Experiment installation authorization denied")
    selected = _selected_entries(plan)
    dependencies = _local_dependencies(selected)
    try:
        held_context = _held_catalog_context(authority.home, dependencies, fault)
        with held_context as held:
            if dependencies:
                _verify_held_catalog(held, dependencies)
            with _store_lock(authority, fault):
                _revalidate_authority(authority)
                _reconcile(authority)
                files, _, key, receipt_digest = _candidate(
                    snapshot,
                    plan,
                    decision,
                    selected,
                    initial_catalog,
                )
                name = str(plan["metadata"]["requestedName"])  # type: ignore[index]
                existing = _existing(authority, name)
                if existing is not None:
                    if existing.installation_key != key:
                        _reject("Experiment name already has a different installation")
                    return {
                        "changed": False,
                        "installationKey": existing.installation_key,
                        "name": name,
                        "receiptDigest": existing.receipt_digest,
                    }
                wrapper, _ = _prepare_stage(
                    authority,
                    files,
                    name,
                    key,
                    receipt_digest,
                    fault,
                )
                _revalidate_authority(authority)
                _fault(fault, "experiment envelope.before_noreplace")
                _rename_noreplace(wrapper / "payload", authority.store / name)
                _fsync_directory(
                    wrapper,
                    "Experiment publication source parent",
                    modes=(0o700,),
                )
                try:
                    os.chmod(authority.store / name, 0o500, follow_symlinks=False)
                except OSError as error:
                    _infra("published Experiment mode is uncertain", error)
                _fsync_directory(
                    authority.store / name,
                    "Experiment published envelope",
                    modes=(0o500,),
                )
                _fault(fault, "experiment envelope.after_noreplace")
                _fsync_directory(authority.store, "Experiment store root")
                _fault(fault, "experiment store root.after_fsync")
                verified = _verify_envelope(authority.store / name, name, authority.store_device)
                if verified.installation_key != key or verified.receipt_digest != receipt_digest:
                    _infra("published Experiment does not match its candidate")
                _cleanup_operation(authority, wrapper)
                return {
                    "changed": True,
                    "installationKey": key,
                    "name": name,
                    "receiptDigest": receipt_digest,
                }
    except StoreError:
        raise
    except experiment.InvalidManifest as error:
        raise StoreReject(str(error)) from error
    except experiment.InfrastructureError as error:
        raise StoreInfrastructure(str(error)) from error
    except (AttributeError, OSError, RuntimeError) as error:
        _infra("Experiment store operation could not establish a result", error)


def inspect_install(home: Path, name: str) -> dict[str, object]:
    """Read-only verification and identity projection for one installed name."""

    if not isinstance(name, str) or EXPERIMENT_NAME.fullmatch(name) is None:
        _reject("Experiment name is invalid")
    authority = _load_home(Path(home))
    try:
        with _store_lock(authority, None, exclusive=False):
            _revalidate_authority(authority)
            installed = _existing(authority, name)
    except StoreError:
        raise
    except OSError as error:
        _infra("Experiment installation cannot be inspected", error)
    if installed is None:
        _reject("Experiment name is not installed")
    return {
        "installationKey": installed.installation_key,
        "name": name,
        "receiptDigest": installed.receipt_digest,
        "state": "installed",
    }
