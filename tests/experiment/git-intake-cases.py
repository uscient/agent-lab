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
import shutil
import signal
import socket
import stat
import subprocess
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
    "GIT-AUTHORITY-001",
    "GIT-CREDENTIAL-001",
    "GIT-REDIRECT-001",
    "GIT-CONTENT-001",
    "GIT-TIMEOUT-001",
    "GIT-OUTPUT-001",
    "GIT-ACQUIRE-001",
    "GIT-PGROUP-001",
    "GIT-CLEANUP-001",
    "GIT-TAXONOMY-001",
    "GIT-CHECK-001",
    "GIT-AUTH-001",
    "GIT-DENY-001",
    "GIT-INSTALL-001",
    "GIT-IDENTITY-001",
    "GIT-RETRY-001",
    "GIT-ADAPTER-001",
    "GIT-NOEF-001",
    "GIT-RUNTIME-001",
    "GIT-DIAG-001",
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


def invoke_with_exit(module, argv: list[str]) -> tuple[int, str, str]:
    stdout = io.StringIO()
    stderr = io.StringIO()
    with redirect_stdout(stdout), redirect_stderr(stderr):
        try:
            result = module.main(argv)
        except SystemExit as error:
            result = error.code if isinstance(error.code, int) else 1
    return result, stdout.getvalue(), stderr.getvalue()


def tree_fingerprint(root: Path) -> str:
    records: list[tuple[str, str, int, str]] = []
    if root.exists():
        for path in sorted(
            root.rglob("*"), key=lambda item: os.fsencode(str(item.relative_to(root)))
        ):
            metadata = path.lstat()
            relative = str(path.relative_to(root))
            mode = stat.S_IMODE(metadata.st_mode)
            if stat.S_ISREG(metadata.st_mode):
                kind = "file"
                content = sha256(path.read_bytes()).hexdigest()
            elif stat.S_ISDIR(metadata.st_mode):
                kind = "directory"
                content = ""
            elif stat.S_ISLNK(metadata.st_mode):
                kind = "symlink"
                content = os.readlink(path)
            else:
                kind = "other"
                content = ""
            records.append((relative, kind, mode, content))
    return sha256(repr(records).encode("utf-8")).hexdigest()


def make_writable(root: Path) -> None:
    if not root.exists():
        return
    for path in root.rglob("*"):
        try:
            metadata = path.lstat()
            if stat.S_ISDIR(metadata.st_mode):
                path.chmod(stat.S_IMODE(metadata.st_mode) | stat.S_IRWXU)
            elif stat.S_ISREG(metadata.st_mode):
                path.chmod(stat.S_IMODE(metadata.st_mode) | stat.S_IRUSR | stat.S_IWUSR)
        except OSError:
            pass


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

        store_calls: list[tuple[Path, str, str]] = []

        class RecordingStore:
            class StoreReject(Exception):
                pass

            class StoreInfrastructure(Exception):
                pass

            @staticmethod
            def install_git(home: Path, url: str, commit: str) -> dict[str, object]:
                store_calls.append((home, url, commit))
                return {
                    "changed": True,
                    "installationKey": "sha256:" + "1" * 64,
                    "name": "fixture",
                    "receiptDigest": "sha256:" + "2" * 64,
                }

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
                original_load_config_receipt = agent_lab.load_config_receipt
                original_store_module = agent_lab.experiment_store_module
                agent_lab.load_config_receipt = lambda _home: (
                    {"paths": {"cache": "cache"}},
                    b"fixture",
                )
                agent_lab.experiment_store_module = lambda: RecordingStore
                try:
                    install = invoke(
                        agent_lab,
                        [
                            "experiment",
                            "install",
                            "--git",
                            URL,
                            "--commit",
                            COMMIT,
                        ],
                    )
                finally:
                    agent_lab.load_config_receipt = original_load_config_receipt
                    agent_lab.experiment_store_module = original_store_module
                expected_calls = [
                    ("experiment.py", "check-git", URL, COMMIT),
                    ("experiment.py", "authorize-git", URL, COMMIT),
                ]
                results.append(
                    (
                        "GIT-CLI-001",
                        check == (0, "", "")
                        and authorize == (0, "", "")
                        and install[0] == 0
                        and install[2] == ""
                        and calls == expected_calls
                        and store_calls == [(Path(raw_home), URL, COMMIT)],
                        "exact pinned Git public forms route once to their adapters",
                    )
                )

                calls.clear()
                store_calls.clear()
                malformed = (
                    ["experiment", "check", "--git"],
                    ["experiment", "check", "--git", URL],
                    ["experiment", "check", "--git", URL, "--commit"],
                    ["experiment", "check", "--commit", COMMIT, "--git", URL],
                    ["experiment", "check", "--git", URL, "--commit", COMMIT, "extra"],
                    ["experiment", "authorize", "install", "--git", URL, "--commit"],
                    ["experiment", "install", "--git"],
                    ["experiment", "install", "--git", URL],
                    ["experiment", "install", "--git", URL, "--commit"],
                    ["experiment", "install", "--git", URL, "--commit", COMMIT, "extra"],
                )
                usage_results = [invoke(agent_lab, list(argv)) for argv in malformed]
                results.append(
                    (
                        "GIT-USAGE-001",
                        all(result[0] == 2 and result[1] == "" for result in usage_results)
                        and calls == []
                        and store_calls == [],
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

                public_platform_access: list[str] = []

                def platform_trap(label: str):
                    def fail(*_arguments, **_keywords):
                        public_platform_access.append(label)
                        raise AssertionError(f"unsupported platform reached {label}")

                    return fail

                original_agent_platform = agent_lab.sys.platform
                original_agent_experiment_module = agent_lab.experiment_module
                original_load_config_receipt = agent_lab.load_config_receipt
                original_store_module = agent_lab.experiment_store_module
                agent_lab.sys.platform = "darwin"
                agent_lab.experiment_module = platform_trap("experiment module")
                agent_lab.load_config_receipt = platform_trap("home receipt")
                agent_lab.experiment_store_module = platform_trap("store module")
                try:
                    public_platform_results = (
                        invoke(
                            agent_lab,
                            ["experiment", "check", "--git", URL, "--commit", COMMIT],
                        ),
                        invoke(
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
                        ),
                        invoke(
                            agent_lab,
                            [
                                "experiment",
                                "install",
                                "--git",
                                URL,
                                "--commit",
                                COMMIT,
                            ],
                        ),
                    )
                finally:
                    agent_lab.sys.platform = original_agent_platform
                    agent_lab.experiment_module = original_agent_experiment_module
                    agent_lab.load_config_receipt = original_load_config_receipt
                    agent_lab.experiment_store_module = original_store_module
                results.append(
                    (
                        "GIT-PLAT-001",
                        platform_outcome is not None
                        and "GIT-PLATFORM" in platform_outcome
                        and unused_request_calls == []
                        and all(result[0] == 125 for result in public_platform_results)
                        and public_platform_access == [],
                        "unsupported hosts refuse every public form before authority access",
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

                expected_headers = (
                    ("Accept", "application/vnd.github+json"),
                    ("Accept-Encoding", "identity"),
                    ("User-Agent", "agent-lab/v0alpha1"),
                    ("X-GitHub-Api-Version", "2022-11-28"),
                )

                ca_bytes = b"-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----\n"
                ca_offset = [0]
                ca_closed: list[int] = []
                original_ca_paths = experiment.GIT_PROVIDER_CA_FILES
                original_open = experiment.os.open
                original_fstat = experiment.os.fstat
                original_read = experiment.os.read
                original_close = experiment.os.close

                class CaMetadata:
                    st_mode = stat.S_IFREG | 0o644
                    st_uid = 0
                    st_nlink = 1
                    st_size = len(ca_bytes)

                def ca_open(path, _flags):
                    if path == "/missing-ca":
                        raise FileNotFoundError(path)
                    if path != "/trusted-ca":
                        raise AssertionError("unexpected CA path")
                    return 73

                def ca_fstat(descriptor):
                    if descriptor != 73:
                        raise AssertionError("unexpected CA descriptor")
                    return CaMetadata()

                def ca_read(descriptor, maximum):
                    if descriptor != 73:
                        raise AssertionError("unexpected CA descriptor")
                    start = ca_offset[0]
                    chunk = ca_bytes[start : start + min(maximum, 11)]
                    ca_offset[0] += len(chunk)
                    return chunk

                def ca_close(descriptor):
                    ca_closed.append(descriptor)

                experiment.GIT_PROVIDER_CA_FILES = ("/missing-ca", "/trusted-ca")
                experiment.os.open = ca_open
                experiment.os.fstat = ca_fstat
                experiment.os.read = ca_read
                experiment.os.close = ca_close
                try:
                    try:
                        ca_pem = experiment._git_system_ca_pem()
                    except experiment.InfrastructureError:
                        ca_pem = None
                finally:
                    experiment.GIT_PROVIDER_CA_FILES = original_ca_paths
                    experiment.os.open = original_open
                    experiment.os.fstat = original_fstat
                    experiment.os.read = original_read
                    experiment.os.close = original_close
                ca_probe_ok = ca_pem == ca_bytes.decode("ascii") and ca_closed == [73]

                import http.client as http_client
                import ssl as ssl_module

                direct_body = b'{"fixture":true}'
                direct_connections = []
                direct_response_specs = [
                    (
                        200,
                        [
                            ("Content-Length", str(len(direct_body))),
                            ("Content-Type", "application/json; charset=utf-8"),
                            ("Content-Encoding", "identity"),
                        ],
                        direct_body,
                    )
                ]
                original_https_connection = http_client.HTTPSConnection
                original_ssl_context = ssl_module.SSLContext
                original_maxline = http_client._MAXLINE
                original_maxheaders = http_client._MAXHEADERS
                original_ca_reader = experiment._git_system_ca_pem

                class FakeSocket:
                    def __init__(self):
                        self.timeouts = []

                    def settimeout(self, value):
                        self.timeouts.append(value)

                class FakeResponse:
                    def __init__(self, status, headers, body):
                        self.status = status
                        self.headers = headers
                        self.body = body
                        self.offset = 0
                        self.closed = False

                    def getheaders(self):
                        return self.headers

                    def read(self, maximum):
                        if self.offset >= len(self.body):
                            return b""
                        chunk = self.body[self.offset : self.offset + maximum]
                        self.offset += len(chunk)
                        return chunk

                    def close(self):
                        self.closed = True

                class FakeContext:
                    def __init__(self, protocol):
                        self.protocol = protocol
                        self.check_hostname = None
                        self.verify_mode = None
                        self.minimum_version = None
                        self.ca_data = None

                    def load_verify_locations(self, *, cadata):
                        self.ca_data = cadata

                class FakeConnection:
                    def __init__(self, authority, *, port, timeout, context):
                        self.authority = authority
                        self.port = port
                        self.timeout = timeout
                        self.context = context
                        self.sock = FakeSocket()
                        if direct_response_specs:
                            spec = direct_response_specs.pop(0)
                        else:
                            spec = (
                                200,
                                [
                                    ("Content-Length", str(len(direct_body))),
                                    (
                                        "Content-Type",
                                        "application/json; charset=utf-8",
                                    ),
                                    ("Content-Encoding", "identity"),
                                ],
                                direct_body,
                            )
                        self.response = FakeResponse(*spec)
                        self.request_record = None
                        self.closed = False
                        direct_connections.append(self)

                    def request(self, method, path, *, headers):
                        self.request_record = (method, path, headers)

                    def getresponse(self):
                        return self.response

                    def close(self):
                        self.closed = True

                http_client.HTTPSConnection = FakeConnection
                ssl_module.SSLContext = FakeContext
                experiment._git_system_ca_pem = lambda: ca_bytes.decode("ascii")
                try:
                    direct_deadline = __import__("time").monotonic() + 1.0
                    direct_https = experiment._github_api_request(
                        "api.github.com",
                        f"/repos/uscient/experiment-fixture/git/commits/{COMMIT}",
                        expected_headers,
                        1_024,
                        direct_deadline,
                    )
                    try:
                        experiment._github_api_request(
                            "credential.invalid",
                            "/repos/uscient/experiment-fixture/git/commits/invalid",
                            expected_headers,
                            1_024,
                            direct_deadline,
                        )
                        direct_invalid = "accepted"
                    except experiment.InfrastructureError as error:
                        direct_invalid = str(error)

                    def direct_status_outcome(status, headers, body, maximum=1_024):
                        direct_response_specs.append((status, headers, body))
                        try:
                            result = experiment._github_api_request(
                                "api.github.com",
                                f"/repos/uscient/experiment-fixture/git/commits/{COMMIT}",
                                expected_headers,
                                maximum,
                                direct_deadline,
                            )
                            try:
                                experiment._git_provider_json(
                                    lambda *_args: result,
                                    f"/repos/uscient/experiment-fixture/git/commits/{COMMIT}",
                                    maximum,
                                    direct_deadline,
                                    stable_not_found=True,
                                )
                                return "ok"
                            except experiment.InvalidManifest:
                                return "reject"
                            except experiment.InfrastructureError:
                                return "infra"
                        except experiment.InfrastructureError:
                            return "infra"

                    framed_headers = [
                        ("Content-Length", "2"),
                        ("Content-Type", "application/json; charset=utf-8"),
                        ("Content-Encoding", "identity"),
                    ]
                    hostile_status_outcomes = (
                        direct_status_outcome(
                            404,
                            [*framed_headers, ("Transfer-Encoding", "chunked")],
                            b"{}",
                        ),
                        direct_status_outcome(
                            422,
                            [
                                ("Content-Length", "2"),
                                ("Content-Type", "application/json; charset=utf-8"),
                                ("Content-Encoding", "gzip"),
                            ],
                            b"{}",
                        ),
                        direct_status_outcome(
                            404,
                            [
                                ("Content-Length", "2"),
                                ("Content-Type", "text/plain"),
                                ("Content-Encoding", "identity"),
                            ],
                            b"{}",
                        ),
                        direct_status_outcome(
                            422,
                            [
                                ("Content-Length", "3"),
                                ("Content-Type", "application/json; charset=utf-8"),
                                ("Content-Encoding", "identity"),
                            ],
                            b"{}",
                        ),
                        direct_status_outcome(
                            404,
                            [
                                ("Content-Length", "5"),
                                ("Content-Type", "application/json; charset=utf-8"),
                                ("Content-Encoding", "identity"),
                            ],
                            b"12345",
                            maximum=4,
                        ),
                        direct_status_outcome(
                            404,
                            [
                                ("Content-Length", "1"),
                                ("Content-Type", "application/json; charset=utf-8"),
                                ("Content-Encoding", "identity"),
                            ],
                            b"{",
                        ),
                        direct_status_outcome(404, framed_headers, b"{}"),
                        direct_status_outcome(422, framed_headers, b"{}"),
                    )

                    def injected_length_outcome(declared):
                        try:
                            experiment._git_provider_json(
                                lambda *_args: (
                                    200,
                                    (
                                        ("content-length", declared),
                                        (
                                            "content-type",
                                            "application/json; charset=utf-8",
                                        ),
                                    ),
                                    b"{}",
                                ),
                                f"/repos/uscient/experiment-fixture/git/commits/{COMMIT}",
                                1_024,
                                direct_deadline,
                                stable_not_found=True,
                            )
                            return "ok"
                        except experiment.InfrastructureError:
                            return "infra"

                    injected_lengths_closed = (
                        injected_length_outcome("2") == "ok"
                        and all(
                            injected_length_outcome(value) == "infra"
                            for value in (" 2", "+2", "02")
                        )
                    )

                    def forced_stable_outcome(path):
                        try:
                            experiment._git_provider_json(
                                lambda *_args: (
                                    404,
                                    (
                                        ("content-length", "2"),
                                        (
                                            "content-type",
                                            "application/json; charset=utf-8",
                                        ),
                                    ),
                                    b"{}",
                                ),
                                path,
                                1_024,
                                direct_deadline,
                                stable_not_found=True,
                            )
                            return "ok"
                        except experiment.InvalidManifest:
                            return "reject"
                        except experiment.InfrastructureError:
                            return "infra"

                    stable_not_found_route_closed = all(
                        forced_stable_outcome(path) == "infra"
                        for path in (
                            f"/repos/uscient/experiment-fixture/git/trees/{TREE}",
                            f"/repos/uscient/experiment-fixture/git/blobs/{BLOB}",
                        )
                    )
                    route_connections_before = len(direct_connections)
                    route_outcomes = []
                    for hostile_path in (
                        f"/repos/uscient/experiment-fixture/git/commits/{COMMIT}/../trees/{TREE}",
                        f"/repos/uscient/experiment-fixture/git/commits/{COMMIT}?recursive=1",
                    ):
                        try:
                            experiment._github_api_request(
                                "api.github.com",
                                hostile_path,
                                expected_headers,
                                1_024,
                                direct_deadline,
                            )
                            route_outcomes.append("accepted")
                        except experiment.InfrastructureError:
                            route_outcomes.append("infra")
                    direct_route_closed = (
                        route_outcomes == ["infra", "infra"]
                        and len(direct_connections) == route_connections_before
                    )
                finally:
                    http_client.HTTPSConnection = original_https_connection
                    ssl_module.SSLContext = original_ssl_context
                    http_client._MAXLINE = original_maxline
                    http_client._MAXHEADERS = original_maxheaders
                    experiment._git_system_ca_pem = original_ca_reader
                direct_connection = direct_connections[0] if direct_connections else None
                direct_status_framing_ok = hostile_status_outcomes == (
                    "infra",
                    "infra",
                    "infra",
                    "infra",
                    "infra",
                    "infra",
                    "reject",
                    "infra",
                )
                direct_https_ok = (
                    direct_https
                    == (
                        200,
                        (
                            ("content-length", str(len(direct_body))),
                            ("content-type", "application/json; charset=utf-8"),
                        ),
                        direct_body,
                    )
                    and direct_connection is not None
                    and direct_connection.authority == "api.github.com"
                    and direct_connection.port == 443
                    and direct_connection.request_record
                    == (
                        "GET",
                        f"/repos/uscient/experiment-fixture/git/commits/{COMMIT}",
                        dict(expected_headers),
                    )
                    and direct_connection.context.protocol
                    == ssl_module.PROTOCOL_TLS_CLIENT
                    and direct_connection.context.check_hostname is True
                    and direct_connection.context.verify_mode == ssl_module.CERT_REQUIRED
                    and direct_connection.context.minimum_version
                    == ssl_module.TLSVersion.TLSv1_2
                    and direct_connection.context.ca_data == ca_bytes.decode("ascii")
                    and direct_connection.response.closed
                    and direct_connection.closed
                    and direct_connection.sock.timeouts
                    and all(value > 0 for value in direct_connection.sock.timeouts)
                    and "GIT-AUTHORITY" in direct_invalid
                )
                results.append(
                    (
                        "GIT-AUTHORITY-001",
                        all(call[0] == "api.github.com" for call in request_calls)
                        and all(call[2] == expected_headers for call in request_calls)
                        and request_calls[0][3] == 1_048_576
                        and request_calls[0][3] > request_calls[1][3] > request_calls[2][3]
                        and direct_https_ok
                        and direct_route_closed,
                        "only the fixed credential-free provider authority is requested",
                    )
                )

                inherited_names = {
                    "GIT_ASKPASS": str(Path(raw_home) / "askpass"),
                    "GIT_CONFIG_GLOBAL": str(Path(raw_home) / "gitconfig"),
                    "HTTPS_PROXY": "http://credential.invalid:9",
                    "SSL_CERT_FILE": str(Path(raw_home) / "caller-ca"),
                }
                prior_inherited = {name: os.environ.get(name) for name in inherited_names}
                os.environ.update(inherited_names)
                original_worker_requester = getattr(experiment, "_github_api_request", None)

                def credential_requester(authority, path, headers, maximum, deadline):
                    if os.environ != {
                        "HOME": "/nonexistent",
                        "LANG": "C",
                        "LC_ALL": "C",
                        "PATH": "/usr/bin:/bin",
                    } or os.getcwd() != "/":
                        raise RuntimeError("worker authority was not isolated")
                    descriptors = {int(item) for item in os.listdir("/proc/self/fd")}
                    if any(descriptor > 4 for descriptor in descriptors):
                        raise RuntimeError("worker inherited an unrelated descriptor")
                    return fixture_responses[path]

                experiment._github_api_request = credential_requester
                try:
                    try:
                        credential_snapshot = experiment.read_git_snapshot(URL, COMMIT)
                    except (experiment.InvalidManifest, experiment.InfrastructureError):
                        credential_snapshot = None
                finally:
                    if original_worker_requester is None:
                        delattr(experiment, "_github_api_request")
                    else:
                        experiment._github_api_request = original_worker_requester
                    for name, value in prior_inherited.items():
                        if value is None:
                            os.environ.pop(name, None)
                        else:
                            os.environ[name] = value
                credential_text = repr(credential_snapshot)
                results.append(
                    (
                        "GIT-CREDENTIAL-001",
                        credential_snapshot is not None
                        and credential_snapshot.data == source
                        and ca_probe_ok
                        and "credential.invalid" not in credential_text
                        and "caller-ca" not in credential_text
                        and "askpass" not in credential_text,
                        "caller credentials, proxy, CA, and Git configuration are not retained",
                    )
                )

                redirect_responses = dict(fixture_responses)
                redirect_responses[next(iter(fixture_responses))] = (
                    302,
                    (
                        ("content-length", "0"),
                        ("content-type", "application/json; charset=utf-8"),
                        ("location", "https://credential.invalid/secret"),
                    ),
                    b"",
                )
                redirect_outcome = acquire(redirect_responses)
                results.append(
                    (
                        "GIT-REDIRECT-001",
                        redirect_outcome[0] == "infra"
                        and "credential.invalid" not in redirect_outcome[1],
                        "provider redirects are infrastructure uncertainty and never followed",
                    )
                )

                content_marker = Path(raw_home) / "content-executed"
                marker_source = (
                    f"// $(touch {content_marker})\n".encode("ascii") + source
                )
                marker_blob = git_oid("blob", marker_source)
                marker_tree_payload = b"100644 experiment.cue\0" + bytes.fromhex(marker_blob)
                marker_tree = git_oid("tree", marker_tree_payload)
                marker_responses = {
                    f"/repos/uscient/experiment-fixture/git/commits/{COMMIT}": response(
                        {"sha": COMMIT, "tree": {"sha": marker_tree}}
                    ),
                    f"/repos/uscient/experiment-fixture/git/trees/{marker_tree}": response(
                        {
                            "sha": marker_tree,
                            "tree": [
                                {
                                    "mode": "100644",
                                    "path": "experiment.cue",
                                    "sha": marker_blob,
                                    "size": len(marker_source),
                                    "type": "blob",
                                }
                            ],
                            "truncated": False,
                        }
                    ),
                    f"/repos/uscient/experiment-fixture/git/blobs/{marker_blob}": response(
                        {
                            "content": base64.b64encode(marker_source).decode("ascii"),
                            "encoding": "base64",
                            "sha": marker_blob,
                            "size": len(marker_source),
                        }
                    ),
                }
                content_outcome = acquire(marker_responses)
                results.append(
                    (
                        "GIT-CONTENT-001",
                        content_outcome[0] == "ok"
                        and content_outcome[1].data == marker_source
                        and not content_marker.exists(),
                        "repository content is snapshotted without checkout or execution",
                    )
                )

                original_timeout = experiment.GIT_ACQUISITION_TIMEOUT_SECONDS
                experiment.GIT_ACQUISITION_TIMEOUT_SECONDS = 0.001

                def slow_requester(authority, path, headers, maximum, deadline):
                    import time

                    time.sleep(0.01)
                    return fixture_responses[path]

                try:
                    try:
                        experiment.read_git_snapshot(URL, COMMIT, requester=slow_requester)
                        timeout_outcome = "ok"
                    except experiment.InfrastructureError as error:
                        timeout_outcome = str(error)
                finally:
                    experiment.GIT_ACQUISITION_TIMEOUT_SECONDS = original_timeout

                original_worker_requester = experiment._github_api_request
                worker_started_marker = Path(raw_home) / "timeout-worker-started"

                def hanging_worker_requester(
                    _authority, _path, _headers, _maximum, _deadline
                ):
                    signal.signal(signal.SIGTERM, signal.SIG_IGN)
                    worker_started_marker.touch()
                    while True:
                        signal.pause()

                experiment._github_api_request = hanging_worker_requester
                calibration_started = __import__("time").monotonic()
                __import__("time").sleep(0.01)
                calibration_elapsed = (
                    __import__("time").monotonic() - calibration_started
                )
                worker_operation_budget = 0.25
                worker_cleanup_reserve = 2 * experiment.GIT_WORKER_GRACE_SECONDS
                worker_timeout_budget = (
                    worker_operation_budget + worker_cleanup_reserve
                )
                worker_timeout_tolerance = min(
                    0.10,
                    max(0.05, 4 * max(0.0, calibration_elapsed - 0.01)),
                )
                worker_timeout_started = __import__("time").monotonic()
                try:
                    try:
                        experiment._github_worker_request(
                            "api.github.com",
                            f"/repos/uscient/experiment-fixture/git/commits/{COMMIT}",
                            expected_headers,
                            1_024,
                            worker_timeout_started + worker_timeout_budget,
                        )
                        worker_timeout_outcome = "ok"
                    except experiment.InfrastructureError as error:
                        worker_timeout_outcome = str(error)
                finally:
                    experiment._github_api_request = original_worker_requester
                worker_timeout_elapsed = (
                    __import__("time").monotonic() - worker_timeout_started
                )
                results.append(
                    (
                        "GIT-TIMEOUT-001",
                        "GIT-TIMEOUT" in timeout_outcome
                        and "GIT-TIMEOUT" in worker_timeout_outcome
                        and worker_started_marker.is_file()
                        and worker_timeout_budget > worker_cleanup_reserve
                        and worker_timeout_elapsed
                        <= worker_timeout_budget + worker_timeout_tolerance,
                        "a started provider worker and its cleanup share one deadline",
                    )
                )

                oversized_responses = dict(fixture_responses)
                oversized_responses[next(iter(fixture_responses))] = (
                    200,
                    (
                        ("content-length", str(1_048_577)),
                        ("content-type", "application/json; charset=utf-8"),
                    ),
                    b"x" * 1_048_577,
                )
                output_outcome = acquire(oversized_responses)

                valid_worker_value = json.dumps(
                    {
                        "body": "",
                        "headers": [
                            ["content-length", "0"],
                            ["content-type", "application/json; charset=utf-8"],
                        ],
                        "kind": "result",
                        "status": 200,
                    },
                    ensure_ascii=True,
                    separators=(",", ":"),
                    sort_keys=True,
                ).encode("ascii")
                valid_worker_frame = (
                    experiment.GIT_WORKER_FRAME
                    + len(valid_worker_value).to_bytes(8, "big")
                    + valid_worker_value
                )
                original_worker_child = experiment._git_worker_child

                def worker_frame_outcome(stdout_data: bytes, stderr_data: bytes = b""):
                    def fixture_worker_child(
                        _control_read,
                        stdout_write,
                        stderr_write,
                        _authority,
                        _path,
                        _headers,
                        _maximum,
                        _deadline,
                    ):
                        try:
                            os.setsid()
                            if stderr_data:
                                os.write(stderr_write, stderr_data)
                            if stdout_data:
                                os.write(stdout_write, stdout_data)
                        finally:
                            os._exit(0)

                    experiment._git_worker_child = fixture_worker_child
                    try:
                        try:
                            experiment._github_worker_request(
                                "api.github.com",
                                f"/repos/uscient/experiment-fixture/git/commits/{COMMIT}",
                                expected_headers,
                                1_024,
                                __import__("time").monotonic() + 1.0,
                            )
                            return "ok"
                        except experiment.InfrastructureError as error:
                            return str(error)
                    finally:
                        experiment._git_worker_child = original_worker_child

                malformed_frame = worker_frame_outcome(b"not-a-worker-frame")
                oversized_frame = worker_frame_outcome(
                    experiment.GIT_WORKER_FRAME
                    + (experiment.GIT_WORKER_MAX_OUTPUT_BYTES + 1).to_bytes(8, "big")
                )
                trailing_frame = worker_frame_outcome(valid_worker_frame + b"trailing")
                stderr_frame = worker_frame_outcome(
                    valid_worker_frame, b"caller-private-diagnostic"
                )

                def acknowledged_stderr_outcome():
                    def fixture_worker_child(
                        control_read,
                        stdout_write,
                        stderr_write,
                        _authority,
                        _path,
                        _headers,
                        _maximum,
                        _deadline,
                    ):
                        try:
                            os.setsid()
                            os.write(stdout_write, valid_worker_frame)
                            acknowledgement = os.read(control_read, 1)
                            if acknowledgement == b"1":
                                os.write(
                                    stderr_write,
                                    b"diagnostic-emitted-after-acknowledgement",
                                )
                        finally:
                            os._exit(0)

                    experiment._git_worker_child = fixture_worker_child
                    try:
                        try:
                            experiment._github_worker_request(
                                "api.github.com",
                                f"/repos/uscient/experiment-fixture/git/commits/{COMMIT}",
                                expected_headers,
                                1_024,
                                __import__("time").monotonic() + 1.0,
                            )
                            return "ok"
                        except experiment.InfrastructureError as error:
                            return str(error)
                    finally:
                        experiment._git_worker_child = original_worker_child

                acknowledged_stderr_frame = acknowledged_stderr_outcome()
                worker_frames_rejected = (
                    "GIT-WORKER" in malformed_frame
                    and "GIT-OUTPUT" in oversized_frame
                    and "trailing" in trailing_frame
                    and (
                        "diagnostic" in stderr_frame
                        or "GIT-WORKER" in stderr_frame
                    )
                    and "diagnostic" in acknowledged_stderr_frame
                )
                results.append(
                    (
                        "GIT-OUTPUT-001",
                        output_outcome[0] == "infra"
                        and "GIT-OUTPUT" in output_outcome[1]
                        and worker_frames_rejected
                        and injected_lengths_closed,
                        "provider and worker output frames are strictly bounded",
                    )
                )

                padded_commit = dict(commit_body)
                padded_commit["ignored"] = "c" * 524_000
                padded_tree = dict(tree_body)
                padded_tree["ignored"] = "t" * 524_000
                aggregate_responses = dict(fixture_responses)
                aggregate_responses[next(iter(fixture_responses))] = response(padded_commit)
                aggregate_responses[f"/repos/uscient/experiment-fixture/git/trees/{TREE}"] = response(
                    padded_tree
                )
                aggregate_outcome = acquire(aggregate_responses)
                results.append(
                    (
                        "GIT-ACQUIRE-001",
                        aggregate_outcome[0] == "infra"
                        and "GIT-OUTPUT" in aggregate_outcome[1]
                        and all(len(item[2]) < 1_048_576 for item in aggregate_responses.values()),
                        "the response-byte bound is aggregate rather than per request",
                    )
                )

                original_worker_requester = getattr(experiment, "_github_api_request", None)
                worker_parent_pid = os.getpid()
                large_source = b"//" + (b"x" * (262_144 - 3)) + b"\n"
                large_blob = git_oid("blob", large_source)
                large_tree = git_oid(
                    "tree", b"100644 experiment.cue\0" + bytes.fromhex(large_blob)
                )
                large_responses = {
                    f"/repos/uscient/experiment-fixture/git/commits/{COMMIT}": response(
                        {"sha": COMMIT, "tree": {"sha": large_tree}}
                    ),
                    f"/repos/uscient/experiment-fixture/git/trees/{large_tree}": response(
                        {
                            "sha": large_tree,
                            "tree": [
                                {
                                    "mode": "100644",
                                    "path": "experiment.cue",
                                    "sha": large_blob,
                                    "size": len(large_source),
                                    "type": "blob",
                                }
                            ],
                            "truncated": False,
                        }
                    ),
                    f"/repos/uscient/experiment-fixture/git/blobs/{large_blob}": response(
                        {
                            "content": base64.b64encode(large_source).decode("ascii"),
                            "encoding": "base64",
                            "sha": large_blob,
                            "size": len(large_source),
                        }
                    ),
                }

                def worker_requester(authority, path, headers, maximum, deadline):
                    import resource

                    worker_pid = os.getpid()
                    if (
                        worker_pid == worker_parent_pid
                        or os.getpgrp() != worker_pid
                        or os.getsid(0) != worker_pid
                        or os.getcwd() != "/"
                        or resource.getrlimit(resource.RLIMIT_CORE) != (0, 0)
                        or resource.getrlimit(resource.RLIMIT_FSIZE) != (0, 0)
                        or resource.getrlimit(resource.RLIMIT_AS)
                        != (
                            experiment.GIT_WORKER_MEMORY_BYTES,
                            experiment.GIT_WORKER_MEMORY_BYTES,
                        )
                        or resource.getrlimit(resource.RLIMIT_NOFILE) != (16, 16)
                        or resource.getrlimit(resource.RLIMIT_CPU) != (4, 4)
                    ):
                        raise RuntimeError("provider worker session is not isolated")
                    return large_responses[path]

                experiment._github_api_request = worker_requester
                try:
                    try:
                        worker_snapshot = experiment.read_git_snapshot(URL, COMMIT)
                    except (experiment.InvalidManifest, experiment.InfrastructureError):
                        worker_snapshot = None
                finally:
                    if original_worker_requester is None:
                        delattr(experiment, "_github_api_request")
                    else:
                        experiment._github_api_request = original_worker_requester

                terminate_wait_options: list[int] = []
                terminate_observe_options: list[int] = []
                original_waitpid = experiment.os.waitpid
                original_waitid = experiment.os.waitid
                original_killpg = experiment.os.killpg
                original_group_alive = experiment._git_worker_group_alive
                original_monotonic = experiment.time.monotonic
                original_sleep = experiment.time.sleep
                terminate_clock = [0.0]

                def terminate_monotonic():
                    terminate_clock[0] += 1.0
                    return terminate_clock[0]

                def terminate_waitpid(_pid, options):
                    terminate_wait_options.append(options)
                    if options == 0:
                        raise OSError("blocking wait forbidden by fixture")
                    return 0, 0

                def terminate_waitid(_idtype, _identifier, options):
                    terminate_observe_options.append(options)
                    if not options & os.WNOHANG or not options & os.WNOWAIT:
                        raise OSError("consuming or blocking observation forbidden by fixture")
                    return None

                experiment.os.waitpid = terminate_waitpid
                experiment.os.waitid = terminate_waitid
                experiment.os.killpg = lambda _pid, _signal: None
                experiment._git_worker_group_alive = lambda _pid: True
                experiment.time.monotonic = terminate_monotonic
                experiment.time.sleep = lambda _duration: None
                try:
                    terminate_result = experiment._git_worker_terminate(
                        991_337, reaped=False, deadline=10.0
                    )
                finally:
                    experiment.os.waitpid = original_waitpid
                    experiment.os.waitid = original_waitid
                    experiment.os.killpg = original_killpg
                    experiment._git_worker_group_alive = original_group_alive
                    experiment.time.monotonic = original_monotonic
                    experiment.time.sleep = original_sleep
                nonblocking_terminate = (
                    terminate_result is False
                    and terminate_observe_options
                    and all(
                        option & os.WNOHANG and option & os.WNOWAIT
                        for option in terminate_observe_options
                    )
                    and all(
                        option == os.WNOHANG for option in terminate_wait_options
                    )
                )

                released_events: list[tuple[object, ...]] = []
                original_waitpid = experiment.os.waitpid
                original_waitid = experiment.os.waitid
                original_kill = experiment.os.kill
                original_killpg = experiment.os.killpg
                original_group_alive = experiment._git_worker_group_alive
                original_monotonic = experiment.time.monotonic
                original_sleep = experiment.time.sleep
                released_clock = [0.0]

                def released_monotonic():
                    released_clock[0] += 1.0
                    return released_clock[0]

                def released_waitpid(_pid, _options):
                    released_events.append(("waitpid", _pid, _options))
                    return 0, 0

                def released_waitid(_idtype, _identifier, _options):
                    released_events.append(
                        ("waitid", _idtype, _identifier, _options)
                    )
                    return None

                def released_kill(_pid, _signum):
                    released_events.append(("kill", _pid, _signum))

                def released_killpg(_pid, _signum):
                    released_events.append(("killpg", _pid, _signum))

                def released_group_alive(_pid):
                    released_events.append(("group-probe", _pid))
                    return True

                experiment.os.waitpid = released_waitpid
                experiment.os.waitid = released_waitid
                experiment.os.kill = released_kill
                experiment.os.killpg = released_killpg
                experiment._git_worker_group_alive = released_group_alive
                experiment.time.monotonic = released_monotonic
                experiment.time.sleep = lambda _duration: None
                try:
                    released_result = experiment._git_worker_terminate(
                        991_338, reaped=True, deadline=10.0
                    )
                finally:
                    experiment.os.waitpid = original_waitpid
                    experiment.os.waitid = original_waitid
                    experiment.os.kill = original_kill
                    experiment.os.killpg = original_killpg
                    experiment._git_worker_group_alive = original_group_alive
                    experiment.time.monotonic = original_monotonic
                    experiment.time.sleep = original_sleep
                released_identity_safe = (
                    released_result is False
                    and released_events == []
                )

                transition_pid = 991_339
                transition_events: list[tuple[object, ...]] = []
                transition_poll_count = [0]
                transition_reaped = [False]
                transition_signals: list[int] = []
                transition_clock = [0.0]

                class ObservableWaitidResult:
                    si_pid = transition_pid
                    si_uid = 0
                    si_signo = signal.SIGCHLD
                    si_status = 0
                    si_code = getattr(os, "CLD_EXITED", 1)

                def transition_monotonic():
                    transition_clock[0] += 0.05
                    return transition_clock[0]

                def transition_waitpid(pid, options):
                    if transition_reaped[0]:
                        transition_events.append(
                            ("waitpid-after-reap", pid, options)
                        )
                        raise ChildProcessError
                    transition_poll_count[0] += 1
                    if transition_poll_count[0] < 2:
                        transition_events.append(("waitpid-empty", pid, options))
                        return 0, 0
                    transition_reaped[0] = True
                    transition_events.append(("waitpid-reap", pid, options))
                    return pid, 0

                def transition_waitid(idtype, identifier, options):
                    if transition_reaped[0]:
                        transition_events.append(
                            (
                                "waitid-after-reap",
                                idtype,
                                identifier,
                                options,
                            )
                        )
                        raise ChildProcessError
                    transition_poll_count[0] += 1
                    if transition_poll_count[0] < 2:
                        transition_events.append(
                            ("waitid-empty", idtype, identifier, options)
                        )
                        return None
                    transition_events.append(
                        ("waitid-observable", idtype, identifier, options)
                    )
                    return ObservableWaitidResult()

                def transition_kill(pid, signum):
                    transition_events.append(("kill", pid, int(signum)))
                    if signum:
                        transition_signals.append(int(signum))

                def transition_killpg(pid, signum):
                    transition_events.append(("killpg", pid, int(signum)))
                    if signum:
                        transition_signals.append(int(signum))

                def transition_group_alive(pid):
                    transition_events.append(("group-probe", pid))
                    return signal.SIGKILL not in transition_signals

                original_waitpid = experiment.os.waitpid
                original_waitid = experiment.os.waitid
                original_kill = experiment.os.kill
                original_killpg = experiment.os.killpg
                original_group_alive = experiment._git_worker_group_alive
                original_monotonic = experiment.time.monotonic
                original_sleep = experiment.time.sleep
                experiment.os.waitpid = transition_waitpid
                experiment.os.waitid = transition_waitid
                experiment.os.kill = transition_kill
                experiment.os.killpg = transition_killpg
                experiment._git_worker_group_alive = transition_group_alive
                experiment.time.monotonic = transition_monotonic
                experiment.time.sleep = lambda _duration: None
                try:
                    transition_result = experiment._git_worker_terminate(
                        transition_pid, reaped=False, deadline=10.0
                    )
                finally:
                    experiment.os.waitpid = original_waitpid
                    experiment.os.waitid = original_waitid
                    experiment.os.kill = original_kill
                    experiment.os.killpg = original_killpg
                    experiment._git_worker_group_alive = original_group_alive
                    experiment.time.monotonic = original_monotonic
                    experiment.time.sleep = original_sleep

                transition_reap_positions = [
                    index
                    for index, event in enumerate(transition_events)
                    if event[0] == "waitpid-reap"
                ]
                transition_signal_positions = [
                    index
                    for index, event in enumerate(transition_events)
                    if event[0] in ("kill", "killpg") and event[2] != 0
                ]
                transition_waitid_events = [
                    event
                    for event in transition_events
                    if event[0] in ("waitid-empty", "waitid-observable")
                ]
                transition_first_reap = (
                    transition_reap_positions[0]
                    if transition_reap_positions
                    else -1
                )
                transition_identity_safe = (
                    transition_result is True
                    and transition_signals
                    == [int(signal.SIGTERM), int(signal.SIGKILL)]
                    and len(transition_reap_positions) == 1
                    and transition_first_reap == len(transition_events) - 1
                    and transition_signal_positions
                    and all(
                        index < transition_first_reap
                        for index in transition_signal_positions
                    )
                    and any(
                        event[0] == "waitid-observable"
                        for event in transition_waitid_events
                    )
                    and all(
                        event[1] == os.P_PID
                        and event[2] == transition_pid
                        and event[3] & os.WNOWAIT
                        for event in transition_waitid_events
                    )
                )

                mask_failure_marker = Path(raw_home) / "mask-clear-requester-reached"
                mask_parent_pid = os.getpid()
                original_pthread_sigmask = experiment.signal.pthread_sigmask
                original_worker_requester = experiment._github_api_request

                def fail_child_mask(how, signals):
                    if (
                        os.getpid() != mask_parent_pid
                        and how == signal.SIG_SETMASK
                        and not signals
                    ):
                        raise OSError("child mask clear failed")
                    return original_pthread_sigmask(how, signals)

                def mask_failure_requester(
                    _authority, path, _headers, _maximum, _deadline
                ):
                    mask_failure_marker.touch()
                    return fixture_responses[path]

                experiment.signal.pthread_sigmask = fail_child_mask
                experiment._github_api_request = mask_failure_requester
                try:
                    try:
                        experiment._github_worker_request(
                            "api.github.com",
                            f"/repos/uscient/experiment-fixture/git/commits/{COMMIT}",
                            expected_headers,
                            1_024,
                            __import__("time").monotonic() + 1.0,
                        )
                        mask_failure_outcome = "ok"
                    except experiment.InfrastructureError as error:
                        mask_failure_outcome = str(error)
                finally:
                    experiment.signal.pthread_sigmask = original_pthread_sigmask
                    experiment._github_api_request = original_worker_requester
                mask_clear_fail_closed = (
                    "GIT-WORKER" in mask_failure_outcome
                    and not mask_failure_marker.exists()
                )

                stop_listener = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                stop_listener.bind(("127.0.0.1", 0))
                stop_listener.settimeout(1.0)
                stop_address = stop_listener.getsockname()
                original_worker_child = experiment._git_worker_child

                def stopped_before_session(
                    _control_read,
                    _stdout_write,
                    _stderr_write,
                    _authority,
                    _path,
                    _headers,
                    _maximum,
                    _deadline,
                ):
                    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sender:
                        sender.sendto(f"{os.getpid()}\n".encode("ascii"), stop_address)
                    os.kill(os.getpid(), signal.SIGSTOP)
                    os._exit(125)

                experiment._git_worker_child = stopped_before_session
                try:
                    try:
                        experiment._github_worker_request(
                            "api.github.com",
                            f"/repos/uscient/experiment-fixture/git/commits/{COMMIT}",
                            expected_headers,
                            1_024,
                            __import__("time").monotonic() + 0.75,
                        )
                        stopped_outcome = "ok"
                    except experiment.InfrastructureError:
                        stopped_outcome = "infra"
                    except BaseException:
                        stopped_outcome = "other"
                finally:
                    experiment._git_worker_child = original_worker_child
                try:
                    stopped_record = stop_listener.recv(64).decode("ascii").strip()
                except (TimeoutError, UnicodeDecodeError):
                    stopped_record = ""
                finally:
                    stop_listener.close()
                stopped_pid = int(stopped_record) if stopped_record.isdigit() else None
                stopped_reaped_before_return = False
                stopped_reaped_by_harness = False
                stopped_alive = False
                if stopped_pid is not None:
                    try:
                        waited, _ = os.waitpid(stopped_pid, os.WNOHANG)
                    except ChildProcessError:
                        stopped_reaped_before_return = True
                        stopped_reaped_by_harness = True
                    else:
                        stopped_reaped_by_harness = waited == stopped_pid
                    try:
                        os.kill(stopped_pid, 0)
                    except ProcessLookupError:
                        stopped_alive = False
                    else:
                        stopped_alive = True
                    if not stopped_reaped_by_harness:
                        if stopped_alive:
                            try:
                                os.kill(stopped_pid, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                        stop_reap_deadline = __import__("time").monotonic() + 1.0
                        while __import__("time").monotonic() < stop_reap_deadline:
                            try:
                                waited, _ = os.waitpid(stopped_pid, os.WNOHANG)
                            except ChildProcessError:
                                stopped_reaped_by_harness = True
                                break
                            if waited == stopped_pid:
                                stopped_reaped_by_harness = True
                                break
                            __import__("time").sleep(0.01)
                if stopped_pid is None or not stopped_reaped_by_harness:
                    raise RuntimeError("stopped worker fixture cleanup is uncertain")
                stopped_child_cleaned = (
                    stopped_outcome == "infra"
                    and stopped_reaped_before_return
                    and not stopped_alive
                )
                results.append(
                    (
                        "GIT-PGROUP-001",
                        worker_snapshot is not None
                        and worker_snapshot.data == large_source
                        and nonblocking_terminate
                        and released_identity_safe
                        and transition_identity_safe
                        and mask_clear_fail_closed
                        and stopped_child_cleaned
                        and len(large_responses[
                            f"/repos/uscient/experiment-fixture/git/blobs/{large_blob}"
                        ][2]) > 65_536,
                        "the fixed worker enforces limits and cleans pre-session stops",
                    )
                )

                def cleanup_fault_probe(kind: str) -> bool:
                    probe_pid = os.fork()
                    if probe_pid == 0:
                        cleanup_probe_process = os.getpid()
                        managed = (
                            signal.SIGHUP,
                            signal.SIGINT,
                            signal.SIGQUIT,
                            signal.SIGTERM,
                        )
                        original_handlers = {
                            signum: signal.getsignal(signum) for signum in managed
                        }
                        original_mask = set(
                            signal.pthread_sigmask(signal.SIG_BLOCK, set())
                        )
                        original_requester = experiment._github_api_request
                        original_group_probe = experiment._git_worker_group_alive
                        original_close = experiment.os.close
                        original_selector = experiment.selectors.DefaultSelector
                        original_pthread_sigmask = (
                            experiment.signal.pthread_sigmask
                        )
                        missing_buffer_factory = object()
                        original_buffer_factory = experiment.__dict__.get(
                            "bytearray", missing_buffer_factory
                        )
                        close_calls = [0]
                        parent_setmask_failures = [0]

                        def cleanup_requester(
                            _authority, _path, _headers, _maximum, _deadline
                        ):
                            return (
                                200,
                                (
                                    ("content-length", "0"),
                                    (
                                        "content-type",
                                        "application/json; charset=utf-8",
                                    ),
                                ),
                                b"",
                            )

                        def failed_group_probe(_pid):
                            raise OSError("process-group probe failed")

                        def failed_cleanup_close(descriptor):
                            if os.getpid() == cleanup_probe_process:
                                close_calls[0] += 1
                                if close_calls[0] == 5:
                                    raise OSError("cleanup close failed")
                            return original_close(descriptor)

                        def failed_selector():
                            raise OSError("selector construction failed")

                        def failed_buffer_allocation(*_args, **_kwargs):
                            raise MemoryError("worker buffer allocation failed")

                        def fail_parent_spawn_mask_restore(how, signals):
                            if (
                                os.getpid() == cleanup_probe_process
                                and how == signal.SIG_SETMASK
                                and parent_setmask_failures[0] == 0
                            ):
                                parent_setmask_failures[0] += 1
                                raise OSError("parent spawn mask restore failed")
                            return original_pthread_sigmask(how, signals)

                        experiment._github_api_request = cleanup_requester
                        if kind == "group":
                            experiment._git_worker_group_alive = failed_group_probe
                        elif kind == "close":
                            experiment.os.close = failed_cleanup_close
                        elif kind == "selector":
                            experiment.selectors.DefaultSelector = failed_selector
                        elif kind == "allocation":
                            experiment.bytearray = failed_buffer_allocation
                        elif kind == "parent-mask-restore":
                            experiment.signal.pthread_sigmask = (
                                fail_parent_spawn_mask_restore
                            )
                        try:
                            try:
                                experiment._github_worker_request(
                                    "api.github.com",
                                    f"/repos/uscient/experiment-fixture/git/commits/{COMMIT}",
                                    expected_headers,
                                    1_024,
                                    __import__("time").monotonic() + 1.0,
                                )
                                outcome = "ok"
                            except experiment.InfrastructureError:
                                outcome = "infra"
                            except BaseException:
                                outcome = "other"
                            restored = (
                                all(
                                    signal.getsignal(signum)
                                    == original_handlers[signum]
                                    for signum in managed
                                )
                                and set(
                                    signal.pthread_sigmask(signal.SIG_BLOCK, set())
                                )
                                == original_mask
                            )
                        finally:
                            experiment._github_api_request = original_requester
                            experiment._git_worker_group_alive = original_group_probe
                            experiment.os.close = original_close
                            experiment.selectors.DefaultSelector = original_selector
                            experiment.signal.pthread_sigmask = (
                                original_pthread_sigmask
                            )
                            if original_buffer_factory is missing_buffer_factory:
                                experiment.__dict__.pop("bytearray", None)
                            else:
                                experiment.bytearray = original_buffer_factory
                        injected_fault_observed = (
                            kind != "parent-mask-restore"
                            or parent_setmask_failures[0] == 1
                        )
                        os._exit(
                            0
                            if outcome == "infra"
                            and restored
                            and injected_fault_observed
                            else 1
                        )

                    probe_status = None
                    probe_deadline = __import__("time").monotonic() + 2.0
                    while __import__("time").monotonic() < probe_deadline:
                        waited, status = os.waitpid(probe_pid, os.WNOHANG)
                        if waited == probe_pid:
                            probe_status = status
                            break
                        __import__("time").sleep(0.01)
                    if probe_status is None:
                        try:
                            os.kill(probe_pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        reap_deadline = __import__("time").monotonic() + 1.0
                        while __import__("time").monotonic() < reap_deadline:
                            waited, status = os.waitpid(probe_pid, os.WNOHANG)
                            if waited == probe_pid:
                                probe_status = status
                                break
                            __import__("time").sleep(0.01)
                    return (
                        probe_status is not None
                        and os.WIFEXITED(probe_status)
                        and os.WEXITSTATUS(probe_status) == 0
                    )

                group_probe_fail_closed = cleanup_fault_probe("group")
                close_failure_fail_closed = cleanup_fault_probe("close")
                selector_failure_fail_closed = cleanup_fault_probe("selector")
                allocation_failure_fail_closed = cleanup_fault_probe("allocation")
                parent_mask_restore_fail_closed = cleanup_fault_probe(
                    "parent-mask-restore"
                )

                residual_listener = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                residual_listener.bind(("127.0.0.1", 0))
                residual_listener.settimeout(1.0)
                residual_address = residual_listener.getsockname()
                residual_spawned = False
                residual_pid = None
                residual_calls = 0

                def residual_requester(authority, path, headers, maximum, deadline):
                    nonlocal residual_calls
                    residual_calls += 1
                    if residual_calls == 1:
                        child = os.fork()
                        if child == 0:
                            try:
                                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sender:
                                    sender.sendto(
                                        f"{os.getpid()}\n".encode("ascii"),
                                        residual_address,
                                    )
                                while True:
                                    signal.pause()
                            finally:
                                os._exit(0)
                    return fixture_responses[path]

                original_worker_requester = getattr(experiment, "_github_api_request", None)
                experiment._github_api_request = residual_requester
                try:
                    try:
                        experiment.read_git_snapshot(URL, COMMIT)
                        residual_outcome = "ok"
                    except experiment.InfrastructureError as error:
                        residual_outcome = str(error)
                finally:
                    if original_worker_requester is None:
                        delattr(experiment, "_github_api_request")
                    else:
                        experiment._github_api_request = original_worker_requester
                try:
                    residual_record = residual_listener.recv(64).decode("ascii").strip()
                except TimeoutError:
                    residual_record = ""
                finally:
                    residual_listener.close()
                if residual_record.isdigit():
                    residual_spawned = True
                    residual_pid = int(residual_record)
                    try:
                        os.kill(residual_pid, 0)
                    except ProcessLookupError:
                        residual_alive = False
                    else:
                        residual_alive = True
                        os.kill(residual_pid, signal.SIGKILL)
                else:
                    residual_alive = False

                def signal_cleanup_probe(*, uncertain: bool, expected_exit: int) -> bool:
                    signal_listener = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                    signal_listener.bind(("127.0.0.1", 0))
                    signal_listener.settimeout(1.0)
                    signal_address = signal_listener.getsockname()
                    signal_probe = os.fork()
                    if signal_probe == 0:
                        original_worker_terminate = experiment._git_worker_terminate

                        def uncertain_worker_terminate(pid, *, reaped, deadline):
                            original_worker_terminate(
                                pid,
                                reaped=reaped,
                                deadline=deadline,
                            )
                            return False

                        def hanging_requester(
                            _authority, _path, _headers, _maximum, _deadline
                        ):
                            with socket.socket(
                                socket.AF_INET, socket.SOCK_DGRAM
                            ) as sender:
                                sender.sendto(
                                    f"{os.getpid()}\n".encode("ascii"),
                                    signal_address,
                                )
                            signal.signal(signal.SIGTERM, signal.SIG_IGN)
                            while True:
                                signal.pause()

                        if uncertain:
                            experiment._git_worker_terminate = (
                                uncertain_worker_terminate
                            )
                        experiment._github_api_request = hanging_requester
                        try:
                            experiment.read_git_snapshot(URL, COMMIT)
                        except SystemExit as error:
                            code = error.code if isinstance(error.code, int) else 124
                            os._exit(code)
                        except experiment.InfrastructureError:
                            os._exit(125)
                        except BaseException:
                            os._exit(124)
                        os._exit(0)
                    try:
                        try:
                            worker_record = (
                                signal_listener.recv(64).decode("ascii").strip()
                            )
                        except TimeoutError:
                            worker_record = ""
                    finally:
                        signal_listener.close()
                    signal_worker_pid = (
                        int(worker_record) if worker_record.isdigit() else None
                    )
                    if signal_worker_pid is not None:
                        os.kill(signal_probe, signal.SIGTERM)
                    signal_status = None
                    signal_deadline = __import__("time").monotonic() + 2.0
                    while __import__("time").monotonic() < signal_deadline:
                        waited, status = os.waitpid(signal_probe, os.WNOHANG)
                        if waited == signal_probe:
                            signal_status = status
                            break
                        __import__("time").sleep(0.01)
                    if signal_status is None:
                        try:
                            os.kill(signal_probe, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        reap_deadline = __import__("time").monotonic() + 1.0
                        while __import__("time").monotonic() < reap_deadline:
                            waited, status = os.waitpid(signal_probe, os.WNOHANG)
                            if waited == signal_probe:
                                signal_status = status
                                break
                            __import__("time").sleep(0.01)
                    signal_worker_alive = False
                    if signal_worker_pid is not None:
                        worker_deadline = __import__("time").monotonic() + 1.0
                        while __import__("time").monotonic() < worker_deadline:
                            try:
                                os.killpg(signal_worker_pid, 0)
                            except ProcessLookupError:
                                break
                            __import__("time").sleep(0.01)
                        else:
                            signal_worker_alive = True
                            try:
                                os.killpg(signal_worker_pid, signal.SIGKILL)
                            except ProcessLookupError:
                                signal_worker_alive = False
                    return (
                        signal_worker_pid is not None
                        and signal_status is not None
                        and os.WIFEXITED(signal_status)
                        and os.WEXITSTATUS(signal_status) == expected_exit
                        and not signal_worker_alive
                    )

                clean_signal_preserved = signal_cleanup_probe(
                    uncertain=False,
                    expected_exit=128 + signal.SIGTERM,
                )
                cleanup_uncertainty_wins = signal_cleanup_probe(
                    uncertain=True,
                    expected_exit=125,
                )
                results.append(
                    (
                        "GIT-CLEANUP-001",
                        residual_spawned
                        and not residual_alive
                        and "residual" in residual_outcome.lower()
                        and clean_signal_preserved
                        and cleanup_uncertainty_wins
                        and group_probe_fail_closed
                        and close_failure_fail_closed
                        and selector_failure_fail_closed
                        and allocation_failure_fail_closed
                        and parent_mask_restore_fail_closed,
                        "cleanup uncertainty fails closed before caller signals are restored",
                    )
                )

                taxonomy_outcomes = []
                for status in (404, 422, 403, 500):
                    status_responses = dict(fixture_responses)
                    status_responses[next(iter(fixture_responses))] = (
                        status,
                        (
                            ("content-length", "2"),
                            ("content-type", "application/json; charset=utf-8"),
                        ),
                        b"{}",
                    )
                    taxonomy_outcomes.append((status, acquire(status_responses)[0]))
                malformed_responses = dict(fixture_responses)
                malformed_responses[next(iter(fixture_responses))] = (
                    200,
                    (
                        ("content-length", "1"),
                        ("content-type", "application/json; charset=utf-8"),
                    ),
                    b"{",
                )
                taxonomy_outcomes.append((200, acquire(malformed_responses)[0]))
                tree_missing = dict(fixture_responses)
                tree_missing[f"/repos/uscient/experiment-fixture/git/trees/{TREE}"] = (
                    404,
                    (
                        ("content-length", "2"),
                        ("content-type", "application/json; charset=utf-8"),
                    ),
                    b"{}",
                )
                taxonomy_outcomes.append(("tree-404", acquire(tree_missing)[0]))
                blob_missing = dict(fixture_responses)
                blob_missing[f"/repos/uscient/experiment-fixture/git/blobs/{BLOB}"] = (
                    422,
                    (
                        ("content-length", "2"),
                        ("content-type", "application/json; charset=utf-8"),
                    ),
                    b"{}",
                )
                taxonomy_outcomes.append(("blob-422", acquire(blob_missing)[0]))
                results.append(
                    (
                        "GIT-TAXONOMY-001",
                        taxonomy_outcomes
                        == [
                            (404, "reject"),
                            (422, "infra"),
                            (403, "infra"),
                            (500, "infra"),
                            (200, "infra"),
                            ("tree-404", "infra"),
                            ("blob-422", "infra"),
                        ]
                        and direct_status_framing_ok
                        and stable_not_found_route_closed,
                        "only a strictly framed commit 404 is stable absence",
                    )
                )

                fixture_directory = (
                    repo / "tests/experiment/fixtures/directories/minimal"
                )
                zip_fixture_module = load_module(
                    repo / "tests/experiment/zip-fixtures.py",
                    "git_intake_zip_fixture",
                )
                common_zip = Path(raw_home) / "common-source.zip"
                common_zip.write_bytes(zip_fixture_module.one("experiment.cue", source))
                directory_snapshot = experiment.read_directory_snapshot(
                    str(fixture_directory)
                )
                zip_snapshot = experiment.read_zip_snapshot(str(common_zip))
                git_snapshot = snapshot

                prior_tools = {
                    "AGENT_LAB_CUE_TOOL_DIR": os.environ.get(
                        "AGENT_LAB_CUE_TOOL_DIR"
                    ),
                    "AGENT_LAB_CEDAR_TOOL_DIR": os.environ.get(
                        "AGENT_LAB_CEDAR_TOOL_DIR"
                    ),
                }
                os.environ["AGENT_LAB_CUE_TOOL_DIR"] = str(
                    repo / ".cache/dev/tools/cue"
                )
                os.environ["AGENT_LAB_CEDAR_TOOL_DIR"] = str(
                    repo / ".cache/dev/tools/cedar"
                )

                identity_ready = git_snapshot is not None
                directory_manifest = None
                zip_manifest = None
                git_manifest = None
                directory_resolution = None
                zip_resolution = None
                git_resolution = None
                directory_decision = None
                zip_decision = None
                git_decision = None
                if identity_ready:
                    try:
                        directory_manifest = experiment.authored_manifest(
                            directory_snapshot
                        )
                        zip_manifest = experiment.authored_manifest(zip_snapshot)
                        git_manifest = experiment.authored_manifest(git_snapshot)
                        directory_resolution = experiment.cue_plan_with_evidence(
                            directory_manifest
                        )
                        zip_resolution = experiment.cue_plan_with_evidence(zip_manifest)
                        git_resolution = experiment.cue_plan_with_evidence(git_manifest)
                        directory_decision = experiment.authorize_plan(
                            directory_resolution.plan, directory_snapshot.digest
                        )[0]
                        zip_decision = experiment.authorize_plan(
                            zip_resolution.plan, zip_snapshot.digest
                        )[0]
                        git_decision = experiment.authorize_plan(
                            git_resolution.plan, git_snapshot.digest
                        )[0]
                    except (AttributeError, OSError, RuntimeError):
                        identity_ready = False

                preview_home = Path(raw_home) / "preview-home"
                preview_init = invoke(
                    agent_lab, ["--home", str(preview_home), "init"]
                )
                preview_before = tree_fingerprint(preview_home)
                source_before = sha256(source).hexdigest()
                original_agent_experiment_module = agent_lab.experiment_module
                original_read_git_snapshot = experiment.read_git_snapshot
                original_authored_manifest = experiment.authored_manifest
                original_cue_plan = experiment.cue_plan_with_evidence
                original_authorize_plan = experiment.authorize_plan
                original_write_checked = experiment.write_checked_source
                original_write_decision = experiment.write_decision
                active_operation = [""]
                operation_log: list[tuple[str, str]] = []
                snapshot_handoffs: list[bool] = []
                checked_values: list[object] = []
                decision_values: list[object] = []

                def injected_git_snapshot(url, commit):
                    operation_log.append((active_operation[0], "snapshot"))
                    if url != URL or commit != COMMIT or git_snapshot is None:
                        raise experiment.InfrastructureError(
                            "git source GIT-TEST fixture is unavailable"
                        )
                    return git_snapshot

                def logged_manifest(value):
                    operation_log.append((active_operation[0], "manifest"))
                    snapshot_handoffs.append(value is git_snapshot)
                    return original_authored_manifest(value)

                def logged_plan(value):
                    operation_log.append((active_operation[0], "plan"))
                    return original_cue_plan(value)

                def logged_authorize(value, digest):
                    operation_log.append((active_operation[0], "authorize"))
                    return original_authorize_plan(value, digest)

                experiment.read_git_snapshot = injected_git_snapshot
                experiment.authored_manifest = logged_manifest
                experiment.cue_plan_with_evidence = logged_plan
                experiment.authorize_plan = logged_authorize
                experiment.write_checked_source = checked_values.append
                experiment.write_decision = decision_values.append
                agent_lab.experiment_module = lambda: experiment
                try:
                    active_operation[0] = "check"
                    checked_result = invoke_with_exit(
                        agent_lab,
                        [
                            "--home",
                            str(preview_home),
                            "experiment",
                            "check",
                            "--git",
                            URL,
                            "--commit",
                            COMMIT,
                        ],
                    )
                    active_operation[0] = "authorize"
                    authorized_result = invoke_with_exit(
                        agent_lab,
                        [
                            "--home",
                            str(preview_home),
                            "experiment",
                            "authorize",
                            "install",
                            "--git",
                            URL,
                            "--commit",
                            COMMIT,
                        ],
                    )
                finally:
                    agent_lab.experiment_module = original_agent_experiment_module
                    experiment.read_git_snapshot = original_read_git_snapshot
                    experiment.authored_manifest = original_authored_manifest
                    experiment.cue_plan_with_evidence = original_cue_plan
                    experiment.authorize_plan = original_authorize_plan
                    experiment.write_checked_source = original_write_checked
                    experiment.write_decision = original_write_decision

                expected_checked = None
                if identity_ready and git_resolution is not None:
                    expected_checked = {
                        "digest": experiment.plan_digest(git_resolution.plan),
                        "plan": git_resolution.plan,
                        "source": {
                            "digest": git_snapshot.digest,
                            **git_snapshot.transport,
                        },
                    }
                    catalog = experiment.catalog_resolution_evidence(
                        git_resolution.bundled_catalog,
                        git_resolution.local_catalog,
                    )
                    if catalog is not None:
                        expected_checked["catalog"] = catalog
                results.append(
                    (
                        "GIT-CHECK-001",
                        checked_result == (0, "", "")
                        and checked_values == [expected_checked],
                        "public Git check uses the common checked-source path",
                    )
                )
                results.append(
                    (
                        "GIT-AUTH-001",
                        authorized_result == (0, "", "")
                        and identity_ready
                        and decision_values == [directory_decision]
                        and directory_decision == zip_decision == git_decision,
                        "Git authorization uses the common source-bound Cedar decision",
                    )
                )

                expected_log = [
                    ("check", "snapshot"),
                    ("check", "manifest"),
                    ("check", "plan"),
                    ("authorize", "snapshot"),
                    ("authorize", "manifest"),
                    ("authorize", "plan"),
                    ("authorize", "authorize"),
                ]
                adapter_downstream_calls: list[str] = []

                def forbidden_adapter_downstream(*_args, **_kwargs):
                    adapter_downstream_calls.append("reached")
                    raise AssertionError("Git adapter crossed into the common pipeline")

                experiment.authored_manifest = forbidden_adapter_downstream
                experiment.cue_plan_with_evidence = forbidden_adapter_downstream
                experiment.authorize_plan = forbidden_adapter_downstream
                try:
                    try:
                        adapter_snapshot = original_read_git_snapshot(
                            URL, COMMIT, requester=requester
                        )
                    except (experiment.InvalidManifest, experiment.InfrastructureError):
                        adapter_snapshot = None
                finally:
                    experiment.authored_manifest = original_authored_manifest
                    experiment.cue_plan_with_evidence = original_cue_plan
                    experiment.authorize_plan = original_authorize_plan
                results.append(
                    (
                        "GIT-ADAPTER-001",
                        identity_ready
                        and operation_log == expected_log
                        and snapshot_handoffs == [True, True]
                        and adapter_snapshot == git_snapshot
                        and adapter_downstream_calls == [],
                        "Git acquisition returns one snapshot to each unchanged common pipeline",
                    )
                )
                preview_after = tree_fingerprint(preview_home)
                results.append(
                    (
                        "GIT-NOEF-001",
                        preview_init[0] == 0
                        and checked_result[0] == 0
                        and authorized_result[0] == 0
                        and preview_before == preview_after
                        and source_before == sha256(source).hexdigest()
                        and operation_log == expected_log,
                        "Git previews leave initialized home and source bytes unchanged",
                    )
                )

                hostile_marker = b"caller-private-diagnostic"

                def hostile_read(url, commit):
                    def hostile_requester(
                        _authority, _path, _headers, _maximum, _deadline
                    ):
                        return (
                            500,
                            (
                                ("content-length", str(len(hostile_marker))),
                                (
                                    "content-type",
                                    "application/json; charset=utf-8",
                                ),
                            ),
                            hostile_marker,
                        )

                    return original_read_git_snapshot(
                        url, commit, requester=hostile_requester
                    )

                experiment.read_git_snapshot = hostile_read
                agent_lab.experiment_module = lambda: experiment
                try:
                    diagnostic_result = invoke_with_exit(
                        agent_lab,
                        [
                            "--home",
                            str(preview_home),
                            "experiment",
                            "check",
                            "--git",
                            URL,
                            "--commit",
                            COMMIT,
                        ],
                    )
                finally:
                    experiment.read_git_snapshot = original_read_git_snapshot
                    agent_lab.experiment_module = original_agent_experiment_module
                results.append(
                    (
                        "GIT-DIAG-001",
                        diagnostic_result[0] == 125
                        and diagnostic_result[1] == ""
                        and "GIT-STATUS" in diagnostic_result[2]
                        and hostile_marker.decode("ascii") not in diagnostic_result[2],
                        "hostile provider diagnostics never reach public output",
                    )
                )

                store = load_module(
                    repo / "scripts/experiment_store.py", "git_intake_store"
                )
                original_store_experiment_module = store._experiment_module
                bool_transport_fields_rejected = True
                for field in (
                    "limitBytes",
                    "requestCount",
                    "temporaryBytes",
                    "temporaryFiles",
                ):
                    hostile_transport = json.loads(
                        json.dumps(expected_transport, sort_keys=True)
                    )
                    hostile_transport["acquisition"][field] = False
                    if store._closed_git_transport(hostile_transport) is not None:
                        bool_transport_fields_rejected = False
                hostile_transport_urls_rejected = True
                for hostile_url in (
                    "https://github.com/a--b/repo.git",
                    "https://github.com/owner/..git",
                    "https://github.com/owner/...git",
                ):
                    hostile_transport = json.loads(
                        json.dumps(expected_transport, sort_keys=True)
                    )
                    hostile_transport["url"] = hostile_url
                    if store._closed_git_transport(hostile_transport) is not None:
                        hostile_transport_urls_rejected = False

                class ExperimentFacade:
                    def __init__(self, *, deny: bool = False):
                        self.deny = deny
                        self.acquisitions: list[tuple[str, str]] = []

                    def __getattr__(self, name):
                        return getattr(experiment, name)

                    def read_git_snapshot(self, url, commit):
                        self.acquisitions.append((url, commit))
                        if url != URL or commit != COMMIT or git_snapshot is None:
                            raise experiment.InfrastructureError(
                                "git source GIT-TEST fixture is unavailable"
                            )
                        return git_snapshot

                    def authorize_plan(self, plan, digest):
                        decision, status = original_authorize_plan(plan, digest)
                        if not self.deny:
                            return decision, status
                        denied = json.loads(
                            json.dumps(
                                decision,
                                ensure_ascii=True,
                                separators=(",", ":"),
                                sort_keys=True,
                            )
                        )
                        denied["verdict"] = "deny"
                        return denied, 1

                def initialized_home(name: str) -> tuple[Path, bool]:
                    home = Path(raw_home) / name
                    outcome = invoke(agent_lab, ["--home", str(home), "init"])
                    return home, outcome[0] == 0 and outcome[2] == ""

                def store_call(name: str, *arguments):
                    operation = getattr(store, name, None)
                    if not callable(operation):
                        return "missing", None
                    try:
                        return "ok", operation(*arguments)
                    except store.StoreReject as error:
                        return "reject", str(error)
                    except store.StoreInfrastructure as error:
                        return "infra", str(error)
                    except Exception as error:
                        return "error", type(error).__name__

                deny_home, deny_home_ready = initialized_home("git-deny-home")
                deny_before = tree_fingerprint(deny_home)
                deny_facade = ExperimentFacade(deny=True)
                store._experiment_module = lambda: deny_facade
                deny_outcome = store_call("install_git", deny_home, URL, COMMIT)
                deny_after = tree_fingerprint(deny_home)
                results.append(
                    (
                        "GIT-DENY-001",
                        deny_home_ready
                        and deny_outcome[0] == "reject"
                        and "authorization denied" in str(deny_outcome[1])
                        and deny_facade.acquisitions == [(URL, COMMIT)]
                        and deny_before == deny_after,
                        "denied Git install leaves the initialized home byte-identical",
                    )
                )

                install_home, install_home_ready = initialized_home("git-install-home")
                install_facade = ExperimentFacade()
                store._experiment_module = lambda: install_facade
                install_outcome = store_call(
                    "install_git", install_home, URL, COMMIT
                )
                installed_root = install_home / "experiments/first-experiment"
                installed_provenance = None
                installed_artifact = None
                if install_outcome[0] == "ok":
                    try:
                        installed_provenance = json.loads(
                            (installed_root / "records/provenance.json").read_text(
                                encoding="utf-8"
                            )
                        )
                        installed_artifact = (
                            installed_root / "artifact/experiment.cue"
                        ).read_bytes()
                    except (OSError, UnicodeError, ValueError):
                        installed_provenance = None
                        installed_artifact = None
                closed_git_provenance = (
                    isinstance(installed_provenance, dict)
                    and set(installed_provenance)
                    == {
                        "apiVersion",
                        "authorizationDigest",
                        "catalog",
                        "contractDigest",
                        "kind",
                        "planDigest",
                        "selectedEntries",
                        "source",
                        "transport",
                    }
                    and installed_provenance.get("source")
                    == {
                        "bytes": len(source),
                        "digest": SOURCE_DIGEST,
                        "entryCount": 1,
                        "fileCount": 1,
                        "format": "agent-lab.experiment-tree/v1",
                        "kind": "directory",
                    }
                    and installed_provenance.get("transport") == expected_transport
                )
                results.append(
                    (
                        "GIT-INSTALL-001",
                        install_home_ready
                        and install_outcome[0] == "ok"
                        and isinstance(install_outcome[1], dict)
                        and install_outcome[1].get("changed") is True
                        and install_facade.acquisitions == [(URL, COMMIT)]
                        and installed_artifact == source
                        and closed_git_provenance
                        and bool_transport_fields_rejected
                        and hostile_transport_urls_rejected,
                        "permitted Git install publishes the common artifact and closed provenance",
                    )
                )

                directory_home, directory_home_ready = initialized_home(
                    "identity-directory-home"
                )
                zip_home, zip_home_ready = initialized_home("identity-zip-home")
                store._experiment_module = lambda: ExperimentFacade()
                directory_install = store_call(
                    "install_directory", directory_home, fixture_directory
                )
                zip_install = store_call("install_zip", zip_home, common_zip)

                def installed_bytes(home: Path, relative: str) -> bytes | None:
                    try:
                        return (
                            home / "experiments/first-experiment" / relative
                        ).read_bytes()
                    except OSError:
                        return None

                directory_key = (
                    directory_install[1].get("installationKey")
                    if directory_install[0] == "ok"
                    and isinstance(directory_install[1], dict)
                    else None
                )
                zip_key = (
                    zip_install[1].get("installationKey")
                    if zip_install[0] == "ok" and isinstance(zip_install[1], dict)
                    else None
                )
                git_key = (
                    install_outcome[1].get("installationKey")
                    if install_outcome[0] == "ok"
                    and isinstance(install_outcome[1], dict)
                    else None
                )
                semantic_identity = (
                    identity_ready
                    and directory_snapshot.digest
                    == zip_snapshot.digest
                    == git_snapshot.digest
                    == SOURCE_DIGEST
                    and directory_manifest == zip_manifest == git_manifest
                    and directory_resolution.plan
                    == zip_resolution.plan
                    == git_resolution.plan
                    and directory_decision == zip_decision == git_decision
                )
                stored_identity = (
                    directory_home_ready
                    and zip_home_ready
                    and directory_install[0] == "ok"
                    and zip_install[0] == "ok"
                    and install_outcome[0] == "ok"
                    and directory_key == zip_key == git_key
                    and directory_key is not None
                    and installed_bytes(directory_home, "artifact/experiment.cue")
                    == installed_bytes(zip_home, "artifact/experiment.cue")
                    == installed_bytes(install_home, "artifact/experiment.cue")
                    == source
                    and installed_bytes(directory_home, "records/plan.json")
                    == installed_bytes(zip_home, "records/plan.json")
                    == installed_bytes(install_home, "records/plan.json")
                    and installed_bytes(directory_home, "records/decision.json")
                    == installed_bytes(zip_home, "records/decision.json")
                    == installed_bytes(install_home, "records/decision.json")
                )
                results.append(
                    (
                        "GIT-IDENTITY-001",
                        semantic_identity and stored_identity,
                        "directory, ZIP, and Git share manifest, plan, Cedar, key, and artifact identity",
                    )
                )

                retry_home, retry_home_ready = initialized_home("git-retry-home")
                retry_facade = ExperimentFacade()
                store._experiment_module = lambda: retry_facade
                retry_directory = store_call(
                    "install_directory", retry_home, fixture_directory
                )
                retry_receipt_path = (
                    retry_home
                    / "experiments/first-experiment/records/install.json"
                )
                retry_receipt_first = installed_bytes(retry_home, "records/install.json")
                retry_zip = store_call("install_zip", retry_home, common_zip)
                retry_receipt_second = installed_bytes(retry_home, "records/install.json")
                retry_git = store_call("install_git", retry_home, URL, COMMIT)
                retry_receipt_third = installed_bytes(retry_home, "records/install.json")
                results.append(
                    (
                        "GIT-RETRY-001",
                        retry_home_ready
                        and retry_directory[0] == "ok"
                        and retry_zip[0] == "ok"
                        and retry_git[0] == "ok"
                        and isinstance(retry_zip[1], dict)
                        and isinstance(retry_git[1], dict)
                        and retry_zip[1].get("changed") is False
                        and retry_git[1].get("changed") is False
                        and retry_facade.acquisitions == [(URL, COMMIT)]
                        and retry_receipt_path.is_file()
                        and retry_receipt_first
                        == retry_receipt_second
                        == retry_receipt_third,
                        "second and third equivalent transports preserve the first receipt",
                    )
                )
                store._experiment_module = original_store_experiment_module

                runtime_manifest = repo / "packaging/agent-lab-local.manifest"
                expected_runtime = (
                    repo / "tests/install/fixtures/expected-runtime-files.txt"
                )
                runtime_root = Path(raw_home) / "installed-runtime"
                runtime_ready = runtime_manifest.read_bytes() == expected_runtime.read_bytes()
                runtime_names = expected_runtime.read_text(encoding="utf-8").splitlines()
                for runtime_name in runtime_names:
                    source_path = repo / runtime_name
                    target_path = runtime_root / runtime_name
                    if not runtime_name or not source_path.is_file():
                        runtime_ready = False
                        continue
                    target_path.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source_path, target_path)
                unrelated = Path(raw_home) / "unrelated-cwd"
                runtime_home = Path(raw_home) / "runtime-home"
                runtime_tmp = Path(raw_home) / "runtime-tmp"
                unrelated.mkdir()
                runtime_tmp.mkdir()
                runtime_environment = {
                    "PATH": "/usr/bin:/bin",
                    "HOME": str(Path(raw_home) / "runtime-user-home"),
                    "TMPDIR": str(runtime_tmp),
                    "LC_ALL": "C",
                    "AGENT_LAB_CUE_TOOL_DIR": str(repo / ".cache/dev/tools/cue"),
                    "AGENT_LAB_CEDAR_TOOL_DIR": str(
                        repo / ".cache/dev/tools/cedar"
                    ),
                }
                runtime_command = [
                    str(runtime_root / "scripts/agent-lab"),
                    "--home",
                    str(runtime_home),
                    "experiment",
                    "check",
                    "--git",
                    "https://example.com/uscient/experiment-fixture.git",
                    "--commit",
                    COMMIT,
                ]
                try:
                    runtime_result = subprocess.run(
                        runtime_command,
                        cwd=unrelated,
                        env=runtime_environment,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        timeout=5,
                        check=False,
                    )
                except (OSError, subprocess.SubprocessError):
                    runtime_result = None
                results.append(
                    (
                        "GIT-RUNTIME-001",
                        runtime_ready
                        and runtime_result is not None
                        and runtime_result.returncode == 1
                        and runtime_result.stdout == b""
                        and b"GIT-URL" in runtime_result.stderr
                        and str(repo).encode("utf-8") not in runtime_result.stderr
                        and not any(runtime_root.rglob("__pycache__")),
                        "installed CLI reaches Git validation from a minimal unrelated runtime",
                    )
                )

                cycle4_results = {item[0]: item for item in results[-10:]}
                del results[-10:]
                results.extend(cycle4_results[item] for item in EXPECTED[-10:])

                for name, value in prior_tools.items():
                    if value is None:
                        os.environ.pop(name, None)
                    else:
                        os.environ[name] = value
                make_writable(Path(raw_home))
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
