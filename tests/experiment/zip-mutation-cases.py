#!/usr/bin/env python3
"""Private-copy sensitivity mutations for the bounded ZIP intake controls."""

from __future__ import annotations

from hashlib import sha256
from importlib.util import module_from_spec, spec_from_file_location
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile


EXPECTED = (
    "M-ZIP-COUNT-001",
    "M-ZIP-NAME-001",
    "M-ZIP-TYPE-001",
    "M-ZIP-FLAG-001",
    "M-ZIP-METHOD-001",
    "M-ZIP-SIZE-001",
    "M-ZIP-CRC-001",
    "M-ZIP-HEADER-001",
    "M-ZIP-EXTRACT-001",
    "M-ZIP-IDENTITY-001",
    "M-ZIP-AUTH-001",
)


def load_module(path: Path, label: str):
    spec = spec_from_file_location(label, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def replace_once(source: str, needle: str, replacement: str) -> str:
    if source.count(needle) != 1:
        raise RuntimeError("private mutation did not match exactly once")
    return source.replace(needle, replacement, 1)


def rejected_with(module, archive: Path, code: str) -> bool:
    try:
        module.read_zip_snapshot(str(archive))
    except module.InvalidManifest as error:
        return code in str(error)
    return False


def accepted_by(module, archive: Path) -> bool:
    try:
        snapshot = module.read_zip_snapshot(str(archive))
    except (module.InvalidManifest, module.InfrastructureError):
        return False
    return isinstance(snapshot, module.SourceSnapshot)


def parser_mutation(
    production: Path,
    original: str,
    private_source: Path,
    baseline_module,
    fixture: Path,
    code: str,
    assertion: str,
    needle: str,
    replacement: str,
    marker: Path,
) -> bool:
    if not rejected_with(baseline_module, fixture, code):
        return False
    private_source.write_text(replace_once(original, needle, replacement), encoding="utf-8")
    marker.unlink(missing_ok=True)
    os.environ["AGENT_LAB_ZIP_MUTATION_MARK"] = str(marker)
    try:
        mutant = load_module(private_source, "zip_mutant_" + assertion.lower().replace("-", "_"))
        killed = accepted_by(mutant, fixture)
    finally:
        os.environ.pop("AGENT_LAB_ZIP_MUTATION_MARK", None)
    return marker.is_file() and killed and sha256(production.read_bytes()).hexdigest() == sha256(
        original.encode("utf-8")
    ).hexdigest()


def run_command(command: list[str], environment: dict[str, str]) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        command,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=5,
    )


def authorization_mutation(repo: Path, root: Path, archive: Path, marker: Path) -> bool:
    runtime = root / "deny-runtime"
    manifest = repo / "packaging/agent-lab-local.manifest"
    for raw in manifest.read_text(encoding="utf-8").splitlines():
        if not raw:
            raise RuntimeError("runtime manifest contains an empty path")
        source = repo / raw
        target = runtime / raw
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    entrypoint = runtime / "scripts/agent-lab"
    entrypoint.chmod(entrypoint.stat().st_mode | stat.S_IXUSR)
    policy = runtime / "authorization/experiment/v0alpha1/operator.cedar"
    policy_text = policy.read_text(encoding="utf-8")
    policy.write_text(
        replace_once(policy_text, "permit (", "forbid ("),
        encoding="utf-8",
    )
    environment = {
        "PATH": "/usr/bin:/bin",
        "HOME": str(root / "empty-home"),
        "TMPDIR": str(root / "tmp"),
        "LC_ALL": "C",
        "AGENT_LAB_CUE_TOOL_DIR": str(repo / ".cache/dev/tools/cue"),
        "AGENT_LAB_CEDAR_TOOL_DIR": str(repo / ".cache/dev/tools/cedar"),
    }
    Path(environment["HOME"]).mkdir()
    Path(environment["TMPDIR"]).mkdir()
    baseline_home = root / "baseline-home"
    baseline_init = run_command(
        [str(entrypoint), "--home", str(baseline_home), "init"], environment
    )
    baseline = run_command(
        [
            str(entrypoint),
            "--home",
            str(baseline_home),
            "experiment",
            "install",
            "--zip",
            str(archive),
        ],
        environment,
    )
    if baseline_init.returncode != 0 or baseline.returncode != 1:
        return False

    store = runtime / "scripts/experiment_store.py"
    store_original = store.read_text(encoding="utf-8")
    needle = "            decision, status = experiment.authorize_plan(plan, snapshot.digest)\n"
    replacement = (
        "            decision, status = experiment.authorize_plan(plan, snapshot.digest)\n"
        "            mutation_marker = os.environ.get(\"AGENT_LAB_ZIP_MUTATION_MARK\")\n"
        "            if mutation_marker is not None:\n"
        "                Path(mutation_marker).touch()\n"
        "                decision = dict(decision)\n"
        "                decision[\"verdict\"] = \"permit\"\n"
        "                status = 0\n"
    )
    store.write_text(replace_once(store_original, needle, replacement), encoding="utf-8")
    marker.unlink(missing_ok=True)
    environment["AGENT_LAB_ZIP_MUTATION_MARK"] = str(marker)
    mutant_home = root / "mutant-home"
    mutant_init = run_command(
        [str(entrypoint), "--home", str(mutant_home), "init"], environment
    )
    mutant = run_command(
        [
            str(entrypoint),
            "--home",
            str(mutant_home),
            "experiment",
            "install",
            "--zip",
            str(archive),
        ],
        environment,
    )
    installed = mutant_home / "experiments/first-experiment/records/install.json"
    return (
        mutant_init.returncode == 0
        and mutant.returncode == 0
        and marker.is_file()
        and installed.is_file()
        and sha256((repo / "scripts/experiment_store.py").read_bytes()).hexdigest()
        == sha256(store_original.encode("utf-8")).hexdigest()
    )


def main() -> int:
    repo = Path(__file__).resolve().parents[2]
    production = repo / "scripts/experiment.py"
    original = production.read_text(encoding="utf-8")
    failures = 0
    infrastructure = 0
    results: list[tuple[str, bool, str]] = []
    work_path = tempfile.mkdtemp(prefix="agent-lab-zip-mutations-")
    work = Path(work_path)
    try:
        fixtures = work / "fixtures"
        generated = subprocess.run(
            [
                sys.executable,
                "-I",
                "-B",
                str(repo / "tests/experiment/zip-fixtures.py"),
                str(repo / "tests/experiment/fixtures/directories/minimal/experiment.cue"),
                str(fixtures),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=5,
        )
        if generated.returncode != 0 or generated.stdout or generated.stderr:
            raise RuntimeError("private ZIP fixtures could not be generated")
        baseline_module = load_module(production, "zip_mutation_baseline")
        private_source = work / "experiment.py"
        shutil.copy2(repo / "scripts/image_reference.py", work / "image_reference.py")
        marker = work / "reached"
        cases = (
            (
                "M-ZIP-COUNT-001",
                "zero-count.zip",
                "ZIP-COUNT",
                "    if disk_entries != 1 or total_entries != 1:\n",
                (
                    "    if os.environ.get(\"AGENT_LAB_ZIP_MUTATION_MARK\") is not None:\n"
                    "        Path(os.environ[\"AGENT_LAB_ZIP_MUTATION_MARK\"]).touch()\n"
                    "    if False:\n"
                ),
            ),
            (
                "M-ZIP-NAME-001",
                "wrong-case.zip",
                "ZIP-PATH",
                '    if decoded_name != "experiment.cue":\n',
                (
                    "    if os.environ.get(\"AGENT_LAB_ZIP_MUTATION_MARK\") is not None:\n"
                    "        Path(os.environ[\"AGENT_LAB_ZIP_MUTATION_MARK\"]).touch()\n"
                    "    if False:\n"
                ),
            ),
            (
                "M-ZIP-TYPE-001",
                "symlink-type.zip",
                "ZIP-TYPE",
                (
                    "    if (\n"
                    "        create_system not in (0, 3)\n"
                    "        or dos_attributes & 0x18\n"
                    "        or (create_system == 3 and unix_type not in (0, stat.S_IFREG))\n"
                    "    ):\n"
                ),
                (
                    "    if os.environ.get(\"AGENT_LAB_ZIP_MUTATION_MARK\") is not None:\n"
                    "        Path(os.environ[\"AGENT_LAB_ZIP_MUTATION_MARK\"]).touch()\n"
                    "    if False:\n"
                ),
            ),
            (
                "M-ZIP-FLAG-001",
                "encrypted.zip",
                "ZIP-FLAG",
                "    if flags & ~allowed_flags:\n",
                (
                    "    if os.environ.get(\"AGENT_LAB_ZIP_MUTATION_MARK\") is not None:\n"
                    "        Path(os.environ[\"AGENT_LAB_ZIP_MUTATION_MARK\"]).touch()\n"
                    "    if False:\n"
                ),
            ),
            (
                "M-ZIP-METHOD-001",
                "unsupported-deflate-method.zip",
                "ZIP-METHOD",
                "    if method not in (0, 8):\n",
                (
                    "    if os.environ.get(\"AGENT_LAB_ZIP_MUTATION_MARK\") is not None:\n"
                    "        Path(os.environ[\"AGENT_LAB_ZIP_MUTATION_MARK\"]).touch()\n"
                    "    if False:\n"
                ),
            ),
            (
                "M-ZIP-SIZE-001",
                "expanded-over.zip",
                "ZIP-SIZE",
                "    if expanded_size > MAX_SOURCE_BYTES:\n",
                (
                    "    if os.environ.get(\"AGENT_LAB_ZIP_MUTATION_MARK\") is not None:\n"
                    "        Path(os.environ[\"AGENT_LAB_ZIP_MUTATION_MARK\"]).touch()\n"
                    "    if False:\n"
                ),
            ),
            (
                "M-ZIP-CRC-001",
                "bad-crc.zip",
                "ZIP-CRC",
                "    if (zlib.crc32(data) & 0xFFFFFFFF) != crc:\n",
                (
                    "    if os.environ.get(\"AGENT_LAB_ZIP_MUTATION_MARK\") is not None:\n"
                    "        Path(os.environ[\"AGENT_LAB_ZIP_MUTATION_MARK\"]).touch()\n"
                    "    if False:\n"
                ),
            ),
            (
                "M-ZIP-HEADER-001",
                "central-signature.zip",
                "ZIP-HEADER",
                '    if central_signature != b"PK\\x01\\x02":\n',
                (
                    "    if os.environ.get(\"AGENT_LAB_ZIP_MUTATION_MARK\") is not None:\n"
                    "        Path(os.environ[\"AGENT_LAB_ZIP_MUTATION_MARK\"]).touch()\n"
                    "    if False:\n"
                ),
            ),
        )
        for assertion, fixture_name, code, needle, replacement in cases:
            result = parser_mutation(
                production,
                original,
                private_source,
                baseline_module,
                fixtures / fixture_name,
                code,
                assertion,
                needle,
                replacement,
                marker,
            )
            results.append((assertion, result, "private parser mutation is killed"))

        extraction = work / "caller-destination"
        extraction.mkdir()
        extraction_needle = "    archive = _read_zip_archive_once(path)\n"
        extraction_replacement = (
            "    archive = _read_zip_archive_once(path)\n"
            "    mutation_marker = os.environ.get(\"AGENT_LAB_ZIP_MUTATION_MARK\")\n"
            "    if mutation_marker is not None:\n"
            "        Path(mutation_marker).touch()\n"
            "        __import__(\"zipfile\").ZipFile(\n"
            "            __import__(\"io\").BytesIO(archive)\n"
            "        ).extractall(Path(os.environ[\"AGENT_LAB_ZIP_MUTATION_DEST\"]))\n"
        )
        private_source.write_text(
            replace_once(original, extraction_needle, extraction_replacement), encoding="utf-8"
        )
        marker.unlink(missing_ok=True)
        os.environ["AGENT_LAB_ZIP_MUTATION_MARK"] = str(marker)
        os.environ["AGENT_LAB_ZIP_MUTATION_DEST"] = str(extraction)
        try:
            mutant = load_module(private_source, "zip_mutant_extract")
            mutant.read_zip_snapshot(str(fixtures / "stored.zip"))
        finally:
            os.environ.pop("AGENT_LAB_ZIP_MUTATION_MARK", None)
            os.environ.pop("AGENT_LAB_ZIP_MUTATION_DEST", None)
        results.append(
            (
                "M-ZIP-EXTRACT-001",
                marker.is_file() and (extraction / "experiment.cue").is_file(),
                "caller-destination extraction mutation is observable",
            )
        )

        identity_needle = (
            "    return SourceSnapshot(\n"
            "        data=data,\n"
            "        digest=source_digest(data),\n"
            "        transport={\n"
            "            \"archiveBytes\": len(archive),\n"
        )
        identity_replacement = (
            "    return SourceSnapshot(\n"
            "        data=data,\n"
            "        digest=(\n"
            "            Path(os.environ[\"AGENT_LAB_ZIP_MUTATION_MARK\"]).touch()\n"
            "            or \"sha256:\" + hashlib.sha256(archive).hexdigest()\n"
            "        ),\n"
            "        transport={\n"
            "            \"archiveBytes\": len(archive),\n"
        )
        private_source.write_text(
            replace_once(original, identity_needle, identity_replacement), encoding="utf-8"
        )
        marker.unlink(missing_ok=True)
        os.environ["AGENT_LAB_ZIP_MUTATION_MARK"] = str(marker)
        try:
            mutant = load_module(private_source, "zip_mutant_identity")
            directory = mutant.read_directory_snapshot(
                str(repo / "tests/experiment/fixtures/directories/minimal")
            )
            zipped = mutant.read_zip_snapshot(str(fixtures / "stored.zip"))
        finally:
            os.environ.pop("AGENT_LAB_ZIP_MUTATION_MARK", None)
        results.append(
            (
                "M-ZIP-IDENTITY-001",
                marker.is_file() and directory.digest != zipped.digest,
                "archive-identity mutation breaks the cross-transport oracle",
            )
        )

        results.append(
            (
                "M-ZIP-AUTH-001",
                authorization_mutation(repo, work / "auth", fixtures / "stored.zip", marker),
                "saved-denial bypass mutation changes the no-effect outcome",
            )
        )
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"INFRA zip mutation harness {error}", file=sys.stderr)
        infrastructure = 1
    finally:
        try:
            for path in work.rglob("*"):
                try:
                    path.chmod(path.stat().st_mode | stat.S_IWUSR | stat.S_IXUSR)
                except OSError:
                    pass
            shutil.rmtree(work)
        except OSError:
            infrastructure = 1

    observed = tuple(item[0] for item in results)
    if observed != EXPECTED:
        infrastructure = 1
    for assertion, passed, detail in results:
        if passed:
            print(f"PASS {assertion} {detail}")
        else:
            print(f"FAIL {assertion} {detail}")
            failures += 1
    print(
        f"SUMMARY assertions={len(results)} expected={len(EXPECTED)} "
        f"failures={failures} infra={infrastructure}"
    )
    if infrastructure:
        return 125
    if failures:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
