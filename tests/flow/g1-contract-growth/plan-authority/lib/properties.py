#!/usr/bin/env python3
"""Property instrument for observed v0alpha2 requested plans.

This instrument never imports product code and never computes a projection: it
only states which properties an observed plan already has, compares two observed
documents, and derives fresh mutants at run time so no implementation can pass by
recognising a stored fixture.

`self-test` calibrates every predicate against synthetic documents that are known
to violate it, so an "OK" answer can never be vacuous.

Exit status: 0 when the property holds, 1 when it does not, 125 when the
instrument itself could not run.
"""

from __future__ import annotations

import json
from pathlib import Path
import re
import sys
from typing import Any


PLAN_API = "agent-lab.request/v0alpha2"
PLAN_KIND = "RequestedExperimentPlan"
CONTRACT_NAME = "agent-lab.experiment"
CONTRACT_VERSION = "v0alpha2"
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
SECRET_NAME_RE = re.compile(r"^[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$")
REFERENCE_RE = re.compile(r"^agent-lab\.secret/[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$")
MEMBER_KEYS = {"command", "name", "requestedSelector", "resourceClass", "secretGrants"}
SECRET_KEYS = {"name", "reference"}
AUTHORITY_INSTALL_KEYS = {"assurance", "principal", "secrets"}
FORBIDDEN_KEYS = {"path", "value"}


class Violation(Exception):
    """The observed document does not have the claimed property."""


def canonical(value: Any) -> str:
    return json.dumps(value, allow_nan=False, ensure_ascii=True, sort_keys=True)


def read_json(path: str) -> Any:
    return json.loads(Path(path).read_bytes().decode("utf-8"))


def walk(value: Any):
    yield value
    if isinstance(value, dict):
        for key, child in value.items():
            yield from walk(key)
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def require(condition: object, reason: str) -> None:
    if not condition:
        raise Violation(reason)


def check_no_material(document: Any) -> None:
    """No secret material and no host path may survive anywhere in a document."""

    for node in walk(document):
        if isinstance(node, dict):
            overlap = sorted(FORBIDDEN_KEYS.intersection(node))
            if overlap:
                raise Violation(f"forbidden key {overlap[0]}")
        if isinstance(node, str):
            require(not node.startswith("/"), "absolute path string")


def check_declared_reference(document: Any, name: str, reference: str) -> None:
    """Require exactly one declared secret object with the exact given pair."""

    secrets = select(document, "spec.secrets")
    require(isinstance(secrets, list), "declared references are not a list")
    expected = {"name": name, "reference": reference}
    require(
        sum(entry == expected for entry in secrets) == 1,
        "exact declared name/reference pair is absent or repeated",
    )


def check_names(names: list[Any], subject: str, within: set[str] | None) -> None:
    require(isinstance(names, list), f"{subject} is not a list")
    for name in names:
        require(isinstance(name, str), f"{subject} entry is not a string")
        require(SECRET_NAME_RE.fullmatch(name) is not None, f"{subject} entry is not a logical name")
    require(len(set(names)) == len(names), f"{subject} contains a duplicate")
    require(names == sorted(names), f"{subject} is not canonically ordered")
    if within is not None:
        require(set(names) <= within, f"{subject} is not a subset of the declared references")


def check_plan(plan: Any, authority: str) -> None:
    require(isinstance(plan, dict), "plan is not an object")
    require(set(plan) == {"apiVersion", "contract", "kind", "metadata", "spec"}, "plan envelope drift")
    require(plan["apiVersion"] == PLAN_API, "plan apiVersion drift")
    require(plan["kind"] == PLAN_KIND, "plan kind drift")

    contract = plan["contract"]
    require(isinstance(contract, dict), "contract is not an object")
    require(set(contract) == {"digest", "name", "version"}, "contract field drift")
    require(contract["name"] == CONTRACT_NAME, "contract name drift")
    require(contract["version"] == CONTRACT_VERSION, "contract version drift")
    require(
        isinstance(contract["digest"], str) and DIGEST_RE.fullmatch(contract["digest"]),
        "contract digest is not a sha256 reference",
    )

    metadata = plan["metadata"]
    require(isinstance(metadata, dict) and set(metadata) == {"requestedName"}, "metadata field drift")

    spec = plan["spec"]
    require(isinstance(spec, dict), "spec is not an object")
    require({"members", "secrets"} <= set(spec), "spec is missing members or secrets")
    require(set(spec) <= {"authority", "members", "secrets"}, "spec field drift")

    secrets = spec["secrets"]
    require(isinstance(secrets, list) and secrets, "declared references are absent")
    declared: list[str] = []
    for entry in secrets:
        require(isinstance(entry, dict), "declared reference is not an object")
        require(set(entry) == SECRET_KEYS, "declared reference field drift")
        name = entry["name"]
        reference = entry["reference"]
        require(isinstance(name, str) and SECRET_NAME_RE.fullmatch(name), "declared name is invalid")
        require(
            isinstance(reference, str) and REFERENCE_RE.fullmatch(reference),
            "declared reference is not a bounded logical reference",
        )
        declared.append(name)
    check_names(declared, "declared references", None)

    members = spec["members"]
    require(isinstance(members, list) and members, "members are absent")
    member_names = []
    for member in members:
        require(isinstance(member, dict), "member is not an object")
        require(set(member) == MEMBER_KEYS, "member field drift")
        require(isinstance(member["name"], str), "member name is not a string")
        member_names.append(member["name"])
        check_names(member["secretGrants"], "template grants", set(declared))
    require(member_names == sorted(member_names), "members are not canonically ordered")

    if authority == "absent":
        require("authority" not in spec, "absent authority was defaulted into the plan")
    else:
        require("authority" in spec, "declared authority is missing from the plan")
        block = spec["authority"]
        require(isinstance(block, dict) and set(block) == {"install"}, "authority field drift")
        install = block["install"]
        require(isinstance(install, dict), "install authority is not an object")
        require(set(install) == AUTHORITY_INSTALL_KEYS, "install authority field drift")
        require(isinstance(install["principal"], str) and install["principal"], "principal is not bound")
        require(isinstance(install["assurance"], str) and install["assurance"], "assurance is not bound")
        check_names(install["secrets"], "authority references", set(declared))

    check_no_material(plan)


def select(document: Any, dotted: str) -> Any:
    value = document
    for key in dotted.split("."):
        if isinstance(value, list):
            value = value[int(key)]
        elif isinstance(value, dict) and key in value:
            value = value[key]
        else:
            raise Violation(f"{dotted} is absent")
    return value


def render(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int) or isinstance(value, float):
        return repr(value)
    return canonical(value)


def mutate(document: Any, operation: str) -> Any:
    value = json.loads(canonical(document))
    spec = value["spec"]
    members = spec["members"]
    if operation == "unknown-member-field":
        members[0]["privileged"] = True
    elif operation == "unknown-spec-field":
        spec["retention"] = "forever"
    elif operation == "undeclared-grant":
        members[0]["secretGrants"] = sorted([*members[0]["secretGrants"], "admin-token"])
    elif operation == "duplicate-grant":
        members[0]["secretGrants"] = [members[0]["secretGrants"][0], *members[0]["secretGrants"]]
    elif operation == "host-path-grant":
        members[0]["secretGrants"] = ["/etc/agent-lab/broker-token"]
    elif operation == "object-grant":
        members[0]["secretGrants"] = [{"selector": {"fromContext": "role"}}]
    elif operation == "rename-member":
        members[0]["name"] = "zz-renamed-template"
    elif operation == "drop-authority":
        spec.pop("authority", None)
    elif operation.startswith("drop-authority-"):
        spec["authority"]["install"].pop(operation[len("drop-authority-") :], None)
    else:
        raise ValueError(f"unknown mutation {operation}")
    return value


def self_test() -> None:
    """Prove every predicate can fail before any assertion relies on it."""

    base = {
        "apiVersion": PLAN_API,
        "contract": {"digest": "sha256:" + "0" * 64, "name": CONTRACT_NAME, "version": CONTRACT_VERSION},
        "kind": PLAN_KIND,
        "metadata": {"requestedName": "plan-authority"},
        "spec": {
            "authority": {
                "install": {
                    "assurance": "declared",
                    "principal": "declared-lab-operator",
                    "secrets": ["broker-token", "registry-pull"],
                }
            },
            "members": [
                {
                    "command": [],
                    "name": "coordinator",
                    "requestedSelector": {"digestRef": "registry.example/team/a@sha256:" + "a" * 64},
                    "resourceClass": "small",
                    "secretGrants": ["broker-token"],
                },
                {
                    "command": [],
                    "name": "hub",
                    "requestedSelector": {"digestRef": "registry.example/team/b@sha256:" + "b" * 64},
                    "resourceClass": "small",
                    "secretGrants": ["broker-token", "registry-pull"],
                },
            ],
            "secrets": [
                {"name": "broker-token", "reference": "agent-lab.secret/broker-token"},
                {"name": "registry-pull", "reference": "agent-lab.secret/registry-pull"},
            ],
        },
    }
    check_plan(base, "present")
    check_plan(mutate(base, "drop-authority"), "absent")

    def must_fail(document: Any, authority: str, label: str) -> None:
        try:
            check_plan(document, authority)
        except Violation:
            return
        raise SystemExit(f"INFRA plan property instrument accepted {label}")

    must_fail(base, "absent", "a defaulted authority block")
    must_fail(mutate(base, "drop-authority"), "present", "a missing authority block")
    must_fail(mutate(base, "unknown-member-field"), "present", "an unknown member field")
    must_fail(mutate(base, "unknown-spec-field"), "present", "an unknown spec field")
    must_fail(mutate(base, "undeclared-grant"), "present", "an undeclared grant")
    must_fail(mutate(base, "duplicate-grant"), "present", "a duplicate grant")
    must_fail(mutate(base, "host-path-grant"), "present", "a host path grant")
    must_fail(mutate(base, "object-grant"), "present", "a runtime-selectable grant")
    must_fail(mutate(base, "drop-authority-principal"), "present", "an unbound principal")
    must_fail(mutate(base, "drop-authority-assurance"), "present", "an unbound assurance")
    must_fail(mutate(base, "drop-authority-secrets"), "present", "an unbound authority secret set")

    unsorted_plan = json.loads(canonical(base))
    unsorted_plan["spec"]["members"].reverse()
    must_fail(unsorted_plan, "present", "unordered members")
    inline = json.loads(canonical(base))
    inline["spec"]["secrets"][0] = {"name": "broker-token", "value": "material"}
    must_fail(inline, "present", "inline secret material")

    if canonical(base) == canonical(mutate(base, "rename-member")):
        raise SystemExit("INFRA plan property instrument cannot observe a benign change")

    if render(select(base, "spec.members.0.name")) != "coordinator":
        raise SystemExit("INFRA plan property instrument cannot select a nested value")
    check_declared_reference(base, "broker-token", "agent-lab.secret/broker-token")
    for wrong_name, wrong_reference in (
        ("registry-pull", "agent-lab.secret/broker-token"),
        ("broker-token", "agent-lab.secret/registry-pull"),
    ):
        try:
            check_declared_reference(base, wrong_name, wrong_reference)
        except Violation:
            pass
        else:
            raise SystemExit("INFRA declared-reference matcher accepted a wrong neighbor")
    try:
        select(base, "spec.authority.install.absent")
    except Violation:
        pass
    else:
        raise SystemExit("INFRA plan property instrument reports an absent value as present")


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(f"usage: {argv[0]} COMMAND [ARGUMENT ...]", file=sys.stderr)
        return 125
    command = argv[1]
    try:
        if command == "self-test":
            self_test()
            return 0
        if command == "plan-shape" and len(argv) == 4:
            check_plan(read_json(argv[2]), argv[3])
            return 0
        if command == "no-material" and len(argv) == 3:
            check_no_material(read_json(argv[2]))
            return 0
        if command == "declared-reference" and len(argv) == 5:
            check_declared_reference(read_json(argv[2]), argv[3], argv[4])
            return 0
        if command == "same" and len(argv) == 4:
            require(canonical(read_json(argv[2])) == canonical(read_json(argv[3])), "documents differ")
            return 0
        if command == "differ" and len(argv) == 4:
            require(canonical(read_json(argv[2])) != canonical(read_json(argv[3])), "documents are identical")
            return 0
        if command == "get" and len(argv) == 4:
            print(render(select(read_json(argv[2]), argv[3])))
            return 0
        if command == "extract" and len(argv) == 5:
            Path(argv[4]).write_text(
                canonical(select(read_json(argv[2]), argv[3])) + "\n", encoding="ascii"
            )
            return 0
        if command == "mutate" and len(argv) == 5:
            Path(argv[4]).write_text(canonical(mutate(read_json(argv[2]), argv[3])) + "\n", encoding="ascii")
            return 0
    except Violation as violation:
        print(f"BAD {violation}", file=sys.stderr)
        return 1
    except (OSError, UnicodeError, ValueError, KeyError, TypeError, IndexError) as error:
        print(f"INFRA property instrument failed: {type(error).__name__}", file=sys.stderr)
        return 125
    print(f"INFRA unsupported property request: {command}", file=sys.stderr)
    return 125


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
