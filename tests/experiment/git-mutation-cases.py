#!/usr/bin/env python3
"""Private-copy sensitivity mutations for pinned Git Experiment intake."""

from __future__ import annotations

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
import sys
import tempfile
import time
from types import SimpleNamespace
from typing import Callable


EXPECTED = (
    "M-GIT-AUTHORITY-001",
    "M-GIT-REF-001",
    "M-GIT-BOUND-001",
    "M-GIT-IDENTITY-001",
    "M-GIT-DOWNSTREAM-001",
)
URL = "https://github.com/uscient/experiment-fixture.git"
FORBIDDEN_AUTHORITY = "credential.invalid"
COMMIT = "1cffa1a28f96d2f2cb898b1bad70d281e359a5b5"
TREE = "64564b8e82ec9581c32cb4951ed802b544e2e0c0"
BLOB = "a1d8c8cd0f1865e66cb2463cbaa801c4b5a85656"
SOURCE_DIGEST = "sha256:463e8a7622e58281fd975d58d8a9ad44ed997dd08af32e237f1476021f7abb23"
MARKER_ENV = "AGENT_LAB_GIT_MUTATION_MARK"


class HarnessInfrastructure(Exception):
    """Private mutation evidence could not be established safely."""


def load_module(path: Path, label: str):
    spec = spec_from_file_location(label, path)
    if spec is None or spec.loader is None:
        raise HarnessInfrastructure(f"cannot load private runtime {path.name}")
    module = module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def git_oid(kind: str, payload: bytes) -> str:
    framed = kind.encode("ascii") + b" " + str(len(payload)).encode("ascii") + b"\0"
    return sha1(framed + payload).hexdigest()


def response(body: object) -> tuple[int, tuple[tuple[str, str], ...], bytes]:
    encoded = json.dumps(
        body,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("ascii")
    return (
        200,
        (
            ("content-length", str(len(encoded))),
            ("content-type", "application/json; charset=utf-8"),
        ),
        encoded,
    )


def fixture_responses(source: bytes) -> dict[str, tuple[int, tuple[tuple[str, str], ...], bytes]]:
    tree_payload = b"100644 experiment.cue\0" + bytes.fromhex(BLOB)
    commit_payload = (
        f"tree {TREE}\n"
        "author Fixture <fixture@example.invalid> 0 +0000\n"
        "committer Fixture <fixture@example.invalid> 0 +0000\n"
        "\n"
        "pinned fixture\n"
    ).encode("ascii")
    if (
        git_oid("blob", source) != BLOB
        or git_oid("tree", tree_payload) != TREE
        or git_oid("commit", commit_payload) != COMMIT
    ):
        raise HarnessInfrastructure("independent Git fixture identity drift")
    return {
        f"/repos/uscient/experiment-fixture/git/commits/{COMMIT}": response(
            {"sha": COMMIT, "tree": {"sha": TREE}}
        ),
        f"/repos/uscient/experiment-fixture/git/trees/{TREE}": response(
            {
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
        ),
        f"/repos/uscient/experiment-fixture/git/blobs/{BLOB}": response(
            {
                "content": base64.b64encode(source).decode("ascii"),
                "encoding": "base64",
                "sha": BLOB,
                "size": len(source),
            }
        ),
    }


def fixture_requester(
    responses: dict[str, tuple[int, tuple[tuple[str, str], ...], bytes]]
):
    def request(_authority, path, _headers, _maximum, _deadline):
        return responses[path]

    return request


def fingerprint(root: Path) -> dict[str, tuple[int, str]]:
    result: dict[str, tuple[int, str]] = {}
    for path in sorted(root.rglob("*")):
        if path.is_file():
            result[path.relative_to(root).as_posix()] = (
                stat.S_IMODE(path.stat().st_mode),
                sha256(path.read_bytes()).hexdigest(),
            )
        elif not path.is_dir():
            raise HarnessInfrastructure("private runtime contains an unsupported entry")
    return result


def replace_once(source: str, needle: str, replacement: str, assertion: str) -> str:
    occurrences = source.count(needle)
    if occurrences != 1:
        raise HarnessInfrastructure(
            f"{assertion} replacement applicability is {occurrences}, expected exactly 1"
        )
    mutated = source.replace(needle, replacement, 1)
    if mutated == source or mutated.count(replacement) != 1:
        raise HarnessInfrastructure(f"{assertion} replacement result is ambiguous")
    try:
        compile(mutated, f"<{assertion}>", "exec")
    except SyntaxError as error:
        raise HarnessInfrastructure(f"{assertion} private mutation does not compile") from error
    return mutated


def authority_probe(module, marker: Path | None) -> bool:
    import http.client
    import ssl

    connections: list[tuple[str, int, float, object]] = []
    requests: list[tuple[str, str, dict[str, str]]] = []
    body = b"{}"

    class FakeContext:
        def __init__(self, protocol):
            self.protocol = protocol
            self.check_hostname = False
            self.verify_mode = None
            self.minimum_version = None
            self.loaded = None

        def load_verify_locations(self, *, cadata):
            self.loaded = cadata

    class FakeSocket:
        def settimeout(self, _timeout):
            return None

    class FakeResponse:
        status = 200

        def __init__(self):
            self.stream = io.BytesIO(body)

        def getheaders(self):
            return [
                ("content-length", str(len(body))),
                ("content-type", "application/json; charset=utf-8"),
            ]

        def read(self, size=-1):
            return self.stream.read(size)

        def close(self):
            return None

    class FakeConnection:
        def __init__(self, authority, *, port, timeout, context):
            connections.append((authority, port, timeout, context))
            self.sock = FakeSocket()

        def request(self, method, path, *, headers):
            requests.append((method, path, dict(headers)))

        def getresponse(self):
            return FakeResponse()

        def close(self):
            return None

    original_context = ssl.SSLContext
    original_connection = http.client.HTTPSConnection
    original_maxline = http.client._MAXLINE
    original_maxheaders = http.client._MAXHEADERS
    original_ca_reader = module._git_system_ca_pem
    ssl.SSLContext = FakeContext
    http.client.HTTPSConnection = FakeConnection
    module._git_system_ca_pem = lambda: "fixture-ca"
    try:
        try:
            result = module._github_api_request(
                FORBIDDEN_AUTHORITY,
                f"/repos/uscient/experiment-fixture/git/commits/{COMMIT}",
                module.GIT_PROVIDER_HEADERS,
                1_024,
                time.monotonic() + 1.0,
            )
        except module.InfrastructureError as error:
            outcome = ("infra", str(error))
        else:
            outcome = ("ok", result)
    finally:
        module._git_system_ca_pem = original_ca_reader
        http.client.HTTPSConnection = original_connection
        http.client._MAXLINE = original_maxline
        http.client._MAXHEADERS = original_maxheaders
        ssl.SSLContext = original_context

    if marker is None:
        return (
            outcome[0] == "infra"
            and "GIT-AUTHORITY" in outcome[1]
            and connections == []
            and requests == []
        )
    if len(connections) != 1:
        return False
    authority, port, timeout, context = connections[0]
    return (
        outcome == (
            "ok",
            (
                200,
                (
                    ("content-length", str(len(body))),
                    ("content-type", "application/json; charset=utf-8"),
                ),
                body,
            ),
        )
        and authority == FORBIDDEN_AUTHORITY
        and port == 443
        and 0 < timeout <= 1.0
        and context.check_hostname is True
        and context.verify_mode == ssl.CERT_REQUIRED
        and context.minimum_version == ssl.TLSVersion.TLSv1_2
        and context.loaded == "fixture-ca"
        and requests
        == [
            (
                "GET",
                f"/repos/uscient/experiment-fixture/git/commits/{COMMIT}",
                dict(module.GIT_PROVIDER_HEADERS),
            )
        ]
    )


def ref_probe(module, marker: Path | None, responses, source: bytes) -> bool:
    if marker is None:
        calls: list[str] = []

        def unused(_authority, path, _headers, _maximum, _deadline):
            calls.append(path)
            raise AssertionError("mutable ref reached acquisition")

        try:
            module.read_git_snapshot(URL, "main", requester=unused)
        except module.InvalidManifest as error:
            return "GIT-OID" in str(error) and calls == []
        return False
    try:
        snapshot = module.read_git_snapshot(
            URL,
            "main",
            requester=fixture_requester(responses),
        )
    except (module.InvalidManifest, module.InfrastructureError):
        return False
    return (
        snapshot.data == source
        and snapshot.digest == SOURCE_DIGEST
        and snapshot.transport.get("requestedCommit") == COMMIT
    )


def group_exists(pgid: int) -> bool:
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def wait_group_gone(pgid: int, timeout: float = 2.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not group_exists(pgid):
            return True
        time.sleep(0.01)
    return not group_exists(pgid)


def bound_probe(module, marker: Path | None, responses) -> bool:
    listener = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    listener.bind(("127.0.0.1", 0))
    listener.settimeout(2.0)
    address = listener.getsockname()

    def residual_requester(_authority, path, _headers, _maximum, _deadline):
        child = os.fork()
        if child == 0:
            try:
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                signal.alarm(5)
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sender:
                    sender.sendto(
                        f"{os.getpid()}:{os.getpgrp()}".encode("ascii"),
                        address,
                    )
                while True:
                    signal.pause()
            finally:
                os._exit(0)
        return responses[path]

    module._github_api_request = residual_requester
    try:
        try:
            module.read_git_snapshot(URL, COMMIT)
        except module.InfrastructureError as error:
            outcome = str(error)
        else:
            outcome = "ok"
        try:
            record = listener.recv(128).decode("ascii")
        except (TimeoutError, UnicodeDecodeError) as error:
            raise HarnessInfrastructure("residual worker identity was not reported") from error
    finally:
        listener.close()
    try:
        raw_pid, raw_pgid = record.split(":", 1)
        pid = int(raw_pid)
        pgid = int(raw_pgid)
    except (TypeError, ValueError) as error:
        raise HarnessInfrastructure("residual worker identity is malformed") from error
    if pid <= 1 or pgid <= 1 or pgid == os.getpgrp():
        raise HarnessInfrastructure("residual worker group is not private")

    alive = group_exists(pgid)
    cleanup_ok = True
    if alive:
        try:
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        cleanup_ok = wait_group_gone(pgid)
    if not cleanup_ok:
        raise HarnessInfrastructure("residual worker cleanup is uncertain")
    if marker is None:
        return "residual process group" in outcome.lower() and not alive
    return "residual process group" in outcome.lower() and alive


def identity_probe(module, marker: Path | None, responses, source: bytes, source_dir: Path) -> bool:
    try:
        directory = module.read_directory_snapshot(str(source_dir))
        git = module.read_git_snapshot(
            URL,
            COMMIT,
            requester=fixture_requester(responses),
        )
    except (module.InvalidManifest, module.InfrastructureError):
        return False
    if directory.data != source or git.data != source:
        return False
    if marker is None:
        return directory.digest == git.digest == SOURCE_DIGEST
    expected_object_digest = "sha256:" + sha256(BLOB.encode("ascii")).hexdigest()
    return git.digest == expected_object_digest and directory.digest != git.digest


def downstream_probe(module, marker: Path | None) -> bool:
    events: list[str] = []
    snapshot = module.SourceSnapshot(
        data=b"fixture",
        digest="sha256:" + "1" * 64,
        transport={"kind": "git"},
    )
    resolution = SimpleNamespace(plan={}, bundled_catalog=None, local_catalog=None)

    def authorize(_plan, _digest):
        events.append("authorize")
        return {"verdict": "deny"}, 1

    module.read_git_snapshot = lambda _url, _commit: snapshot
    module.authored_manifest = lambda _snapshot: {}
    module.cue_plan_with_evidence = lambda _manifest: resolution
    module.authorize_plan = authorize
    module.write_decision = lambda _decision: events.append("decision")
    module.write_checked_source = lambda _checked: events.append("checked")
    result = module.main(["experiment.py", "authorize-git", URL, COMMIT])
    if marker is None:
        return result == 1 and events == ["authorize", "decision"]
    return result == 0 and events == ["checked"]


Probe = Callable[[object, Path | None], bool]


def execute_mutation(
    repo: Path,
    production: Path,
    original: str,
    production_digest: str,
    root: Path,
    assertion: str,
    needle: str,
    replacement: str,
    probe: Probe,
) -> bool:
    runtime = root / "runtime"
    runtime.mkdir(parents=True)
    private_source = runtime / "experiment.py"
    shutil.copy2(production, private_source)
    shutil.copy2(repo / "scripts/image_reference.py", runtime / "image_reference.py")
    pristine_topology = fingerprint(runtime)
    pristine = load_module(private_source, assertion.lower().replace("-", "_") + "_pristine")
    if not probe(pristine, None):
        raise HarnessInfrastructure(f"{assertion} pristine private probe is not GREEN")
    if fingerprint(runtime) != pristine_topology:
        raise HarnessInfrastructure(f"{assertion} pristine probe changed private runtime")

    mutated = replace_once(original, needle, replacement, assertion)
    private_source.write_text(mutated, encoding="utf-8")
    mutated_topology = fingerprint(runtime)
    changed = [
        path
        for path in sorted(set(pristine_topology) | set(mutated_topology))
        if pristine_topology.get(path) != mutated_topology.get(path)
    ]
    if changed != ["experiment.py"]:
        raise HarnessInfrastructure(f"{assertion} changed unexpected private runtime paths")

    marker = root / "mutation-reached"
    marker.unlink(missing_ok=True)
    prior_marker = os.environ.get(MARKER_ENV)
    os.environ[MARKER_ENV] = str(marker)
    try:
        mutant = load_module(private_source, assertion.lower().replace("-", "_") + "_mutant")
        detected = probe(mutant, marker)
    finally:
        if prior_marker is None:
            os.environ.pop(MARKER_ENV, None)
        else:
            os.environ[MARKER_ENV] = prior_marker
    if not marker.is_file():
        raise HarnessInfrastructure(f"{assertion} did not prove its mutated path was reached")
    if fingerprint(runtime) != mutated_topology:
        raise HarnessInfrastructure(f"{assertion} mutant probe changed private runtime")
    if sha256(production.read_bytes()).hexdigest() != production_digest:
        raise HarnessInfrastructure(f"{assertion} changed the production implementation")
    return detected


def make_writable(root: Path) -> None:
    for path in root.rglob("*"):
        try:
            path.chmod(path.stat().st_mode | stat.S_IWUSR | stat.S_IXUSR)
        except OSError:
            pass


def main() -> int:
    sys.dont_write_bytecode = True
    repo = Path(__file__).resolve().parents[2]
    production = repo / "scripts/experiment.py"
    original = production.read_text(encoding="utf-8")
    production_digest = sha256(production.read_bytes()).hexdigest()
    source_dir = repo / "tests/experiment/fixtures/directories/minimal"
    source = (source_dir / "experiment.cue").read_bytes()
    responses = fixture_responses(source)
    work = Path(tempfile.mkdtemp(prefix="agent-lab-git-mutations-"))
    failures = 0
    infrastructure = 0
    results: list[tuple[str, bool, str]] = []
    try:
        cases: tuple[tuple[str, str, str, Probe, str], ...] = (
            (
                "M-GIT-AUTHORITY-001",
                "        authority != GIT_PROVIDER_AUTHORITY\n",
                (
                    "        (\n"
                    "            authority != GIT_PROVIDER_AUTHORITY\n"
                    "            and (\n"
                    f"                Path(os.environ[\"{MARKER_ENV}\"]).touch()\n"
                    "                or False\n"
                    "            )\n"
                    "        )\n"
                ),
                authority_probe,
                "forbidden provider authority reaches the HTTPS connection canary",
            ),
            (
                "M-GIT-REF-001",
                "    if not isinstance(commit, str) or GIT_SHA1.fullmatch(commit) is None:\n",
                (
                    "    if commit == \"main\":\n"
                    f"        Path(os.environ[\"{MARKER_ENV}\"]).touch()\n"
                    f"        commit = \"{COMMIT}\"\n"
                    "    if not isinstance(commit, str) or GIT_SHA1.fullmatch(commit) is None:\n"
                ),
                lambda module, marker: ref_probe(module, marker, responses, source),
                "mutable ref acceptance reaches the pinned-object adapter",
            ),
            (
                "M-GIT-BOUND-001",
                (
                    "                terminated = _git_worker_terminate(\n"
                    "                    pid,\n"
                    "                    reaped=reaped,\n"
                    "                    deadline=cleanup_deadline,\n"
                    "                )\n"
                ),
                (
                    f"                Path(os.environ[\"{MARKER_ENV}\"]).touch()\n"
                    "                mutant_observed = _git_worker_observe(pid)\n"
                    "                mutant_waited, mutant_status = os.waitpid(\n"
                    "                    pid, os.WNOHANG\n"
                    "                )\n"
                    "                terminated = (\n"
                    "                    mutant_observed is not None\n"
                    "                    and mutant_waited == pid\n"
                    "                    and _git_worker_status_matches(\n"
                    "                        mutant_observed, mutant_status\n"
                    "                    )\n"
                    "                )\n"
                ),
                lambda module, marker: bound_probe(module, marker, responses),
                "removed process-group cleanup leaves a live provider descendant",
            ),
            (
                "M-GIT-IDENTITY-001",
                (
                    "        digest=source_digest(data),\n"
                    "        transport={\n"
                    "            \"acquisition\": {\n"
                ),
                (
                    "        digest=(\n"
                    f"            Path(os.environ[\"{MARKER_ENV}\"]).touch()\n"
                    "            or \"sha256:\"\n"
                    "            + hashlib.sha256(blob_id.encode(\"ascii\")).hexdigest()\n"
                    "        ),\n"
                    "        transport={\n"
                    "            \"acquisition\": {\n"
                ),
                lambda module, marker: identity_probe(
                    module,
                    marker,
                    responses,
                    source,
                    source_dir,
                ),
                "object-ID-derived identity breaks the cross-transport oracle",
            ),
            (
                "M-GIT-DOWNSTREAM-001",
                "            if directory_checking or zip_checking or git_checking:\n",
                (
                    "            if (\n"
                    "                directory_checking\n"
                    "                or zip_checking\n"
                    "                or git_checking\n"
                    "                or (\n"
                    "                    git_authorizing\n"
                    "                    and (\n"
                    f"                        Path(os.environ[\"{MARKER_ENV}\"]).touch()\n"
                    "                        or True\n"
                    "                    )\n"
                    "                )\n"
                    "            ):\n"
                ),
                downstream_probe,
                "Git authorization routed around the common decision path",
            ),
        )
        for index, (assertion, needle, replacement, probe, message) in enumerate(cases):
            case_root = work / f"case-{index}"
            try:
                detected = execute_mutation(
                    repo,
                    production,
                    original,
                    production_digest,
                    case_root,
                    assertion,
                    needle,
                    replacement,
                    probe,
                )
            except HarnessInfrastructure:
                raise
            except Exception as error:
                raise HarnessInfrastructure(
                    f"{assertion} probe raised {type(error).__name__}"
                ) from error
            results.append((assertion, detected, message))
    except (HarnessInfrastructure, OSError) as error:
        print(f"INFRA Git mutation harness {error}", file=sys.stderr)
        infrastructure = 1
    finally:
        try:
            make_writable(work)
            shutil.rmtree(work)
        except OSError:
            infrastructure = 1

    if sha256(production.read_bytes()).hexdigest() != production_digest:
        infrastructure = 1
    observed = tuple(assertion for assertion, _, _ in results)
    if observed != EXPECTED:
        infrastructure = 1
    for assertion, passed, message in results:
        if passed:
            print(f"PASS {assertion} {message}")
        else:
            print(f"FAIL {assertion} {message}")
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
