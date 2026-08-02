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


EXPECTED = (
    "GIT-CLI-001",
    "GIT-USAGE-001",
    "GIT-URL-001",
    "GIT-OID-001",
    "GIT-PLAT-001",
    "GIT-FIXTURE-001",
    "GIT-PIN-001",
    "GIT-COMMIT-001",
    "GIT-ROOT-001",
    "GIT-TYPE-001",
    "GIT-BLOB-001",
    "GIT-DRIFT-001",
)
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

                def acquire(
                    responses: dict[str, tuple[int, tuple[tuple[str, str], ...], bytes]],
                    *,
                    source_url: str = URL,
                    source_commit: str = COMMIT,
                ):
                    calls: list[tuple[str, str, tuple[tuple[str, str], ...], int]] = []

                    def fixture_requester(authority, path, headers, maximum, _deadline):
                        calls.append((authority, path, tuple(headers), maximum))
                        return responses[path]

                    try:
                        value = experiment.read_git_snapshot(
                            source_url,
                            source_commit,
                            requester=fixture_requester,
                        )
                        return "ok", value, calls
                    except experiment.InvalidManifest as error:
                        return "reject", str(error), calls
                    except experiment.InfrastructureError as error:
                        return "infra", str(error), calls

                unused_request_calls: list[str] = []

                def unused_requester(_authority, path, _headers, _maximum, _deadline):
                    unused_request_calls.append(path)
                    raise AssertionError("invalid input reached acquisition")

                invalid_urls = (
                    "http://github.com/uscient/experiment-fixture.git",
                    "https://example.com/uscient/experiment-fixture.git",
                    "https://user@github.com/uscient/experiment-fixture.git",
                    "https://github.com:443/uscient/experiment-fixture.git",
                    "https://github.com/uscient/experiment-fixture.git?ref=main",
                    "https://github.com/uscient/experiment-fixture.git#main",
                    "https://github.com/uscient/experiment-fixture",
                    "https://github.com/uscient/%65xperiment-fixture.git",
                    "https://github.com/uscient/experiment-fixture.git/extra",
                    "https://github.com/uscient/experiment-fixture.git\n",
                )
                url_rejections = []
                for invalid_url in invalid_urls:
                    try:
                        experiment.read_git_snapshot(
                            invalid_url, COMMIT, requester=unused_requester
                        )
                    except experiment.InvalidManifest as error:
                        url_rejections.append("GIT-URL" in str(error))
                    except experiment.InfrastructureError:
                        url_rejections.append(False)
                results.append(
                    (
                        "GIT-URL-001",
                        all(url_rejections) and unused_request_calls == [],
                        "only normalized unauthenticated GitHub HTTPS URLs are accepted",
                    )
                )

                invalid_oids = (
                    "main",
                    "refs/heads/main",
                    "1" * 7,
                    "1" * 39,
                    "1" * 41,
                    "A" * 40,
                    "g" * 40,
                    "-" * 40,
                )
                oid_rejections = []
                for invalid_oid in invalid_oids:
                    try:
                        experiment.read_git_snapshot(
                            URL, invalid_oid, requester=unused_requester
                        )
                    except experiment.InvalidManifest as error:
                        oid_rejections.append("GIT-OID" in str(error))
                    except experiment.InfrastructureError:
                        oid_rejections.append(False)
                results.append(
                    (
                        "GIT-OID-001",
                        all(oid_rejections) and unused_request_calls == [],
                        "mutable refs and non-full object IDs are rejected before acquisition",
                    )
                )

                original_platform = experiment.sys.platform
                experiment.sys.platform = "darwin"
                try:
                    platform_outcome = None
                    try:
                        experiment.read_git_snapshot(URL, COMMIT, requester=unused_requester)
                    except experiment.InfrastructureError as error:
                        platform_outcome = str(error)
                finally:
                    experiment.sys.platform = original_platform
                results.append(
                    (
                        "GIT-PLAT-001",
                        platform_outcome is not None
                        and "GIT-PLATFORM" in platform_outcome
                        and unused_request_calls == [],
                        "unsupported hosts refuse before acquisition",
                    )
                )

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

                results.append(
                    (
                        "GIT-PIN-001",
                        [call[1] for call in request_calls]
                        == [
                            f"/repos/uscient/experiment-fixture/git/commits/{COMMIT}",
                            f"/repos/uscient/experiment-fixture/git/trees/{TREE}",
                            f"/repos/uscient/experiment-fixture/git/blobs/{BLOB}",
                        ]
                        and all("heads" not in call[1] and "tags" not in call[1] for call in request_calls),
                        "acquisition follows only the exact pinned object chain",
                    )
                )

                mismatched_commit = dict(fixture_responses)
                mismatched_commit[next(iter(fixture_responses))] = response(
                    {"sha": "0" * 40, "tree": {"sha": TREE}}
                )
                commit_outcome = acquire(mismatched_commit)
                results.append(
                    (
                        "GIT-COMMIT-001",
                        commit_outcome[0] == "infra"
                        and "GIT-COMMIT" in commit_outcome[1],
                        "provider commit identity must equal the exact request",
                    )
                )

                extra_tree = dict(tree_body)
                extra_tree["tree"] = list(tree_body["tree"]) + [
                    {
                        "mode": "100644",
                        "path": "extra",
                        "sha": BLOB,
                        "size": len(source),
                        "type": "blob",
                    }
                ]
                root_responses = dict(fixture_responses)
                root_responses[f"/repos/uscient/experiment-fixture/git/trees/{TREE}"] = response(
                    extra_tree
                )
                root_outcome = acquire(root_responses)
                results.append(
                    (
                        "GIT-ROOT-001",
                        root_outcome[0] == "reject" and "GIT-ROOT" in root_outcome[1],
                        "extra root entries fail closed",
                    )
                )

                type_outcomes = []
                for path, mode, kind in (
                    ("experiment.cue", "100755", "blob"),
                    ("experiment.cue", "120000", "blob"),
                    ("experiment.cue", "160000", "commit"),
                    ("experiment.cue/nested", "100644", "blob"),
                    ("experiment.cue", "040000", "tree"),
                ):
                    changed_tree = dict(tree_body)
                    changed_tree["tree"] = [
                        {
                            "mode": mode,
                            "path": path,
                            "sha": BLOB,
                            "size": len(source),
                            "type": kind,
                        }
                    ]
                    changed_responses = dict(fixture_responses)
                    changed_responses[
                        f"/repos/uscient/experiment-fixture/git/trees/{TREE}"
                    ] = response(changed_tree)
                    type_outcomes.append(acquire(changed_responses))
                results.append(
                    (
                        "GIT-TYPE-001",
                        all(
                            outcome[0] == "reject" and "GIT-TYPE" in outcome[1]
                            for outcome in type_outcomes
                        ),
                        "non-regular root modes and nested paths fail closed",
                    )
                )

                encoded_source = blob_body["content"]
                assert isinstance(encoded_source, str)
                wrapped_blob = dict(blob_body)
                wrapped_blob["content"] = "\n".join(
                    encoded_source[index : index + 60]
                    for index in range(0, len(encoded_source), 60)
                ) + "\n"
                wrapped_responses = dict(fixture_responses)
                wrapped_responses[f"/repos/uscient/experiment-fixture/git/blobs/{BLOB}"] = response(
                    wrapped_blob
                )
                wrapped_outcome = acquire(wrapped_responses)
                corrupt_blob = dict(blob_body)
                corrupt_blob["content"] = base64.b64encode(source + b"x").decode("ascii")
                corrupt_responses = dict(fixture_responses)
                corrupt_responses[f"/repos/uscient/experiment-fixture/git/blobs/{BLOB}"] = response(
                    corrupt_blob
                )
                corrupt_outcome = acquire(corrupt_responses)
                results.append(
                    (
                        "GIT-BLOB-001",
                        wrapped_outcome[0] == "ok"
                        and wrapped_outcome[1].data == source
                        and corrupt_outcome[0] == "infra"
                        and "GIT-BLOB" in corrupt_outcome[1],
                        "documented base64 wrapping is accepted but object drift is not",
                    )
                )

                drift_tree = dict(tree_body)
                drift_tree["sha"] = "0" * 40
                drift_responses = dict(fixture_responses)
                drift_responses[f"/repos/uscient/experiment-fixture/git/trees/{TREE}"] = response(
                    drift_tree
                )
                drift_outcome = acquire(drift_responses)
                results.append(
                    (
                        "GIT-DRIFT-001",
                        drift_outcome[0] == "infra" and "GIT-TREE" in drift_outcome[1],
                        "changed object output is infrastructure uncertainty",
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
