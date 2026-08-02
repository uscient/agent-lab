#!/usr/bin/env python3
"""Strict Experiment planning and no-effect authorization."""

from __future__ import annotations

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
from typing import NamedTuple, NoReturn
import zlib


MAX_MANIFEST_BYTES = 262_144
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
    """Read the first local ZIP member into the common source snapshot."""

    try:
        archive = Path(path).read_bytes()
        (
            signature,
            _version,
            _flags,
            method,
            _modified_time,
            _modified_date,
            _crc,
            compressed_size,
            _expanded_size,
            name_size,
            extra_size,
        ) = struct.unpack_from("<4s5H3I2H", archive)
        if signature != b"PK\x03\x04":
            raise ValueError("local header")
        start = 30 + name_size + extra_size
        payload = archive[start : start + compressed_size]
        if method == 0:
            data = payload
        elif method == 8:
            data = zlib.decompress(payload, -15)
        else:
            raise ValueError("compression method")
    except OSError as error:
        raise InfrastructureError("zip archive could not be read") from error
    except (struct.error, ValueError, zlib.error) as error:
        raise InvalidManifest("zip archive is malformed") from error
    return SourceSnapshot(
        data=data,
        digest=source_digest(data),
        transport={
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


def main(argv: list[str]) -> int:
    directory_checking = len(argv) == 3 and argv[1] == "check-directory"
    directory_authorizing = len(argv) == 3 and argv[1] == "authorize-directory"
    zip_checking = len(argv) == 3 and argv[1] == "check-zip"
    if directory_checking or directory_authorizing or zip_checking:
        try:
            if zip_checking:
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
                sys.stdout.buffer.write(canonical_json(checked) + b"\n")
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
