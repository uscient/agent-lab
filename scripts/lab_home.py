#!/usr/bin/env python3
"""No-follow selected-home inspection for the public Agent Lab facade."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
import json
import os
from pathlib import Path
import pwd
import stat


MAX_AUTHORITY_BYTES = 65_536
CONFIG_VERSION = "agent-lab.config/v0alpha1"
HOME_VERSION = "agent-lab.home/v0alpha1"


class HomeKind(Enum):
    ABSENT = "absent"
    EMPTY = "uninitialized"
    READY = "ready"
    UNSAFE = "unsafe"
    INCOMPATIBLE = "incompatible"
    UNCERTAIN = "uncertain"


@dataclass(frozen=True)
class HomeObservation:
    path: Path
    kind: HomeKind
    device: int | None = None
    inode: int | None = None


def select_home(raw: str | None) -> Path:
    """Apply facade precedence without consulting ambient HOME."""

    selected = raw if raw is not None else os.environ.get("AGENT_LAB_HOME")
    if selected is None:
        selected = str(Path(pwd.getpwuid(os.getuid()).pw_dir) / ".agent-lab")
    if not selected or not os.path.isabs(selected):
        raise ValueError("selected home must be an absolute non-root path")
    normalized = os.path.normpath(selected)
    if normalized == "/":
        raise ValueError("selected home must be an absolute non-root path")
    return Path(normalized)


def _identity(metadata: os.stat_result) -> tuple[int, int, int, int, int]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _authority_safe(metadata: os.stat_result) -> bool:
    return (
        stat.S_ISREG(metadata.st_mode)
        and metadata.st_uid == os.getuid()
        and metadata.st_nlink == 1
        and stat.S_IMODE(metadata.st_mode) == 0o600
        and metadata.st_size <= MAX_AUTHORITY_BYTES
    )


def _read_authority(path: Path, lexical: os.stat_result) -> bytes:
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if not _authority_safe(opened) or _identity(opened) != _identity(lexical):
            raise OSError("authority identity changed")
        chunks: list[bytes] = []
        remaining = MAX_AUTHORITY_BYTES + 1
        while remaining:
            chunk = os.read(descriptor, min(remaining, 65_536))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        final = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    current = path.lstat()
    data = b"".join(chunks)
    if (
        len(data) > MAX_AUTHORITY_BYTES
        or len(data) != final.st_size
        or not _authority_safe(final)
        or not _authority_safe(current)
        or _identity(opened) != _identity(final)
        or _identity(opened) != _identity(current)
    ):
        raise OSError("authority changed while read")
    return data


def _canonical(value: object) -> bytes:
    return json.dumps(
        value, ensure_ascii=True, separators=(",", ":"), sort_keys=True
    ).encode("ascii") + b"\n"


def _version_kind(config_raw: bytes, receipt_raw: bytes) -> HomeKind:
    try:
        config = json.loads(config_raw.decode("utf-8"))
        receipt = json.loads(receipt_raw.decode("utf-8"))
    except (RecursionError, UnicodeError, ValueError):
        return HomeKind.UNCERTAIN
    if not isinstance(config, dict) or not isinstance(receipt, dict):
        return HomeKind.UNCERTAIN
    if (
        set(config) == {"apiVersion", "paths"}
        and isinstance(config.get("apiVersion"), str)
        and config["apiVersion"] != CONFIG_VERSION
        and config_raw == _canonical(config)
    ):
        return HomeKind.INCOMPATIBLE
    if (
        set(receipt) == {"apiVersion", "configDigest", "locks", "paths"}
        and isinstance(receipt.get("apiVersion"), str)
        and receipt["apiVersion"] != HOME_VERSION
        and receipt_raw == _canonical(receipt)
    ):
        return HomeKind.INCOMPATIBLE
    if config.get("apiVersion") != CONFIG_VERSION or receipt.get("apiVersion") != HOME_VERSION:
        return HomeKind.UNCERTAIN
    if config_raw != _canonical(config) or receipt_raw != _canonical(receipt):
        return HomeKind.UNCERTAIN
    return HomeKind.READY


def inspect_home(path: Path) -> HomeObservation:
    """Classify a selected boundary without following or changing it."""

    try:
        root = path.lstat()
    except FileNotFoundError:
        # A missing leaf below an aliased ancestor is not a canonical boundary.
        parent = path.parent
        try:
            if os.path.realpath(parent) != str(parent):
                return HomeObservation(path, HomeKind.UNSAFE)
        except OSError:
            return HomeObservation(path, HomeKind.UNCERTAIN)
        return HomeObservation(path, HomeKind.ABSENT)
    except OSError:
        return HomeObservation(path, HomeKind.UNCERTAIN)

    if (
        not stat.S_ISDIR(root.st_mode)
        or root.st_uid != os.getuid()
        or stat.S_IMODE(root.st_mode) != 0o700
    ):
        return HomeObservation(path, HomeKind.UNSAFE, root.st_dev, root.st_ino)
    try:
        if os.path.realpath(path) != str(path):
            return HomeObservation(path, HomeKind.UNSAFE, root.st_dev, root.st_ino)
    except OSError:
        return HomeObservation(path, HomeKind.UNCERTAIN, root.st_dev, root.st_ino)

    authorities: list[tuple[Path, os.stat_result | None]] = []
    for name in ("config.json", "home.json"):
        authority = path / name
        try:
            metadata = authority.lstat()
        except FileNotFoundError:
            metadata = None
        except OSError:
            return HomeObservation(path, HomeKind.UNCERTAIN, root.st_dev, root.st_ino)
        authorities.append((authority, metadata))

    present = [metadata is not None for _, metadata in authorities]
    if not any(present):
        try:
            empty = next(os.scandir(path), None) is None
        except OSError:
            return HomeObservation(path, HomeKind.UNCERTAIN, root.st_dev, root.st_ino)
        kind = HomeKind.EMPTY if empty else HomeKind.UNCERTAIN
        return HomeObservation(path, kind, root.st_dev, root.st_ino)
    if not all(present):
        return HomeObservation(path, HomeKind.UNCERTAIN, root.st_dev, root.st_ino)
    if any(not _authority_safe(metadata) for _, metadata in authorities if metadata is not None):
        return HomeObservation(path, HomeKind.UNSAFE, root.st_dev, root.st_ino)

    try:
        config_raw = _read_authority(authorities[0][0], authorities[0][1])  # type: ignore[arg-type]
        receipt_raw = _read_authority(authorities[1][0], authorities[1][1])  # type: ignore[arg-type]
        current = path.lstat()
    except (OSError, RuntimeError):
        return HomeObservation(path, HomeKind.UNCERTAIN, root.st_dev, root.st_ino)
    if (
        not stat.S_ISDIR(current.st_mode)
        or current.st_uid != root.st_uid
        or stat.S_IMODE(current.st_mode) != 0o700
        or (current.st_dev, current.st_ino) != (root.st_dev, root.st_ino)
    ):
        return HomeObservation(path, HomeKind.UNCERTAIN, root.st_dev, root.st_ino)
    return HomeObservation(
        path, _version_kind(config_raw, receipt_raw), root.st_dev, root.st_ino
    )
