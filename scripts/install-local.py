#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import pwd
import shutil
import stat
import sys
import tempfile


def fail(message: str, code: int = 1) -> int:
    print(f"FAIL local install {message}", file=sys.stderr)
    return code


def prefix_from(argv: list[str]) -> Path:
    if len(argv) == 2 and argv[0] == "--prefix" and argv[1]:
        raw = argv[1]
    elif not argv:
        raw = os.environ.get("AGENT_LAB_PREFIX") or str(Path(pwd.getpwuid(os.getuid()).pw_dir) / ".local")
    else:
        raise ValueError("Usage: scripts/install-local [--prefix ABSOLUTE_PREFIX]")
    path = Path(raw)
    if not path.is_absolute() or path == Path("/"):
        raise ValueError("prefix must be an absolute non-root path")
    return path


def main(argv: list[str]) -> int:
    try:
        prefix = prefix_from(argv)
    except ValueError as error:
        print(error, file=sys.stderr)
        return 2
    root = Path(__file__).resolve().parent.parent
    manifest_path = root / "packaging/agent-lab-local.manifest"
    try:
        names = manifest_path.read_text(encoding="ascii").splitlines()
    except OSError:
        return fail("runtime manifest is unavailable", 125)
    if names != sorted(set(names)) or not names:
        return fail("runtime manifest is not canonical", 125)
    digest = hashlib.sha256(b"agent-lab.local-bundle.v1\0")
    sources: list[tuple[str, Path, bytes, int]] = []
    try:
        for name in names:
            relative = Path(name)
            if relative.is_absolute() or ".." in relative.parts:
                raise OSError("unsafe manifest path")
            source = root / relative
            metadata = source.lstat()
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
                raise OSError("unsafe runtime source")
            data = source.read_bytes()
            final = source.stat()
            if (metadata.st_dev, metadata.st_ino, metadata.st_size, metadata.st_mtime_ns) != (
                final.st_dev, final.st_ino, final.st_size, final.st_mtime_ns
            ):
                raise OSError("runtime source changed")
            encoded = name.encode("ascii")
            digest.update(len(encoded).to_bytes(4, "big"))
            digest.update(encoded)
            digest.update(len(data).to_bytes(8, "big"))
            digest.update(data)
            sources.append((name, source, data, stat.S_IMODE(metadata.st_mode)))
    except (OSError, UnicodeError):
        return fail("runtime source is unsafe or changing", 125)
    release_id = digest.hexdigest()
    releases = prefix / "lib/agent-lab/releases"
    release = releases / release_id
    try:
        releases.mkdir(mode=0o700, parents=True, exist_ok=True)
        if not release.exists():
            stage = Path(tempfile.mkdtemp(prefix=".agent-lab-release-", dir=releases))
            try:
                for name, _source, data, mode in sources:
                    target = stage / name
                    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                    target.write_bytes(data)
                    target.chmod(0o755 if mode & 0o111 else 0o644)
                os.rename(stage, release)
            except BaseException:
                shutil.rmtree(stage, ignore_errors=True)
                raise
        bindir = prefix / "bin"
        bindir.mkdir(mode=0o700, parents=True, exist_ok=True)
        temporary = bindir / f".agent-lab-{os.getpid()}"
        target = Path("../lib/agent-lab/releases") / release_id / "scripts/agent-lab"
        os.symlink(target, temporary)
        os.replace(temporary, bindir / "agent-lab")
    except OSError:
        return fail("bundle could not be published", 125)
    print(f"installed:{release_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
