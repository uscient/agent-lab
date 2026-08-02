#!/usr/bin/env python3
"""Adversarial local image-catalog filesystem and durability cases."""

from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import hashlib
from importlib.util import module_from_spec, spec_from_file_location
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile


REPO_ROOT = Path(__file__).resolve().parents[2]
AGENT_LAB = REPO_ROOT / "scripts" / "agent-lab"
AGENT_LAB_MODULE = REPO_ROOT / "scripts" / "agent-lab.py"
SUBJECT = "registry.example/operator/worker@sha256:" + "a" * 64
OTHER_SUBJECT = "registry.example/operator/other@sha256:" + "b" * 64
ENTRY_DOMAIN = b"agent-lab.local-image-entry.v1\0"
SNAPSHOT_DOMAIN = b"agent-lab.local-image-snapshot.v1\0"


def canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"), sort_keys=True).encode()


def digest(domain: bytes, value: object) -> str:
    return "sha256:" + hashlib.sha256(domain + canonical(value)).hexdigest()


def load_module():
    spec = spec_from_file_location("agent_lab_catalog_state", AGENT_LAB_MODULE)
    if spec is None or spec.loader is None:
        raise RuntimeError("Agent Lab application module cannot be loaded")
    module = module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


MODULE = load_module()
FAILURES = 0
OBSERVED: list[str] = []


def check(assertion: str, condition: bool, message: str, detail: str = "") -> None:
    global FAILURES
    OBSERVED.append(assertion)
    if condition:
        print(f"PASS {assertion} {message}")
    else:
        FAILURES += 1
        suffix = f" ({detail})" if detail else ""
        print(f"FAIL {assertion} {message}{suffix}")


def cli(home: Path, *arguments: str, timeout: float = 20.0) -> subprocess.CompletedProcess[bytes]:
    environment = {
        "PATH": "/usr/bin:/bin",
        "LANG": "C",
        "LC_ALL": "C",
    }
    return subprocess.run(
        [str(AGENT_LAB), "--home", str(home), *arguments],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        timeout=timeout,
        check=False,
    )


def module_image(home: Path, *arguments: str) -> tuple[int | None, str, str, BaseException | None]:
    output = io.StringIO()
    errors = io.StringIO()
    try:
        with redirect_stdout(output), redirect_stderr(errors):
            result = MODULE.image_command(home, list(arguments))
        return result, output.getvalue(), errors.getvalue(), None
    except BaseException as error:  # The assertion records an uncontained production fault as RED.
        return None, output.getvalue(), errors.getvalue(), error


def module_main(home: Path, arguments: list[str], output: io.TextIOBase | None = None) -> tuple[int | None, BaseException | None]:
    stream = output if output is not None else io.StringIO()
    errors = io.StringIO()
    try:
        with redirect_stdout(stream), redirect_stderr(errors):
            result = MODULE.main(["--home", str(home), *arguments])
        return result, None
    except BaseException as error:  # The assertion records an uncontained production fault as RED.
        return None, error


def new_home(root: Path, name: str) -> Path:
    home = root / name
    completed = cli(home, "init")
    if completed.returncode != 0:
        raise RuntimeError(f"temporary home init failed: {completed.stderr.decode(errors='replace')}")
    return home


def add(home: Path, name: str = "vendor.worker", subject: str = SUBJECT) -> dict[str, object]:
    completed = cli(home, "image", "add", name, subject)
    if completed.returncode != 0:
        raise RuntimeError(f"catalog setup add failed: {completed.stderr.decode(errors='replace')}")
    value = json.loads(completed.stdout)
    if not isinstance(value, dict):
        raise RuntimeError("catalog setup add returned a non-object")
    return value


def current_snapshot(home: Path) -> tuple[Path, dict[str, object], str]:
    root = home / "images" / "catalog"
    pointer = json.loads((root / "current.json").read_bytes())
    snapshot_digest = pointer["snapshotDigest"]
    path = root / "snapshots" / f"{snapshot_digest[7:]}.json"
    value = json.loads(path.read_bytes())
    return path, value, snapshot_digest


def fingerprint(root: Path) -> tuple[tuple[str, str, int, int, str], ...]:
    if not root.exists() and not root.is_symlink():
        return ()
    records: list[tuple[str, str, int, int, str]] = []
    paths = [root, *sorted(root.rglob("*"), key=lambda item: os.fsencode(str(item.relative_to(root))))]
    for path in paths:
        metadata = path.lstat()
        relative = "." if path == root else str(path.relative_to(root))
        if stat.S_ISLNK(metadata.st_mode):
            kind = "l"
            identity = os.readlink(path)
        elif stat.S_ISREG(metadata.st_mode):
            kind = "f"
            identity = hashlib.sha256(path.read_bytes()).hexdigest()
        elif stat.S_ISDIR(metadata.st_mode):
            kind = "d"
            identity = ""
        else:
            kind = "o"
            identity = ""
        records.append((relative, kind, stat.S_IMODE(metadata.st_mode), metadata.st_nlink, identity))
    return tuple(records)


class BrokenOutput(io.StringIO):
    def write(self, value: str) -> int:
        raise OSError("injected result-output failure")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="agent-lab-catalog-state-") as directory:
        root = Path(directory)

        missing_home = new_home(root, "missing-home")
        add(missing_home)
        committed = missing_home / "images" / "catalog"
        saved_catalog = root / "saved-committed-catalog"
        committed.rename(saved_catalog)
        completed = cli(missing_home, "image", "list")
        check(
            "CAT-STATE-001",
            completed.returncode == 125 and completed.stdout == b"" and not committed.exists(),
            "a missing previously committed catalog is infrastructure uncertainty, not empty",
            f"rc={completed.returncode} stdout={completed.stdout!r}",
        )

        history_home = new_home(root, "history-home")
        add(history_home)
        entries = history_home / "images" / "catalog" / "entries"
        entries.rename(root / "removed-entry-history")
        completed = cli(history_home, "image", "list")
        check(
            "CAT-STATE-002",
            completed.returncode == 125 and completed.stdout == b"",
            "missing immutable entry history fails closed",
            f"rc={completed.returncode} stdout={completed.stdout!r}",
        )

        canonical_home = new_home(root, "canonical-home")
        add(canonical_home)
        snapshot_path, snapshot, _ = current_snapshot(canonical_home)
        snapshot_path.write_text(json.dumps(snapshot, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        completed = cli(canonical_home, "image", "list")
        check(
            "CAT-STATE-003",
            completed.returncode == 125,
            "noncanonical snapshot bytes fail closed even when semantic digest fields match",
            f"rc={completed.returncode}",
        )

        corrupt_home = new_home(root, "corrupt-home")
        add(corrupt_home)
        _, snapshot, _ = current_snapshot(corrupt_home)
        records = snapshot.get("records")
        if not isinstance(records, dict) or not isinstance(records.get("vendor.worker"), dict):
            raise RuntimeError("catalog setup snapshot has an unexpected shape")
        records["vendor.worker"]["state"] = "future"
        corrupt_digest = digest(SNAPSHOT_DOMAIN, snapshot)
        corrupt_path = corrupt_home / "images" / "catalog" / "snapshots" / f"{corrupt_digest[7:]}.json"
        corrupt_path.write_bytes(canonical(snapshot) + b"\n")
        (corrupt_home / "images" / "catalog" / "current.json").write_bytes(
            canonical({"snapshotDigest": corrupt_digest}) + b"\n"
        )
        completed = cli(corrupt_home, "image", "list")
        check(
            "CAT-STATE-004",
            completed.returncode == 125 and completed.stdout == b"",
            "closed record validation rejects an unknown state even under a recomputed snapshot digest",
            f"rc={completed.returncode} stdout={completed.stdout!r}",
        )

        mode_home = new_home(root, "mode-home")
        add(mode_home)
        current = mode_home / "images" / "catalog" / "current.json"
        current.chmod(0o644)
        completed = cli(mode_home, "image", "list")
        check(
            "CAT-STATE-005",
            completed.returncode == 125,
            "wrong catalog record mode fails closed",
            f"rc={completed.returncode}",
        )

        link_count_home = new_home(root, "link-count-home")
        add(link_count_home)
        current = link_count_home / "images" / "catalog" / "current.json"
        os.link(current, root / "second-current-link")
        completed = cli(link_count_home, "image", "list")
        check(
            "CAT-STATE-006",
            completed.returncode == 125,
            "multiply linked catalog authority fails closed",
            f"rc={completed.returncode}",
        )

        source_home = new_home(root, "symlink-source-home")
        add(source_home)
        outside_catalog = root / "outside-catalog"
        (source_home / "images" / "catalog").rename(outside_catalog)
        symlink_home = new_home(root, "symlink-home")
        os.symlink(outside_catalog, symlink_home / "images" / "catalog")
        before = fingerprint(outside_catalog)
        completed = cli(symlink_home, "image", "add", "vendor.second", OTHER_SUBJECT)
        after = fingerprint(outside_catalog)
        check(
            "CAT-STATE-007",
            completed.returncode == 125 and before == after,
            "a symlinked initialized catalog is refused before external target mutation",
            f"rc={completed.returncode} target_changed={before != after}",
        )

        lock_home = new_home(root, "lock-home")
        add(lock_home)
        lock_path = lock_home / "state" / "locks" / "image-catalog.lock"
        saved_lock = root / "saved-image-catalog.lock"
        lock_path.rename(saved_lock)
        os.symlink(saved_lock, lock_path)
        completed = cli(lock_home, "image", "list")
        check(
            "CAT-STATE-008",
            completed.returncode == 125,
            "replacement or symlink of the stable catalog lock fails closed",
            f"rc={completed.returncode}",
        )

        staging_home = new_home(root, "staging-home")
        foreign_wrapper = staging_home / "images" / ".staging" / "foreign-wrapper"
        (foreign_wrapper / "payload").mkdir(parents=True)
        (foreign_wrapper / "intent.json").write_text('{"owner":"foreign"}\n', encoding="utf-8")
        before = fingerprint(foreign_wrapper)
        completed = cli(staging_home, "image", "add", "vendor.worker", SUBJECT)
        after = fingerprint(foreign_wrapper)
        check(
            "CAT-STATE-009",
            completed.returncode == 125
            and before == after
            and not (staging_home / "images" / "catalog").exists(),
            "unknown staging ownership is preserved and blocks new mutation",
            f"rc={completed.returncode} wrapper_changed={before != after}",
        )

        pristine_home = new_home(root, "pristine-home")
        before = fingerprint(pristine_home / "images")
        completed = cli(pristine_home, "image", "list")
        after = fingerprint(pristine_home / "images")
        check(
            "CAT-STATE-010",
            completed.returncode == 0 and completed.stdout == b"[]\n" and before == after,
            "pristine read returns canonical empty without initialization or cleanup",
            f"rc={completed.returncode} changed={before != after} stdout={completed.stdout!r}",
        )

        schema_home = new_home(root, "schema-home")
        add(schema_home)
        entry_paths = list((schema_home / "images" / "catalog" / "entries").glob("*.json"))
        snapshot_paths = list((schema_home / "images" / "catalog" / "snapshots").glob("*.json"))
        schema_ok = len(entry_paths) == 1 and len(snapshot_paths) == 1
        for path in [*entry_paths, *snapshot_paths]:
            raw = path.read_bytes()
            try:
                value = json.loads(raw)
            except (UnicodeError, json.JSONDecodeError):
                schema_ok = False
                continue
            api_version = value.get("apiVersion") if isinstance(value, dict) else None
            schema_ok = (
                schema_ok
                and isinstance(api_version, str)
                and api_version.startswith("agent-lab.")
                and api_version.endswith("/v0alpha1")
                and raw == canonical(value) + b"\n"
            )
        check(
            "CAT-STATE-011",
            schema_ok,
            "immutable entry and snapshot records carry closed versioned canonical schemas",
        )

        truncated_home = new_home(root, "truncated-home")
        add(truncated_home)
        current = truncated_home / "images" / "catalog" / "current.json"
        current.write_bytes(b'{"snapshotDigest":')
        before = current.read_bytes()
        completed = cli(truncated_home, "image", "inspect", "vendor.worker")
        check(
            "CAT-STATE-012",
            completed.returncode == 125 and completed.stdout == b"" and current.read_bytes() == before,
            "truncated authority is infrastructure uncertainty and read-only commands do not repair it",
            f"rc={completed.returncode}",
        )

        names_home = new_home(root, "names-bound-home")
        names_ok = True
        for index in range(256):
            rc, _, _, error = module_image(names_home, "add", f"v{index:03d}.image", SUBJECT)
            if rc != 0 or error is not None:
                names_ok = False
                break
        before = fingerprint(names_home / "images" / "catalog")
        rc, _, _, error = module_image(names_home, "add", "v256.image", SUBJECT)
        after = fingerprint(names_home / "images" / "catalog")
        check(
            "CAT-BOUND-001",
            names_ok and rc == 1 and error is None and before == after,
            "the 257th logical name is a stable refusal with no publication",
            f"setup_ok={names_ok} rc={rc} error={error!r} changed={before != after}",
        )

        bytes_home = new_home(root, "bytes-bound-home")
        add(bytes_home)
        orphan = bytes_home / "images" / "catalog" / "entries" / ("f" * 64 + ".json")
        with orphan.open("wb") as stream:
            stream.truncate(67_108_865)
        before = orphan.stat().st_size
        completed = cli(bytes_home, "image", "list")
        check(
            "CAT-BOUND-002",
            completed.returncode == 125 and orphan.exists() and orphan.stat().st_size == before,
            "over-bound physical catalog state fails closed without broad deletion",
            f"rc={completed.returncode}",
        )

        fsync_home = new_home(root, "fsync-home")
        original_fsync = MODULE.os.fsync
        fsync_calls = 0

        def fail_first_fsync(descriptor: int) -> None:
            nonlocal fsync_calls
            fsync_calls += 1
            if fsync_calls == 1:
                raise OSError("injected fsync failure")
            original_fsync(descriptor)

        MODULE.os.fsync = fail_first_fsync
        try:
            first_rc, _, _, first_error = module_image(fsync_home, "add", "vendor.worker", SUBJECT)
        finally:
            MODULE.os.fsync = original_fsync
        retry = cli(fsync_home, "image", "add", "vendor.worker", SUBJECT)
        staged = list((fsync_home / "images" / ".staging").iterdir())
        check(
            "CAT-CRASH-001",
            first_rc == 125
            and first_error is None
            and retry.returncode == 0
            and json.loads(retry.stdout).get("changed") is True
            and not staged,
            "record fsync failure is contained and the next effectful retry reconciles safely",
            f"first_rc={first_rc} error={first_error!r} retry_rc={retry.returncode} staged={len(staged)}",
        )

        replace_home = new_home(root, "replace-home")
        original_replace = MODULE.os.replace
        replace_calls = 0

        def fail_pointer_replace(source: os.PathLike[str] | str, target: os.PathLike[str] | str) -> None:
            nonlocal replace_calls
            if Path(target).name == "current.json":
                replace_calls += 1
                if replace_calls == 1:
                    raise OSError("injected pointer publication failure")
            original_replace(source, target)

        MODULE.os.replace = fail_pointer_replace
        try:
            first_rc, _, _, first_error = module_image(replace_home, "add", "vendor.worker", SUBJECT)
        finally:
            MODULE.os.replace = original_replace
        retry = cli(replace_home, "image", "add", "vendor.worker", SUBJECT)
        staged = list((replace_home / "images" / ".staging").iterdir())
        check(
            "CAT-CRASH-002",
            first_rc == 125
            and first_error is None
            and retry.returncode == 0
            and json.loads(retry.stdout).get("changed") is True
            and not staged,
            "pointer publication failure leaves an uncommitted operation that retry proves and reconciles",
            f"first_rc={first_rc} error={first_error!r} retry_rc={retry.returncode} staged={len(staged)}",
        )

        result_home = new_home(root, "result-home")
        first_rc, first_error = module_main(
            result_home,
            ["image", "add", "vendor.worker", SUBJECT],
            BrokenOutput(),
        )
        retry = cli(result_home, "image", "add", "vendor.worker", SUBJECT)
        retry_value = json.loads(retry.stdout) if retry.returncode == 0 else {}
        check(
            "CAT-CRASH-003",
            first_rc == 125
            and first_error is None
            and retry.returncode == 0
            and retry_value.get("changed") is False,
            "lost result output reports uncertainty while retry observes the committed binding idempotently",
            f"first_rc={first_rc} error={first_error!r} retry_rc={retry.returncode} retry={retry_value!r}",
        )

        platform_home = new_home(root, "platform-home")
        before = fingerprint(platform_home)
        original_platform = MODULE.sys.platform
        MODULE.sys.platform = "darwin"
        try:
            platform_rc, platform_error = module_main(
                platform_home,
                ["image", "add", "vendor.worker", SUBJECT],
            )
        finally:
            MODULE.sys.platform = original_platform
        after = fingerprint(platform_home)
        check(
            "CAT-PLAT-001",
            platform_rc == 125 and platform_error is None and before == after,
            "an injected non-Linux host refuses mutation before opening catalog state",
            f"rc={platform_rc} error={platform_error!r} changed={before != after}",
        )

    expected = [
        "CAT-STATE-001",
        "CAT-STATE-002",
        "CAT-STATE-003",
        "CAT-STATE-004",
        "CAT-STATE-005",
        "CAT-STATE-006",
        "CAT-STATE-007",
        "CAT-STATE-008",
        "CAT-STATE-009",
        "CAT-STATE-010",
        "CAT-STATE-011",
        "CAT-STATE-012",
        "CAT-BOUND-001",
        "CAT-BOUND-002",
        "CAT-CRASH-001",
        "CAT-CRASH-002",
        "CAT-CRASH-003",
        "CAT-PLAT-001",
    ]
    if OBSERVED != expected:
        print(f"INFRA catalog state assertion identity drift: {OBSERVED!r}", file=sys.stderr)
        return 125
    print(f"SUMMARY assertions=18 expected=18 failures={FAILURES} infra=0")
    return 0 if FAILURES == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
