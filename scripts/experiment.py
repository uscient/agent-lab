#!/usr/bin/env python3
"""Strict, read-once Experiment manifest validation and plan generation."""

from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
from typing import NoReturn


MAX_MANIFEST_BYTES = 262_144
MAX_CUE_OUTPUT_BYTES = 1_048_576
MAX_CONTRACT_FILE_BYTES = 1_048_576
MAX_HELPER_BYTES = 1_048_576
CUE_TIMEOUT_SECONDS = 10
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
PROBE_MANIFEST = {
    "apiVersion": "agent-lab/v0alpha1",
    "kind": "Experiment",
    "metadata": {"name": "contract-probe"},
    "spec": {
        "members": [
            {
                "name": "probe",
                "image": "probe@sha256:0000000000000000000000000000000000000000000000000000000000000000",
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


def read_manifest_once(path: str) -> bytes:
    try:
        path_stat = os.lstat(path)
    except OSError as error:
        raise InfrastructureError("manifest cannot be inspected") from error
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
        if (opened_stat.st_dev, opened_stat.st_ino) != (path_stat.st_dev, path_stat.st_ino):
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
    before = (
        opened_stat.st_dev,
        opened_stat.st_ino,
        opened_stat.st_size,
        opened_stat.st_mtime_ns,
    )
    after = (
        final_stat.st_dev,
        final_stat.st_ino,
        final_stat.st_size,
        final_stat.st_mtime_ns,
    )
    if before != after or len(data) != final_stat.st_size:
        raise InfrastructureError("manifest changed while it was read")
    return data


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
        members = [
            {
                "command": member.get("command", []),
                "image": member["image"],
                "name": member["name"],
                "resourceClass": member.get("resourceClass", "small"),
            }
            for member in raw_members
        ]
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


def cue_plan(manifest: object) -> object:
    repo_root = Path(__file__).resolve().parent.parent
    contract_root = repo_root / "contracts" / "experiment" / "v0alpha1"
    cue_tool = repo_root / "scripts" / "dev" / "cue-tool"
    cue_helper = repo_root / "scripts" / "dev" / "cue-tool.py"
    required = (
        cue_tool,
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
            return plan
    except OSError as error:
        raise InfrastructureError("private validation snapshot could not be managed") from error


def write_envelope(plan: object) -> None:
    plan_bytes = canonical_json(plan)
    digest = hashlib.sha256(plan_bytes).hexdigest()
    envelope = canonical_json({"digest": f"sha256:{digest}", "plan": plan}) + b"\n"
    try:
        written = sys.stdout.buffer.write(envelope)
        if written != len(envelope):
            raise OSError("partial plan output")
        sys.stdout.buffer.flush()
    except (BrokenPipeError, OSError) as error:
        raise InfrastructureError("plan output could not be written") from error


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] != "check":
        print("Usage: scripts/experiment check [--] MANIFEST", file=sys.stderr)
        return 2
    try:
        manifest_bytes = read_manifest_once(argv[2])
        manifest = strict_json(manifest_bytes, source="input")
        if not isinstance(manifest, dict):
            raise InvalidManifest("must be one JSON object")
        plan = cue_plan(manifest)
        write_envelope(plan)
    except InvalidManifest as error:
        fail(str(error))
    except InfrastructureError as error:
        infra(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
