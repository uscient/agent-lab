#!/usr/bin/env python3
"""Provision and verified-execute the repository-pinned Cedar CLI release."""

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
from urllib.parse import urlsplit
from urllib.request import Request, urlopen


MAX_ARCHIVE_BYTES = 64 * 1024 * 1024
MAX_BINARY_BYTES = 128 * 1024 * 1024
MAX_ARCHIVE_MEMBERS = 64
MAX_EXPANDED_ARCHIVE_BYTES = 256 * 1024 * 1024
TARGETS = {
    ("darwin", "amd64"): "x86_64-apple-darwin",
    ("darwin", "arm64"): "aarch64-apple-darwin",
    ("linux", "amd64"): "x86_64-unknown-linux-gnu",
    ("linux", "arm64"): "aarch64-unknown-linux-gnu",
}
SUPPORTED_PLATFORMS = set(TARGETS)
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")


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
        raise ToolError("Cedar tool lock is unavailable") from error
    if path.is_symlink() or not stat.S_ISREG(path_stat.st_mode):
        raise ToolError("Cedar tool lock is missing or unsafe")
    if path_stat.st_size > maximum:
        raise ToolError("Cedar tool lock is overlong")
    try:
        data = path.read_bytes()
    except OSError as error:
        raise ToolError("Cedar tool lock cannot be read") from error
    if len(data) > maximum:
        raise ToolError("Cedar tool lock is overlong")
    return data


def parse_lock(path: Path) -> Lock:
    data = trusted_bytes(path, 16_384)
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError as error:
        raise ToolError("Cedar tool lock is not ASCII data") from error
    lines = text.splitlines()
    if len(lines) != 5 or any(not line or line != line.strip() for line in lines):
        raise ToolError("Cedar tool lock must contain one version and four artifacts")
    version_fields = lines[0].split(" ")
    if (
        len(version_fields) != 2
        or version_fields[0] != "version"
        or not VERSION_RE.fullmatch(version_fields[1])
    ):
        raise ToolError("Cedar tool lock version record is malformed")

    artifacts: dict[tuple[str, str], Artifact] = {}
    for line in lines[1:]:
        fields = line.split(" ")
        if len(fields) != 5 or fields[0] != "artifact":
            raise ToolError("Cedar tool lock artifact record is malformed")
        key = (fields[1], fields[2])
        if key not in SUPPORTED_PLATFORMS or key in artifacts:
            raise ToolError("Cedar tool lock platform matrix is malformed")
        if not SHA256_RE.fullmatch(fields[3]) or not SHA256_RE.fullmatch(fields[4]):
            raise ToolError("Cedar tool lock checksum is malformed")
        artifacts[key] = Artifact(fields[3], fields[4])
    if set(artifacts) != SUPPORTED_PLATFORMS:
        raise ToolError("Cedar tool lock platform matrix is incomplete")
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
        raise ToolError("unsupported Cedar platform or architecture")
    return key


def lexical_absolute(path: str) -> Path:
    if not os.path.isabs(path):
        raise ToolError("Cedar cache override must be absolute")
    normalized = Path(os.path.abspath(path))
    if normalized == Path(normalized.anchor):
        raise ToolError("Cedar cache root is too broad")
    return normalized


def cache_root(repo_root: Path) -> Path:
    configured = os.environ.get("AGENT_LAB_CEDAR_TOOL_DIR")
    root = lexical_absolute(configured) if configured else repo_root / ".cache/dev/tools/cedar"
    try:
        relative = root.relative_to(repo_root)
    except ValueError:
        return root
    if not relative.parts or relative.parts[0] != ".cache":
        raise ToolError("Cedar cache cannot use a tracked checkout path")
    return root


def open_directory_chain(path: Path, *, create: bool) -> int:
    if not path.is_absolute():
        raise ToolError("Cedar cache path is not absolute")
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        descriptor = os.open(path.anchor, flags)
    except OSError as error:
        raise ToolError("Cedar cache root cannot be opened") from error
    try:
        for component in path.parts[1:]:
            try:
                child = os.open(component, flags, dir_fd=descriptor)
            except FileNotFoundError:
                if not create:
                    raise ToolError("pinned Cedar tool is not provisioned") from None
                try:
                    os.mkdir(component, mode=0o700, dir_fd=descriptor)
                except FileExistsError:
                    pass
                except OSError as error:
                    raise ToolError("Cedar cache directory cannot be created") from error
                try:
                    child = os.open(component, flags, dir_fd=descriptor)
                except OSError as error:
                    raise ToolError("Cedar cache directory cannot be opened") from error
            except OSError as error:
                raise ToolError("Cedar cache path contains a symlink or non-directory") from error
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def binary_path(root: Path, lock: Lock, key: tuple[str, str]) -> Path:
    return root / lock.version / f"{key[0]}_{key[1]}" / "cedar"


def target_triple(key: tuple[str, str]) -> str:
    try:
        return TARGETS[key]
    except KeyError as error:
        raise ToolError("unsupported Cedar release target") from error


def archive_name(key: tuple[str, str]) -> str:
    return f"cedar-policy-cli-{target_triple(key)}.tar.xz"


def archive_member(key: tuple[str, str]) -> str:
    stem = archive_name(key).removesuffix(".tar.xz")
    return f"{stem}/cedar"


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
            raise ToolError("cached Cedar binary is overlong")
        digest.update(chunk)
    os.lseek(descriptor, 0, os.SEEK_SET)
    return digest.hexdigest()


def verified_descriptor(directory: int, name: str, expected_sha256: str) -> int:
    if not name or "/" in name or name in {".", ".."}:
        raise ToolError("cached Cedar binary name is unsafe")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(name, flags, dir_fd=directory)
    except OSError as error:
        raise ToolError(
            "pinned Cedar tool is unavailable; run scripts/dev/cedar-tool provision"
        ) from error
    try:
        binary_stat = os.fstat(descriptor)
        if (
            not stat.S_ISREG(binary_stat.st_mode)
            or stat.S_IMODE(binary_stat.st_mode) != 0o555
        ):
            raise ToolError("cached Cedar binary type or mode is unsafe")
        if hash_descriptor(descriptor, MAX_BINARY_BYTES) != expected_sha256:
            raise ToolError("cached Cedar binary checksum mismatch")
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
            raise ToolError("Cedar release archive is overlong")
        chunks.append(chunk)
    return b"".join(chunks)


def download_archive(url: str) -> bytes:
    request = Request(url, headers={"User-Agent": "agent-lab-cedar-provisioner/1"})
    try:
        with urlopen(request, timeout=30) as response:
            final_url = urlsplit(response.geturl())
            if final_url.scheme != "https":
                raise ToolError("Cedar release download left HTTPS")
            return read_bounded(response, MAX_ARCHIVE_BYTES)
    except (OSError, URLError) as error:
        raise ToolError("Cedar release download failed") from error


def extract_binary(archive: bytes, expected_member: str) -> bytes:
    found: bytes | None = None
    member_count = 0
    expanded_bytes = 0
    try:
        with tarfile.open(fileobj=BytesIO(archive), mode="r|xz") as bundle:
            for member in bundle:
                member_count += 1
                if member_count > MAX_ARCHIVE_MEMBERS:
                    raise ToolError("Cedar release archive has too many members")
                if member.size < 0:
                    raise ToolError("Cedar release archive has an invalid member size")
                expanded_bytes += member.size
                if expanded_bytes > MAX_EXPANDED_ARCHIVE_BYTES:
                    raise ToolError("Cedar release archive expands beyond its bound")
                if member.name != expected_member:
                    continue
                if found is not None or not member.isfile():
                    raise ToolError("Cedar release archive has no unique binary")
                if member.size > MAX_BINARY_BYTES:
                    raise ToolError("Cedar release binary is overlong")
                extracted = bundle.extractfile(member)
                if extracted is None:
                    raise ToolError("Cedar release binary cannot be extracted")
                data = extracted.read(MAX_BINARY_BYTES + 1)
                if len(data) > MAX_BINARY_BYTES or len(data) != member.size:
                    raise ToolError("Cedar release binary size is invalid")
                found = data
    except (EOFError, OSError, tarfile.TarError) as error:
        raise ToolError("Cedar release archive cannot be decoded") from error
    if found is None:
        raise ToolError("Cedar release archive has no unique binary")
    return found


def write_all(descriptor: int, data: bytes) -> None:
    offset = 0
    while offset < len(data):
        written = os.write(descriptor, data[offset:])
        if written <= 0:
            raise ToolError("Cedar release binary write made no progress")
        offset += written


def install_binary(directory: int, target_name: str, data: bytes) -> None:
    if not target_name or "/" in target_name or target_name in {".", ".."}:
        raise ToolError("Cedar release binary name is unsafe")
    descriptor = -1
    temporary = f".cedar.{os.getpid()}.{secrets.token_hex(8)}"
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
        write_all(descriptor, data)
        os.fchmod(descriptor, 0o555)
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
        raise ToolError("Cedar release binary cannot be installed") from error
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
    parent = open_directory_chain(target.parent, create=True)
    try:
        try:
            descriptor = verified_descriptor(parent, target.name, artifact.binary_sha256)
        except ToolError:
            pass
        else:
            os.close(descriptor)
            print(f"PASS Cedar {lock.version} already provisioned for {key[0]}/{key[1]}")
            return

        name = archive_name(key)
        tag = f"cedar-policy-cli-v{lock.version}"
        url = f"https://github.com/cedar-policy/cedar/releases/download/{tag}/{name}"
        archive = download_archive(url)
        if sha256(archive).hexdigest() != artifact.archive_sha256:
            raise ToolError("Cedar release archive checksum mismatch")
        binary = extract_binary(archive, archive_member(key))
        if sha256(binary).hexdigest() != artifact.binary_sha256:
            raise ToolError("Cedar release binary checksum mismatch")
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
            raise ToolError("Cedar cache path changed during provisioning")
        descriptor = verified_descriptor(
            canonical_parent,
            target.name,
            artifact.binary_sha256,
        )
        os.close(descriptor)
    finally:
        os.close(canonical_parent)
    print(f"PASS provisioned Cedar {lock.version} for {key[0]}/{key[1]}")


def execute_verified(
    descriptor: int,
    target: Path,
    arguments: list[str],
    environment: dict[str, str],
) -> NoReturn:
    argv = [str(target), *arguments]
    try:
        if os.execve in os.supports_fd:
            os.execve(descriptor, argv, environment)
        descriptor_stat = os.fstat(descriptor)
        path_stat = os.stat(target, follow_symlinks=False)
        identity = lambda value: (
            value.st_dev,
            value.st_ino,
            value.st_mode,
            value.st_size,
            value.st_mtime_ns,
            value.st_ctime_ns,
        )
        if identity(descriptor_stat) != identity(path_stat):
            raise ToolError("verified Cedar binary path changed before execution")
        os.execve(str(target), argv, environment)
    except BaseException:
        os.close(descriptor)
        raise
    raise AssertionError("unreachable")


def execute(repo_root: Path, lock: Lock, key: tuple[str, str], arguments: list[str]) -> NoReturn:
    root = cache_root(repo_root)
    target = binary_path(root, lock, key)
    parent = open_directory_chain(target.parent, create=False)
    try:
        descriptor = verified_descriptor(
            parent,
            target.name,
            lock.artifacts[key].binary_sha256,
        )
    finally:
        os.close(parent)
    execute_verified(descriptor, target, arguments, os.environ.copy())


def main(argv: list[str]) -> int:
    repo_root = Path(__file__).resolve().parents[2]
    try:
        lock = parse_lock(repo_root / "tools/cedar.lock")
        key = current_platform()
        if len(argv) >= 2 and argv[1] == "provision":
            if len(argv) != 2:
                raise ToolError("Cedar provision accepts no additional arguments")
            provision(repo_root, lock, key)
            return 0
        execute(repo_root, lock, key, argv[1:])
    except (OSError, ToolError) as error:
        infra(str(error))
    return 125


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
