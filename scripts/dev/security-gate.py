#!/usr/bin/env python3
"""Run versioned Agent Lab security suites with bounded deterministic evidence."""

from __future__ import annotations

from dataclasses import dataclass
from collections.abc import Callable
import errno
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import socket
import stat
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[2]
ENTRYPOINT = str(Path(__file__).with_suffix(""))
FAST_WORKERS = 4
DOCKER_WORKERS = 1
PREFLIGHT_TERMINATION_SECONDS = 1.0
FAST_TERMINATION_SECONDS = 3.0
DOCKER_TERMINATION_SECONDS = 15.0
MAX_SUITE_OUTPUT_BYTES = 8 * 1024 * 1024
MAX_TOTAL_OUTPUT_BYTES = 32 * 1024 * 1024
HANDLED_SIGNALS = frozenset(
    {signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT}
)


@dataclass(frozen=True)
class Suite:
    suite_id: str
    path: Path
    display_path: str
    marker: str


@dataclass
class RunningSuite:
    index: int
    process: subprocess.Popen[bytes]
    stream: socket.socket
    output: bytearray
    eof: bool = False


@dataclass
class EvidenceDirectory:
    path: Path
    descriptor: int
    device: int
    inode: int


def usage() -> None:
    print(f"Usage: {ENTRYPOINT} [fast|docker] [--manifest PATH]", file=sys.stderr)


def infra(message: str) -> None:
    print(f"INFRA {message}", file=sys.stderr, flush=True)


def interrupt_without_suites(signum: int, _frame: object) -> None:
    for handled_signal in HANDLED_SIGNALS:
        signal.signal(handled_signal, signal.SIG_IGN)
    name = signal.Signals(signum).name.removeprefix("SIG")
    infra(f"security-gate interrupted by {name}")
    raise SystemExit(128 + signum)


def parse_args(argv: list[str]) -> tuple[str, Path]:
    mode = "fast"
    manifest: str | None = None
    index = 0
    if argv and argv[0] in ("fast", "docker"):
        mode = argv[0]
        index = 1
    while index < len(argv):
        argument = argv[index]
        if argument == "--manifest":
            if index + 1 >= len(argv):
                usage()
                raise SystemExit(2)
            manifest = argv[index + 1]
            index += 2
        elif argument in ("-h", "--help"):
            usage()
            raise SystemExit(0)
        else:
            usage()
            raise SystemExit(2)
    manifest_path = (
        Path(manifest) if manifest is not None else ROOT / "tests/security" / f"{mode}.manifest"
    )
    if not manifest_path.is_absolute():
        manifest_path = ROOT / manifest_path
    return mode, manifest_path


def parse_manifest(path: Path) -> tuple[list[str], list[tuple[str, str]], list[Suite]]:
    try:
        manifest_bytes = path.read_bytes()
    except OSError as error:
        infra(f"required manifest cannot be read: {path}: {error}")
        raise SystemExit(125)
    if b"\0" in manifest_bytes:
        infra(f"security-gate manifest contains a NUL byte: {path}")
        raise SystemExit(125)
    try:
        lines = manifest_bytes.decode("utf-8").split("\n")
    except UnicodeError:
        infra(f"required manifest cannot be read: {path}: invalid UTF-8")
        raise SystemExit(125)

    tools: list[str] = []
    tool_any: list[tuple[str, str]] = []
    suites: list[Suite] = []
    seen_suite_ids: set[str] = set()
    errors: list[str] = []
    for line_no, line in enumerate(lines, 1):
        if not line or line.startswith("#"):
            continue
        fields = re.split(r"[ \t]+", line.strip(" \t"), maxsplit=3)
        if not fields:
            continue
        kind = fields[0]
        if kind == "tool":
            if len(fields) != 2:
                errors.append(f"malformed tool entry at {path}:{line_no}")
            else:
                tools.append(fields[1])
        elif kind == "tool-any":
            if len(fields) != 3:
                errors.append(f"malformed tool-any entry at {path}:{line_no}")
            else:
                tool_any.append((fields[1], fields[2]))
        elif kind == "suite":
            if len(fields) != 4:
                errors.append(f"malformed suite entry at {path}:{line_no}")
                continue
            suite_id, suite_name, marker = fields[1:]
            if re.fullmatch(r"[A-Za-z0-9._-]+", suite_id) is None:
                errors.append(f"invalid suite ID at {path}:{line_no}: {suite_id}")
                continue
            if suite_id in seen_suite_ids:
                errors.append(f"duplicate suite ID in {path}: {suite_id}")
                continue
            seen_suite_ids.add(suite_id)
            suite_path = Path(suite_name)
            if not suite_path.is_absolute():
                suite_path = ROOT / suite_path
            try:
                display_path = str(suite_path.relative_to(ROOT))
            except ValueError:
                display_path = str(suite_path)
            suites.append(Suite(suite_id, suite_path, display_path, marker))
        else:
            errors.append(f"unknown manifest entry at {path}:{line_no}: {kind}")

    if errors:
        for error in errors:
            infra(error)
        raise SystemExit(125)
    if not suites:
        infra(f"manifest defines no required suites: {path}")
        raise SystemExit(125)
    return tools, tool_any, suites


def terminate_preflight_group(
    process: subprocess.Popen[bytes],
    grace_seconds: float,
) -> None:
    if process_group_alive(process):
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + grace_seconds
    while time.monotonic() < deadline:
        process.poll()
        if not process_group_alive(process):
            break
        time.sleep(0.005)
    if process_group_alive(process):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        pass


def run_preflight_command(command: list[str]) -> int | None:
    process: subprocess.Popen[bytes] | None = None
    cancellation_observed = False

    def interrupted(signum: int, _frame: object) -> None:
        nonlocal cancellation_observed
        cancellation_observed = True
        for handled_signal in HANDLED_SIGNALS:
            signal.signal(handled_signal, signal.SIG_IGN)
        if process is not None:
            terminate_preflight_group(process, PREFLIGHT_TERMINATION_SECONDS)
        name = signal.Signals(signum).name.removeprefix("SIG")
        infra(f"security-gate interrupted by {name}")
        raise SystemExit(128 + signum)

    for handled_signal in HANDLED_SIGNALS:
        signal.signal(handled_signal, interrupted)

    try:
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, HANDLED_SIGNALS)

        def restore_child_signal_mask() -> None:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)

        try:
            try:
                process = subprocess.Popen(
                    command,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                    preexec_fn=restore_child_signal_mask,
                )
            except (OSError, subprocess.SubprocessError):
                return None
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        returncode = process.wait()
        if process_group_alive(process):
            terminate_preflight_group(process, PREFLIGHT_TERMINATION_SECONDS)
            return None
        return returncode
    finally:
        if not cancellation_observed:
            for handled_signal in HANDLED_SIGNALS:
                signal.signal(handled_signal, interrupt_without_suites)


def preflight(
    tools: list[str],
    tool_any: list[tuple[str, str]],
    suites: list[Suite],
    mode: str,
) -> None:
    failed = False
    for tool in tools:
        if shutil.which(tool) is None:
            infra(f"missing required tool: {tool}")
            failed = True
    for left, right in tool_any:
        if shutil.which(left) is None and shutil.which(right) is None:
            infra(f"missing required tool (need one of: {left} {right})")
            failed = True
    for suite in suites:
        if not suite.path.is_file():
            infra(f"required suite is missing: {suite.suite_id} ({suite.path})")
            failed = True
    if failed:
        raise SystemExit(125)

    if mode == "docker":
        docker_info = run_preflight_command(["docker", "info"])
        if docker_info is None or docker_info != 0:
            infra("Docker daemon is unavailable")
            raise SystemExit(125)
        compose_version = run_preflight_command(["docker", "compose", "version"])
        if compose_version is None or compose_version != 0:
            infra("Docker Compose v2 is unavailable")
            raise SystemExit(125)


def worker_count(mode: str) -> int:
    if mode == "docker":
        return DOCKER_WORKERS
    override = os.environ.get("AGENT_LAB_SECURITY_GATE_JOBS")
    if override is None:
        return FAST_WORKERS
    if not override.isascii() or not override.isdecimal():
        infra("AGENT_LAB_SECURITY_GATE_JOBS must be an integer from 1 through 4")
        raise SystemExit(125)
    jobs = int(override)
    if jobs < 1 or jobs > FAST_WORKERS:
        infra("AGENT_LAB_SECURITY_GATE_JOBS must be an integer from 1 through 4")
        raise SystemExit(125)
    return jobs


def protect_runner_process() -> None:
    if sys.platform != "linux":
        return
    try:
        import ctypes

        prctl = ctypes.CDLL(None, use_errno=True).prctl
        prctl.argtypes = [
            ctypes.c_int,
            ctypes.c_ulong,
            ctypes.c_ulong,
            ctypes.c_ulong,
            ctypes.c_ulong,
        ]
        prctl.restype = ctypes.c_int
        set_dumpable = prctl(4, 0, 0, 0, 0)  # PR_SET_DUMPABLE
        get_dumpable = prctl(3, 0, 0, 0, 0)  # PR_GET_DUMPABLE
    except (AttributeError, ImportError, OSError):
        set_dumpable = -1
        get_dumpable = -1
    if set_dumpable != 0 or get_dumpable != 0:
        infra("cannot protect security-gate runner process")
        raise SystemExit(125)


def process_group_alive(process: subprocess.Popen[bytes]) -> bool:
    try:
        os.killpg(process.pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def terminate_groups(
    running: list[RunningSuite],
    grace_seconds: float,
    monitor_output: Callable[[], None] | None = None,
) -> None:
    for item in running:
        if process_group_alive(item.process):
            try:
                os.killpg(item.process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
    deadline = time.monotonic() + grace_seconds
    while time.monotonic() < deadline:
        # Reap exited group leaders while waiting. Otherwise killpg(..., 0)
        # observes the leader zombie and every cooperative cleanup pays the
        # entire grace period even when no descendant remains.
        for item in running:
            item.process.poll()
        if monitor_output is not None:
            monitor_output()
        if not any(process_group_alive(item.process) for item in running):
            break
        time.sleep(0.005)
    for item in running:
        if process_group_alive(item.process):
            try:
                os.killpg(item.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        try:
            item.process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass
        try:
            item.stream.close()
        except OSError:
            pass


def remove_residual_group(
    item: RunningSuite,
    grace_seconds: float,
    monitor_output: Callable[[], None],
) -> bool:
    if not process_group_alive(item.process):
        return False
    try:
        os.killpg(item.process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return True
    deadline = time.monotonic() + grace_seconds
    while True:
        monitor_output()
        if not process_group_alive(item.process):
            return True
        if time.monotonic() >= deadline:
            break
        time.sleep(0.005)
    if process_group_alive(item.process):
        try:
            os.killpg(item.process.pid, signal.SIGKILL)
        except ProcessLookupError:
            return True
    kill_deadline = time.monotonic() + 1.0
    while process_group_alive(item.process) and time.monotonic() < kill_deadline:
        monitor_output()
        time.sleep(0.005)
    monitor_output()
    return True


def normalized_status(returncode: int) -> int:
    return 128 - returncode if returncode < 0 else returncode


def close_capture(
    selector: selectors.BaseSelector,
    item: RunningSuite,
) -> None:
    if item.eof:
        return
    try:
        selector.unregister(item.stream)
    except (KeyError, OSError, ValueError):
        pass
    try:
        item.stream.close()
    except OSError:
        pass
    item.eof = True


def enforce_captured_output_limits(
    suites: list[Suite],
    running: list[RunningSuite],
    retained_output_bytes: int,
    report_failure: bool = True,
) -> None:
    live_total = retained_output_bytes
    for item in running:
        suite = suites[item.index]
        output_size = len(item.output)
        if output_size > MAX_SUITE_OUTPUT_BYTES:
            terminate_groups(running, 0.0)
            if report_failure:
                infra(
                    f"suite {suite.suite_id} exceeded the output limit of "
                    f"{MAX_SUITE_OUTPUT_BYTES} bytes"
                )
            raise SystemExit(125)
        live_total += output_size
        if live_total > MAX_TOTAL_OUTPUT_BYTES:
            terminate_groups(running, 0.0)
            if report_failure:
                infra(
                    "security-gate suite output exceeded the aggregate limit of "
                    f"{MAX_TOTAL_OUTPUT_BYTES} bytes"
                )
            raise SystemExit(125)


def receive_available_output(
    selector: selectors.BaseSelector,
    suites: list[Suite],
    running: list[RunningSuite],
    item: RunningSuite,
    retained_output_bytes: int,
    report_failure: bool = True,
) -> None:
    if item.eof:
        return
    suite = suites[item.index]
    while True:
        try:
            chunk = item.stream.recv(65536)
        except BlockingIOError:
            return
        except OSError:
            terminate_groups(running, 0.0)
            if report_failure:
                infra(f"cannot read captured output for suite: {suite.suite_id}")
            raise SystemExit(125)
        if not chunk:
            close_capture(selector, item)
            return
        try:
            item.output.extend(chunk)
        except MemoryError:
            terminate_groups(running, 0.0)
            if report_failure:
                infra(f"cannot retain captured output for suite: {suite.suite_id}")
            raise SystemExit(125)
        enforce_captured_output_limits(
            suites,
            running,
            retained_output_bytes,
            report_failure,
        )


def drain_ready_outputs(
    selector: selectors.BaseSelector,
    suites: list[Suite],
    running: list[RunningSuite],
    retained_output_bytes: int,
    timeout: float,
    report_failure: bool = True,
) -> None:
    try:
        ready = selector.select(timeout)
    except OSError:
        terminate_groups(running, 0.0)
        if report_failure:
            infra("cannot monitor security-gate capture channels")
        raise SystemExit(125)
    for key, _events in ready:
        receive_available_output(
            selector,
            suites,
            running,
            key.data,
            retained_output_bytes,
            report_failure,
        )


def run_suites(
    suites: list[Suite],
    jobs: int,
    grace_seconds: float,
) -> tuple[list[int], list[bytes]]:
    statuses: list[int | None] = [None] * len(suites)
    outputs: list[bytes | None] = [None] * len(suites)
    running: list[RunningSuite] = []
    try:
        selector = selectors.DefaultSelector()
    except OSError:
        infra("cannot create security-gate capture monitor")
        raise SystemExit(125)
    next_index = 0
    total_output_bytes = 0
    suite_environment = dict(os.environ)
    suite_environment.pop("AGENT_LAB_SECURITY_GATE_EVIDENCE_DIR", None)
    suite_environment.pop("AGENT_LAB_SECURITY_GATE_JOBS", None)

    def interrupted(signum: int, _frame: object) -> None:
        for handled_signal in HANDLED_SIGNALS:
            signal.signal(handled_signal, signal.SIG_IGN)
        try:
            terminate_groups(
                running,
                grace_seconds,
                lambda: drain_ready_outputs(
                    selector,
                    suites,
                    running,
                    total_output_bytes,
                    0.0,
                    False,
                ),
            )
        except BaseException:
            # Cancellation is authoritative once observed. Capture failures can
            # shorten cleanup, but cannot replace the exact signal result.
            terminate_groups(running, 0.0)
        name = signal.Signals(signum).name.removeprefix("SIG")
        infra(f"security-gate interrupted by {name}")
        raise SystemExit(128 + signum)

    for handled_signal in HANDLED_SIGNALS:
        signal.signal(handled_signal, interrupted)

    try:
        while next_index < len(suites) or running:
            while next_index < len(suites) and len(running) < jobs:
                suite = suites[next_index]
                try:
                    parent_stream, child_stream = socket.socketpair()
                    parent_stream.setblocking(False)
                except OSError:
                    terminate_groups(running, 0.0)
                    infra(f"cannot create capture channel for suite: {suite.suite_id}")
                    raise SystemExit(125)
                previous_mask = signal.pthread_sigmask(
                    signal.SIG_BLOCK,
                    HANDLED_SIGNALS,
                )

                def restore_child_signal_mask() -> None:
                    # The parent blocks termination only across spawn-and-register
                    # so its handler cannot miss a live group. The suite must
                    # inherit the caller's original mask, not that critical section.
                    signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)

                try:
                    try:
                        process = subprocess.Popen(
                            ["bash", str(suite.path)],
                            stdout=child_stream,
                            stderr=subprocess.STDOUT,
                            start_new_session=True,
                            env=suite_environment,
                            preexec_fn=restore_child_signal_mask,
                        )
                    except (OSError, subprocess.SubprocessError) as error:
                        launch_error = error
                    else:
                        item = RunningSuite(
                            next_index,
                            process,
                            parent_stream,
                            bytearray(),
                        )
                        try:
                            selector.register(
                                parent_stream,
                                selectors.EVENT_READ,
                                item,
                            )
                        except (KeyError, OSError, ValueError) as error:
                            launch_error = error
                            terminate_groups([item], 0.0)
                        else:
                            launch_error = None
                            running.append(item)
                finally:
                    signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
                    child_stream.close()
                if launch_error is not None:
                    statuses[next_index] = 125
                    launch_output = (
                        f"INFRA could not start suite {suite.suite_id}: "
                        f"{launch_error}\n"
                    ).encode()
                    outputs[next_index] = launch_output
                    total_output_bytes += len(launch_output)
                    parent_stream.close()
                    if total_output_bytes > MAX_TOTAL_OUTPUT_BYTES:
                        terminate_groups(running, 0.0)
                        infra(
                            "security-gate suite output exceeded the aggregate limit of "
                            f"{MAX_TOTAL_OUTPUT_BYTES} bytes"
                        )
                        raise SystemExit(125)
                next_index += 1

            drain_ready_outputs(
                selector,
                suites,
                running,
                total_output_bytes,
                0.005,
            )
            completed = [item for item in running if item.process.poll() is not None]
            for item in completed:
                returncode = item.process.wait()
                had_residual = remove_residual_group(
                    item,
                    grace_seconds,
                    lambda: drain_ready_outputs(
                        selector,
                        suites,
                        running,
                        total_output_bytes,
                        0.0,
                    ),
                )
                receive_available_output(
                    selector,
                    suites,
                    running,
                    item,
                    total_output_bytes,
                )
                close_capture(selector, item)
                status = normalized_status(returncode)
                if had_residual and status == 0:
                    status = 125
                statuses[item.index] = status
                suite = suites[item.index]
                try:
                    captured = bytes(item.output)
                except MemoryError:
                    terminate_groups(running, 0.0)
                    infra(f"cannot retain captured output for suite: {suite.suite_id}")
                    raise SystemExit(125)
                previous_mask = signal.pthread_sigmask(
                    signal.SIG_BLOCK,
                    HANDLED_SIGNALS,
                )
                try:
                    outputs[item.index] = captured
                    item.output = bytearray()
                    running.remove(item)
                    total_output_bytes += len(captured)
                finally:
                    signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
    except BaseException:
        terminate_groups(running, 0.0)
        raise
    finally:
        for handled_signal in HANDLED_SIGNALS:
            signal.signal(handled_signal, interrupt_without_suites)
        selector.close()

    return (
        [125 if status is None else status for status in statuses],
        [b"" if output is None else output for output in outputs],
    )


def classify(suites: list[Suite], statuses: list[int], outputs: list[bytes]) -> int:
    forbidden = re.compile(
        r"^\s*(SKIP|NOT_IMPLEMENTED|WARN)([\s:]|$)",
        re.MULTILINE,
    )
    passed = 0
    failed = 0
    skipped = 0
    infrastructure = 0

    for suite, status, output in zip(suites, statuses, outputs, strict=True):
        print(f"\n== security suite: {suite.suite_id} ({suite.display_path}) ==")
        sys.stdout.flush()
        sys.stdout.buffer.write(output)
        sys.stdout.buffer.flush()
        decoded = output.decode("utf-8", errors="replace")

        if status == 0:
            if forbidden.search(decoded):
                print(
                    f"FAIL suite {suite.suite_id} emitted forbidden status output",
                    file=sys.stderr,
                    flush=True,
                )
                failed += 1
            elif suite.marker.encode() not in output:
                print(
                    f"FAIL suite {suite.suite_id} missing completion marker: {suite.marker}",
                    file=sys.stderr,
                    flush=True,
                )
                failed += 1
            else:
                passed += 1
        elif status == 77:
            print(f"SKIP suite {suite.suite_id} returned 77", file=sys.stderr, flush=True)
            skipped += 1
        elif status == 125:
            infra(f"suite {suite.suite_id} reported infrastructure failure")
            infrastructure += 1
        else:
            print(f"FAIL suite {suite.suite_id} exited {status}", file=sys.stderr, flush=True)
            failed += 1

    print(
        f"\nSECURITY GATE SUMMARY pass={passed} fail={failed} "
        f"skip={skipped} infra={infrastructure}"
    )
    if failed or skipped:
        return 1
    if infrastructure:
        return 125
    print("SECURITY GATE PASS")
    return 0


def evidence_directory() -> EvidenceDirectory | None:
    configured = os.environ.get("AGENT_LAB_SECURITY_GATE_EVIDENCE_DIR")
    if configured is None:
        return None
    evidence = Path(configured)
    try:
        evidence.mkdir(parents=True, exist_ok=True)
    except OSError as error:
        infra(f"cannot create security-gate evidence directory: {evidence}: {error}")
        raise SystemExit(125)

    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
    try:
        descriptor = os.open(evidence, directory_flags)
    except OSError:
        infra(f"cannot open security-gate evidence directory: {evidence}")
        raise SystemExit(125)

    try:
        directory_stat = os.fstat(descriptor)
        if not stat.S_ISDIR(directory_stat.st_mode):
            raise OSError("evidence descriptor is not a directory")
        if os.listdir(descriptor):
            infra(f"security-gate evidence directory is not empty: {evidence}")
            raise SystemExit(125)
    except OSError:
        os.close(descriptor)
        infra(f"cannot read security-gate evidence directory: {evidence}")
        raise SystemExit(125)
    except BaseException:
        os.close(descriptor)
        raise
    return EvidenceDirectory(
        evidence,
        descriptor,
        directory_stat.st_dev,
        directory_stat.st_ino,
    )


def evidence_path_matches(evidence: EvidenceDirectory) -> bool:
    try:
        current = os.stat(evidence.path, follow_symlinks=False)
    except OSError:
        return False
    return (
        stat.S_ISDIR(current.st_mode)
        and current.st_dev == evidence.device
        and current.st_ino == evidence.inode
    )


def read_evidence_file(
    evidence: EvidenceDirectory,
    name: str,
    expected_identity: tuple[int, int],
    expected_size: int,
) -> bytes:
    descriptor = -1
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
            dir_fd=evidence.descriptor,
        )
        file_stat = os.fstat(descriptor)
        if (
            not stat.S_ISREG(file_stat.st_mode)
            or file_stat.st_nlink != 1
            or (file_stat.st_dev, file_stat.st_ino) != expected_identity
            or file_stat.st_size != expected_size
        ):
            raise OSError("evidence identity changed")
        chunks: list[bytes] = []
        remaining = expected_size + 1
        while remaining:
            chunk = os.read(descriptor, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        payload = b"".join(chunks)
        final_stat = os.fstat(descriptor)
        if (
            len(payload) != expected_size
            or not stat.S_ISREG(final_stat.st_mode)
            or final_stat.st_nlink != 1
            or (final_stat.st_dev, final_stat.st_ino) != expected_identity
            or final_stat.st_size != expected_size
        ):
            raise OSError("evidence changed during readback")
        return payload
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def write_evidence_file(
    evidence: EvidenceDirectory,
    name: str,
    payload: bytes,
) -> tuple[int, int]:
    descriptor = -1
    target = evidence.path / name
    try:
        descriptor = os.open(
            name,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | os.O_CLOEXEC
            | os.O_NOFOLLOW,
            0o600,
            dir_fd=evidence.descriptor,
        )
        remaining = memoryview(payload)
        while remaining:
            written = os.write(descriptor, remaining)
            if written <= 0:
                raise OSError("short evidence write")
            remaining = remaining[written:]
        os.fsync(descriptor)
        file_stat = os.fstat(descriptor)
        if not stat.S_ISREG(file_stat.st_mode) or file_stat.st_nlink != 1:
            raise OSError("unsafe evidence file identity")
        identity = (file_stat.st_dev, file_stat.st_ino)
    except OSError:
        infra(f"cannot persist security-gate evidence: {target}")
        raise SystemExit(125)
    finally:
        if descriptor >= 0:
            os.close(descriptor)

    try:
        if read_evidence_file(evidence, name, identity, len(payload)) != payload:
            raise OSError("evidence readback mismatch")
    except OSError:
        infra(f"cannot verify security-gate evidence: {target}")
        raise SystemExit(125)
    return identity


def persist_evidence(
    evidence: EvidenceDirectory,
    suites: list[Suite],
    statuses: list[int],
    outputs: list[bytes],
) -> None:
    if not evidence_path_matches(evidence):
        infra(f"security-gate evidence directory identity changed: {evidence.path}")
        raise SystemExit(125)
    try:
        if os.listdir(evidence.descriptor):
            infra(f"security-gate evidence directory changed during suite execution: {evidence.path}")
            raise SystemExit(125)
    except OSError:
        infra(f"cannot read security-gate evidence directory: {evidence.path}")
        raise SystemExit(125)

    records: dict[str, tuple[bytes, tuple[int, int]]] = {}
    for index, (suite, status, output) in enumerate(
        zip(suites, statuses, outputs, strict=True)
    ):
        output_name = f"{index:03d}-{suite.suite_id}.out"
        status_name = f"{index:03d}-{suite.suite_id}.status"
        records[output_name] = (
            output,
            write_evidence_file(evidence, output_name, output),
        )
        status_bytes = f"{status}\n".encode("ascii")
        records[status_name] = (
            status_bytes,
            write_evidence_file(evidence, status_name, status_bytes),
        )

    try:
        try:
            os.fsync(evidence.descriptor)
        except OSError as error:
            if error.errno not in {errno.EINVAL, errno.ENOTSUP}:
                raise
        if set(os.listdir(evidence.descriptor)) != set(records):
            raise OSError("evidence directory contents changed")
        if not evidence_path_matches(evidence):
            raise OSError("evidence directory identity changed")
        for name, (payload, identity) in records.items():
            if read_evidence_file(evidence, name, identity, len(payload)) != payload:
                raise OSError("evidence readback mismatch")
    except OSError:
        infra(f"cannot verify completed security-gate evidence: {evidence.path}")
        raise SystemExit(125)


def close_evidence_directory(evidence: EvidenceDirectory) -> None:
    try:
        os.close(evidence.descriptor)
    except OSError:
        infra(f"cannot close security-gate evidence directory: {evidence.path}")
        raise SystemExit(125)


def main(argv: list[str]) -> int:
    if sys.version_info < (3, 11):
        infra("security-gate requires Python 3.11 or newer")
        return 125
    for handled_signal in HANDLED_SIGNALS:
        signal.signal(handled_signal, interrupt_without_suites)
    try:
        os.chdir(ROOT)
    except OSError as error:
        infra(f"cannot enter repository root: {ROOT}: {error}")
        return 125
    protect_runner_process()
    mode, manifest = parse_args(argv)
    if not manifest.is_file():
        infra(f"required manifest is missing: {manifest}")
        return 125
    tools, tool_any, suites = parse_manifest(manifest)
    preflight(tools, tool_any, suites, mode)
    jobs = worker_count(mode)
    grace_seconds = (
        DOCKER_TERMINATION_SECONDS if mode == "docker" else FAST_TERMINATION_SECONDS
    )
    evidence = evidence_directory()
    try:
        statuses, outputs = run_suites(suites, jobs, grace_seconds)
        if evidence is not None:
            persist_evidence(evidence, suites, statuses, outputs)
    except BaseException:
        if evidence is not None:
            close_evidence_directory(evidence)
        raise
    if evidence is not None:
        close_evidence_directory(evidence)
    return classify(suites, statuses, outputs)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
