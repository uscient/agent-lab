#!/usr/bin/env python3
"""Deterministic public-contract cases for pinned Git Experiment intake."""

from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
from importlib.util import module_from_spec, spec_from_file_location
import io
import os
from pathlib import Path
import sys
import tempfile


EXPECTED = ("GIT-CLI-001", "GIT-USAGE-001")
URL = "https://github.com/uscient/experiment-fixture.git"
COMMIT = "1cffa1a28f96d2f2cb898b1bad70d281e359a5b5"


def load_module(path: Path, label: str):
    spec = spec_from_file_location(label, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def invoke(module, argv: list[str]) -> tuple[int, str, str]:
    stdout = io.StringIO()
    stderr = io.StringIO()
    with redirect_stdout(stdout), redirect_stderr(stderr):
        result = module.main(argv)
    return result, stdout.getvalue(), stderr.getvalue()


def main() -> int:
    repo = Path(__file__).resolve().parents[2]
    failures = 0
    infrastructure = 0
    results: list[tuple[str, bool, str]] = []
    try:
        agent_lab = load_module(repo / "scripts/agent-lab.py", "git_intake_agent_lab")
        calls: list[tuple[str, ...]] = []

        class RecordingExperiment:
            @staticmethod
            def main(argv: list[str]) -> int:
                calls.append(tuple(argv))
                return 0

        agent_lab.experiment_module = lambda: RecordingExperiment
        with tempfile.TemporaryDirectory(prefix="agent-lab-git-cli-") as raw_home:
            prior_home = os.environ.get("AGENT_LAB_HOME")
            os.environ["AGENT_LAB_HOME"] = raw_home
            try:
                check = invoke(
                    agent_lab,
                    ["experiment", "check", "--git", URL, "--commit", COMMIT],
                )
                authorize = invoke(
                    agent_lab,
                    [
                        "experiment",
                        "authorize",
                        "install",
                        "--git",
                        URL,
                        "--commit",
                        COMMIT,
                    ],
                )
                expected_calls = [
                    ("experiment.py", "check-git", URL, COMMIT),
                    ("experiment.py", "authorize-git", URL, COMMIT),
                ]
                results.append(
                    (
                        "GIT-CLI-001",
                        check == (0, "", "")
                        and authorize == (0, "", "")
                        and calls == expected_calls,
                        "exact pinned Git preview forms route once to the adapter",
                    )
                )

                calls.clear()
                malformed = (
                    ["experiment", "check", "--git"],
                    ["experiment", "check", "--git", URL],
                    ["experiment", "check", "--git", URL, "--commit"],
                    ["experiment", "check", "--commit", COMMIT, "--git", URL],
                    ["experiment", "check", "--git", URL, "--commit", COMMIT, "extra"],
                    ["experiment", "authorize", "install", "--git", URL, "--commit"],
                )
                usage_results = [invoke(agent_lab, list(argv)) for argv in malformed]
                results.append(
                    (
                        "GIT-USAGE-001",
                        all(result == (2, "", "") for result in usage_results)
                        and calls == [],
                        "malformed Git option shapes fail before adapter access",
                    )
                )
            finally:
                if prior_home is None:
                    os.environ.pop("AGENT_LAB_HOME", None)
                else:
                    os.environ["AGENT_LAB_HOME"] = prior_home
    except Exception as error:
        print(f"INFRA Git intake contract probe failed: {type(error).__name__}", file=sys.stderr)
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
