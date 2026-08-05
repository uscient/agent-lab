#!/usr/bin/env python3
"""Public, bounded operator facade over verified Agent Lab onboarding."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys

from importlib.util import module_from_spec, spec_from_file_location


def _load_home_module():
    path = Path(__file__).resolve().with_name("lab_home.py")
    spec = spec_from_file_location("agent_lab_facade_home", path)
    if spec is None or spec.loader is None:
        raise ImportError("facade home module cannot be loaded")
    module = module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


_home_module = _load_home_module()
HomeKind = _home_module.HomeKind
HomeObservation = _home_module.HomeObservation
inspect_home = _home_module.inspect_home
select_home = _home_module.select_home


USAGE = "Usage: ./lab [--home ABSOLUTE_HOME] {init|add PATH|doctor|prepare NAME|serve|start NAME|status [NAME]|stop NAME|list|inspect NAME|remove NAME}"
HELP = """Agent Lab uses two terminals:
  Terminal 1: ./lab serve
  Terminal 2: ./lab add PATH, then ./lab status [NAME]
Initialize the selected home first with ./lab init.
"""
CORE = Path(__file__).resolve().with_name("agent-lab")
CHECKOUT = Path(__file__).resolve().parent.parent


def usage() -> int:
    print(USAGE, file=sys.stderr)
    return 2


def _core(home: Path, arguments: list[str], *, private_umask: bool = False) -> subprocess.CompletedProcess[bytes]:
    previous = None
    if private_umask:
        previous = os.umask(0o077)
    try:
        return subprocess.run(
            [str(CORE), "--home", str(home), *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    finally:
        if previous is not None:
            os.umask(previous)


def _write_success(data: bytes) -> int:
    if len(data) > 65_536:
        print("INFRA Agent Lab result exceeded its safe output bound", file=sys.stderr)
        return 125
    try:
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
    except OSError:
        print("INFRA Agent Lab result could not be reported safely", file=sys.stderr)
        return 125
    return 0


def _deny_observation(observation: HomeObservation, *, allow_empty: bool) -> int | None:
    if observation.kind is HomeKind.UNSAFE:
        print("FAIL selected Agent Lab home boundary is unsafe", file=sys.stderr)
        return 1
    if observation.kind is HomeKind.INCOMPATIBLE:
        print("FAIL selected Agent Lab home uses an unsupported version", file=sys.stderr)
        return 1
    if observation.kind is HomeKind.UNCERTAIN:
        print("INFRA selected Agent Lab home boundary could not be proved", file=sys.stderr)
        return 125
    if not allow_empty and observation.kind in {HomeKind.ABSENT, HomeKind.EMPTY}:
        print("FAIL selected Agent Lab home is not initialized; run ./lab init", file=sys.stderr)
        return 1
    return None


def command_init(home: Path) -> int:
    observation = inspect_home(home)
    denied = _deny_observation(observation, allow_empty=True)
    if denied is not None:
        return denied
    if observation.kind is HomeKind.READY:
        check = _core(home, ["config", "check"])
        if check.returncode != 0:
            print("INFRA selected Agent Lab home authority could not be proved", file=sys.stderr)
            return 125
    completed = _core(home, ["init"], private_umask=True)
    if completed.returncode == 0:
        return _write_success(completed.stdout)
    if completed.returncode == 1:
        print("FAIL selected Agent Lab home conflicts with initialization", file=sys.stderr)
        return 1
    print("INFRA selected Agent Lab home could not be initialized safely", file=sys.stderr)
    return 125


def command_add(home: Path, source: str) -> int:
    observation = inspect_home(home)
    denied = _deny_observation(observation, allow_empty=False)
    if denied is not None:
        return denied
    completed = _core(home, ["experiment", "install", source], private_umask=True)
    if completed.returncode == 0:
        return _write_success(completed.stdout)
    if completed.returncode == 1:
        print("FAIL Experiment could not be added; inspect the source or run ./lab list", file=sys.stderr)
        return 1
    print("INFRA Experiment addition could not be proved safe", file=sys.stderr)
    return 125


def command_doctor(home: Path) -> int:
    observation = inspect_home(home)
    checkout = CHECKOUT.stat()
    result: dict[str, object] = {
        "checkout": str(CHECKOUT),
        "checkoutDevice": checkout.st_dev,
        "checkoutInode": checkout.st_ino,
        "home": str(home),
        "homeState": observation.kind.value,
    }
    if observation.device is not None and observation.inode is not None:
        result["homeDevice"] = observation.device
        result["homeInode"] = observation.inode
    print(json.dumps(result, ensure_ascii=True, separators=(",", ":"), sort_keys=True))
    return 0


def later_denial(name: str | None) -> int:
    if name is None:
        print("FAIL this command belongs to a later group and is not available yet", file=sys.stderr)
    else:
        print("FAIL no installed Experiment owns that name; use ./lab list or ./lab add PATH", file=sys.stderr)
    return 1


def main(argv: list[str]) -> int:
    if not argv:
        print(HELP, end="")
        return 0

    home_raw = None
    if argv[:1] == ["--home"]:
        if len(argv) < 3:
            return usage()
        home_raw = argv[1]
        argv = argv[2:]
    if not argv:
        return usage()

    verb, arguments = argv[0], argv[1:]
    arity_valid = (
        (verb in {"init", "doctor", "serve", "list"} and not arguments)
        or (verb in {"add", "prepare", "start", "stop", "inspect", "remove"} and len(arguments) == 1)
        or (verb == "status" and len(arguments) <= 1)
    )
    if not arity_valid:
        return usage()
    try:
        home = select_home(home_raw)
    except ValueError:
        return usage()

    if verb == "init":
        return command_init(home)
    if verb == "add":
        return command_add(home, arguments[0])
    if verb == "doctor":
        return command_doctor(home)
    if verb in {"prepare", "start", "stop", "inspect", "remove"}:
        return later_denial(arguments[0])
    if verb == "status" and arguments:
        return later_denial(arguments[0])
    return later_denial(None)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
