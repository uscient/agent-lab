#!/usr/bin/env python3
from __future__ import annotations

from importlib.util import module_from_spec, spec_from_file_location
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import stat
import subprocess
import sys

SAFE_COMPONENT = re.compile(r"^[a-z][a-z0-9-]{0,47}$")
IMAGE_COMPONENT = re.compile(r"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$")
OCI_SUBJECT = re.compile(r"^[a-z0-9][a-z0-9./_-]*@sha256:[0-9a-f]{64}$")


def canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"), sort_keys=True).encode()


def record_digest(domain: bytes, value: object) -> str:
    return "sha256:" + hashlib.sha256(domain + canonical(value)).hexdigest()


def image_name(value: str) -> bool:
    parts = value.split(".")
    return (
        len(value.encode("utf-8")) <= 63
        and len(parts) == 2
        and all(part.isascii() and 1 <= len(part) <= 31 and IMAGE_COMPONENT.fullmatch(part) for part in parts)
    )


def effective_home(raw: str | None) -> Path:
    selected = raw if raw is not None else os.environ.get("AGENT_LAB_HOME")
    if selected is None:
        selected = str(Path(pwd.getpwuid(os.getuid()).pw_dir) / ".agent-lab")
    path = Path(selected)
    if not selected or not path.is_absolute() or path == Path("/"):
        raise ValueError("home must be an absolute non-root path")
    return path


def config_value(components: dict[str, str]) -> dict[str, object]:
    return {"apiVersion": "agent-lab.config/v0alpha1", "paths": components}


def init_home(home: Path, argv: list[str]) -> int:
    components = {"experiments": "experiments", "images": "images", "cache": "cache", "state": "state"}
    option_map = {"--experiments-dir": "experiments", "--images-dir": "images", "--cache-dir": "cache", "--state-dir": "state"}
    while argv:
        option = argv.pop(0)
        if option not in option_map or not argv:
            return 2
        components[option_map[option]] = argv.pop(0)
    if len(set(components.values())) != 4 or any(not SAFE_COMPONENT.fullmatch(value) for value in components.values()):
        print("FAIL Agent Lab configuration has unsafe data components", file=sys.stderr)
        return 1
    config = config_value(components)
    config_bytes = canonical(config) + b"\n"
    receipt = {
        "apiVersion": "agent-lab.home/v0alpha1",
        "configDigest": "sha256:" + hashlib.sha256(canonical(config)).hexdigest(),
        "paths": components,
    }
    receipt_bytes = canonical(receipt) + b"\n"
    try:
        home.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(home, 0o700)
        existing = home / "home.json"
        config_path = home / "config.json"
        if existing.exists() or config_path.exists():
            if existing.read_bytes() == receipt_bytes and config_path.read_bytes() == config_bytes:
                print("changed:false")
                return 0
            print("FAIL Agent Lab home conflicts with requested configuration", file=sys.stderr)
            return 1
        for key in ("experiments", "images"):
            (home / components[key] / ".staging").mkdir(mode=0o700, parents=True)
        (home / components["cache"] / "tools/cue").mkdir(mode=0o700, parents=True)
        (home / components["cache"] / "tools/cedar").mkdir(mode=0o700, parents=True)
        locks = home / components["state"] / "locks"
        locks.mkdir(mode=0o700, parents=True)
        for name in ("image-catalog.lock", "experiments.lock"):
            descriptor = os.open(locks / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            os.close(descriptor)
        for path, data in ((config_path, config_bytes), (existing, receipt_bytes)):
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            os.write(descriptor, data)
            os.close(descriptor)
    except OSError:
        print("INFRA Agent Lab home could not be initialized safely", file=sys.stderr)
        return 125
    print("changed:true")
    return 0


def load_config(home: Path) -> tuple[dict[str, object], bytes] | None:
    config_path = home / "config.json"
    receipt_path = home / "home.json"
    try:
        config_metadata = config_path.lstat()
        receipt_metadata = receipt_path.lstat()
    except FileNotFoundError:
        if not config_path.exists() and not receipt_path.exists():
            return None
        raise RuntimeError("home receipt and configuration are incomplete")
    for metadata in (config_metadata, receipt_metadata):
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1 or stat.S_IMODE(metadata.st_mode) != 0o600:
            raise RuntimeError("home authority files are unsafe")
    try:
        raw = config_path.read_bytes()
        receipt_raw = receipt_path.read_bytes()
        value = json.loads(raw.decode("utf-8"))
        receipt = json.loads(receipt_raw.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        raise RuntimeError("configuration is malformed")
    if not isinstance(value, dict) or set(value) != {"apiVersion", "paths"} or value["apiVersion"] != "agent-lab.config/v0alpha1":
        raise RuntimeError("configuration is not closed")
    paths = value["paths"]
    if not isinstance(paths, dict) or set(paths) != {"experiments", "images", "cache", "state"}:
        raise RuntimeError("configuration paths are not closed")
    if len(set(paths.values())) != 4 or any(not isinstance(item, str) or not SAFE_COMPONENT.fullmatch(item) for item in paths.values()):
        raise RuntimeError("configuration paths are unsafe")
    canonical_config = canonical(value) + b"\n"
    if raw != canonical_config:
        raise RuntimeError("configuration is not canonical")
    if (
        not isinstance(receipt, dict)
        or set(receipt) != {"apiVersion", "configDigest", "paths"}
        or receipt["apiVersion"] != "agent-lab.home/v0alpha1"
        or receipt["paths"] != paths
        or receipt["configDigest"] != "sha256:" + hashlib.sha256(canonical(value)).hexdigest()
        or receipt_raw != canonical(receipt) + b"\n"
    ):
        raise RuntimeError("configuration does not match the initialized home receipt")
    return value, canonical_config


def experiment_module():
    path = Path(__file__).resolve().with_name("experiment.py")
    spec = spec_from_file_location("agent_lab_experiment", path)
    assert spec is not None and spec.loader is not None
    module = module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def atomic_json(path: Path, value: object) -> None:
    data = canonical(value) + b"\n"
    temporary = path.with_name(f".{path.name}.{os.getpid()}")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(descriptor, data)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.replace(temporary, path)


def catalog_paths(home: Path, loaded: tuple[dict[str, object], bytes]) -> tuple[Path, Path]:
    paths = loaded[0]["paths"]
    assert isinstance(paths, dict)
    return home / str(paths["images"]) / "catalog", home / str(paths["state"]) / "locks/image-catalog.lock"


def load_catalog(root: Path) -> dict[str, object]:
    current = root / "current.json"
    if not root.exists():
        return {"revision": 0, "previous": None, "records": {}}
    try:
        pointer = json.loads(current.read_text(encoding="utf-8"))
        digest = pointer["snapshotDigest"]
        if not isinstance(digest, str) or not digest.startswith("sha256:"):
            raise ValueError
        snapshot_path = root / "snapshots" / f"{digest[7:]}.json"
        snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
    except (OSError, KeyError, ValueError, json.JSONDecodeError) as error:
        raise RuntimeError("image catalog is malformed") from error
    if record_digest(b"agent-lab.local-image-snapshot.v1\0", snapshot) != digest:
        raise RuntimeError("image catalog snapshot digest mismatch")
    if not isinstance(snapshot, dict) or set(snapshot) != {"revision", "previous", "records"} or not isinstance(snapshot["records"], dict):
        raise RuntimeError("image catalog snapshot is not closed")
    return snapshot


def write_catalog(root: Path, snapshot: dict[str, object], entry: dict[str, object]) -> tuple[str, str]:
    entries = root / "entries"
    snapshots = root / "snapshots"
    entries.mkdir(mode=0o700, parents=True, exist_ok=True)
    snapshots.mkdir(mode=0o700, parents=True, exist_ok=True)
    entry_digest = record_digest(b"agent-lab.local-image-entry.v1\0", entry)
    entry_path = entries / f"{entry_digest[7:]}.json"
    if not entry_path.exists():
        atomic_json(entry_path, entry)
    snapshot_digest = record_digest(b"agent-lab.local-image-snapshot.v1\0", snapshot)
    snapshot_path = snapshots / f"{snapshot_digest[7:]}.json"
    if not snapshot_path.exists():
        atomic_json(snapshot_path, snapshot)
    atomic_json(root / "current.json", {"snapshotDigest": snapshot_digest})
    return entry_digest, snapshot_digest


def image_command(home: Path, argv: list[str]) -> int:
    try:
        loaded = load_config(home)
    except RuntimeError as error:
        print(f"INFRA Agent Lab {error}", file=sys.stderr)
        return 125
    if loaded is None:
        print("FAIL Agent Lab home is not initialized", file=sys.stderr)
        return 1
    root, lock_path = catalog_paths(home, loaded)
    try:
        lock = open(lock_path, "r+b", buffering=0)
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        snapshot = load_catalog(root)
    except (OSError, RuntimeError) as error:
        print(f"INFRA Agent Lab {error}", file=sys.stderr)
        return 125
    try:
        records = snapshot["records"]
        assert isinstance(records, dict)
        if argv[:1] == ["add"] and len(argv) == 3:
            name, subject = argv[1:]
            if not image_name(name) or name.startswith("agent-lab.") or not OCI_SUBJECT.fullmatch(subject):
                print("FAIL image mapping is invalid or reserved", file=sys.stderr)
                return 1
            prior = records.get(name)
            if prior is not None:
                if prior["state"] == "active" and prior["subject"] == subject:
                    print(canonical({"changed": False, "entryDigest": prior["entryDigest"], "generation": 1}).decode())
                    return 0
                print("FAIL image name already exists or is tombstoned", file=sys.stderr)
                return 1
            entry = {"generation": 1, "name": name, "previousEntryDigest": None, "state": "active", "subject": subject}
            entry_digest = record_digest(b"agent-lab.local-image-entry.v1\0", entry)
            record = {**entry, "entryDigest": entry_digest}
            new_records = {**records, name: record}
            next_snapshot = {"previous": record_digest(b"agent-lab.local-image-snapshot.v1\0", snapshot) if snapshot["revision"] else None, "records": new_records, "revision": int(snapshot["revision"]) + 1}
            write_catalog(root, next_snapshot, entry)
            print(canonical({"changed": True, "entryDigest": entry_digest, "generation": 1}).decode())
            return 0
        if argv[:1] == ["remove"] and len(argv) == 4 and argv[2] == "--expect":
            name, expected = argv[1], argv[3]
            prior = records.get(name)
            if prior is None:
                print("FAIL image name is unknown", file=sys.stderr)
                return 1
            if prior["state"] == "removed" and prior["previousEntryDigest"] == expected:
                print(canonical({"changed": False, "entryDigest": prior["entryDigest"], "generation": 2, "state": "removed"}).decode())
                return 0
            if prior["state"] != "active" or prior["entryDigest"] != expected:
                print("FAIL image remove compare-and-swap conflict", file=sys.stderr)
                return 1
            entry = {"generation": 2, "name": name, "previousEntryDigest": expected, "state": "removed", "subject": prior["subject"]}
            entry_digest = record_digest(b"agent-lab.local-image-entry.v1\0", entry)
            record = {**entry, "entryDigest": entry_digest}
            next_snapshot = {"previous": record_digest(b"agent-lab.local-image-snapshot.v1\0", snapshot), "records": {**records, name: record}, "revision": int(snapshot["revision"]) + 1}
            write_catalog(root, next_snapshot, entry)
            print(canonical({"changed": True, "entryDigest": entry_digest, "generation": 2, "state": "removed"}).decode())
            return 0
        if argv[:1] == ["list"] and (len(argv) == 1 or argv == ["list", "--all"]):
            include_all = len(argv) == 2
            values = [records[name] for name in sorted(records) if include_all or records[name]["state"] == "active"]
            print(canonical(values).decode())
            return 0
        if argv[:1] == ["inspect"] and len(argv) == 2:
            record = records.get(argv[1])
            if record is None:
                print("FAIL image name is unknown", file=sys.stderr)
                return 1
            print(canonical(record).decode())
            return 0
        return 2
    finally:
        lock.close()


def main(argv: list[str]) -> int:
    home_raw = None
    if argv[:1] == ["--home"]:
        if len(argv) < 2:
            return 2
        home_raw = argv[1]
        argv = argv[2:]
    try:
        home = effective_home(home_raw)
    except ValueError as error:
        print(f"FAIL Agent Lab {error}", file=sys.stderr)
        return 1
    if argv == ["version"]:
        print("agent-lab v0alpha1")
        return 0
    if argv[:1] == ["init"]:
        return init_home(home, argv[1:])
    if argv == ["config", "check"] or argv == ["config", "show"]:
        try:
            loaded = load_config(home)
        except RuntimeError as error:
            print(f"INFRA Agent Lab {error}", file=sys.stderr)
            return 125
        if loaded is None:
            print("FAIL Agent Lab home is not initialized", file=sys.stderr)
            return 1
        if argv[-1] == "show":
            sys.stdout.buffer.write(loaded[1])
        else:
            print("valid:true")
        return 0
    if argv == ["tools", "provision"]:
        try:
            loaded = load_config(home)
        except RuntimeError as error:
            print(f"INFRA Agent Lab {error}", file=sys.stderr)
            return 125
        if loaded is None:
            print("FAIL Agent Lab home is not initialized", file=sys.stderr)
            return 1
        paths = loaded[0]["paths"]
        assert isinstance(paths, dict)
        cache = home / str(paths["cache"]) / "tools"
        root = Path(__file__).resolve().parent.parent
        environment = {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"}
        for name in ("cue", "cedar"):
            environment[f"AGENT_LAB_{name.upper()}_TOOL_DIR"] = str(cache / name)
            completed = subprocess.run(
                [sys.executable, "-I", str(root / f"scripts/dev/{name}-tool.py"), "provision"],
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=120,
                check=False,
            )
            if completed.returncode != 0:
                sys.stderr.buffer.write(completed.stderr)
                return 125
        print("tools:ready")
        return 0
    if argv[:2] == ["experiment", "check"] and len(argv) == 3:
        os.environ["AGENT_LAB_HOME"] = str(home)
        os.environ.setdefault("AGENT_LAB_CUE_TOOL_DIR", str(home / "cache/tools/cue"))
        return experiment_module().main(["experiment.py", "check-directory", argv[2]])
    if argv[:3] == ["experiment", "authorize", "install"] and len(argv) == 4:
        os.environ["AGENT_LAB_HOME"] = str(home)
        os.environ.setdefault("AGENT_LAB_CUE_TOOL_DIR", str(home / "cache/tools/cue"))
        os.environ.setdefault("AGENT_LAB_CEDAR_TOOL_DIR", str(home / "cache/tools/cedar"))
        return experiment_module().main(["experiment.py", "authorize-directory", argv[3]])
    if argv[:1] == ["image"]:
        return image_command(home, argv[1:])
    print("Usage: agent-lab [--home ABSOLUTE_HOME] {version|init|config|experiment}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
