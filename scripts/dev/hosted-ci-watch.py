#!/usr/bin/env python3
"""Observe exact-head hosted CI and diagnose terminal jobs without run-wide delay."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from typing import Protocol


REQUIRED_JOBS = {
    "ci.yml": ("Fast", "Static", "Docker security", "Required gates"),
    "codeql.yml": ("CodeQL",),
}
ACCEPTANCE_JOBS = (("ci.yml", "Required gates"), ("codeql.yml", "CodeQL"))
TERMINAL = frozenset({"completed"})
SUCCESS = "success"
MAX_EXCERPT = 2000
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
SECRET_PATTERNS = (
    re.compile(r"\bgh[pousr]_[A-Za-z0-9_]{20,}\b"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"),
    re.compile(r"(?i)\b(?:authorization|bearer)\s*[:=]?\s+\S+"),
    re.compile(r"(?i)\b(?:token|password|secret|api[_-]?key)\s*[:=]\s*\S+"),
)
FAILURE_LINE_RE = re.compile(r"(?i)(?:\bINFRA\b|\bFAIL(?:ED|URE)?\b|\bERROR\b|##\[error\])")
GENERIC_ANNOTATION_RE = re.compile(r"(?i)^process completed with exit code [0-9]+\.?$")


class WatchError(RuntimeError):
    pass


class ApiUnavailable(WatchError):
    pass


@dataclass(frozen=True)
class WorkflowState:
    workflow: str
    run: dict[str, object] | None
    jobs: tuple[dict[str, object], ...]
    ignored_heads: tuple[str, ...]


@dataclass(frozen=True)
class Snapshot:
    head: str
    merge_sha: str
    workflows: dict[str, WorkflowState]

    @property
    def all_runs_terminal(self) -> bool:
        return all(
            item.run is not None and item.run.get("status") in TERMINAL
            for item in self.workflows.values()
        )


@dataclass(frozen=True)
class Decision:
    kind: str
    detail: str
    failed_job: tuple[str, dict[str, object]] | None = None


class Client(Protocol):
    def pull_request(self, number: int) -> dict[str, object]: ...

    def workflow_runs(self, workflow: str) -> list[dict[str, object]]: ...

    def run_jobs(self, workflow: str, run_id: int) -> list[dict[str, object]]: ...

    def annotations(self, job_id: int) -> list[dict[str, object]]: ...

    def job_log(self, job_id: int) -> str: ...


def trusted_gh() -> str:
    for candidate in ("/usr/bin/gh", "/usr/local/bin/gh"):
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    raise ApiUnavailable("trusted GitHub CLI is unavailable")


class GhClient:
    def __init__(self, repository: str, pull_request: int) -> None:
        self.repository = repository
        self.pull_request_number = pull_request
        self.gh = trusted_gh()

    def _value(self, endpoint: str) -> object:
        result = subprocess.run(
            [self.gh, "api", endpoint, "--hostname", "github.com"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            detail = bounded(result.stderr or result.stdout or "GitHub API request failed")
            raise ApiUnavailable(detail)
        try:
            value = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise ApiUnavailable(f"GitHub API returned malformed JSON: {error}") from error
        return value

    def _json(self, endpoint: str) -> dict[str, object]:
        value = self._value(endpoint)
        if not isinstance(value, dict):
            raise ApiUnavailable("GitHub API returned a non-object response")
        return value

    def pull_request(self, number: int) -> dict[str, object]:
        return self._json(f"repos/{self.repository}/pulls/{number}")

    def workflow_runs(self, workflow: str) -> list[dict[str, object]]:
        value = self._json(
            f"repos/{self.repository}/actions/workflows/{workflow}/runs"
            "?event=pull_request&per_page=100"
        )
        return object_list(value.get("workflow_runs"), "workflow_runs")

    def run_jobs(self, workflow: str, run_id: int) -> list[dict[str, object]]:
        value = self._json(
            f"repos/{self.repository}/actions/runs/{run_id}/jobs?filter=latest&per_page=100"
        )
        return object_list(value.get("jobs"), f"{workflow} jobs")

    def annotations(self, job_id: int) -> list[dict[str, object]]:
        value = self._value(
            f"repos/{self.repository}/check-runs/{job_id}/annotations?per_page=100"
        )
        return object_list(value, "annotations")

    def job_log(self, job_id: int) -> str:
        result = subprocess.run(
            [
                self.gh,
                "api",
                f"repos/{self.repository}/actions/jobs/{job_id}/logs",
                "--hostname",
                "github.com",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            raise ApiUnavailable(bounded(result.stderr or result.stdout or "job log unavailable"))
        return result.stdout


class FixtureClient:
    def __init__(self, fixture: Path) -> None:
        try:
            value = json.loads(fixture.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise ApiUnavailable(f"cannot read fixture: {error}") from error
        if not isinstance(value, dict):
            raise ApiUnavailable("fixture must be an object")
        self.value = value
        self.log_offsets: dict[str, int] = {}

    def pull_request(self, number: int) -> dict[str, object]:
        value = self.value.get("pr")
        if not isinstance(value, dict) or value.get("number") != number:
            raise ApiUnavailable("fixture pull request is missing or mismatched")
        return value

    def _workflow(self, workflow: str) -> dict[str, object]:
        workflows = self.value.get("workflows")
        value = workflows.get(workflow) if isinstance(workflows, dict) else None
        if not isinstance(value, dict):
            return {"runs": [], "jobs": []}
        return value

    def workflow_runs(self, workflow: str) -> list[dict[str, object]]:
        return object_list(self._workflow(workflow).get("runs"), "fixture runs")

    def run_jobs(self, workflow: str, run_id: int) -> list[dict[str, object]]:
        del run_id
        return object_list(self._workflow(workflow).get("jobs"), "fixture jobs")

    def annotations(self, job_id: int) -> list[dict[str, object]]:
        values = self.value.get("annotations")
        raw = values.get(str(job_id), []) if isinstance(values, dict) else []
        return object_list(raw, "fixture annotations")

    def job_log(self, job_id: int) -> str:
        values = self.value.get("logs")
        raw = values.get(str(job_id), []) if isinstance(values, dict) else []
        if not isinstance(raw, list):
            raise ApiUnavailable("fixture log sequence is malformed")
        key = str(job_id)
        offset = self.log_offsets.get(key, 0)
        self.log_offsets[key] = offset + 1
        if offset >= len(raw) or not isinstance(raw[offset], dict):
            raise ApiUnavailable("fixture job log unavailable")
        entry = raw[offset]
        if entry.get("status") != 200:
            raise ApiUnavailable(str(entry.get("text", "fixture job log unavailable")))
        return str(entry.get("text", ""))


def object_list(value: object, label: str) -> list[dict[str, object]]:
    if not isinstance(value, list) or not all(isinstance(item, dict) for item in value):
        raise ApiUnavailable(f"{label} must be an object array")
    return value


def bounded(value: str, limit: int = MAX_EXCERPT) -> str:
    cleaned = ANSI_RE.sub("", value)
    for pattern in SECRET_PATTERNS:
        cleaned = pattern.sub("[REDACTED]", cleaned)
    lines = [" ".join(line.split()) for line in cleaned.splitlines() if line.strip()]
    result = " | ".join(lines[-8:])
    if len(result) > limit:
        result = result[: limit - 3] + "..."
    return result


def log_excerpt(value: str) -> str:
    cleaned = ANSI_RE.sub("", value)
    relevant = [line for line in cleaned.splitlines() if FAILURE_LINE_RE.search(line)]
    return bounded("\n".join(relevant[-8:] if relevant else cleaned.splitlines()[-8:]))


def pull_identity(value: dict[str, object]) -> tuple[str, str]:
    head = value.get("head")
    head_sha = head.get("sha") if isinstance(head, dict) else None
    merge_sha = value.get("merge_commit_sha")
    if not isinstance(head_sha, str) or not SHA_RE.fullmatch(head_sha):
        raise ApiUnavailable("pull request has no canonical head SHA")
    if not isinstance(merge_sha, str) or not SHA_RE.fullmatch(merge_sha):
        raise ApiUnavailable("pull request has no canonical merge SHA")
    return head_sha, merge_sha


def run_matches_pr(run: dict[str, object], pull_request: int) -> bool:
    pulls = run.get("pull_requests")
    if not isinstance(pulls, list):
        return False
    return any(isinstance(item, dict) and item.get("number") == pull_request for item in pulls)


def latest_run(
    runs: list[dict[str, object]], pull_request: int, head_sha: str
) -> tuple[dict[str, object] | None, tuple[str, ...]]:
    matching: list[dict[str, object]] = []
    ignored: set[str] = set()
    for item in runs:
        if not run_matches_pr(item, pull_request):
            continue
        run_head = item.get("head_sha")
        if not isinstance(run_head, str) or not SHA_RE.fullmatch(run_head):
            raise ApiUnavailable("workflow run has no canonical head SHA")
        if run_head != head_sha:
            ignored.add(run_head)
            continue
        matching.append(item)
    if not matching:
        return None, tuple(sorted(ignored))
    matching.sort(key=lambda item: int(item.get("id", 0)))
    return matching[-1], tuple(sorted(ignored))


def collect_snapshot(client: Client, pull_request: int) -> Snapshot:
    pr = client.pull_request(pull_request)
    head, merge_sha = pull_identity(pr)
    workflows: dict[str, WorkflowState] = {}
    for workflow in REQUIRED_JOBS:
        selected, ignored = latest_run(client.workflow_runs(workflow), pull_request, head)
        jobs: tuple[dict[str, object], ...] = ()
        if selected is not None:
            run_id = selected.get("id")
            if not isinstance(run_id, int) or run_id < 1:
                raise ApiUnavailable(f"{workflow} run has no positive integer ID")
            jobs = tuple(client.run_jobs(workflow, run_id))
            for item in jobs:
                job_head = item.get("head_sha")
                if job_head != head:
                    raise ApiUnavailable(f"{workflow} job is bound to the wrong PR head SHA")
        workflows[workflow] = WorkflowState(workflow, selected, jobs, ignored)
    return Snapshot(head, merge_sha, workflows)


def evaluate(snapshot: Snapshot, expected_head: str) -> Decision:
    if snapshot.head != expected_head:
        return Decision(
            "refused",
            f"expected head {expected_head} but PR head is {snapshot.head}",
        )
    failed_jobs: list[tuple[str, dict[str, object]]] = []
    required: dict[tuple[str, str], dict[str, object]] = {}
    pending_details: list[str] = []
    for workflow, expected_names in REQUIRED_JOBS.items():
        state = snapshot.workflows[workflow]
        if state.run is None:
            if state.ignored_heads:
                pending_details.append(
                    f"run head {state.ignored_heads[-1]} does not match current PR head {snapshot.head}"
                )
            else:
                pending_details.append(f"{workflow} run not observed")
            continue
        by_name: dict[str, list[dict[str, object]]] = {}
        for item in state.jobs:
            name = item.get("name")
            if isinstance(name, str):
                by_name.setdefault(name, []).append(item)
            if item.get("status") in TERMINAL and item.get("conclusion") != SUCCESS:
                failed_jobs.append((workflow, item))
        for name in expected_names:
            entries = by_name.get(name, [])
            if len(entries) == 1:
                required[(workflow, name)] = entries[0]
            elif not entries:
                pending_details.append(f"{workflow}/{name} not observed")
            else:
                return Decision("refused", f"duplicate {workflow}/{name} jobs")
    all_required_terminal = all(
        key in required and required[key].get("status") in TERMINAL
        for key in ((workflow, name) for workflow, names in REQUIRED_JOBS.items() for name in names)
    )
    if failed_jobs:
        failed_jobs.sort(key=lambda item: int(item[1].get("id", 0)))
        workflow, item = failed_jobs[0]
        return Decision("failed", "terminal required workflow job failed", (workflow, item))
    if not all_required_terminal:
        detail = pending_details[0] if pending_details else "required jobs are still pending"
        return Decision("pending", detail)
    for key in ACCEPTANCE_JOBS:
        item = required.get(key)
        if item is None or item.get("conclusion") != SUCCESS:
            return Decision("pending", f"{key[0]}/{key[1]} is not successful")
    return Decision("accepted", "complete exact-head required Actions set is successful")


def failing_step(job: dict[str, object]) -> str:
    steps = job.get("steps")
    if isinstance(steps, list):
        for item in steps:
            if isinstance(item, dict) and item.get("status") in TERMINAL and item.get("conclusion") != SUCCESS:
                name = item.get("name")
                if isinstance(name, str) and name:
                    return bounded(name, 240)
    return "unavailable"


def diagnose(
    client: Client, job: dict[str, object], retries: int, delay: float
) -> tuple[str, str]:
    job_id = job.get("id")
    if not isinstance(job_id, int) or job_id < 1:
        return "unavailable", "job has no positive integer ID"
    try:
        annotations = client.annotations(job_id)
    except ApiUnavailable:
        annotations = []
    failure_annotations = [
        item for item in annotations if item.get("annotation_level") == "failure"
    ]
    selected = failure_annotations[0] if failure_annotations else None
    annotation_excerpt = ""
    if selected is not None:
        message = selected.get("message") or selected.get("raw_details") or selected.get("title")
        if isinstance(message, str) and message.strip():
            annotation_excerpt = bounded(message)
            if not GENERIC_ANNOTATION_RE.fullmatch(annotation_excerpt):
                return "check-annotations", annotation_excerpt
    last_error = "direct job log unavailable"
    for attempt in range(1, retries + 1):
        try:
            log = client.job_log(job_id)
            excerpt = log_excerpt(log)
            if excerpt:
                return f"job-log attempt={attempt}/{retries}", excerpt
            last_error = "direct job log was empty"
        except ApiUnavailable as error:
            last_error = bounded(str(error))
        if attempt < retries and delay:
            time.sleep(delay)
    if annotation_excerpt:
        return "check-annotations", annotation_excerpt
    return f"unavailable attempts={retries}", last_error


def print_failure(
    snapshot: Snapshot,
    decision: Decision,
    source: str,
    excerpt: str,
) -> None:
    assert decision.failed_job is not None
    workflow, job = decision.failed_job
    print("HOSTED CI DIAGNOSIS")
    print(f"head={snapshot.head}")
    print(f"merge={snapshot.merge_sha}")
    print(f"workflow={workflow}")
    print(f"job-id={job.get('id')}")
    print(f"job-name={bounded(str(job.get('name', 'unavailable')), 240)}")
    print(f"conclusion={job.get('conclusion')}")
    print(f"failing-step={failing_step(job)}")
    print(f"diagnostic-source={source}")
    print(f"excerpt={excerpt}")
    print("HOSTED CI FAILED")


def process_snapshot(
    client: Client,
    snapshot: Snapshot,
    expected_head: str,
    retries: int,
    delay: float,
) -> Decision:
    decision = evaluate(snapshot, expected_head)
    if decision.kind == "failed":
        assert decision.failed_job is not None
        source, excerpt = diagnose(client, decision.failed_job[1], retries, delay)
        print_failure(snapshot, decision, source, excerpt)
    elif decision.kind == "refused":
        print(f"REFUSE hosted-ci-watch {decision.detail}")
    elif decision.kind == "accepted":
        print(
            f"HOSTED CI ACCEPTED head={snapshot.head} "
            "required=ci.yml/Required gates,codeql.yml/CodeQL"
        )
    return decision


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--pr", type=int, required=True)
    parser.add_argument("--expected-head", required=True)
    parser.add_argument("--poll-seconds", type=float, default=15.0)
    parser.add_argument("--timeout", type=float, default=10800.0)
    parser.add_argument("--diagnostic-retries", type=int, default=3)
    parser.add_argument("--diagnostic-delay", type=float, default=2.0)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--fixture", type=Path)
    args = parser.parse_args()
    if not REPO_RE.fullmatch(args.repo):
        parser.error("--repo must be owner/name")
    if args.pr < 1:
        parser.error("--pr must be positive")
    if not SHA_RE.fullmatch(args.expected_head):
        parser.error("--expected-head must be a lowercase 40-hex SHA")
    if not 1 <= args.diagnostic_retries <= 5:
        parser.error("--diagnostic-retries must be between 1 and 5")
    if args.diagnostic_delay < 0 or args.diagnostic_delay > 30:
        parser.error("--diagnostic-delay must be between 0 and 30 seconds")
    if args.poll_seconds <= 0 or args.poll_seconds > 300:
        parser.error("--poll-seconds must be greater than 0 and at most 300")
    if args.timeout < 60 or args.timeout > 21600:
        parser.error("--timeout must be between 60 and 21600 seconds")
    if args.fixture is not None and os.environ.get("AGENT_LAB_HOSTED_CI_WATCH_TESTING") != "1":
        parser.error("--fixture is test-only")
    return args


def main() -> int:
    args = parse_args()
    try:
        client: Client = FixtureClient(args.fixture) if args.fixture is not None else GhClient(args.repo, args.pr)
        deadline = time.monotonic() + args.timeout
        last_pending = ""
        while True:
            snapshot = collect_snapshot(client, args.pr)
            decision = process_snapshot(
                client,
                snapshot,
                args.expected_head,
                args.diagnostic_retries,
                args.diagnostic_delay,
            )
            if decision.kind == "accepted":
                return 0
            if decision.kind == "failed":
                return 1
            if decision.kind == "refused":
                return 2
            if args.once:
                print(f"HOSTED CI PENDING head={snapshot.head} detail={bounded(decision.detail, 500)}")
                return 125
            if decision.detail != last_pending:
                print(f"HOSTED CI PENDING head={snapshot.head} detail={bounded(decision.detail, 500)}", flush=True)
                last_pending = decision.detail
            if time.monotonic() >= deadline:
                print(f"INFRA hosted-ci-watch timed out after {int(args.timeout)} seconds", file=sys.stderr)
                return 125
            time.sleep(args.poll_seconds)
    except ApiUnavailable as error:
        print(f"INFRA hosted-ci-watch {bounded(str(error), 1000)}", file=sys.stderr)
        return 125


if __name__ == "__main__":
    raise SystemExit(main())
