#!/usr/bin/env python3
"""Deterministic public-contract cases for pinned Git Experiment intake."""

from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import base64
from hashlib import sha1, sha256
from importlib.util import module_from_spec, spec_from_file_location
import io
import json
import os
from pathlib import Path
import sys
import tempfile


EXPECTED = ("GIT-CLI-001", "GIT-USAGE-001", "GIT-FIXTURE-001")
URL = "https://github.com/uscient/experiment-fixture.git"
COMMIT = "1cffa1a28f96d2f2cb898b1bad70d281e359a5b5"
TREE = "64564b8e82ec9581c32cb4951ed802b544e2e0c0"
BLOB = "a1d8c8cd0f1865e66cb2463cbaa801c4b5a85656"
RAW_SOURCE_SHA256 = "efd32f249a63704830bbb9e83902fd501a5857f43b54b7dc34874ef1a9e1e593"
SOURCE_DIGEST = "sha256:463e8a7622e58281fd975d58d8a9ad44ed997dd08af32e237f1476021f7abb23"


def git_oid(kind: str, payload: bytes) -> str:
    framed = kind.encode("ascii") + b" " + str(len(payload)).encode("ascii") + b"\0" + payload
    return sha1(framed).hexdigest()


def response(body: object) -> tuple[int, tuple[tuple[str, str], ...], bytes]:
    encoded = json.dumps(body, ensure_ascii=True, separators=(",", ":"), sort_keys=True).encode()
    return (
        200,
        (("content-length", str(len(encoded))), ("content-type", "application/json; charset=utf-8")),
        encoded,
    )


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
                        all(result[0] == 2 and result[1] == "" for result in usage_results)
                        and calls == [],
                        "malformed Git option shapes fail before adapter access",
                    )
                )

                source = (
                    repo / "tests/experiment/fixtures/directories/minimal/experiment.cue"
                ).read_bytes()
                tree_payload = b"100644 experiment.cue\0" + bytes.fromhex(BLOB)
                commit_payload = (
                    f"tree {TREE}\n"
                    "author Fixture <fixture@example.invalid> 0 +0000\n"
                    "committer Fixture <fixture@example.invalid> 0 +0000\n"
                    "\n"
                    "pinned fixture\n"
                ).encode("ascii")
                fixture_exact = (
                    len(source) == 326
                    and sha256(source).hexdigest() == RAW_SOURCE_SHA256
                    and git_oid("blob", source) == BLOB
                    and git_oid("tree", tree_payload) == TREE
                    and git_oid("commit", commit_payload) == COMMIT
                )
                commit_body = {"sha": COMMIT, "tree": {"sha": TREE}}
                tree_body = {
                    "sha": TREE,
                    "tree": [
                        {
                            "mode": "100644",
                            "path": "experiment.cue",
                            "sha": BLOB,
                            "size": len(source),
                            "type": "blob",
                        }
                    ],
                    "truncated": False,
                }
                blob_body = {
                    "content": base64.b64encode(source).decode("ascii"),
                    "encoding": "base64",
                    "sha": BLOB,
                    "size": len(source),
                }
                fixture_responses = {
                    f"/repos/uscient/experiment-fixture/git/commits/{COMMIT}": response(commit_body),
                    f"/repos/uscient/experiment-fixture/git/trees/{TREE}": response(tree_body),
                    f"/repos/uscient/experiment-fixture/git/blobs/{BLOB}": response(blob_body),
                }
                request_calls: list[tuple[str, str, tuple[tuple[str, str], ...], int]] = []

                def requester(authority, path, headers, maximum, _deadline):
                    request_calls.append((authority, path, tuple(headers), maximum))
                    return fixture_responses[path]

                experiment = load_module(repo / "scripts/experiment.py", "git_intake_experiment")
                try:
                    snapshot = experiment.read_git_snapshot(
                        URL, COMMIT, requester=requester
                    )
                except (AttributeError, experiment.InvalidManifest, experiment.InfrastructureError):
                    snapshot = None
                acquired_bytes = sum(len(item[2]) for item in fixture_responses.values())
                expected_transport = {
                    "acquisition": {
                        "acquiredBytes": acquired_bytes,
                        "limitBytes": 1_048_576,
                        "method": "github-git-data-v3",
                        "requestCount": 3,
                        "temporaryBytes": 0,
                        "temporaryFiles": 0,
                    },
                    "blob": f"sha1:{BLOB}",
                    "commit": f"sha1:{COMMIT}",
                    "kind": "git",
                    "requestedCommit": COMMIT,
                    "tree": f"sha1:{TREE}",
                    "url": URL,
                }
                results.append(
                    (
                        "GIT-FIXTURE-001",
                        fixture_exact
                        and snapshot is not None
                        and snapshot.data == source
                        and snapshot.digest == SOURCE_DIGEST
                        and snapshot.transport == expected_transport
                        and [call[0] for call in request_calls]
                        == ["api.github.com"] * 3
                        and [call[1] for call in request_calls]
                        == list(fixture_responses),
                        "independent pinned Git fixture normalizes to one closed snapshot",
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
