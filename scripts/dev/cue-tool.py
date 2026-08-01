#!/usr/bin/env python3
"""Provision and descriptor-execute the repository-pinned CUE release."""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
from io import BytesIO
import os
from pathlib import Path
import platform
import re
import secrets
import stat
import sys
import tarfile
from typing import NoReturn
from urllib.error import URLError
from urllib.request import Request, urlopen


MAX_ARCHIVE_BYTES = 64 * 1024 * 1024
MAX_BINARY_BYTES = 128 * 1024 * 1024
SUPPORTED_PLATFORMS = {
    ("darwin", "amd64"),
    ("darwin", "arm64"),
    ("linux", "amd64"),
    ("linux", "arm64"),
}
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
VERSION_RE = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")


class ToolError(Exception):
    """The pinned tool cannot be trusted or made available."""


@dataclass(frozen=True)
class Artifact:
    archive_sha256: str
    binary_sha256: str


@dataclass(frozen=True)
class Lock:
    version: str
    artifacts: dict[tuple[str, str], Artifact]


def infra(message: str) -> NoReturn:
    print(f"INFRA {message}", file=sys.stderr)
    raise SystemExit(125)


def trusted_bytes(path: Path, maximum: int) -> bytes:
    try:
        path_stat = path.lstat()
    except OSError as error:
        raise ToolError("CUE tool lock is unavailable") from error
    if path.is_symlink() or not stat.S_ISREG(path_stat.st_mode):
        raise ToolError("CUE tool lock is missing or unsafe")
    if path_stat.st_size > maximum:
        raise ToolError("CUE tool lock is overlong")
    try:
        data = path.read_bytes()
    except OSError as error:
        raise ToolError("CUE tool lock cannot be read") from error
    if len(data) > maximum:
        raise ToolError("CUE tool lock is overlong")
    return data


def parse_lock(path: Path) -> Lock:
    data = trusted_bytes(path, 16_384)
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError as error:
        raise ToolError("CUE tool lock is not ASCII data") from error
    lines = text.splitlines()
    if len(lines) != 5 or any(not line or line != line.strip() for line in lines):
        raise ToolError("CUE tool lock must contain one version and four artifacts")
    version_fields = lines[0].split(" ")
    if (
        len(version_fields) != 2
        or version_fields[0] != "version"
        or not VERSION_RE.fullmatch(version_fields[1])
    ):
        raise ToolError("CUE tool lock version record is malformed")

    artifacts: dict[tuple[str, str], Artifact] = {}
    for line in lines[1:]:
        fields = line.split(" ")
        if len(fields) != 5 or fields[0] != "artifact":
            raise ToolError("CUE tool lock artifact record is malformed")
        key = (fields[1], fields[2])
        if key not in SUPPORTED_PLATFORMS or key in artifacts:
            raise ToolError("CUE tool lock platform matrix is malformed")
        if not SHA256_RE.fullmatch(fields[3]) or not SHA256_RE.fullmatch(fields[4]):
            raise ToolError("CUE tool lock checksum is malformed")
        artifacts[key] = Artifact(fields[3], fields[4])
    if set(artifacts) != SUPPORTED_PLATFORMS:
        raise ToolError("CUE tool lock platform matrix is incomplete")
    return Lock(version_fields[1], artifacts)


def current_platform() -> tuple[str, str]:
    system = platform.system().lower()
    machine = platform.machine().lower()
    architecture = {
        "aarch64": "arm64",
        "amd64": "amd64",
        "arm64": "arm64",
        "x86_64": "amd64",
    }.get(machine)
    key = (system, architecture or "")
    if key not in SUPPORTED_PLATFORMS:
        raise ToolError("unsupported CUE platform or architecture")
    return key


def lexical_absolute(path: str) -> Path:
    if not os.path.isabs(path):
        raise ToolError("CUE cache override must be absolute")
    normalized = Path(os.path.abspath(path))
    if normalized == Path(normalized.anchor):
        raise ToolError("CUE cache root is too broad")
    return normalized


def cache_root(repo_root: Path) -> Path:
    configured = os.environ.get("AGENT_LAB_CUE_TOOL_DIR")
    root = lexical_absolute(configured) if configured else repo_root / ".cache/dev/tools/cue"
    try:
        relative = root.relative_to(repo_root)
    except ValueError:
        return root
    if not relative.parts or relative.parts[0] != ".cache":
        raise ToolError("CUE cache cannot use a tracked checkout path")
    return root


def open_directory_chain(path: Path, *, create: bool) -> int:
    if not path.is_absolute():
        raise ToolError("CUE cache path is not absolute")
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        descriptor = os.open(path.anchor, flags)
    except OSError as error:
        raise ToolError("CUE cache root cannot be opened") from error
    try:
        for component in path.parts[1:]:
            try:
                child = os.open(component, flags, dir_fd=descriptor)
            except FileNotFoundError:
                if not create:
                    raise ToolError("pinned CUE tool is not provisioned") from None
                try:
                    os.mkdir(component, mode=0o700, dir_fd=descriptor)
                except FileExistsError:
                    pass
                except OSError as error:
                    raise ToolError("CUE cache directory cannot be created") from error
                try:
                    child = os.open(component, flags, dir_fd=descriptor)
                except OSError as error:
                    raise ToolError("CUE cache directory cannot be opened") from error
            except OSError as error:
                raise ToolError("CUE cache path contains a symlink or non-directory") from error
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def binary_path(root: Path, lock: Lock, key: tuple[str, str]) -> Path:
    return root / lock.version / f"{key[0]}_{key[1]}" / "cue"


def hash_descriptor(descriptor: int, maximum: int) -> str:
    digest = sha256()
    total = 0
    os.lseek(descriptor, 0, os.SEEK_SET)
    while True:
        chunk = os.read(descriptor, 65_536)
        if not chunk:
            break
        total += len(chunk)
        if total > maximum:
            raise ToolError("cached CUE binary is overlong")
        digest.update(chunk)
    os.lseek(descriptor, 0, os.SEEK_SET)
    return digest.hexdigest()


def verified_descriptor(directory: int, name: str, expected_sha256: str) -> int:
    if not name or "/" in name or name in {".", ".."}:
        raise ToolError("cached CUE binary name is unsafe")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(name, flags, dir_fd=directory)
    except OSError as error:
        raise ToolError("pinned CUE tool is unavailable; run scripts/dev/cue-tool provision") from error
    try:
        binary_stat = os.fstat(descriptor)
        if not stat.S_ISREG(binary_stat.st_mode) or binary_stat.st_mode & 0o222:
            raise ToolError("cached CUE binary type or mode is unsafe")
        if hash_descriptor(descriptor, MAX_BINARY_BYTES) != expected_sha256:
            raise ToolError("cached CUE binary checksum mismatch")
    except BaseException:
        os.close(descriptor)
        raise
    return descriptor


def read_bounded(response: object, maximum: int) -> bytes:
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = response.read(65_536)  # type: ignore[attr-defined]
        if not chunk:
            break
        total += len(chunk)
        if total > maximum:
            raise ToolError("CUE release archive is overlong")
        chunks.append(chunk)
    return b"".join(chunks)


def download_archive(url: str) -> bytes:
    request = Request(url, headers={"User-Agent": "agent-lab-cue-provisioner/1"})
    try:
        with urlopen(request, timeout=30) as response:
            final_url = response.geturl()
            if not final_url.startswith("https://"):
                raise ToolError("CUE release download left HTTPS")
            return read_bounded(response, MAX_ARCHIVE_BYTES)
    except (OSError, URLError) as error:
        raise ToolError("CUE release download failed") from error


def extract_binary(archive: bytes) -> bytes:
    try:
        with tarfile.open(fileobj=BytesIO(archive), mode="r:gz") as bundle:
            members = [member for member in bundle.getmembers() if member.name == "cue"]
            if len(members) != 1 or not members[0].isfile():
                raise ToolError("CUE release archive has no unique binary")
            if members[0].size > MAX_BINARY_BYTES:
                raise ToolError("CUE release binary is overlong")
            extracted = bundle.extractfile(members[0])
            if extracted is None:
                raise ToolError("CUE release binary cannot be extracted")
            data = extracted.read(MAX_BINARY_BYTES + 1)
    except (tarfile.TarError, OSError) as error:
        raise ToolError("CUE release archive cannot be decoded") from error
    if len(data) > MAX_BINARY_BYTES or len(data) != members[0].size:
        raise ToolError("CUE release binary size is invalid")
    return data


def write_all(descriptor: int, data: bytes) -> None:
    offset = 0
    while offset < len(data):
        written = os.write(descriptor, data[offset:])
        if written <= 0:
            raise ToolError("CUE release binary write made no progress")
        offset += written


def install_binary(directory: int, target_name: str, data: bytes) -> None:
    if not target_name or "/" in target_name or target_name in {".", ".."}:
        raise ToolError("CUE release binary name is unsafe")
    descriptor = -1
    temporary = f".cue.{os.getpid()}.{secrets.token_hex(8)}"
    try:
        descriptor = os.open(
            temporary,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            0o500,
            dir_fd=directory,
        )
        os.fchmod(descriptor, 0o555)
        write_all(descriptor, data)
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        os.replace(
            temporary,
            target_name,
            src_dir_fd=directory,
            dst_dir_fd=directory,
        )
        temporary = ""
        os.fsync(directory)
    except (OSError, ToolError) as error:
        if isinstance(error, ToolError):
            raise
        raise ToolError("CUE release binary cannot be installed") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary:
            try:
                os.unlink(temporary, dir_fd=directory)
            except FileNotFoundError:
                pass


def provision(repo_root: Path, lock: Lock, key: tuple[str, str]) -> None:
    root = cache_root(repo_root)
    target = binary_path(root, lock, key)
    artifact = lock.artifacts[key]
    parent = -1
    try:
        parent = open_directory_chain(target.parent, create=False)
        descriptor = verified_descriptor(parent, target.name, artifact.binary_sha256)
    except ToolError:
        pass
    else:
        os.close(descriptor)
        os.close(parent)
        parent = -1
        print(f"PASS CUE {lock.version} already provisioned for {key[0]}/{key[1]}")
        return
    finally:
        if parent >= 0:
            os.close(parent)

    archive_name = f"cue_{lock.version}_{key[0]}_{key[1]}.tar.gz"
    url = f"https://github.com/cue-lang/cue/releases/download/{lock.version}/{archive_name}"
    archive = download_archive(url)
    if sha256(archive).hexdigest() != artifact.archive_sha256:
        raise ToolError("CUE release archive checksum mismatch")
    binary = extract_binary(archive)
    if sha256(binary).hexdigest() != artifact.binary_sha256:
        raise ToolError("CUE release binary checksum mismatch")
    parent = open_directory_chain(target.parent, create=True)
    try:
        installed_identity = os.fstat(parent)
        install_binary(parent, target.name, binary)
        descriptor = verified_descriptor(parent, target.name, artifact.binary_sha256)
        os.close(descriptor)
    finally:
        os.close(parent)
    canonical_parent = open_directory_chain(target.parent, create=False)
    try:
        canonical_identity = os.fstat(canonical_parent)
        if (installed_identity.st_dev, installed_identity.st_ino) != (
            canonical_identity.st_dev,
            canonical_identity.st_ino,
        ):
            raise ToolError("CUE cache path changed during provisioning")
        descriptor = verified_descriptor(
            canonical_parent,
            target.name,
            artifact.binary_sha256,
        )
        os.close(descriptor)
    finally:
        os.close(canonical_parent)
    print(f"PASS provisioned CUE {lock.version} for {key[0]}/{key[1]}")


def execute(repo_root: Path, lock: Lock, key: tuple[str, str], arguments: list[str]) -> NoReturn:
    root = cache_root(repo_root)
    target = binary_path(root, lock, key)
    parent = open_directory_chain(target.parent, create=False)
    try:
        descriptor = verified_descriptor(parent, target.name, lock.artifacts[key].binary_sha256)
    finally:
        os.close(parent)
    if os.execve not in os.supports_fd:
        os.close(descriptor)
        raise ToolError("descriptor-bound CUE execution is unsupported")
    argv = [str(target), *arguments]
    os.execve(descriptor, argv, os.environ.copy())
    raise AssertionError("unreachable")


def main(argv: list[str]) -> int:
    repo_root = Path(__file__).resolve().parents[2]
    try:
        lock = parse_lock(repo_root / "tools/cue.lock")
        key = current_platform()
        if len(argv) >= 2 and argv[1] == "provision":
            if len(argv) != 2:
                raise ToolError("CUE provision accepts no additional arguments")
            provision(repo_root, lock, key)
            return 0
        execute(repo_root, lock, key, argv[1:])
    except (OSError, ToolError) as error:
        infra(str(error))
    return 125


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
