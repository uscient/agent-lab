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
    print("Usage: agent-lab [--home ABSOLUTE_HOME] {version|init|config|experiment}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
