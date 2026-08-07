#!/usr/bin/env python3
"""Deterministic contract and mutation checks for hosted-ci-watch."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_HELPER = ROOT / "scripts" / "dev" / "hosted-ci-watch.py"
HEAD = "1" * 40
OLD_HEAD = "2" * 40
MERGE = "a" * 40
OLD_MERGE = "b" * 40
PR = 55
failures = 0


def pass_case(message: str) -> None:
    print(f"PASS {message}")


def fail_case(message: str) -> None:
    global failures
    failures += 1
    print(f"FAIL {message}")


def job(job_id: int, name: str, status: str, conclusion: str | None, step: str = "") -> dict[str, object]:
    steps: list[dict[str, object]] = []
    if step:
        steps.append({"name": step, "status": "completed", "conclusion": conclusion})
    return {
        "id": job_id,
        "name": name,
        "head_sha": HEAD,
        "status": status,
        "conclusion": conclusion,
        "html_url": f"https://github.test/jobs/{job_id}",
        "steps": steps,
    }


def run(run_id: int, workflow: str, status: str, conclusion: str | None, *, head: str = HEAD) -> dict[str, object]:
    return {
        "id": run_id,
        "name": "CI" if workflow == "ci.yml" else "CodeQL",
        "path": f".github/workflows/{workflow}",
        "event": "pull_request",
        "head_sha": head,
        "status": status,
        "conclusion": conclusion,
        "html_url": f"https://github.test/runs/{run_id}",
        "pull_requests": [{"number": PR}],
    }


def fixture(kind: str) -> dict[str, object]:
    pr_head = HEAD
    merge = MERGE
    if kind in {"failure", "delayed"}:
        ci_jobs = [
            job(101, "Fast", "completed", "failure", "Fast security gate"),
            job(102, "Static", "completed", "success"),
            job(103, "Docker security", "in_progress", None),
            job(104, "Required gates", "completed", "success"),
        ]
        ci_run = run(11, "ci.yml", "in_progress", None)
        codeql_jobs = [job(201, "CodeQL", "in_progress", None)]
        codeql_run = run(21, "codeql.yml", "in_progress", None)
    elif kind == "pending":
        ci_jobs = [
            job(101, "Fast", "completed", "success"),
            job(102, "Static", "in_progress", None),
            job(103, "Docker security", "queued", None),
            job(104, "Required gates", "completed", "success"),
        ]
        ci_run = run(11, "ci.yml", "in_progress", None)
        codeql_jobs = [job(201, "CodeQL", "completed", "success")]
        codeql_run = run(21, "codeql.yml", "completed", "success")
    else:
        ci_jobs = [
            job(101, "Fast", "completed", "success"),
            job(102, "Static", "completed", "success"),
            job(103, "Docker security", "completed", "success"),
            job(104, "Required gates", "completed", "success"),
        ]
        codeql_jobs = [job(201, "CodeQL", "completed", "success")]
        ci_run = run(11, "ci.yml", "completed", "success")
        codeql_run = run(21, "codeql.yml", "completed", "success")
    if kind == "duplicate":
        ci_jobs.append(job(105, "Fast", "completed", "success"))
    if kind == "old-head":
        ci_run = run(11, "ci.yml", "completed", "success", head=OLD_HEAD)
        codeql_run = run(21, "codeql.yml", "completed", "success", head=OLD_HEAD)
        for item in [*ci_jobs, *codeql_jobs]:
            item["head_sha"] = OLD_HEAD
    annotations: dict[str, object] = {}
    logs: dict[str, object] = {}
    if kind == "failure":
        annotations["101"] = [
            {
                "annotation_level": "warning",
                "message": "unrelated runtime deprecation",
                "path": ".github",
                "start_line": 1,
            },
            {
                "annotation_level": "failure",
                "title": "Process completed with exit code 125",
                "message": "missing bwrap ghp_" + "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890",
                "path": "tests/flow/g0-operator-surface/cases.sh",
                "start_line": 153,
            },
        ]
    if kind == "delayed":
        annotations["101"] = []
        logs["101"] = [
            {"status": 404, "text": "not ready"},
            {"status": 200, "text": "setup\nFast security gate\nINFRA missing bwrap\nerror\n"},
        ]
    return {
        "pr": {
            "number": PR,
            "state": "open",
            "head": {"sha": pr_head, "ref": "work/ci-fail-fast-diagnostics"},
            "base": {"ref": "dev"},
            "merge_commit_sha": merge,
        },
        "workflows": {
            "ci.yml": {"runs": [ci_run], "jobs": ci_jobs},
            "codeql.yml": {"runs": [codeql_run], "jobs": codeql_jobs},
        },
        "annotations": annotations,
        "logs": logs,
    }


def invoke(helper: Path, kind: str) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory(prefix="hosted-ci-watch-case-") as raw:
        fixture_path = Path(raw) / "fixture.json"
        fixture_path.write_text(json.dumps(fixture(kind)), encoding="utf-8")
        env = os.environ.copy()
        env["AGENT_LAB_HOSTED_CI_WATCH_TESTING"] = "1"
        return subprocess.run(
            [
                sys.executable,
                "-I",
                "-B",
                str(helper),
                "--repo",
                "uscient/agent-lab",
                "--pr",
                str(PR),
                "--expected-head",
                HEAD,
                "--once",
                "--diagnostic-retries",
                "3",
                "--diagnostic-delay",
                "0",
                "--fixture",
                str(fixture_path),
            ],
            cwd=ROOT,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )


def check_case(helper: Path, kind: str, *, quiet: bool = False) -> bool:
    result = invoke(helper, kind)
    output = result.stdout
    ok = True
    if kind == "failure":
        required = (
            "HOSTED CI FAILED",
            f"head={HEAD}",
            "workflow=ci.yml",
            "job-id=101",
            "job-name=Fast",
            "conclusion=failure",
            "failing-step=Fast security gate",
            "diagnostic-source=check-annotations",
            "excerpt=missing bwrap [REDACTED]",
        )
        ok = result.returncode == 1 and all(item in output for item in required)
        ok = ok and "HOSTED CI ACCEPTED" not in output
    elif kind == "delayed":
        ok = result.returncode == 1
        ok = ok and "diagnostic-source=job-log attempt=2/3" in output
        ok = ok and "excerpt=INFRA missing bwrap | error" in output
    elif kind == "pending":
        ok = result.returncode == 125 and f"HOSTED CI PENDING head={HEAD}" in output
        ok = ok and "HOSTED CI ACCEPTED" not in output
    elif kind == "old-head":
        ok = result.returncode == 125
        ok = ok and f"run head {OLD_HEAD} does not match current PR head {HEAD}" in output
        ok = ok and "HOSTED CI ACCEPTED" not in output
    elif kind == "success":
        ok = result.returncode == 0 and f"HOSTED CI ACCEPTED head={HEAD}" in output
        ok = ok and "required=ci.yml/Required gates,codeql.yml/CodeQL" in output
    elif kind == "duplicate":
        ok = result.returncode == 2 and "REFUSE hosted-ci-watch duplicate ci.yml/Fast jobs" in output
        ok = ok and "HOSTED CI ACCEPTED" not in output
    if not quiet:
        if ok:
            pass_case({
                "failure": "one terminal failure diagnoses while siblings and overall run remain pending",
                "delayed": "direct diagnostic retrieval retries are bounded and do not wait for the run",
                "pending": "partial or pending required results cannot become accepted hosted CI",
                "old-head": "a new head cannot reuse completed results from the failed old merge head",
                "success": "acceptance requires the complete exact-head required Actions set",
                "duplicate": "duplicate required job names are refused instead of selected arbitrarily",
            }[kind])
        else:
            fail_case(f"{kind} contract (rc={result.returncode})\n{output}")
    return ok


def mutation(helper: Path, label: str, old: str, new: str, case: str) -> None:
    text = helper.read_text(encoding="utf-8")
    if text.count(old) != 1:
        fail_case(f"{label} mutation anchor is not unique")
        return
    with tempfile.TemporaryDirectory(prefix="hosted-ci-watch-mutation-") as raw:
        mutated = Path(raw) / "hosted-ci-watch.py"
        mutated.write_text(text.replace(old, new), encoding="utf-8")
        if check_case(mutated, case, quiet=True):
            fail_case(f"{label} mutation survived")
        else:
            pass_case(f"{label} mutation turns its required contract RED")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--helper", type=Path, default=DEFAULT_HELPER)
    parser.add_argument(
        "--case", choices=("failure", "delayed", "pending", "old-head", "success", "duplicate")
    )
    args = parser.parse_args()
    helper = args.helper.resolve()
    if not helper.is_file():
        fail_case(f"hosted CI watcher helper is unavailable: {helper}")
        print(f"SUMMARY failures={failures}")
        return 1
    if args.case:
        ok = check_case(helper, args.case)
        print(f"SUMMARY failures={failures}")
        return 0 if ok else 1
    for case in ("failure", "delayed", "pending", "old-head", "success", "duplicate"):
        check_case(helper, case)
    mutation(
        helper,
        "failure-waits-for-siblings",
        "if failed_jobs:\n",
        "if failed_jobs and all_required_terminal:\n",
        "failure",
    )
    mutation(
        helper,
        "diagnosis-waits-for-run",
        'if decision.kind == "failed":\n        assert decision.failed_job is not None\n',
        'if decision.kind == "failed" and snapshot.all_runs_terminal:\n        assert decision.failed_job is not None\n',
        "failure",
    )
    mutation(
        helper,
        "partial-results-accepted",
        "if not all_required_terminal:\n",
        "if False and not all_required_terminal:\n",
        "pending",
    )
    mutation(
        helper,
        "old-head-results-reused",
        "if run_head != head_sha:\n",
        "if False and run_head != head_sha:\n",
        "old-head",
    )
    mutation(
        helper,
        "duplicate-required-job-selected",
        '            else:\n                return Decision("refused", f"duplicate {workflow}/{name} jobs")\n',
        "            else:\n                required[(workflow, name)] = entries[-1]\n",
        "duplicate",
    )
    print(f"SUMMARY failures={failures}")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
