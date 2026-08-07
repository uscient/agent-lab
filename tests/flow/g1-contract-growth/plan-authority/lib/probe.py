#!/usr/bin/env python3
"""Report exactly what the real product modules returned for one question.

This driver never reimplements product behaviour and never decides whether an
answer is correct.  It loads `scripts/experiment.py` and
`scripts/experiment_store.py` through the existing isolated import pattern and
prints one canonical JSON object describing what the product did, so the focused
suite can keep three outcomes apart that must never be confused:

  * the successor seam is absent            -> assertion evidence, not a fault
  * the seam is present and refused input   -> a product result
  * the seam is present and produced a plan -> a product result

Nothing but that one JSON object reaches stdout.  A caller may therefore grep
the answer for a synthetic secret canary and know that anything it finds was
echoed by the product rather than added here.

Exit status is 0 whenever an answer was produced, including "the seam is
absent"; 125 only when this driver itself could not run.
"""

from __future__ import annotations

from importlib.util import module_from_spec, spec_from_file_location
import json
from pathlib import Path
import sys
from typing import Any


EXPERIMENT_SYMBOLS = (
    "AUTHORIZATION_FILES_V0ALPHA2",
    "CONTRACT_FILES_V0ALPHA2",
    "authorize_plan_v0alpha2",
    "authored_policy_is_forbid_only",
    "contract_snapshot_v0alpha2",
    "cue_plan_v0alpha2",
    "expected_plan_v0alpha2",
    "plan_binding_v0alpha2",
)
STORE_SYMBOLS = (
    "EXECUTION_AUTHORITY_INCOMPLETE",
    "EXECUTION_ELIGIBLE",
    "EXECUTION_NON_EXECUTABLE",
    "classify_plan_execution",
)
CONTRACT_DIRECTORY = "contracts/experiment/v0alpha2"
AUTHORIZATION_DIRECTORY = "authorization/experiment/v0alpha2"


def emit(answer: dict[str, Any]) -> int:
    sys.stdout.write(
        json.dumps(answer, allow_nan=False, ensure_ascii=True, sort_keys=True) + "\n"
    )
    return 0


def load(path: Path, label: str):
    spec = spec_from_file_location(label, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"{label} cannot be located")
    module = module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def read_json(path: str) -> Any:
    return json.loads(Path(path).read_bytes().decode("utf-8"))


class SeamAbsent(Exception):
    """The successor seam this question needs has not been implemented."""

    def __init__(self, missing: list[str]) -> None:
        super().__init__(",".join(missing))
        self.missing = missing


class Seam:
    def __init__(self, repo_root: Path) -> None:
        self.repo_root = repo_root
        self.missing: list[str] = []
        self.experiment = None
        self.store = None
        for relative in (CONTRACT_DIRECTORY, AUTHORIZATION_DIRECTORY):
            if not (repo_root / relative).is_dir():
                self.missing.append(relative)
        try:
            self.experiment = load(repo_root / "scripts/experiment.py", "g1_experiment")
        except Exception:  # noqa: BLE001 - any load failure is a missing seam report
            self.missing.append("scripts/experiment.py")
        try:
            self.store = load(
                repo_root / "scripts/experiment_store.py", "g1_experiment_store"
            )
        except Exception:  # noqa: BLE001
            self.missing.append("scripts/experiment_store.py")
        for name in EXPERIMENT_SYMBOLS:
            if self.experiment is None or not hasattr(self.experiment, name):
                self.missing.append(f"scripts/experiment.py:{name}")
        for name in STORE_SYMBOLS:
            if self.store is None or not hasattr(self.store, name):
                self.missing.append(f"scripts/experiment_store.py:{name}")

    def require(self, *names: str):
        absent = [name for name in names if name in self.missing]
        if absent:
            raise SeamAbsent(absent)


def question_seam(seam: Seam, _arguments: list[str]) -> dict[str, Any]:
    return {"ok": True, "present": not seam.missing, "missing": seam.missing}


def question_constants(seam: Seam, _arguments: list[str]) -> dict[str, Any]:
    seam.require(*(f"scripts/experiment_store.py:{name}" for name in STORE_SYMBOLS))
    return {
        "ok": True,
        "eligible": seam.store.EXECUTION_ELIGIBLE,
        "incomplete": seam.store.EXECUTION_AUTHORITY_INCOMPLETE,
        "non_executable": seam.store.EXECUTION_NON_EXECUTABLE,
    }


def question_validate(seam: Seam, arguments: list[str]) -> dict[str, Any]:
    seam.require("scripts/experiment.py:cue_plan_v0alpha2")
    manifest = read_json(arguments[0])
    try:
        plan = seam.experiment.cue_plan_v0alpha2(manifest)
    except seam.experiment.InvalidManifest as error:
        return {"ok": True, "verdict": "reject", "message": str(error)}
    except seam.experiment.InfrastructureError as error:
        return {"ok": True, "verdict": "uncertain", "message": str(error)}
    return {"ok": True, "verdict": "accept", "plan": plan}


def question_expected_plan(seam: Seam, arguments: list[str]) -> dict[str, Any]:
    seam.require("scripts/experiment.py:expected_plan_v0alpha2")
    manifest = read_json(arguments[0])
    try:
        plan = seam.experiment.expected_plan_v0alpha2(manifest, arguments[1])
    except seam.experiment.InvalidManifest as error:
        return {"ok": True, "verdict": "reject", "message": str(error)}
    except seam.experiment.InfrastructureError as error:
        return {"ok": True, "verdict": "uncertain", "message": str(error)}
    return {"ok": True, "verdict": "accept", "plan": plan}


def question_contract_digest(seam: Seam, _arguments: list[str]) -> dict[str, Any]:
    seam.require("scripts/experiment.py:contract_snapshot_v0alpha2")
    digest, files = seam.experiment.contract_snapshot_v0alpha2(seam.repo_root)
    return {"ok": True, "digest": digest, "files": sorted(files)}


def question_classify(seam: Seam, arguments: list[str]) -> dict[str, Any]:
    seam.require("scripts/experiment_store.py:classify_plan_execution")
    plan = read_json(arguments[0])
    before = json.dumps(plan, sort_keys=True)
    try:
        classification = seam.store.classify_plan_execution(plan)
    except Exception as error:  # noqa: BLE001 - the product's own failure is the answer
        return {
            "ok": True,
            "verdict": "raised",
            "error": type(error).__name__,
            "message": str(error),
        }
    return {
        "ok": True,
        "verdict": "returned",
        "classification": classification,
        "input_unchanged": before == json.dumps(plan, sort_keys=True),
    }


def question_authorize(seam: Seam, arguments: list[str]) -> dict[str, Any]:
    seam.require("scripts/experiment.py:authorize_plan_v0alpha2")
    plan = read_json(arguments[0])
    try:
        decision, status = seam.experiment.authorize_plan_v0alpha2(plan, arguments[1])
    except seam.experiment.InvalidManifest as error:
        return {"ok": True, "verdict": "reject", "message": str(error)}
    except seam.experiment.InfrastructureError as error:
        return {"ok": True, "verdict": "uncertain", "message": str(error)}
    return {"ok": True, "verdict": "decided", "decision": decision, "status": status}


def question_forbid_only(seam: Seam, arguments: list[str]) -> dict[str, Any]:
    seam.require("scripts/experiment.py:authored_policy_is_forbid_only")
    text = Path(arguments[0]).read_bytes().decode("utf-8", errors="replace")
    try:
        answer = seam.experiment.authored_policy_is_forbid_only(text)
    except Exception as error:  # noqa: BLE001
        return {
            "ok": True,
            "verdict": "raised",
            "error": type(error).__name__,
            "message": str(error),
        }
    return {"ok": True, "verdict": "returned", "forbid_only": bool(answer)}


QUESTIONS = {
    "authorize": question_authorize,
    "classify": question_classify,
    "constants": question_constants,
    "contract-digest": question_contract_digest,
    "expected-plan": question_expected_plan,
    "forbid-only": question_forbid_only,
    "seam": question_seam,
    "validate": question_validate,
}


def main(argv: list[str]) -> int:
    if len(argv) < 3 or argv[2] not in QUESTIONS:
        print(f"usage: {argv[0]} REPO_ROOT QUESTION [ARGUMENT ...]", file=sys.stderr)
        return 125
    repo_root = Path(argv[1])
    try:
        seam = Seam(repo_root)
    except Exception as error:  # noqa: BLE001
        print(f"INFRA seam resolution failed: {error}", file=sys.stderr)
        return 125
    try:
        return emit(QUESTIONS[argv[2]](seam, argv[3:]))
    except SeamAbsent as absent:
        return emit({"ok": False, "reason": "seam-absent", "missing": absent.missing})
    except (IndexError, OSError, UnicodeError, ValueError) as error:
        print(f"INFRA probe question failed: {type(error).__name__}", file=sys.stderr)
        return 125


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
