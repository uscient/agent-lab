#!/usr/bin/env python3
"""Evaluate Docker inspect assertions for the Bash runtime checker.

Exit codes 80 through 92 encode zero through twelve failed structured
assertions. Exit 64 asks the stable Bash entrypoint to use its jq oracle for
input whose jq diagnostics cannot be reproduced byte-for-byte with the Python
standard library.
"""

import json
import sys


ORACLE_FALLBACK = 64
RESULT_BASE = 80


def jq_default(value, default):
    """Match jq's `value // default` for the Docker-shaped values we accept."""
    return default if value is None or value is False else value


def is_supported_shape(document):
    """Limit Python evaluation to Docker-shaped JSON with jq-equivalent types."""
    if not isinstance(document, list) or len(document) != 1:
        return False
    container = document[0]
    if not isinstance(container, dict):
        return False

    config = container.get("Config")
    host = container.get("HostConfig")
    network = container.get("NetworkSettings")
    mounts = container.get("Mounts")
    if not all(isinstance(value, dict) for value in (config, host, network)):
        return False
    if not isinstance(mounts, list) or not all(
        isinstance(mount, dict) for mount in mounts
    ):
        return False

    list_fields = (
        "CapDrop",
        "CapAdd",
        "SecurityOpt",
        "Devices",
        "DeviceRequests",
        "DeviceCgroupRules",
        "ExtraHosts",
        "Binds",
    )
    if any(
        host.get(field) is not None
        and host.get(field) is not False
        and not isinstance(host.get(field), list)
        for field in list_fields
    ):
        return False
    if any(
        not isinstance(bind, str)
        for bind in jq_default(host.get("Binds"), [])
    ):
        return False

    for field in ("PortBindings", "Tmpfs"):
        value = host.get(field)
        if value is not None and value is not False and not isinstance(value, dict):
            return False
    exposed_ports = config.get("ExposedPorts")
    if (
        exposed_ports is not None
        and exposed_ports is not False
        and not isinstance(exposed_ports, dict)
    ):
        return False

    networks = network.get("Networks")
    ports = network.get("Ports")
    if not isinstance(networks, dict):
        return False
    if ports is not None and ports is not False and not isinstance(ports, dict):
        return False
    if isinstance(ports, dict) and any(
        value is not None and not isinstance(value, list)
        for value in ports.values()
    ):
        return False

    for mount in mounts:
        for field in ("Source", "Destination", "Type"):
            value = mount.get(field)
            if value is not None and value is not False and not isinstance(value, str):
                return False
    return True


def raw_string(value):
    """Render the jq -r scalar forms used by mount destination extraction."""
    if value is None:
        return "null"
    if value is False:
        return "false"
    return value


def evaluate(document, mode, expected_uid, expected_gid, project):
    container = document[0]
    config = container["Config"]
    host = container["HostConfig"]
    mounts = container["Mounts"]
    network = container["NetworkSettings"]
    expected_user = f"{expected_uid}:{expected_gid}"
    expected_network = f"{project}_agents"
    results = []

    def assertion(name, passed):
        results.append((name, bool(passed)))

    assertion(
        "root filesystem is structurally read-only",
        host.get("ReadonlyRootfs") is True,
    )
    assertion(
        "configured user is the exact numeric UID:GID",
        config.get("User") == expected_user,
    )
    assertion(
        "all capabilities are dropped and none are added",
        "ALL" in jq_default(host.get("CapDrop"), [])
        and len(jq_default(host.get("CapAdd"), [])) == 0,
    )
    assertion(
        "no-new-privileges is configured",
        "no-new-privileges:true"
        in jq_default(host.get("SecurityOpt"), []),
    )
    assertion(
        "PID, memory, and CPU limits are exact",
        host.get("PidsLimit") == 512
        and host.get("Memory") == 1073741824
        and host.get("NanoCpus") == 1000000000,
    )
    assertion(
        "privilege, device, and extra-host surfaces are empty",
        host.get("Privileged") is False
        and len(jq_default(host.get("Devices"), [])) == 0
        and len(jq_default(host.get("DeviceRequests"), [])) == 0
        and len(jq_default(host.get("DeviceCgroupRules"), [])) == 0
        and len(jq_default(host.get("ExtraHosts"), [])) == 0,
    )
    published_ports = jq_default(host.get("PortBindings"), {})
    exposed_ports = jq_default(config.get("ExposedPorts"), {})
    runtime_ports = jq_default(network.get("Ports"), {})
    assertion(
        "no host ports are published or exposed",
        len(published_ports) == 0
        and host.get("PublishAllPorts") is False
        and len(exposed_ports) == 0
        and all(value is None or len(value) == 0 for value in runtime_ports.values()),
    )
    assertion(
        "agent is attached only to its project-scoped internal network",
        sorted(network["Networks"].keys()) == [expected_network],
    )
    socket_absent = all(
        "docker.sock" not in jq_default(mount.get("Source"), "")
        and "docker.sock" not in jq_default(mount.get("Destination"), "")
        for mount in mounts
    ) and all(
        "docker.sock" not in bind
        for bind in jq_default(host.get("Binds"), [])
    )
    assertion("Docker socket is absent from every configured mount", socket_absent)

    mount_targets = sorted(raw_string(mount.get("Destination")) for mount in mounts)
    tmpfs_targets = sorted(jq_default(host.get("Tmpfs"), {}).keys())
    if mode == "ephemeral":
        expected_mounts = ["/run/agent-secrets", "/workspace"]
        expected_tmpfs = ["/home/agent", "/tmp"]
    else:
        expected_mounts = ["/home/agent", "/run/agent-secrets", "/workspace"]
        expected_tmpfs = ["/tmp"]
    assertion(
        f"user-controlled mounts and tmpfs targets are exact for {mode} HOME",
        mount_targets == expected_mounts and tmpfs_targets == expected_tmpfs,
    )
    assertion(
        "workspace is read-write and secrets are read-only",
        any(
            mount.get("Destination") == "/workspace" and mount.get("RW") is True
            for mount in mounts
        )
        and any(
            mount.get("Destination") == "/run/agent-secrets"
            and mount.get("RW") is False
            for mount in mounts
        ),
    )
    if mode == "persistent":
        assertion(
            "persistent HOME is a read-write named volume",
            any(
                mount.get("Destination") == "/home/agent"
                and mount.get("Type") == "volume"
                and mount.get("RW") is True
                for mount in mounts
            ),
        )
    return results


def main(argv):
    if len(argv) != 6:
        return ORACLE_FALLBACK
    inspect_path, mode, expected_uid, expected_gid, project = argv[1:]
    if mode not in ("ephemeral", "persistent"):
        return ORACLE_FALLBACK
    try:
        with open(inspect_path, encoding="utf-8") as stream:
            document = json.load(stream)
    except (OSError, UnicodeError, ValueError, RecursionError):
        return ORACLE_FALLBACK
    if not is_supported_shape(document):
        return ORACLE_FALLBACK

    try:
        results = evaluate(document, mode, expected_uid, expected_gid, project)
    except (AttributeError, KeyError, OverflowError, TypeError, ValueError):
        return ORACLE_FALLBACK

    sys.stdout.write(
        "".join(
            f"{'PASS' if passed else 'FAIL'} {name}\n"
            for name, passed in results
        )
    )
    return RESULT_BASE + sum(not passed for _, passed in results)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
