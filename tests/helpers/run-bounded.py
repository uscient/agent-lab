#!/usr/bin/env python3
"""Run one test command with a bounded, fully reaped process group."""

from __future__ import annotations

import argparse
from contextlib import ExitStack
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


MAX_TIMEOUT_SECONDS = 5.0
TERMINATION_GRACE_SECONDS = 1.0
HANDLED_SIGNALS = (signal.SIGINT, signal.SIGHUP, signal.SIGTERM)
ACTIVE_PROCESS: subprocess.Popen[bytes] | None = None
STATUS_PATH: Path | None = None


def process_group_exists(group: int) -> bool:
    try:
        os.killpg(group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def terminate_process_group(
    process: subprocess.Popen[bytes],
    grace_seconds: float = TERMINATION_GRACE_SECONDS,
) -> bool:
    group = process.pid
    if process_group_exists(group):
        try:
            os.killpg(group, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + grace_seconds
    while process_group_exists(group) and time.monotonic() < deadline:
        process.poll()
        time.sleep(0.01)
    if process_group_exists(group):
        try:
            os.killpg(group, signal.SIGKILL)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=grace_seconds)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(group, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=grace_seconds)
        except subprocess.TimeoutExpired:
            return False
    deadline = time.monotonic() + grace_seconds
    while process_group_exists(group) and time.monotonic() < deadline:
        time.sleep(0.01)
    return not process_group_exists(group)


def normalized_returncode(returncode: int) -> int:
    if returncode < 0:
        return 128 + abs(returncode)
    return returncode


def execute_bounded(
    command: list[str],
    stdout_path: Path,
    stderr_path: Path,
    timeout_seconds: float,
    grace_seconds: float = TERMINATION_GRACE_SECONDS,
) -> tuple[str, int]:
    global ACTIVE_PROCESS

    process: subprocess.Popen[bytes] | None = None
    try:
        with ExitStack() as stack:
            stdout = stack.enter_context(stdout_path.open("wb"))
            stderr = stack.enter_context(stderr_path.open("wb"))
            previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, HANDLED_SIGNALS)
            try:
                process = subprocess.Popen(
                    command,
                    stdin=subprocess.DEVNULL,
                    stdout=stdout,
                    stderr=stderr,
                    start_new_session=True,
                )
                ACTIVE_PROCESS = process
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
            try:
                returncode = process.wait(timeout=timeout_seconds)
            except subprocess.TimeoutExpired:
                if not terminate_process_group(process, grace_seconds):
                    return "infra", 125
                return "infra", 125
            if process_group_exists(process.pid):
                if not terminate_process_group(process, grace_seconds):
                    return "infra", 125
                return "infra", 125
            return "child", normalized_returncode(returncode)
    except (OSError, subprocess.SubprocessError):
        if process is not None and process_group_exists(process.pid):
            terminate_process_group(process, grace_seconds)
        return "infra", 125
    finally:
        ACTIVE_PROCESS = None


def write_status(path: Path, kind: str, returncode: int) -> bool:
    try:
        path.write_text(f"{kind}:{returncode}\n", encoding="ascii")
    except OSError:
        return False
    return True


def interrupted(signum: int, _frame: object) -> None:
    process = ACTIVE_PROCESS
    if process is not None:
        terminate_process_group(process)
    status = STATUS_PATH
    if status is not None:
        write_status(status, "infra", 125)
    os._exit(128 + signum)


def descendant_fixture(pid_path: Path, *, hang_parent: bool) -> str:
    parent_action = "time.sleep(30)" if hang_parent else "os._exit(0)"
    return f"""
import os
from pathlib import Path
import signal
import time

pid_path = Path({str(pid_path)!r})
child = os.fork()
if child == 0:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    pid_path.write_text(str(os.getpid()), encoding="ascii")
    os.close(0)
    os.close(1)
    os.close(2)
    time.sleep(30)
deadline = time.monotonic() + 1.0
while not pid_path.exists() and time.monotonic() < deadline:
    time.sleep(0.01)
{parent_action}
"""


def run_self_test() -> int:
    try:
        with tempfile.TemporaryDirectory(prefix="agent-lab-bounded-command-") as directory:
            root = Path(directory)
            for name, hang_parent, timeout_seconds in (
                ("normal-residual", False, 1.0),
                ("timeout-residual", True, 0.2),
            ):
                pid_path = root / f"{name}.pid"
                kind, returncode = execute_bounded(
                    [
                        sys.executable,
                        "-I",
                        "-B",
                        "-c",
                        descendant_fixture(pid_path, hang_parent=hang_parent),
                    ],
                    root / f"{name}.out",
                    root / f"{name}.err",
                    timeout_seconds,
                    0.1,
                )
                if kind != "infra" or returncode != 125 or not pid_path.is_file():
                    return 125
                try:
                    descendant = int(pid_path.read_text(encoding="ascii"))
                    os.kill(descendant, 0)
                except ProcessLookupError:
                    continue
                except (OSError, ValueError):
                    return 125
                try:
                    os.kill(descendant, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                return 125
    except OSError:
        return 125
    return 0


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--timeout", type=float, default=MAX_TIMEOUT_SECONDS)
    parser.add_argument("--status")
    parser.add_argument("--stdout")
    parser.add_argument("--stderr")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    global STATUS_PATH

    arguments = parse_arguments(argv)
    if arguments.self_test:
        return run_self_test()
    command = list(arguments.command)
    if command and command[0] == "--":
        command.pop(0)
    if (
        not command
        or arguments.status is None
        or arguments.stdout is None
        or arguments.stderr is None
        or not 0 < arguments.timeout <= MAX_TIMEOUT_SECONDS
    ):
        return 125
    STATUS_PATH = Path(arguments.status)
    kind, returncode = execute_bounded(
        command,
        Path(arguments.stdout),
        Path(arguments.stderr),
        arguments.timeout,
    )
    if not write_status(STATUS_PATH, kind, returncode):
        return 125
    return returncode


for handled_signal in HANDLED_SIGNALS:
    signal.signal(handled_signal, interrupted)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
