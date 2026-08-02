#!/usr/bin/env python3
from __future__ import annotations

from importlib.util import module_from_spec, spec_from_file_location
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
LOCK_SPECS = {
    "imageCatalog": (
        "image-catalog.lock",
        "agent-lab.image-catalog-lock/v0alpha1",
        b"initialized\n",
    ),
    "experiments": (
        "experiments.lock",
        "agent-lab.experiments-lock/v0alpha1",
        b"",
    ),
}


def canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"), sort_keys=True).encode()


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


def write_all(descriptor: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise OSError("write made no progress")
        view = view[written:]


def lock_record(path: Path, relative: str, schema: str) -> dict[str, object]:
    metadata = path.lstat()
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or metadata.st_nlink != 1
        or stat.S_IMODE(metadata.st_mode) != 0o600
    ):
        raise OSError("Agent Lab stable lock metadata is unsafe")
    return {
        "device": metadata.st_dev,
        "inode": metadata.st_ino,
        "path": relative,
        "schema": schema,
    }


def verify_lock(home: Path, state_component: str, key: str, record: object) -> None:
    filename, schema, appended = LOCK_SPECS[key]
    relative = f"{state_component}/locks/{filename}"
    if (
        not isinstance(record, dict)
        or set(record) != {"device", "inode", "path", "schema"}
        or not isinstance(record.get("device"), int)
        or isinstance(record.get("device"), bool)
        or not isinstance(record.get("inode"), int)
        or isinstance(record.get("inode"), bool)
        or record.get("path") != relative
        or record.get("schema") != schema
    ):
        raise RuntimeError("home lock receipt is not closed")
    path = home / relative
    maximum = len(schema.encode("ascii") + b"\n" + appended)
    try:
        lexical = path.lstat()
        identity = (lexical.st_dev, lexical.st_ino)
        if (
            not stat.S_ISREG(lexical.st_mode)
            or lexical.st_uid != os.getuid()
            or lexical.st_nlink != 1
            or stat.S_IMODE(lexical.st_mode) != 0o600
            or lexical.st_size > maximum
            or identity != (record["device"], record["inode"])
        ):
            raise OSError("home lock authority metadata is unsafe")
        descriptor = os.open(
            path,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_NONBLOCK", 0),
        )
    except OSError as error:
        raise RuntimeError("home lock authority is unavailable") from error
    try:
        opened = os.fstat(descriptor)
        chunks: list[bytes] = []
        remaining = maximum + 1
        while remaining:
            chunk = os.read(descriptor, remaining)
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        final = os.fstat(descriptor)
    except OSError as error:
        raise RuntimeError("home lock authority could not be verified") from error
    finally:
        os.close(descriptor)
    try:
        current = path.lstat()
    except OSError as error:
        raise RuntimeError("home lock authority could not be reverified") from error
    if (
        not stat.S_ISREG(opened.st_mode)
        or opened.st_uid != os.getuid()
        or opened.st_nlink != 1
        or stat.S_IMODE(opened.st_mode) != 0o600
        or opened.st_size > maximum
        or not stat.S_ISREG(final.st_mode)
        or final.st_uid != os.getuid()
        or final.st_nlink != 1
        or stat.S_IMODE(final.st_mode) != 0o600
        or final.st_size > maximum
        or not stat.S_ISREG(current.st_mode)
        or current.st_uid != os.getuid()
        or current.st_nlink != 1
        or stat.S_IMODE(current.st_mode) != 0o600
        or current.st_size > maximum
        or (opened.st_dev, opened.st_ino) != identity
        or (final.st_dev, final.st_ino) != identity
        or (current.st_dev, current.st_ino) != identity
        or identity != (record["device"], record["inode"])
    ):
        raise RuntimeError("home lock authority identity is unsafe")
    base = schema.encode("ascii") + b"\n"
    accepted = (base, base + appended) if appended else (base,)
    if data not in accepted or final.st_size != len(data):
        raise RuntimeError("home lock authority bytes are invalid")


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
    try:
        home.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(home, 0o700)
        existing = home / "home.json"
        config_path = home / "config.json"
        if existing.exists() or config_path.exists():
            try:
                loaded = load_config(home)
            except RuntimeError as error:
                print(f"INFRA Agent Lab {error}", file=sys.stderr)
                return 125
            if loaded is not None and loaded[1] == config_bytes:
                print("changed:false")
                return 0
            print("FAIL Agent Lab home conflicts with requested configuration", file=sys.stderr)
            return 1
        component_roots = {
            key: home / component
            for key, component in components.items()
        }
        for path in component_roots.values():
            try:
                path.lstat()
            except FileNotFoundError:
                continue
            raise OSError("Agent Lab data component already exists")
        for path in component_roots.values():
            path.mkdir(mode=0o700)
        for key in ("experiments", "images"):
            (component_roots[key] / ".staging").mkdir(mode=0o700)
        (component_roots["cache"] / "tools/cue").mkdir(mode=0o700, parents=True)
        (component_roots["cache"] / "tools/cedar").mkdir(mode=0o700, parents=True)
        locks = component_roots["state"] / "locks"
        locks.mkdir(mode=0o700)
        lock_records: dict[str, object] = {}
        for key, (name, schema, _) in LOCK_SPECS.items():
            path = locks / name
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            try:
                write_all(descriptor, schema.encode("ascii") + b"\n")
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            relative = f"{components['state']}/locks/{name}"
            lock_records[key] = lock_record(path, relative, schema)
        receipt = {
            "apiVersion": "agent-lab.home/v0alpha1",
            "configDigest": "sha256:" + hashlib.sha256(canonical(config)).hexdigest(),
            "locks": lock_records,
            "paths": components,
        }
        receipt_bytes = canonical(receipt) + b"\n"
        for path, data in ((config_path, config_bytes), (existing, receipt_bytes)):
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            try:
                write_all(descriptor, data)
                os.fsync(descriptor)
            finally:
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
        or set(receipt) != {"apiVersion", "configDigest", "locks", "paths"}
        or receipt["apiVersion"] != "agent-lab.home/v0alpha1"
        or receipt["paths"] != paths
        or receipt["configDigest"] != "sha256:" + hashlib.sha256(canonical(value)).hexdigest()
        or receipt_raw != canonical(receipt) + b"\n"
    ):
        raise RuntimeError("configuration does not match the initialized home receipt")
    locks = receipt["locks"]
    if not isinstance(locks, dict) or set(locks) != set(LOCK_SPECS):
        raise RuntimeError("home lock receipt is not closed")
    state_component = paths["state"]
    assert isinstance(state_component, str)
    for key in LOCK_SPECS:
        verify_lock(home, state_component, key, locks[key])
    return value, canonical_config


def experiment_module():
    path = Path(__file__).resolve().with_name("experiment.py")
    spec = spec_from_file_location("agent_lab_experiment", path)
    assert spec is not None and spec.loader is not None
    module = module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def image_catalog_module():
    path = Path(__file__).resolve().with_name("image_catalog.py")
    spec = spec_from_file_location("agent_lab_image_catalog", path)
    if spec is None or spec.loader is None:
        raise ImportError("image catalog module cannot be loaded")
    module = module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def write_json(value: object) -> None:
    output = canonical(value).decode("ascii") + "\n"
    written = sys.stdout.write(output)
    if written != len(output):
        raise OSError("partial command output")
    sys.stdout.flush()


def image_command(home: Path, argv: list[str]) -> int:
    if argv[:1] == ["add"] and len(argv) == 3:
        operation = "add"
    elif argv[:1] == ["remove"] and len(argv) == 4 and argv[2] == "--expect":
        operation = "remove"
    elif argv[:1] == ["list"] and (len(argv) == 1 or argv == ["list", "--all"]):
        operation = "list"
    elif argv[:1] == ["inspect"] and len(argv) == 2:
        operation = "inspect"
    else:
        return 2

    if operation in {"add", "remove"} and sys.platform != "linux":
        print("INFRA Agent Lab local image catalog mutations require Linux", file=sys.stderr)
        return 125

    try:
        catalog = image_catalog_module()
    except (ImportError, OSError) as error:
        print(f"INFRA Agent Lab image catalog is unavailable: {error}", file=sys.stderr)
        return 125

    try:
        if operation == "add":
            result = catalog.add_image(home, argv[1], argv[2])
        elif operation == "remove":
            result = catalog.remove_image(home, argv[1], argv[3])
        elif operation == "list":
            result = catalog.list_images(home, include_removed=len(argv) == 2)
        else:
            result = catalog.inspect_image(home, argv[1])
    except catalog.CatalogReject as error:
        print(f"FAIL image {error}", file=sys.stderr)
        return 1
    except catalog.CatalogInfrastructure as error:
        print(f"INFRA Agent Lab image catalog {error}", file=sys.stderr)
        return 125
    except (AttributeError, OSError) as error:
        print(f"INFRA Agent Lab image catalog operation is unavailable: {error}", file=sys.stderr)
        return 125

    try:
        write_json(result)
    except OSError as error:
        print(f"INFRA Agent Lab image catalog result is uncertain: {error}", file=sys.stderr)
        return 125
    return 0


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
    print("Usage: agent-lab [--home ABSOLUTE_HOME] {version|init|config|experiment|image}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
