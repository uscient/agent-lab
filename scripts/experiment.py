#!/usr/bin/env python3
"""Strict Experiment planning and no-effect authorization."""

from __future__ import annotations

import base64
import hashlib
from importlib.util import module_from_spec, spec_from_file_location
import json
import math
import os
from pathlib import Path
import re
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import time
from typing import Callable, NamedTuple, NoReturn
import zlib


MAX_MANIFEST_BYTES = 262_144
MAX_ARCHIVE_BYTES = 1_048_576
MAX_SOURCE_BYTES = MAX_MANIFEST_BYTES
ZIP_DECODE_TIMEOUT_SECONDS = 5
GIT_ACQUISITION_TIMEOUT_SECONDS = 5
GIT_PROVIDER_AUTHORITY = "api.github.com"
GIT_PROVIDER_METHOD = "github-git-data-v3"
GIT_PROVIDER_HEADERS = (
    ("Accept", "application/vnd.github+json"),
    ("User-Agent", "agent-lab/v0alpha1"),
    ("X-GitHub-Api-Version", "2022-11-28"),
)
GIT_SHA1 = re.compile(r"[0-9a-f]{40}", re.ASCII)
GITHUB_SOURCE_URL = re.compile(
    r"https://github\.com/"
    r"([A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?)/"
    r"([A-Za-z0-9_.-]{1,100})\.git",
    re.ASCII,
)
SOURCE_DIGEST_DOMAIN = b"agent-lab.experiment-tree.v1\0"
PLAN_DOMAIN = b"agent-lab.experiment-plan.v1\0"
BUNDLED_CATALOG_DOMAIN = b"agent-lab.experiment-image-catalog.v1\0"
BUNDLED_ENTRY_DOMAIN = b"agent-lab.experiment-image-entry.v1\0"
MAX_CUE_OUTPUT_BYTES = 1_048_576
MAX_CONTRACT_FILE_BYTES = 1_048_576
MAX_HELPER_BYTES = 1_048_576
CUE_TIMEOUT_SECONDS = 10
CEDAR_TIMEOUT_SECONDS = 10
MAX_CEDAR_OUTPUT_BYTES = 65_536
MAX_AUTHORIZATION_FILE_BYTES = 1_048_576
CONTRACT_FILES = tuple(
    sorted(
        (
            "contracts/experiment/v0alpha1/cue.mod/module.cue",
            "contracts/experiment/v0alpha1/plan.cue",
            "contracts/experiment/v0alpha1/schema.cue",
            "tools/cue.lock",
        )
    )
)
CONTRACT_DIGEST_DOMAIN = b"agent-lab.contract.v1\0"
AUTHORIZATION_FILES = tuple(
    sorted(
        (
            "authorization/experiment/v0alpha1/operator.cedar",
            "authorization/experiment/v0alpha1/schema.cedarschema",
            "tools/cedar.lock",
        )
    )
)
CEDAR_HELPER = "scripts/dev/cedar-tool.py"
AUTHORIZATION_DIGEST_DOMAIN = b"agent-lab.authorization-contract.v1\0"
CEDAR_VALIDATION_SUCCESS = (
    b'{"message": "policy set validation passed","severity": "advice",'
    b'"causes": ["no errors or warnings"],"labels": [],"related": []}\n'
)
CEDAR_ALLOW = b"\nALLOW\n"
CEDAR_DENY = b"\nDENY\n"
LEGACY_PRINCIPAL_ID = "legacy-local-operator"
INSTALL_ACTION_ID = "experiment.install"
PROBE_MANIFEST = {
    "apiVersion": "agent-lab/v0alpha1",
    "kind": "Experiment",
    "metadata": {"name": "contract-probe"},
    "spec": {
        "members": [
            {
                "name": "probe",
                "image": {
                    "digestRef": "probe@sha256:0000000000000000000000000000000000000000000000000000000000000000"
                },
            }
        ]
    },
}


class InvalidManifest(Exception):
    """The caller supplied bytes, but they are not a valid Experiment manifest."""


class InfrastructureError(Exception):
    """No trustworthy validation result can be produced."""


class DuplicateKey(InvalidManifest):
    """A JSON object contains the same decoded key more than once."""


class PlanBinding(NamedTuple):
    """Facts derived only from one canonical CUE plan."""

    plan_digest: str
    contract_digest: str
    contract_version: str
    requested_name: str
    member_count: int
    resource_classes: tuple[str, ...]
    source_digest: str


class SourceSnapshot(NamedTuple):
    data: bytes
    digest: str
    transport: dict[str, object]


class PlanResolution(NamedTuple):
    plan: dict[str, object]
    bundled_catalog: dict[str, object] | None
    local_catalog: dict[str, object] | None


def fail(message: str) -> NoReturn:
    print(f"FAIL Experiment manifest {message}", file=sys.stderr)
    raise SystemExit(1)


def infra(message: str) -> NoReturn:
    print(f"INFRA Experiment {message}", file=sys.stderr)
    raise SystemExit(125)


def safe_key(key: str) -> str:
    rendered = json.dumps(key, ensure_ascii=True)
    if len(rendered) > 130:
        return f"{rendered[:126]}...\""
    return rendered


def reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            raise DuplicateKey(f"contains duplicate JSON key {safe_key(key)}")
        value[key] = item
    return value


def reject_non_json_constant(value: str) -> NoReturn:
    raise InvalidManifest(f"contains non-JSON numeric constant {value}")


def reject_non_finite_numbers(value: object) -> None:
    if isinstance(value, float) and not math.isfinite(value):
        raise InvalidManifest("contains a number outside the supported JSON range")
    if isinstance(value, dict):
        for item in value.values():
            reject_non_finite_numbers(item)
    elif isinstance(value, list):
        for item in value:
            reject_non_finite_numbers(item)


def _manifest_identity(metadata: os.stat_result) -> tuple[int, ...]:
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


def read_manifest_once(
    path: str,
    *,
    expected: os.stat_result | None = None,
) -> bytes:
    try:
        path_stat = os.lstat(path)
    except OSError as error:
        raise InfrastructureError("manifest cannot be inspected") from error
    if expected is not None and _manifest_identity(path_stat) != _manifest_identity(expected):
        raise InfrastructureError("manifest identity changed before read")
    if stat.S_ISLNK(path_stat.st_mode):
        raise InfrastructureError("manifest symlinks are not accepted")
    if not stat.S_ISREG(path_stat.st_mode):
        raise InfrastructureError("manifest is not a regular file")
    if path_stat.st_size > MAX_MANIFEST_BYTES:
        raise InvalidManifest(f"exceeds the {MAX_MANIFEST_BYTES}-byte limit")

    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NONBLOCK", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise InfrastructureError("manifest cannot be opened") from error

    try:
        opened_stat = os.fstat(descriptor)
        if not stat.S_ISREG(opened_stat.st_mode):
            raise InfrastructureError("manifest changed to a non-regular file")
        if _manifest_identity(opened_stat) != _manifest_identity(path_stat):
            raise InfrastructureError("manifest identity changed before read")
        chunks: list[bytes] = []
        remaining = MAX_MANIFEST_BYTES + 1
        while remaining:
            chunk = os.read(descriptor, min(65_536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        final_stat = os.fstat(descriptor)
    except OSError as error:
        raise InfrastructureError("manifest could not be read completely") from error
    finally:
        try:
            os.close(descriptor)
        except OSError as error:
            raise InfrastructureError("manifest descriptor could not be closed") from error

    if len(data) > MAX_MANIFEST_BYTES:
        raise InvalidManifest(f"exceeds the {MAX_MANIFEST_BYTES}-byte limit")
    before = _manifest_identity(opened_stat)
    after = _manifest_identity(final_stat)
    if before != after or len(data) != final_stat.st_size:
        raise InfrastructureError("manifest changed while it was read")
    return data


def source_digest(data: bytes) -> str:
    name = b"experiment.cue"
    digest = hashlib.sha256(SOURCE_DIGEST_DOMAIN)
    digest.update(len(name).to_bytes(4, "big"))
    digest.update(name)
    digest.update(len(data).to_bytes(8, "big"))
    digest.update(data)
    return f"sha256:{digest.hexdigest()}"


GitRequester = Callable[
    [str, str, tuple[tuple[str, str], ...], int, float],
    tuple[int, tuple[tuple[str, str], ...], bytes],
]


def _git_reject(code: str, detail: str) -> NoReturn:
    raise InvalidManifest(f"git source {code} {detail}")


def _parse_git_source(url: str, commit: str) -> tuple[str, str, str, str]:
    if not isinstance(url, str) or not url.isascii():
        _git_reject("GIT-URL", "must be one normalized ASCII GitHub HTTPS URL")
    matched = GITHUB_SOURCE_URL.fullmatch(url)
    if matched is None:
        _git_reject("GIT-URL", "must be one normalized unauthenticated GitHub HTTPS URL")
    owner, repository = matched.groups()
    if owner.endswith("-") or "--" in owner or repository in (".", ".."):
        _git_reject("GIT-URL", "has an unsupported repository identity")
    if not isinstance(commit, str) or GIT_SHA1.fullmatch(commit) is None:
        _git_reject("GIT-OID", "commit must be one full lowercase SHA-1 object ID")
    owner = owner.lower()
    repository = repository.lower()
    canonical = f"https://github.com/{owner}/{repository}.git"
    return canonical, owner, repository, commit


def _git_object_id(kind: str, payload: bytes) -> str:
    framed = kind.encode("ascii") + b" " + str(len(payload)).encode("ascii") + b"\0"
    return hashlib.sha1(framed + payload, usedforsecurity=False).hexdigest()


def _git_provider_json(
    requester: GitRequester,
    path: str,
    remaining: int,
    deadline: float,
) -> tuple[object, int]:
    if remaining <= 0:
        raise InfrastructureError("git provider GIT-ACQUIRE exhausted its response bound")
    try:
        status, raw_headers, body = requester(
            GIT_PROVIDER_AUTHORITY,
            path,
            GIT_PROVIDER_HEADERS,
            remaining,
            deadline,
        )
    except (InvalidManifest, InfrastructureError):
        raise
    except Exception as error:
        raise InfrastructureError("git provider GIT-TRANSPORT request failed") from error
    if time.monotonic() > deadline:
        raise InfrastructureError("git provider GIT-TIMEOUT deadline expired")
    if not isinstance(status, int) or isinstance(status, bool):
        raise InfrastructureError("git provider GIT-STATUS response is malformed")
    if status in (404, 422):
        _git_reject("GIT-NOTFOUND", "does not expose the requested public object")
    if 300 <= status <= 399:
        _git_reject("GIT-REDIRECT", "redirects are not accepted")
    if status != 200:
        raise InfrastructureError("git provider GIT-STATUS did not establish a result")
    if not isinstance(raw_headers, tuple):
        raise InfrastructureError("git provider GIT-HEADER response is malformed")
    headers: dict[str, str] = {}
    for item in raw_headers:
        if (
            not isinstance(item, tuple)
            or len(item) != 2
            or not all(isinstance(value, str) for value in item)
        ):
            raise InfrastructureError("git provider GIT-HEADER response is malformed")
        name, value = item
        lowered = name.lower()
        if lowered in headers:
            raise InfrastructureError("git provider GIT-HEADER response is ambiguous")
        headers[lowered] = value
    if headers.get("content-type") != "application/json; charset=utf-8":
        raise InfrastructureError("git provider GIT-HEADER content type is uncertain")
    try:
        declared_length = int(headers.get("content-length", ""))
    except ValueError as error:
        raise InfrastructureError("git provider GIT-HEADER content length is invalid") from error
    if (
        not isinstance(body, bytes)
        or len(body) > remaining
        or declared_length != len(body)
    ):
        raise InfrastructureError("git provider GIT-OUTPUT response exceeded its bound")
    try:
        value = strict_json(body, source="git provider response")
    except InvalidManifest as error:
        raise InfrastructureError("git provider GIT-JSON response is malformed") from error
    return value, len(body)


def read_git_snapshot(
    url: str,
    commit: str,
    *,
    requester: GitRequester | None = None,
) -> SourceSnapshot:
    """Acquire one exact public GitHub commit through the bounded Git Data API."""

    if sys.platform != "linux":
        raise InfrastructureError("git source GIT-PLATFORM requires Linux")
    canonical, owner, repository, requested_commit = _parse_git_source(url, commit)
    if requester is None:
        raise InfrastructureError("git provider GIT-TRANSPORT runner is unavailable")
    deadline = time.monotonic() + GIT_ACQUISITION_TIMEOUT_SECONDS
    acquired = 0

    commit_path = f"/repos/{owner}/{repository}/git/commits/{requested_commit}"
    commit_value, used = _git_provider_json(
        requester, commit_path, MAX_ARCHIVE_BYTES - acquired, deadline
    )
    acquired += used
    if not isinstance(commit_value, dict) or commit_value.get("sha") != requested_commit:
        raise InfrastructureError("git provider GIT-COMMIT returned a different object")
    commit_tree = commit_value.get("tree")
    if not isinstance(commit_tree, dict):
        raise InfrastructureError("git provider GIT-COMMIT tree binding is malformed")
    tree_id = commit_tree.get("sha")
    if not isinstance(tree_id, str) or GIT_SHA1.fullmatch(tree_id) is None:
        raise InfrastructureError("git provider GIT-COMMIT tree identity is malformed")

    tree_path = f"/repos/{owner}/{repository}/git/trees/{tree_id}"
    tree_value, used = _git_provider_json(
        requester, tree_path, MAX_ARCHIVE_BYTES - acquired, deadline
    )
    acquired += used
    if (
        not isinstance(tree_value, dict)
        or tree_value.get("sha") != tree_id
        or tree_value.get("truncated") is not False
    ):
        raise InfrastructureError("git provider GIT-TREE response is inconsistent")
    entries = tree_value.get("tree")
    if not isinstance(entries, list) or len(entries) != 1:
        _git_reject("GIT-ROOT", "root tree must contain exactly experiment.cue")
    entry = entries[0]
    if not isinstance(entry, dict):
        raise InfrastructureError("git provider GIT-TREE entry is malformed")
    if (
        entry.get("path") != "experiment.cue"
        or entry.get("mode") != "100644"
        or entry.get("type") != "blob"
    ):
        _git_reject("GIT-TYPE", "experiment.cue must be one regular non-executable blob")
    blob_id = entry.get("sha")
    blob_size = entry.get("size")
    if not isinstance(blob_id, str) or GIT_SHA1.fullmatch(blob_id) is None:
        raise InfrastructureError("git provider GIT-TREE blob identity is malformed")
    if (
        not isinstance(blob_size, int)
        or isinstance(blob_size, bool)
        or not 0 <= blob_size <= MAX_SOURCE_BYTES
    ):
        _git_reject("GIT-SIZE", "experiment.cue exceeds the source limit")

    tree_payload = b"100644 experiment.cue\0" + bytes.fromhex(blob_id)
    if _git_object_id("tree", tree_payload) != tree_id:
        raise InfrastructureError("git provider GIT-TREE object identity is inconsistent")

    blob_path = f"/repos/{owner}/{repository}/git/blobs/{blob_id}"
    blob_value, used = _git_provider_json(
        requester, blob_path, MAX_ARCHIVE_BYTES - acquired, deadline
    )
    acquired += used
    if (
        not isinstance(blob_value, dict)
        or blob_value.get("sha") != blob_id
        or blob_value.get("size") != blob_size
        or blob_value.get("encoding") != "base64"
        or not isinstance(blob_value.get("content"), str)
    ):
        raise InfrastructureError("git provider GIT-BLOB response is inconsistent")
    encoded = blob_value["content"]
    assert isinstance(encoded, str)
    encoded_size = ((blob_size + 2) // 3) * 4
    if not encoded.isascii() or "\r" in encoded:
        raise InfrastructureError("git provider GIT-BLOB encoding exceeded its bound")
    if "\n" in encoded:
        if not encoded.endswith("\n"):
            raise InfrastructureError("git provider GIT-BLOB wrapping is malformed")
        lines = encoded[:-1].split("\n")
        if (
            not lines
            or any(len(line) != 60 for line in lines[:-1])
            or not 1 <= len(lines[-1]) <= 60
        ):
            raise InfrastructureError("git provider GIT-BLOB wrapping is malformed")
        compact = "".join(lines)
    else:
        compact = encoded
    if len(compact) != encoded_size:
        raise InfrastructureError("git provider GIT-BLOB encoding exceeded its bound")
    try:
        data = base64.b64decode(compact, validate=True)
    except (ValueError, base64.binascii.Error) as error:
        raise InfrastructureError("git provider GIT-BLOB encoding is malformed") from error
    if len(data) != blob_size or _git_object_id("blob", data) != blob_id:
        raise InfrastructureError("git provider GIT-BLOB object identity is inconsistent")

    return SourceSnapshot(
        data=data,
        digest=source_digest(data),
        transport={
            "acquisition": {
                "acquiredBytes": acquired,
                "limitBytes": MAX_ARCHIVE_BYTES,
                "method": GIT_PROVIDER_METHOD,
                "requestCount": 3,
                "temporaryBytes": 0,
                "temporaryFiles": 0,
            },
            "blob": f"sha1:{blob_id}",
            "commit": f"sha1:{requested_commit}",
            "kind": "git",
            "requestedCommit": requested_commit,
            "tree": f"sha1:{tree_id}",
            "url": canonical,
        },
    )


def _zip_reject(code: str, detail: str) -> NoReturn:
    raise InvalidManifest(f"zip archive {code} {detail}")


def _read_zip_archive_once(path: str) -> bytes:
    try:
        path_stat = os.lstat(path)
    except OSError as error:
        raise InfrastructureError("zip archive ZIP-READ cannot be inspected") from error
    if stat.S_ISLNK(path_stat.st_mode) or not stat.S_ISREG(path_stat.st_mode):
        raise InfrastructureError("zip archive ZIP-READ is not a safe regular file")
    if path_stat.st_size > MAX_ARCHIVE_BYTES:
        _zip_reject("ZIP-SIZE", f"exceeds the {MAX_ARCHIVE_BYTES}-byte limit")

    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NONBLOCK", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise InfrastructureError("zip archive ZIP-READ cannot be opened") from error

    opened_stat: os.stat_result | None = None
    final_stat: os.stat_result | None = None
    try:
        opened_stat = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened_stat.st_mode)
            or _manifest_identity(opened_stat) != _manifest_identity(path_stat)
        ):
            raise InfrastructureError("zip archive ZIP-READ identity changed before read")
        chunks: list[bytes] = []
        remaining = MAX_ARCHIVE_BYTES + 1
        while remaining:
            chunk = os.read(descriptor, min(65_536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        archive = b"".join(chunks)
        final_stat = os.fstat(descriptor)
    except InfrastructureError:
        raise
    except OSError as error:
        raise InfrastructureError("zip archive ZIP-READ could not be read completely") from error
    finally:
        try:
            os.close(descriptor)
        except OSError as error:
            raise InfrastructureError("zip archive ZIP-READ descriptor could not be closed") from error

    assert opened_stat is not None and final_stat is not None
    try:
        current_stat = os.lstat(path)
    except OSError as error:
        raise InfrastructureError("zip archive ZIP-READ cannot be reverified") from error
    expected = _manifest_identity(path_stat)
    if (
        _manifest_identity(opened_stat) != expected
        or _manifest_identity(final_stat) != expected
        or _manifest_identity(current_stat) != expected
        or len(archive) != final_stat.st_size
    ):
        raise InfrastructureError("zip archive ZIP-READ changed while being read")
    if len(archive) > MAX_ARCHIVE_BYTES:
        _zip_reject("ZIP-SIZE", f"exceeds the {MAX_ARCHIVE_BYTES}-byte limit")
    return archive


def _zip_eocd(archive: bytes) -> tuple[int, tuple[object, ...]]:
    eocd_offset = archive.rfind(b"PK\x05\x06")
    if eocd_offset < 0 or len(archive) - eocd_offset < 22:
        _zip_reject("ZIP-TRUNC", "has no complete end record")
    try:
        record = struct.unpack_from("<4s4H2IH", archive, eocd_offset)
    except struct.error as error:
        raise InvalidManifest("zip archive ZIP-TRUNC has an incomplete end record") from error
    comment_size = int(record[-1])
    if eocd_offset + 22 + comment_size != len(archive):
        _zip_reject("ZIP-TRAIL", "has bytes outside its canonical end")
    if comment_size != 0:
        _zip_reject("ZIP-META", "has an archive comment")
    return eocd_offset, record


def _zip_decode(payload: bytes, expanded_size: int) -> bytes:
    try:
        deadline = time.monotonic() + ZIP_DECODE_TIMEOUT_SECONDS
        decoder = zlib.decompressobj(-15)
        output: list[bytes] = []
        produced = 0
        offset = 0
        while offset < len(payload):
            if time.monotonic() >= deadline:
                raise TimeoutError("zip decoder deadline")
            chunk = payload[offset : offset + 65_536]
            offset += len(chunk)
            while chunk:
                remaining = MAX_SOURCE_BYTES + 1 - produced
                if remaining <= 0:
                    _zip_reject("ZIP-BOMB", "expands beyond the source limit")
                decoded = decoder.decompress(chunk, remaining)
                output.append(decoded)
                produced += len(decoded)
                chunk = decoder.unconsumed_tail
                if produced > MAX_SOURCE_BYTES:
                    _zip_reject("ZIP-BOMB", "expands beyond the source limit")
        if time.monotonic() >= deadline:
            raise TimeoutError("zip decoder deadline")
        remaining = MAX_SOURCE_BYTES + 1 - produced
        decoded = decoder.flush(remaining)
        output.append(decoded)
        produced += len(decoded)
        if produced > MAX_SOURCE_BYTES:
            _zip_reject("ZIP-BOMB", "expands beyond the source limit")
        if not decoder.eof:
            _zip_reject("ZIP-TRUNC", "deflate stream ended early")
        if decoder.unused_data or decoder.unconsumed_tail:
            _zip_reject("ZIP-TRAIL", "deflate stream has unused input")
        data = b"".join(output)
        if len(data) != expanded_size:
            _zip_reject("ZIP-LENGTH", "decoded length disagrees with its header")
    except InvalidManifest:
        raise
    except zlib.error as error:
        raise InvalidManifest("zip archive ZIP-TRUNC has an invalid deflate stream") from error
    except TimeoutError as error:
        raise InfrastructureError("zip archive ZIP-TIMEOUT decoder deadline expired") from error
    except Exception as error:
        raise InfrastructureError("zip archive ZIP-DECODE decoder result is uncertain") from error
    return data


def read_directory_snapshot(path: str) -> SourceSnapshot:
    try:
        directory_stat = os.lstat(path)
    except OSError as error:
        raise InfrastructureError("source directory cannot be inspected") from error
    if stat.S_ISLNK(directory_stat.st_mode) or not stat.S_ISDIR(directory_stat.st_mode):
        raise InvalidManifest("source must be one directory")
    try:
        before = os.listdir(path)
    except OSError as error:
        raise InfrastructureError("source directory cannot be listed") from error
    if before != ["experiment.cue"]:
        raise InvalidManifest("directory must contain only experiment.cue")
    authored_path = os.path.join(path, "experiment.cue")
    try:
        authored_stat = os.lstat(authored_path)
    except OSError as error:
        raise InfrastructureError("authored file cannot be inspected") from error
    if authored_stat.st_nlink != 1:
        raise InvalidManifest("experiment.cue must have one link")
    authored_mode = stat.S_IMODE(authored_stat.st_mode)
    if authored_mode & 0o111 or authored_mode & 0o022:
        raise InvalidManifest("experiment.cue has a suspicious mode")
    data = read_manifest_once(authored_path, expected=authored_stat)
    try:
        after = os.listdir(path)
        final_directory_stat = os.lstat(path)
    except OSError as error:
        raise InfrastructureError("source directory cannot be verified") from error
    if after != before or (directory_stat.st_dev, directory_stat.st_ino) != (
        final_directory_stat.st_dev,
        final_directory_stat.st_ino,
    ):
        raise InfrastructureError("source directory changed while snapshotting")
    return SourceSnapshot(
        data=data,
        digest=source_digest(data),
        transport={"kind": "directory"},
    )


def read_zip_snapshot(path: str) -> SourceSnapshot:
    """Inspect and bounded-decode one canonical in-memory ZIP source."""

    archive = _read_zip_archive_once(path)
    eocd_offset, eocd = _zip_eocd(archive)
    (
        _signature,
        disk_number,
        central_disk,
        disk_entries,
        total_entries,
        central_size,
        central_offset,
        _comment_size,
    ) = eocd
    if (
        disk_number != 0
        or central_disk != 0
        or disk_entries == 0xFFFF
        or total_entries == 0xFFFF
        or central_size == 0xFFFFFFFF
        or central_offset == 0xFFFFFFFF
    ):
        _zip_reject("ZIP-ZIP64", "uses ZIP64 or multiple disks")
    if disk_entries != 1 or total_entries != 1:
        _zip_reject("ZIP-COUNT", "must contain exactly one entry")
    if central_offset + central_size != eocd_offset:
        _zip_reject("ZIP-HEADER", "central directory bounds disagree")
    if central_size < 46 or central_offset < 30:
        _zip_reject("ZIP-TRUNC", "central directory is incomplete")
    try:
        central = struct.unpack_from("<4s6H3I5H2I", archive, central_offset)
    except struct.error as error:
        raise InvalidManifest("zip archive ZIP-TRUNC central header is incomplete") from error
    (
        central_signature,
        version_made,
        version_needed,
        flags,
        method,
        modified_time,
        modified_date,
        crc,
        compressed_size,
        expanded_size,
        name_size,
        central_extra_size,
        member_comment_size,
        member_disk,
        _internal_attributes,
        external_attributes,
        local_offset,
    ) = central
    if central_signature != b"PK\x01\x02":
        _zip_reject("ZIP-HEADER", "central signature is invalid")
    if (
        version_needed >= 45
        or compressed_size == 0xFFFFFFFF
        or expanded_size == 0xFFFFFFFF
        or local_offset == 0xFFFFFFFF
        or member_disk != 0
    ):
        _zip_reject("ZIP-ZIP64", "uses ZIP64 or multiple disks")
    central_record_size = 46 + name_size + central_extra_size + member_comment_size
    if central_record_size != central_size:
        _zip_reject("ZIP-HEADER", "central record size disagrees")
    if central_offset + central_record_size > eocd_offset:
        _zip_reject("ZIP-TRUNC", "central record is incomplete")
    if central_extra_size != 0 or member_comment_size != 0:
        _zip_reject("ZIP-META", "contains member metadata")
    if method not in (0, 8):
        _zip_reject("ZIP-METHOD", "uses unsupported compression")
    allowed_flags = 0x800 | (0x6 if method == 8 else 0)
    if flags & ~allowed_flags:
        _zip_reject("ZIP-FLAG", "uses unsupported general-purpose flags")
    minimum_version = 20 if method == 8 else 10
    if version_needed < minimum_version:
        _zip_reject("ZIP-HEADER", "version is too old for its compression method")
    if expanded_size > MAX_SOURCE_BYTES:
        _zip_reject("ZIP-SIZE", f"source exceeds the {MAX_SOURCE_BYTES}-byte limit")
    central_name = archive[central_offset + 46 : central_offset + 46 + name_size]
    create_system = version_made >> 8
    unix_mode = external_attributes >> 16
    unix_type = stat.S_IFMT(unix_mode)
    dos_attributes = external_attributes & 0xFFFF
    if (
        create_system not in (0, 3, 10, 14)
        or dos_attributes & 0x458
        or (create_system == 3 and unix_type not in (0, stat.S_IFREG))
    ):
        _zip_reject("ZIP-TYPE", "member is not a regular file")
    if local_offset != 0:
        _zip_reject("ZIP-HEADER", "local header is not at the canonical offset")

    try:
        local = struct.unpack_from("<4s5H3I2H", archive, local_offset)
    except struct.error as error:
        raise InvalidManifest("zip archive ZIP-TRUNC local header is incomplete") from error
    (
        local_signature,
        local_version,
        local_flags,
        local_method,
        local_time,
        local_date,
        local_crc,
        local_compressed_size,
        local_expanded_size,
        local_name_size,
        local_extra_size,
    ) = local
    if local_signature != b"PK\x03\x04":
        _zip_reject("ZIP-HEADER", "local signature is invalid")
    local_record_size = 30 + local_name_size + local_extra_size
    if local_record_size > central_offset:
        _zip_reject("ZIP-TRUNC", "local header is incomplete")
    local_name = archive[30 : 30 + local_name_size]
    if local_extra_size != 0:
        _zip_reject("ZIP-META", "contains local member metadata")
    if (
        local_version != version_needed
        or local_flags != flags
        or local_method != method
        or local_time != modified_time
        or local_date != modified_date
        or local_crc != crc
        or local_compressed_size != compressed_size
        or local_expanded_size != expanded_size
        or local_name != central_name
    ):
        _zip_reject("ZIP-HEADER", "local and central records disagree")
    try:
        decoded_name = central_name.decode("ascii")
    except UnicodeError as error:
        raise InvalidManifest("zip archive ZIP-PATH member name is not ASCII") from error
    if decoded_name != "experiment.cue":
        _zip_reject("ZIP-PATH", "member name must be exactly experiment.cue")
    payload_end = local_record_size + compressed_size
    if payload_end != central_offset:
        _zip_reject("ZIP-LENGTH", "compressed payload bounds disagree")
    payload = archive[local_record_size:payload_end]
    if len(payload) != compressed_size:
        _zip_reject("ZIP-TRUNC", "compressed payload is incomplete")
    if method == 0:
        if compressed_size != expanded_size:
            _zip_reject("ZIP-LENGTH", "stored member lengths disagree")
        data = payload
    else:
        data = _zip_decode(payload, expanded_size)
    if len(data) != expanded_size:
        _zip_reject("ZIP-LENGTH", "decoded length disagrees with its header")
    if (zlib.crc32(data) & 0xFFFFFFFF) != crc:
        _zip_reject("ZIP-CRC", "member checksum disagrees")
    return SourceSnapshot(
        data=data,
        digest=source_digest(data),
        transport={
            "archiveBytes": len(archive),
            "archiveDigest": "sha256:" + hashlib.sha256(archive).hexdigest(),
            "kind": "zip",
        },
    )


def authored_manifest(snapshot: SourceSnapshot) -> object:
    repo_root = Path(__file__).resolve().parent.parent
    cue_helper = repo_root / "scripts/dev/cue-tool.py"
    module = b'module: "agent-lab.local/experiment-snapshot"\nlanguage: version: "v0.9.0"\n'
    try:
        with tempfile.TemporaryDirectory(prefix="agent-lab-source-", dir="/tmp") as directory:
            root = Path(directory)
            write_private_file(root, "cue.mod/module.cue", module)
            write_private_file(root, "experiment.cue", snapshot.data)
            completed = subprocess.run(
                (
                    sys.executable,
                    "-I",
                    str(cue_helper),
                    "-C",
                    str(root),
                    "export",
                    "-E",
                    "experiment.cue",
                    "-e",
                    "experiment",
                    "--out",
                    "json",
                ),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                env=cue_environment(repo_root),
                timeout=CUE_TIMEOUT_SECONDS,
            )
    except (OSError, subprocess.SubprocessError) as error:
        raise InfrastructureError("authored CUE evaluation could not complete") from error
    if completed.returncode == 1:
        raise InvalidManifest("authored CUE value is invalid or incomplete")
    if completed.returncode != 0 or completed.stderr or not completed.stdout:
        raise InfrastructureError("pinned CUE could not export authored Experiment")
    if len(completed.stdout) > MAX_CUE_OUTPUT_BYTES:
        raise InfrastructureError("authored CUE output exceeded its bound")
    manifest = strict_json(completed.stdout, source="authored CUE export")
    if not isinstance(manifest, dict):
        raise InvalidManifest("experiment must export one object")
    return manifest


def strict_json(data: bytes, *, source: str) -> object:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise InvalidManifest(f"{source} is not UTF-8 JSON") from error
    try:
        value = json.loads(
            text,
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_non_json_constant,
        )
    except DuplicateKey:
        raise
    except (InvalidManifest, json.JSONDecodeError, RecursionError, ValueError) as error:
        if isinstance(error, InvalidManifest):
            raise
        if isinstance(error, json.JSONDecodeError):
            detail = f"is not strict JSON at line {error.lineno}, column {error.colno}"
        else:
            detail = "is not bounded strict JSON"
        raise InvalidManifest(f"{source} {detail}") from error
    try:
        json.dumps(value, ensure_ascii=False).encode("utf-8")
        reject_non_finite_numbers(value)
    except UnicodeEncodeError as error:
        raise InvalidManifest(f"{source} contains an invalid Unicode scalar") from error
    except RecursionError as error:
        raise InvalidManifest(f"{source} exceeds the supported nesting depth") from error
    return value


def canonical_json(value: object) -> bytes:
    try:
        return json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=True,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
    except (TypeError, ValueError, UnicodeEncodeError) as error:
        raise InfrastructureError("CUE produced a non-canonicalizable plan") from error


def plan_digest(plan: object) -> str:
    """Return the canonical, domain-separated identity of one checked plan."""

    return "sha256:" + hashlib.sha256(PLAN_DOMAIN + canonical_json(plan)).hexdigest()


def cue_environment(repo_root: Path) -> dict[str, str]:
    environment = {
        "PATH": "/usr/bin:/bin",
        "LANG": "C",
        "LC_ALL": "C",
        "CUE_CACHE_DIR": os.devnull,
        "CUE_CONFIG_DIR": os.devnull,
        "CUE_REGISTRY": "none",
    }
    tool_dir = os.environ.get("AGENT_LAB_CUE_TOOL_DIR")
    environment["AGENT_LAB_CUE_TOOL_DIR"] = tool_dir or str(
        repo_root / ".cache" / "dev" / "tools" / "cue"
    )
    return environment


def cedar_environment(repo_root: Path) -> dict[str, str]:
    environment = {
        "PATH": "/usr/bin:/bin",
        "LANG": "C",
        "LC_ALL": "C",
    }
    tool_dir = os.environ.get("AGENT_LAB_CEDAR_TOOL_DIR")
    environment["AGENT_LAB_CEDAR_TOOL_DIR"] = tool_dir or str(
        repo_root / ".cache" / "dev" / "tools" / "cedar"
    )
    return environment


def stable_file_bytes(path: Path, maximum: int, purpose: str) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise InfrastructureError(f"{purpose} cannot be opened") from error
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise InfrastructureError(f"{purpose} is not a regular file")
        if before.st_size > maximum:
            raise InfrastructureError(f"{purpose} is overlong")
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
        raise InfrastructureError(f"{purpose} cannot be read") from error
    finally:
        try:
            os.close(descriptor)
        except OSError as error:
            raise InfrastructureError(f"{purpose} descriptor cannot be closed") from error
    identity = lambda value: (
        value.st_dev,
        value.st_ino,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )
    if len(data) > maximum or len(data) != after.st_size or identity(before) != identity(after):
        raise InfrastructureError(f"{purpose} changed while it was read")
    return data


def framed_digest(domain: bytes, names: tuple[str, ...], files: dict[str, bytes]) -> str:
    digest = hashlib.sha256(domain)
    for name in sorted(names):
        data = files[name]
        encoded = name.encode("utf-8")
        digest.update(len(encoded).to_bytes(4, "big"))
        digest.update(encoded)
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)
    return f"sha256:{digest.hexdigest()}"


def authorization_snapshot(repo_root: Path) -> tuple[str, dict[str, bytes]]:
    files = {
        name: stable_file_bytes(
            repo_root / name,
            MAX_AUTHORIZATION_FILE_BYTES,
            "authorization snapshot",
        )
        for name in (*AUTHORIZATION_FILES, CEDAR_HELPER)
    }
    digest = framed_digest(AUTHORIZATION_DIGEST_DOMAIN, AUTHORIZATION_FILES, files)
    return digest, files


def verify_authorization_snapshot(repo_root: Path, expected: dict[str, bytes]) -> None:
    _, current = authorization_snapshot(repo_root)
    if current != expected:
        raise InfrastructureError("authorization snapshot changed during evaluation")


def contract_snapshot(repo_root: Path) -> tuple[str, dict[str, bytes]]:
    files: dict[str, bytes] = {}
    digest = hashlib.sha256(CONTRACT_DIGEST_DOMAIN)
    for name in CONTRACT_FILES:
        data = stable_file_bytes(
            repo_root / name,
            MAX_CONTRACT_FILE_BYTES,
            "contract snapshot",
        )
        files[name] = data
        encoded = name.encode("utf-8")
        digest.update(len(encoded).to_bytes(4, "big"))
        digest.update(encoded)
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)
    return digest.hexdigest(), files


def verify_contract_snapshot(repo_root: Path, expected: dict[str, bytes]) -> None:
    _, current = contract_snapshot(repo_root)
    if current != expected:
        raise InfrastructureError("contract snapshot changed during validation")


def write_private_file(root: Path, name: str, data: bytes) -> None:
    relative = Path(name)
    if relative.is_absolute() or ".." in relative.parts:
        raise InfrastructureError("private validation path is unsafe")
    target = root / relative
    try:
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        descriptor = os.open(
            target,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            0o400,
        )
    except OSError as error:
        raise InfrastructureError("private validation snapshot cannot be created") from error
    try:
        offset = 0
        while offset < len(data):
            written = os.write(descriptor, data[offset:])
            if written <= 0:
                raise InfrastructureError("private validation snapshot write made no progress")
            offset += written
    except OSError as error:
        raise InfrastructureError("private validation snapshot cannot be written") from error
    finally:
        try:
            os.close(descriptor)
        except OSError as error:
            raise InfrastructureError("private validation descriptor cannot be closed") from error


def materialize_validation_root(
    root: Path,
    contract_files: dict[str, bytes],
    cue_helper: bytes,
) -> None:
    for name, data in contract_files.items():
        write_private_file(root, name, data)
    write_private_file(root, "scripts/dev/cue-tool.py", cue_helper)


def materialize_authorization_root(
    root: Path,
    snapshot: dict[str, bytes],
    request: dict[str, object],
    entities: list[dict[str, object]],
) -> None:
    expected_names = set((*AUTHORIZATION_FILES, CEDAR_HELPER))
    if set(snapshot) != expected_names:
        raise InfrastructureError("authorization snapshot has an unexpected shape")
    for name, data in snapshot.items():
        write_private_file(root, name, data)
    write_private_file(root, "authorization-request.json", canonical_json(request) + b"\n")
    write_private_file(root, "authorization-entities.json", canonical_json(entities) + b"\n")


def expected_plan(manifest: object, contract_digest: str) -> dict[str, object]:
    try:
        assert isinstance(manifest, dict)
        if set(manifest) != {"apiVersion", "kind", "metadata", "spec"}:
            raise KeyError("top-level field drift")
        metadata = manifest["metadata"]
        specification = manifest["spec"]
        assert isinstance(metadata, dict) and isinstance(specification, dict)
        if set(metadata) != {"name"} or set(specification) != {"members"}:
            raise KeyError("metadata or spec field drift")
        raw_members = specification["members"]
        assert isinstance(raw_members, list)
        for member in raw_members:
            if (
                not isinstance(member, dict)
                or not {"name", "image"} <= set(member)
                or not set(member) <= {"name", "image", "command", "resourceClass"}
            ):
                raise KeyError("member field drift")
        members = []
        for member in raw_members:
            selector = member["image"]
            if not isinstance(selector, dict) or set(selector) not in ({"digestRef"}, {"catalogName"}):
                raise KeyError("unresolved selector")
            members.append({
                "command": member.get("command", []),
                "name": member["name"],
                "requestedSelector": selector,
                "resourceClass": member.get("resourceClass", "small"),
            })
        members.sort(key=lambda member: str(member["name"]))
        name = metadata["name"]
    except (AssertionError, KeyError, TypeError) as error:
        raise InfrastructureError("CUE accepted an input with an unexpected shape") from error
    return {
        "apiVersion": "agent-lab.request/v0alpha1",
        "contract": {
            "digest": f"sha256:{contract_digest}",
            "name": "agent-lab.experiment",
            "version": "v0alpha1",
        },
        "kind": "RequestedExperimentPlan",
        "metadata": {"requestedName": name},
        "spec": {"members": members},
    }


def image_reference_module():
    path = Path(__file__).resolve().with_name("image_reference.py")
    spec = spec_from_file_location("agent_lab_image_reference", path)
    if spec is None or spec.loader is None:
        raise InfrastructureError("shared image-reference grammar cannot be loaded")
    module = module_from_spec(spec)
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
    except (ImportError, OSError) as error:
        raise InfrastructureError("shared image-reference grammar cannot be loaded") from error
    return module


valid_catalog_name = image_reference_module().valid_image_name


def digest_record(domain: bytes, value: object) -> str:
    return "sha256:" + hashlib.sha256(domain + canonical_json(value)).hexdigest()


def image_catalog_module():
    path = Path(__file__).resolve().with_name("image_catalog.py")
    spec = spec_from_file_location("agent_lab_image_catalog", path)
    if spec is None or spec.loader is None:
        raise InfrastructureError("local image catalog support cannot be loaded")
    module = module_from_spec(spec)
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
    except (ImportError, OSError) as error:
        raise InfrastructureError("local image catalog support cannot be loaded") from error
    return module


def bundled_catalog(repo_root: Path) -> tuple[dict[str, object], str]:
    path = repo_root / "catalog/experiment-images/v0alpha1.json"
    data = stable_file_bytes(path, MAX_CONTRACT_FILE_BYTES, "bundled image catalog")
    value = strict_json(data, source="bundled image catalog")
    if not isinstance(value, dict) or set(value) != {"apiVersion", "entries"}:
        raise InfrastructureError("bundled image catalog has an unexpected shape")
    if value["apiVersion"] != "agent-lab.experiment-images/v0alpha1" or not isinstance(value["entries"], list):
        raise InfrastructureError("bundled image catalog has an unknown schema")
    return value, digest_record(BUNDLED_CATALOG_DOMAIN, value)


def resolve_plan_with_evidence(
    plan: dict[str, object],
    repo_root: Path,
    catalog: dict[str, object] | None = None,
) -> PlanResolution:
    resolved = json.loads(canonical_json(plan))
    members = resolved["spec"]["members"]
    bundled_names: set[str] = set()
    local_names: set[str] = set()
    for member in members:
        selector = member["requestedSelector"]
        if set(selector) == {"digestRef"}:
            member["resolvedImage"] = {"origin": "direct", "subject": selector["digestRef"]}
            continue
        if set(selector) != {"catalogName"} or not valid_catalog_name(selector["catalogName"]):
            raise InvalidManifest("contains an invalid image selector")
        name = selector["catalogName"]
        if name.startswith("agent-lab."):
            bundled_names.add(name)
        else:
            local_names.add(name)

    catalog_support = None
    bundled_by_name: dict[str, dict[str, object]] = {}
    bundled_evidence: dict[str, object] | None = None
    if bundled_names:
        catalog_support = image_catalog_module()
        selected_catalog = catalog
        if selected_catalog is None:
            selected_catalog, _ = bundled_catalog(repo_root)
        if (
            not isinstance(selected_catalog, dict)
            or set(selected_catalog) != {"apiVersion", "entries"}
            or selected_catalog.get("apiVersion")
            != "agent-lab.experiment-images/v0alpha1"
        ):
            raise InfrastructureError("bundled image catalog has an unexpected shape")
        entries = selected_catalog.get("entries")
        if not isinstance(entries, list):
            raise InfrastructureError("bundled image catalog entries are malformed")
        for entry in entries:
            if not isinstance(entry, dict) or set(entry) != {"name", "subject"}:
                raise InfrastructureError("bundled image catalog entry is malformed")
            name, subject = entry["name"], entry["subject"]
            if (
                not valid_catalog_name(name)
                or not isinstance(subject, str)
                or not catalog_support.oci_subject(subject)
            ):
                raise InfrastructureError("bundled image catalog entry is invalid")
            assert isinstance(name, str)
            if not name.startswith("agent-lab.") or name in bundled_by_name:
                raise InfrastructureError("bundled image catalog namespace is invalid")
            bundled_by_name[name] = entry
        bundled_evidence = {
            "snapshotDigest": digest_record(BUNDLED_CATALOG_DOMAIN, selected_catalog)
        }

    local_records: dict[str, dict[str, object]] = {}
    local_evidence: dict[str, object] | None = None
    if local_names:
        if catalog_support is None:
            catalog_support = image_catalog_module()
        raw_home = os.environ.get("AGENT_LAB_HOME")
        if not raw_home:
            raise InvalidManifest("local image name requires an initialized Agent Lab home")
        try:
            local_resolution = catalog_support.resolve_local_images(
                Path(raw_home), tuple(sorted(local_names))
            )
        except catalog_support.CatalogReject as error:
            raise InvalidManifest(str(error)) from error
        except catalog_support.CatalogInfrastructure as error:
            raise InfrastructureError(str(error)) from error
        try:
            if not isinstance(local_resolution, dict) or set(local_resolution) != {"catalog", "records"}:
                raise ValueError("resolution envelope")
            records = local_resolution["records"]
            evidence = local_resolution["catalog"]
            if not isinstance(records, dict) or set(records) != local_names:
                raise ValueError("resolution records")
            if not isinstance(evidence, dict) or set(evidence) != {"revision", "snapshotDigest"}:
                raise ValueError("resolution evidence")
            revision = evidence["revision"]
            snapshot_digest = evidence["snapshotDigest"]
            if (
                not isinstance(revision, int)
                or isinstance(revision, bool)
                or revision < 1
                or not is_sha256(snapshot_digest)
            ):
                raise ValueError("resolution evidence values")
            for name in local_names:
                record = records[name]
                if (
                    not isinstance(record, dict)
                    or record.get("name") != name
                    or record.get("state") != "active"
                    or type(record.get("generation")) is not int
                    or record["generation"] != 1
                    or record.get("previousEntryDigest") is not None
                    or not is_sha256(record.get("entryDigest"))
                    or not isinstance(record.get("subject"), str)
                    or not catalog_support.oci_subject(record["subject"])
                ):
                    raise ValueError("selected local record")
            local_records = records
            local_evidence = {
                "revision": revision,
                "snapshotDigest": snapshot_digest,
            }
        except (KeyError, TypeError, ValueError) as error:
            raise InfrastructureError("local image catalog returned invalid resolution evidence") from error

    for member in members:
        selector = member["requestedSelector"]
        if set(selector) == {"digestRef"}:
            continue
        name = selector["catalogName"]
        if name.startswith("agent-lab."):
            entry = bundled_by_name.get(name)
            if entry is None:
                raise InvalidManifest("references an unknown bundled image name")
            member["resolvedImage"] = {
                "entryDigest": digest_record(BUNDLED_ENTRY_DOMAIN, entry),
                "generation": 1,
                "origin": "agent-lab",
                "subject": entry["subject"],
            }
        else:
            record = local_records[name]
            member["resolvedImage"] = {
                "entryDigest": record["entryDigest"],
                "generation": record["generation"],
                "origin": "local",
                "subject": record["subject"],
            }
    return PlanResolution(resolved, bundled_evidence, local_evidence)


def resolve_plan(
    plan: dict[str, object],
    repo_root: Path,
    catalog: dict[str, object] | None = None,
) -> dict[str, object]:
    return resolve_plan_with_evidence(plan, repo_root, catalog).plan


def invoke_cue(
    manifest: object,
    contract_digest: str,
    validation_root: Path,
    repo_root: Path,
    contract_root: Path,
) -> subprocess.CompletedProcess[bytes]:
    cue_helper = validation_root / "scripts" / "dev" / "cue-tool.py"
    manifest_bytes = canonical_json(manifest) + b"\n"
    command = (
        sys.executable,
        "-I",
        str(cue_helper),
        "-C",
        str(contract_root),
        "export",
        "-E",
        "schema.cue",
        "plan.cue",
        "-l",
        "manifest:",
        "json:",
        "-",
        "-e",
        "#Plan",
        "-t",
        f"contractDigest=sha256:{contract_digest}",
        "--out",
        "json",
    )
    try:
        return subprocess.run(
            command,
            input=manifest_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            env=cue_environment(repo_root),
            timeout=CUE_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise InfrastructureError("CUE validation could not complete") from error


def parse_cue_plan(completed: subprocess.CompletedProcess[bytes]) -> dict[str, object]:
    if completed.stderr:
        raise InfrastructureError("pinned CUE emitted unexpected diagnostics")
    if not completed.stdout or len(completed.stdout) > MAX_CUE_OUTPUT_BYTES:
        raise InfrastructureError("pinned CUE emitted invalid output size")
    try:
        plan = strict_json(completed.stdout, source="CUE plan")
    except InvalidManifest as error:
        raise InfrastructureError("pinned CUE emitted malformed plan JSON") from error
    if not isinstance(plan, dict):
        raise InfrastructureError("pinned CUE emitted a non-object plan")
    return plan


def cue_plan_with_evidence(manifest: object) -> PlanResolution:
    repo_root = Path(__file__).resolve().parent.parent
    contract_root = repo_root / "contracts" / "experiment" / "v0alpha1"
    cue_helper = repo_root / "scripts" / "dev" / "cue-tool.py"
    required = (
        cue_helper,
        contract_root / "schema.cue",
        contract_root / "plan.cue",
        contract_root / "cue.mod" / "module.cue",
    )
    if any(not path.is_file() or path.is_symlink() for path in required):
        raise InfrastructureError("contract files are missing or unsafe")

    contract_digest, snapshot = contract_snapshot(repo_root)
    helper_snapshot = stable_file_bytes(cue_helper, MAX_HELPER_BYTES, "CUE tool helper")
    try:
        with tempfile.TemporaryDirectory(prefix="agent-lab-contract-", dir="/tmp") as directory:
            validation_root = Path(directory)
            materialize_validation_root(validation_root, snapshot, helper_snapshot)
            private_contract_root = validation_root / contract_root.relative_to(repo_root)

            probe = invoke_cue(
                PROBE_MANIFEST,
                contract_digest,
                validation_root,
                repo_root,
                private_contract_root,
            )
            verify_contract_snapshot(repo_root, snapshot)
            if probe.returncode != 0:
                raise InfrastructureError("trusted CUE contract health check failed")
            probe_plan = parse_cue_plan(probe)
            if probe_plan != expected_plan(PROBE_MANIFEST, contract_digest):
                raise InfrastructureError("trusted CUE contract health output is inconsistent")

            completed = invoke_cue(
                manifest,
                contract_digest,
                validation_root,
                repo_root,
                private_contract_root,
            )
            verify_contract_snapshot(repo_root, snapshot)
            if completed.returncode == 1:
                raise InvalidManifest("does not satisfy agent-lab/v0alpha1")
            if completed.returncode != 0:
                raise InfrastructureError("pinned CUE validation failed")
            plan = parse_cue_plan(completed)
            if plan != expected_plan(manifest, contract_digest):
                raise InfrastructureError("pinned CUE plan violates its exact postcondition")
            return resolve_plan_with_evidence(plan, repo_root)
    except OSError as error:
        raise InfrastructureError("private validation snapshot could not be managed") from error


def cue_plan(manifest: object) -> object:
    return cue_plan_with_evidence(manifest).plan


def is_sha256(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 71
        and value.startswith("sha256:")
        and all(character in "0123456789abcdef" for character in value[7:])
    )


def plan_binding(plan: object, source_digest: str) -> PlanBinding:
    """Derive the only facts the v0alpha1 policy is allowed to see."""
    try:
        if not isinstance(plan, dict) or set(plan) != {
            "apiVersion",
            "contract",
            "kind",
            "metadata",
            "spec",
        }:
            raise ValueError("plan envelope")
        if (
            plan["apiVersion"] != "agent-lab.request/v0alpha1"
            or plan["kind"] != "RequestedExperimentPlan"
        ):
            raise ValueError("plan identity")

        contract = plan["contract"]
        metadata = plan["metadata"]
        specification = plan["spec"]
        if not isinstance(contract, dict) or set(contract) != {"digest", "name", "version"}:
            raise ValueError("contract binding")
        if (
            contract["name"] != "agent-lab.experiment"
            or contract["version"] != "v0alpha1"
            or not is_sha256(contract["digest"])
        ):
            raise ValueError("contract identity")
        if not isinstance(metadata, dict) or set(metadata) != {"requestedName"}:
            raise ValueError("requested metadata")
        requested_name = metadata["requestedName"]
        if not isinstance(requested_name, str):
            raise ValueError("requested name")
        if not isinstance(specification, dict) or set(specification) != {"members"}:
            raise ValueError("plan specification")
        members = specification["members"]
        if not isinstance(members, list) or not members:
            raise ValueError("plan members")
        resource_classes: set[str] = set()
        for member in members:
            if not isinstance(member, dict) or set(member) != {
                "command",
                "name",
                "requestedSelector",
                "resolvedImage",
                "resourceClass",
            }:
                raise ValueError("plan member")
            resource_class = member["resourceClass"]
            if not isinstance(resource_class, str):
                raise ValueError("resource class")
            resource_classes.add(resource_class)
        contract_digest = contract["digest"]
        contract_version = contract["version"]
        assert isinstance(contract_digest, str) and isinstance(contract_version, str)
    except (AssertionError, KeyError, TypeError, ValueError) as error:
        raise InfrastructureError("CUE plan cannot be bound to authorization") from error

    bound_plan_digest = plan_digest(plan)
    return PlanBinding(
        plan_digest=bound_plan_digest,
        contract_digest=contract_digest,
        contract_version=contract_version,
        requested_name=requested_name,
        member_count=len(members),
        resource_classes=tuple(sorted(resource_classes)),
        source_digest=source_digest,
    )


def cedar_documents(
    binding: PlanBinding,
) -> tuple[dict[str, object], list[dict[str, object]]]:
    principal_uid = {"type": "AgentLab::Principal", "id": LEGACY_PRINCIPAL_ID}
    resource_uid = {
        "type": "AgentLab::RequestedExperimentPlan",
        "id": binding.plan_digest,
    }
    entities: list[dict[str, object]] = [
        {
            "uid": principal_uid,
            "attrs": {
                "authenticated": False,
                "assurance": "none",
                "source": "fixed-local-cli",
            },
            "parents": [],
        },
        {
            "uid": resource_uid,
            "attrs": {
                "planDigest": binding.plan_digest,
                "sourceDigest": binding.source_digest,
                "contractDigest": binding.contract_digest,
                "contractVersion": binding.contract_version,
                "requestedName": binding.requested_name,
                "memberCount": binding.member_count,
                "resourceClasses": list(binding.resource_classes),
            },
            "parents": [],
        },
    ]
    request: dict[str, object] = {
        "principal": f'AgentLab::Principal::"{LEGACY_PRINCIPAL_ID}"',
        "action": f'AgentLab::Action::"{INSTALL_ACTION_ID}"',
        "resource": (
            f'AgentLab::RequestedExperimentPlan::"{binding.plan_digest}"'
        ),
        "context": {
            "bindingVersion": "v0alpha1",
            "planDigest": binding.plan_digest,
            "sourceDigest": binding.source_digest,
            "contractDigest": binding.contract_digest,
        },
    }
    return request, entities


def cedar_group_alive(process: subprocess.Popen[bytes]) -> bool:
    try:
        os.killpg(process.pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def terminate_cedar_group(process: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=1.0)
    except subprocess.TimeoutExpired as error:
        raise InfrastructureError("Cedar process group could not be terminated") from error
    deadline = time.monotonic() + 1.0
    while cedar_group_alive(process) and time.monotonic() < deadline:
        time.sleep(0.01)
    if cedar_group_alive(process):
        raise InfrastructureError("Cedar process group could not be terminated")


def invoke_cedar(
    helper: Path,
    arguments: tuple[str, ...],
    repo_root: Path,
) -> subprocess.CompletedProcess[bytes]:
    command = (sys.executable, "-I", str(helper), *arguments)
    process: subprocess.Popen[bytes] | None = None
    completed: subprocess.CompletedProcess[bytes] | None = None
    interrupted: int | None = None
    handlers: dict[int, object] = {}
    managed_signals: set[int] = set()

    def interrupt(signum: int, _frame: object) -> None:
        nonlocal interrupted
        if interrupted is None:
            interrupted = signum

    def change_mask(how: int, signals: set[int]) -> set[signal.Signals]:
        try:
            return set(signal.pthread_sigmask(how, signals))
        except (AttributeError, OSError, ValueError) as error:
            raise InfrastructureError("Cedar signal controls are unavailable") from error

    def record_pending(signals: set[int]) -> None:
        nonlocal interrupted
        try:
            while True:
                pending = set(signal.sigpending()).intersection(signals)
                if not pending:
                    return
                for signum in sorted(pending, key=int):
                    received = int(signal.sigwait({signum}))
                    if interrupted is None:
                        interrupted = received
        except (AttributeError, OSError, ValueError) as error:
            raise InfrastructureError("Cedar pending signals could not be collected") from error

    try:
        original_mask = change_mask(signal.SIG_BLOCK, set())
        for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGQUIT, signal.SIGTERM):
            previous = signal.getsignal(signum)
            if previous == signal.SIG_IGN or signum in original_mask:
                continue
            handlers[signum] = previous
            signal.signal(signum, interrupt)
            managed_signals.add(signum)

        with tempfile.TemporaryFile() as stdout_file, tempfile.TemporaryFile() as stderr_file:
            spawn_mask = change_mask(signal.SIG_BLOCK, managed_signals)
            try:
                if interrupted is None:
                    process = subprocess.Popen(
                        command,
                        stdout=stdout_file,
                        stderr=stderr_file,
                        env=cedar_environment(repo_root),
                        start_new_session=True,
                    )
            finally:
                change_mask(signal.SIG_SETMASK, set(spawn_mask))

            if process is None:
                if interrupted is None:
                    raise InfrastructureError("Cedar evaluation did not start")
            else:
                deadline = time.monotonic() + CEDAR_TIMEOUT_SECONDS
                failure: str | None = None
                while interrupted is None:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        failure = "pinned Cedar evaluation timed out"
                        break
                    try:
                        returncode = process.wait(timeout=min(0.05, remaining))
                        break
                    except subprocess.TimeoutExpired:
                        if (
                            os.fstat(stdout_file.fileno()).st_size
                            > MAX_CEDAR_OUTPUT_BYTES
                            or os.fstat(stderr_file.fileno()).st_size
                            > MAX_CEDAR_OUTPUT_BYTES
                        ):
                            failure = "pinned Cedar emitted overlong output"
                            break

                if interrupted is None:
                    if failure is None and cedar_group_alive(process):
                        failure = "pinned Cedar left a residual process group"
                    if failure is not None:
                        raise InfrastructureError(failure)

                    stdout_size = os.fstat(stdout_file.fileno()).st_size
                    stderr_size = os.fstat(stderr_file.fileno()).st_size
                    if (
                        stdout_size > MAX_CEDAR_OUTPUT_BYTES
                        or stderr_size > MAX_CEDAR_OUTPUT_BYTES
                    ):
                        raise InfrastructureError("pinned Cedar emitted overlong output")
                    stdout_file.seek(0)
                    stderr_file.seek(0)
                    stdout = stdout_file.read(MAX_CEDAR_OUTPUT_BYTES + 1)
                    stderr = stderr_file.read(MAX_CEDAR_OUTPUT_BYTES + 1)
                    completed = subprocess.CompletedProcess(
                        command, returncode, stdout, stderr
                    )
    except InfrastructureError:
        raise
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        raise InfrastructureError("Cedar evaluation could not complete") from error
    finally:
        cleanup_error: InfrastructureError | None = None
        cleanup_mask: set[signal.Signals] | None = None
        try:
            cleanup_mask = change_mask(signal.SIG_BLOCK, managed_signals)
            if process is not None and cedar_group_alive(process):
                terminate_cedar_group(process)
            record_pending(managed_signals)
        except InfrastructureError as error:
            cleanup_error = error
        finally:
            for signum, previous in handlers.items():
                try:
                    signal.signal(signum, previous)
                except (OSError, ValueError):
                    if cleanup_error is None:
                        cleanup_error = InfrastructureError(
                            "Cedar signal dispositions could not be restored"
                        )
            if cleanup_mask is not None:
                try:
                    record_pending(managed_signals)
                except InfrastructureError as error:
                    if cleanup_error is None:
                        cleanup_error = error
                try:
                    change_mask(signal.SIG_SETMASK, set(cleanup_mask))
                except InfrastructureError as error:
                    if cleanup_error is None:
                        cleanup_error = error
        if cleanup_error is not None:
            raise cleanup_error

    if interrupted is not None:
        raise SystemExit(128 + interrupted)
    if completed is None:
        raise InfrastructureError("Cedar evaluation produced no result")
    return completed


def parse_cedar_validation(completed: subprocess.CompletedProcess[bytes]) -> None:
    if (
        completed.returncode != 0
        or completed.stdout != CEDAR_VALIDATION_SUCCESS
        or completed.stderr != b""
    ):
        raise InfrastructureError("strict Cedar policy validation was not exact")


def parse_cedar_authorization(completed: subprocess.CompletedProcess[bytes]) -> str:
    outcome = (completed.returncode, completed.stdout, completed.stderr)
    if outcome == (0, CEDAR_ALLOW, b""):
        return "permit"
    if outcome == (2, CEDAR_DENY, b""):
        return "deny"
    raise InfrastructureError("Cedar authorization result was ambiguous")


def evaluate_cedar(
    snapshot: dict[str, bytes],
    request: dict[str, object],
    entities: list[dict[str, object]],
    repo_root: Path,
) -> str:
    try:
        with tempfile.TemporaryDirectory(
            prefix="agent-lab-authorization-", dir="/tmp"
        ) as directory:
            root = Path(directory)
            materialize_authorization_root(root, snapshot, request, entities)
            helper = root / CEDAR_HELPER
            schema = root / "authorization/experiment/v0alpha1/schema.cedarschema"
            policies = root / "authorization/experiment/v0alpha1/operator.cedar"
            request_path = root / "authorization-request.json"
            entities_path = root / "authorization-entities.json"

            validated = invoke_cedar(
                helper,
                (
                    "--error-format",
                    "json",
                    "validate",
                    "--deny-warnings",
                    "--validation-mode",
                    "strict",
                    "--schema",
                    str(schema),
                    "--policies",
                    str(policies),
                ),
                repo_root,
            )
            parse_cedar_validation(validated)

            completed = invoke_cedar(
                helper,
                (
                    "--error-format",
                    "json",
                    "authorize",
                    "--request-validation",
                    "true",
                    "--schema",
                    str(schema),
                    "--policies",
                    str(policies),
                    "--entities",
                    str(entities_path),
                    "--request-json",
                    str(request_path),
                ),
                repo_root,
            )
            return parse_cedar_authorization(completed)
    except OSError as error:
        raise InfrastructureError("private authorization snapshot could not be managed") from error


def authorize_plan(plan: object, source_digest: str) -> tuple[dict[str, object], int]:
    repo_root = Path(__file__).resolve().parent.parent
    binding = plan_binding(plan, source_digest)
    request, entities = cedar_documents(binding)
    authorization_digest, snapshot = authorization_snapshot(repo_root)
    verdict = evaluate_cedar(snapshot, request, entities, repo_root)
    verify_authorization_snapshot(repo_root, snapshot)

    decision: dict[str, object] = {
        "action": INSTALL_ACTION_ID,
        "apiVersion": "agent-lab.authorization/v0alpha1",
        "binding": {
            "authorizationDigest": authorization_digest,
            "contractDigest": binding.contract_digest,
            "planDigest": binding.plan_digest,
            "sourceDigest": binding.source_digest,
        },
        "kind": "ExperimentAuthorizationDecision",
        "principal": {
            "assurance": "none",
            "authenticated": False,
            "id": LEGACY_PRINCIPAL_ID,
            "source": "fixed-local-cli",
            "type": "AgentLab::Principal",
        },
        "resource": {
            "id": binding.plan_digest,
            "requestedName": binding.requested_name,
            "type": "AgentLab::RequestedExperimentPlan",
        },
        "verdict": verdict,
    }
    return decision, 0 if verdict == "permit" else 1


def verify_trusted_inputs(plan: object, decision: object) -> None:
    """Re-snapshot trusted inputs and bind them to one authorized plan."""

    try:
        if (
            not isinstance(decision, dict)
            or not isinstance(decision.get("binding"), dict)
            or not isinstance(decision.get("resource"), dict)
        ):
            raise ValueError("decision envelope")
        binding = decision["binding"]
        resource = decision["resource"]
        if set(binding) != {
            "authorizationDigest",
            "contractDigest",
            "planDigest",
            "sourceDigest",
        }:
            raise ValueError("decision binding")
        source_digest = binding["sourceDigest"]
        if not is_sha256(source_digest):
            raise ValueError("source identity")
        expected = plan_binding(plan, source_digest)
        if (
            binding["planDigest"] != expected.plan_digest
            or binding["contractDigest"] != expected.contract_digest
            or resource.get("id") != expected.plan_digest
        ):
            raise ValueError("plan decision identity")
    except (KeyError, TypeError, ValueError) as error:
        raise InfrastructureError("authorized plan binding is inconsistent") from error

    repo_root = Path(__file__).resolve().parent.parent
    contract_digest, contract_files = contract_snapshot(repo_root)
    authorization_digest, authorization_files = authorization_snapshot(repo_root)
    verify_contract_snapshot(repo_root, contract_files)
    verify_authorization_snapshot(repo_root, authorization_files)
    if (
        expected.contract_digest != f"sha256:{contract_digest}"
        or binding["authorizationDigest"] != authorization_digest
    ):
        raise InfrastructureError("trusted inputs no longer match the authorization")


def catalog_resolution_evidence(
    bundled_catalog: dict[str, object] | None,
    local_catalog: dict[str, object] | None,
) -> dict[str, object] | None:
    catalog: dict[str, object] = {}
    if bundled_catalog is not None:
        catalog["bundled"] = bundled_catalog
    if local_catalog is not None:
        catalog["local"] = local_catalog
    return catalog or None


def write_envelope(
    plan: object,
    bundled_catalog: dict[str, object] | None = None,
    local_catalog: dict[str, object] | None = None,
) -> None:
    value: dict[str, object] = {"digest": plan_digest(plan), "plan": plan}
    catalog = catalog_resolution_evidence(bundled_catalog, local_catalog)
    if catalog is not None:
        value["catalog"] = catalog
    envelope = canonical_json(value) + b"\n"
    try:
        written = sys.stdout.buffer.write(envelope)
        if written != len(envelope):
            raise OSError("partial plan output")
        sys.stdout.buffer.flush()
    except (BrokenPipeError, OSError) as error:
        raise InfrastructureError("plan output could not be written") from error


def write_decision(decision: object) -> None:
    output = canonical_json(decision) + b"\n"
    try:
        written = sys.stdout.buffer.write(output)
        if written != len(output):
            raise OSError("partial decision output")
        sys.stdout.buffer.flush()
    except (BrokenPipeError, OSError) as error:
        raise InfrastructureError("authorization decision could not be written") from error


def write_checked_source(checked: object) -> None:
    output = canonical_json(checked) + b"\n"
    try:
        written = sys.stdout.buffer.write(output)
        if written != len(output):
            raise OSError("partial checked-source output")
        sys.stdout.buffer.flush()
    except (BrokenPipeError, OSError) as error:
        raise InfrastructureError("checked source output could not be written") from error


def main(argv: list[str]) -> int:
    directory_checking = len(argv) == 3 and argv[1] == "check-directory"
    directory_authorizing = len(argv) == 3 and argv[1] == "authorize-directory"
    zip_checking = len(argv) == 3 and argv[1] == "check-zip"
    zip_authorizing = len(argv) == 3 and argv[1] == "authorize-zip"
    if directory_checking or directory_authorizing or zip_checking or zip_authorizing:
        try:
            if zip_checking or zip_authorizing:
                snapshot = read_zip_snapshot(argv[2])
            else:
                snapshot = read_directory_snapshot(argv[2])
            manifest = authored_manifest(snapshot)
            resolution = cue_plan_with_evidence(manifest)
            plan = resolution.plan
            if directory_checking or zip_checking:
                checked: dict[str, object] = {
                    "digest": plan_digest(plan),
                    "plan": plan,
                    "source": {"digest": snapshot.digest, **snapshot.transport},
                }
                catalog = catalog_resolution_evidence(
                    resolution.bundled_catalog,
                    resolution.local_catalog,
                )
                if catalog is not None:
                    checked["catalog"] = catalog
                write_checked_source(checked)
                return 0
            decision, result = authorize_plan(plan, snapshot.digest)
            write_decision(decision)
            return result
        except InvalidManifest as error:
            fail(str(error))
        except InfrastructureError as error:
            infra(str(error))
    checking = len(argv) == 3 and argv[1] == "check"
    authorizing = (
        len(argv) == 4 and argv[1] == "authorize" and argv[2] == "install"
    )
    if not checking and not authorizing:
        print(
            "Usage: scripts/experiment check [--] MANIFEST\n"
            "Usage: scripts/experiment authorize install [--] MANIFEST",
            file=sys.stderr,
        )
        return 2
    try:
        manifest_bytes = read_manifest_once(argv[-1])
        manifest = strict_json(manifest_bytes, source="input")
        if not isinstance(manifest, dict):
            raise InvalidManifest("must be one JSON object")
        resolution = cue_plan_with_evidence(manifest)
        plan = resolution.plan
        if checking:
            write_envelope(
                plan,
                resolution.bundled_catalog,
                resolution.local_catalog,
            )
            return 0
        decision, result = authorize_plan(plan, "sha256:" + "0" * 64)
        write_decision(decision)
        return result
    except InvalidManifest as error:
        fail(str(error))
    except InfrastructureError as error:
        infra(str(error))
    raise AssertionError("unreachable")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
