#!/usr/bin/env python3
"""Fail-loud MCP smoke for Agent Lab's exact containerized Serena launcher."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import threading
import time
import tomllib
from typing import Any


PROTOCOL_VERSION = "2025-11-25"
REQUEST_TIMEOUT_SECONDS = 180
EXPECTED_TOOLS = {
    "activate_project",
    "find_declaration",
    "find_referencing_symbols",
    "find_symbol",
    "get_current_config",
    "get_diagnostics_for_file",
    "get_symbols_overview",
    "insert_after_symbol",
    "insert_before_symbol",
    "list_memories",
    "replace_symbol_body",
}
FORBIDDEN_TOOLS = {
    "rename_symbol",
    "replace_content",
    "replace_in_files",
    "safe_delete_symbol",
}
REQUIRED_ACTIVE_EDIT_TOOLS = {
    "insert_after_symbol",
    "insert_before_symbol",
    "replace_symbol_body",
}


class SmokeFailure(RuntimeError):
    """An acceptance-stage failure with actionable context."""


class McpClient:
    def __init__(
        self,
        command: list[str],
        context: str,
        client_cwd: Path,
        compose_project: str,
    ) -> None:
        self.context = context
        self.compose_project = compose_project
        self._next_id = 1
        self._stderr_lines: list[str] = []
        child_env = dict(os.environ)
        child_env["COMPOSE_PROJECT_NAME"] = compose_project
        self._process = subprocess.Popen(
            command,
            cwd=client_cwd,
            env=child_env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self._stderr_thread = threading.Thread(
            target=self._drain_stderr,
            name=f"serena-stderr-{context}",
            daemon=True,
        )
        self._stderr_thread.start()

    def _drain_stderr(self) -> None:
        assert self._process.stderr is not None
        for line in self._process.stderr:
            self._stderr_lines.append(line.rstrip())
            if len(self._stderr_lines) > 500:
                del self._stderr_lines[:100]

    def close(self) -> None:
        if self._process.stdin is not None and not self._process.stdin.closed:
            self._process.stdin.close()
        try:
            self._process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self._process.terminate()
            try:
                self._process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._process.kill()
                self._process.wait(timeout=5)
        self._stderr_thread.join(timeout=2)

    def failure_logs(self) -> str:
        if not self._stderr_lines:
            return "<no Serena/container stderr was captured>"
        return "\n".join(self._stderr_lines[-80:])

    def readiness_logs(self) -> str:
        selected = [
            line
            for line in self._stderr_lines
            if "language server" in line.lower()
            or "bashlanguageserver" in line.lower()
        ]
        return "\n".join(selected[-20:])

    def notify(self, method: str, params: dict[str, Any] | None = None) -> None:
        self._send(
            {
                "jsonrpc": "2.0",
                "method": method,
                "params": params or {},
            }
        )

    def request(
        self,
        method: str,
        params: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        request_id = self._next_id
        self._next_id += 1
        self._send(
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "method": method,
                "params": params or {},
            }
        )

        deadline = time.monotonic() + REQUEST_TIMEOUT_SECONDS
        assert self._process.stdout is not None
        while time.monotonic() < deadline:
            if self._process.poll() is not None:
                raise SmokeFailure(
                    f"{self.context}: MCP server exited with "
                    f"{self._process.returncode} while waiting for {method}"
                )
            remaining = max(0.0, deadline - time.monotonic())
            readable, _, _ = select.select(
                [self._process.stdout],
                [],
                [],
                min(1.0, remaining),
            )
            if not readable:
                continue
            line = self._process.stdout.readline()
            if not line:
                continue
            try:
                message = json.loads(line)
            except json.JSONDecodeError as exc:
                raise SmokeFailure(
                    f"{self.context}: non-JSON stdout corrupted MCP framing: "
                    f"{line.rstrip()!r}"
                ) from exc
            if message.get("id") != request_id:
                continue
            if "error" in message:
                raise SmokeFailure(
                    f"{self.context}: {method} returned MCP error: "
                    f"{json.dumps(message['error'], sort_keys=True)}"
                )
            result = message.get("result")
            if not isinstance(result, dict):
                raise SmokeFailure(
                    f"{self.context}: {method} returned malformed result: "
                    f"{message!r}"
                )
            return result

        raise SmokeFailure(
            f"{self.context}: timed out after {REQUEST_TIMEOUT_SECONDS}s "
            f"waiting for {method}"
        )

    def _call_tool_result(
        self,
        name: str,
        arguments: dict[str, Any],
    ) -> dict[str, Any]:
        return self.request(
            "tools/call",
            {
                "name": name,
                "arguments": arguments,
            },
        )

    def _tool_text(self, name: str, result: dict[str, Any]) -> str:
        content = result.get("content")
        if not isinstance(content, list):
            raise SmokeFailure(
                f"{self.context}: tool {name} returned no content list"
            )
        texts = [
            item["text"]
            for item in content
            if isinstance(item, dict)
            and item.get("type") == "text"
            and isinstance(item.get("text"), str)
        ]
        if not texts:
            raise SmokeFailure(
                f"{self.context}: tool {name} returned no text content"
            )
        return "\n".join(texts)

    def call_tool(self, name: str, arguments: dict[str, Any]) -> str:
        result = self._call_tool_result(name, arguments)
        if result.get("isError"):
            raise SmokeFailure(
                f"{self.context}: tool {name} failed: "
                f"{json.dumps(result, sort_keys=True)}"
            )
        return self._tool_text(name, result)

    def call_tool_error(self, name: str, arguments: dict[str, Any]) -> str:
        result = self._call_tool_result(name, arguments)
        if not result.get("isError"):
            raise SmokeFailure(
                f"{self.context}: tool {name} unexpectedly succeeded before "
                "project activation"
            )
        return self._tool_text(name, result)

    def _send(self, message: dict[str, Any]) -> None:
        if self._process.poll() is not None:
            raise SmokeFailure(
                f"{self.context}: MCP server already exited with "
                f"{self._process.returncode}"
            )
        assert self._process.stdin is not None
        self._process.stdin.write(
            json.dumps(message, separators=(",", ":")) + "\n"
        )
        self._process.stdin.flush()


def require_text(stage: str, value: str, *needles: str) -> None:
    missing = [needle for needle in needles if needle not in value]
    if missing:
        raise SmokeFailure(
            f"{stage}: expected {missing!r} in result:\n{value}"
        )


def parse_active_tools(config_overview: str) -> set[str]:
    header = (
        "Active tools (after all exclusions from the project, context, and modes):\n"
    )
    if header not in config_overview:
        raise SmokeFailure(
            "configuration did not contain the active-tools section:\n"
            f"{config_overview}"
        )
    active_block = config_overview.split(header, 1)[1]
    active_block = active_block.split(
        "\nAvailable but not active tools:",
        1,
    )[0]
    return {
        tool_name.strip()
        for line in active_block.splitlines()
        for tool_name in line.split(",")
        if tool_name.strip()
    }


def require_error_diagnostic_codes(
    stage: str,
    value: str,
    relative_path: str,
    expected_codes: set[str],
) -> None:
    try:
        payload = json.loads(value)
    except json.JSONDecodeError as exc:
        raise SmokeFailure(
            f"{stage}: diagnostics were not valid JSON:\n{value}"
        ) from exc
    if not isinstance(payload, dict):
        raise SmokeFailure(
            f"{stage}: expected a diagnostics object, got {payload!r}"
        )

    severities = payload.get(relative_path)
    if not isinstance(severities, dict):
        raise SmokeFailure(
            f"{stage}: no diagnostics entry for {relative_path!r}:\n{value}"
        )
    errors_by_symbol = severities.get("Error")
    if not isinstance(errors_by_symbol, dict) or not errors_by_symbol:
        raise SmokeFailure(
            f"{stage}: expected Error diagnostics for {relative_path!r}:\n{value}"
        )

    normalized_codes: set[str] = set()
    for diagnostics in errors_by_symbol.values():
        if not isinstance(diagnostics, list):
            continue
        for diagnostic in diagnostics:
            if not isinstance(diagnostic, dict):
                continue
            code = diagnostic.get("code")
            if isinstance(code, bool):
                continue
            if isinstance(code, int):
                normalized_codes.add(f"SC{code}")
            elif isinstance(code, str):
                normalized = code.upper()
                if normalized.isdigit():
                    normalized = f"SC{normalized}"
                normalized_codes.add(normalized)

    missing_codes = expected_codes - normalized_codes
    if missing_codes:
        raise SmokeFailure(
            f"{stage}: missing expected Error diagnostic codes "
            f"{sorted(missing_codes)!r}; got {sorted(normalized_codes)!r}:\n{value}"
        )


def print_evidence(label: str, value: str) -> None:
    print(f"EVIDENCE {label}")
    print(value)


def load_client_registration(repo_root: Path, context: str) -> list[str]:
    if context == "claude-code":
        config_path = repo_root / ".mcp.json"
        config = json.loads(config_path.read_text(encoding="utf-8"))
        registration = config.get("mcpServers", {}).get("serena")
        if isinstance(registration, dict) and registration.get("type") != "stdio":
            raise SmokeFailure(
                f"{config_path}: Serena registration is not stdio"
            )
    elif context in {"codex", "grok"}:
        config_path = (
            repo_root / ".codex/config.toml"
            if context == "codex"
            else repo_root / ".grok/config.toml"
        )
        with config_path.open("rb") as config_file:
            config = tomllib.load(config_file)
        registration = config.get("mcp_servers", {}).get("serena")
    else:
        raise SmokeFailure(f"unsupported client context {context!r}")

    if not isinstance(registration, dict):
        raise SmokeFailure(
            f"{config_path}: missing Serena MCP registration"
        )
    command = registration.get("command")
    args = registration.get("args")
    if not isinstance(command, str) or not command:
        raise SmokeFailure(
            f"{config_path}: Serena MCP command must be a non-empty string"
        )
    if (
        not isinstance(args, list)
        or not all(isinstance(arg, str) for arg in args)
    ):
        raise SmokeFailure(
            f"{config_path}: Serena MCP args must be a list of strings"
        )

    parsed_command = [command, *args]
    print_evidence(
        f"{context} parsed client registration",
        json.dumps(
            {
                "config": str(config_path.relative_to(repo_root)),
                "command": parsed_command,
            },
            sort_keys=True,
        ),
    )
    return parsed_command


def load_expected_protected_mounts(repo_root: Path) -> dict[str, Path]:
    policy_path = repo_root / "policy" / "protected.paths"
    expected: dict[str, Path] = {}
    for raw_line in policy_path.read_text(encoding="utf-8").splitlines():
        entry = raw_line.strip()
        if not entry or entry.startswith("#"):
            continue
        relative = entry.rstrip("/")
        relative_path = Path(relative)
        if relative_path.is_absolute() or ".." in relative_path.parts:
            raise SmokeFailure(
                f"runtime inspection: unsafe protected-path entry {entry!r}"
            )
        source = repo_root / relative_path
        if not source.exists():
            continue
        destination = f"/workspace/{relative_path.as_posix()}"
        expected[destination] = source.resolve()
    return expected


def inspect_runtime(repo_root: Path, compose_project: str) -> str:
    container_ids = subprocess.check_output(
        [
            "docker",
            "ps",
            "--filter",
            f"label=com.docker.compose.project={compose_project}",
            "--filter",
            "label=com.docker.compose.service=serena",
            "--format",
            "{{.ID}}",
        ],
        text=True,
    ).split()
    if len(container_ids) != 1:
        raise SmokeFailure(
            "runtime inspection: expected one live Serena container for "
            f"Compose project {compose_project!r}, got {container_ids!r}"
        )

    container_id = container_ids[0]
    inspected = json.loads(
        subprocess.check_output(
            ["docker", "inspect", container_id],
            text=True,
        )
    )
    if not isinstance(inspected, list) or len(inspected) != 1:
        raise SmokeFailure("runtime inspection: malformed docker inspect result")
    container = inspected[0]
    host_config = container.get("HostConfig", {})
    config = container.get("Config", {})

    if host_config.get("NetworkMode") != "none":
        raise SmokeFailure("runtime inspection: Serena network mode is not none")
    if host_config.get("ReadonlyRootfs") is not True:
        raise SmokeFailure("runtime inspection: Serena rootfs is not read-only")
    if "ALL" not in (host_config.get("CapDrop") or []):
        raise SmokeFailure("runtime inspection: Serena does not drop all caps")
    security_opts = host_config.get("SecurityOpt") or []
    if not any("no-new-privileges" in option for option in security_opts):
        raise SmokeFailure(
            "runtime inspection: no-new-privileges is not active"
        )
    if "/tmp" not in (host_config.get("Tmpfs") or {}):
        raise SmokeFailure("runtime inspection: /tmp is not tmpfs")
    if not config.get("User") or config.get("User", "").startswith("0"):
        raise SmokeFailure("runtime inspection: Serena is not explicitly non-root")
    if config.get("ExposedPorts"):
        raise SmokeFailure("runtime inspection: Serena exposes ports")

    mounts = container.get("Mounts")
    if not isinstance(mounts, list) or not mounts:
        raise SmokeFailure(
            f"runtime inspection: expected workspace bind mounts, got {mounts!r}"
        )

    mounts_by_destination: dict[str, dict[str, Any]] = {}
    for mount in mounts:
        if not isinstance(mount, dict):
            raise SmokeFailure(
                f"runtime inspection: malformed mount entry: {mount!r}"
            )
        destination = mount.get("Destination")
        if not isinstance(destination, str) or not destination:
            raise SmokeFailure(
                f"runtime inspection: mount has no destination: {mount!r}"
            )
        if destination in mounts_by_destination:
            raise SmokeFailure(
                "runtime inspection: duplicate mount destination "
                f"{destination!r}"
            )
        if mount.get("Type") != "bind":
            raise SmokeFailure(
                f"runtime inspection: unexpected non-bind mount: {mount!r}"
            )
        if destination != "/workspace" and not destination.startswith(
            "/workspace/"
        ):
            raise SmokeFailure(
                "runtime inspection: mount escapes the project namespace: "
                f"{mount!r}"
            )

        raw_source = mount.get("Source")
        if not isinstance(raw_source, str) or not raw_source.startswith("/"):
            raise SmokeFailure(
                f"runtime inspection: mount source is not absolute: {mount!r}"
            )
        source = Path(raw_source).resolve()
        if source != repo_root and repo_root.is_relative_to(source):
            raise SmokeFailure(
                "runtime inspection: broad host ancestor is mounted: "
                f"{mount!r}"
            )
        if source.is_relative_to(repo_root / ".git"):
            raise SmokeFailure(
                "runtime inspection: host Git state is mounted: "
                f"{mount!r}"
            )
        if source.is_relative_to(repo_root / "secrets"):
            raise SmokeFailure(
                "runtime inspection: repo-local secrets are mounted: "
                f"{mount!r}"
            )
        mounts_by_destination[destination] = mount

    project_mount = mounts_by_destination.get("/workspace")
    if (
        project_mount is None
        or project_mount.get("RW") is not True
        or Path(str(project_mount.get("Source", ""))).resolve() != repo_root
    ):
        raise SmokeFailure(
            "runtime inspection: missing expected writable project mount: "
            f"{project_mount!r}"
        )

    git_mask = mounts_by_destination.get("/workspace/.git")
    git_mask_source = (
        Path(str(git_mask.get("Source", ""))).resolve()
        if git_mask is not None
        else Path("/")
    )
    if (
        git_mask is None
        or git_mask.get("RW") is not False
        or git_mask_source.is_relative_to(repo_root)
    ):
        raise SmokeFailure(
            f"runtime inspection: Git state is not privately masked: {git_mask!r}"
        )

    project_cache = mounts_by_destination.get("/workspace/.serena/cache")
    project_cache_source = (
        Path(str(project_cache.get("Source", ""))).resolve()
        if project_cache is not None
        else Path("/")
    )
    if (
        project_cache is None
        or project_cache.get("RW") is not True
        or project_cache_source.is_relative_to(repo_root)
        or project_cache_source.name != "project-cache"
        or git_mask_source.parent != project_cache_source.parent
        or git_mask_source.name not in {"empty-dir", "empty-file"}
    ):
        raise SmokeFailure(
            "runtime inspection: Serena cache is not a private writable mount: "
            f"{project_cache!r}"
        )

    protected_mounts = load_expected_protected_mounts(repo_root)
    state_mask_names = {
        "data",
        "volumes",
        "runtime",
        "logs",
        "state",
        "cache",
        ".cache",
        "models",
        "browser-profiles",
        "agent-state",
        ".tmp",
        "tmp",
        "node_modules",
        ".pytest_cache",
        "__pycache__",
        ".idea",
        "proj",
        "secrets",
    }
    base_destinations = {
        "/workspace",
        "/workspace/.git",
        "/workspace/.serena/cache",
    }
    for destination, mount in mounts_by_destination.items():
        if destination in base_destinations:
            continue

        source = Path(str(mount["Source"])).resolve()
        protected_source = protected_mounts.get(destination)
        if protected_source is not None:
            if source != protected_source or mount.get("RW") is not False:
                raise SmokeFailure(
                    "runtime inspection: protected rail is not an exact "
                    f"read-only bind: {mount!r}"
                )
            continue

        relative_destination = destination.removeprefix("/workspace/")
        is_env_mask = (
            relative_destination == ".env"
            or (
                relative_destination.startswith(".env.")
                and not relative_destination.endswith(".example")
            )
        )
        if (
            "/" in relative_destination
            or (
                relative_destination not in state_mask_names
                and not is_env_mask
            )
            or mount.get("RW") is not False
            or source.parent != project_cache_source.parent
            or source.name not in {"empty-dir", "empty-file"}
        ):
            raise SmokeFailure(
                "runtime inspection: unrecognized or unsafe workspace overlay: "
                f"{mount!r}"
            )

    missing_protected_mounts = sorted(
        set(protected_mounts) - set(mounts_by_destination)
    )
    if missing_protected_mounts:
        raise SmokeFailure(
            "runtime inspection: protected rails lack read-only overlays: "
            f"{missing_protected_mounts!r}"
        )

    writable_destinations = {
        destination
        for destination, mount in mounts_by_destination.items()
        if mount.get("RW") is True
    }
    expected_writable_destinations = {
        "/workspace",
        "/workspace/.serena/cache",
    }
    if writable_destinations != expected_writable_destinations:
        raise SmokeFailure(
            "runtime inspection: unexpected writable mount destinations: "
            f"{sorted(writable_destinations)!r}"
        )

    env = config.get("Env") or []
    forbidden_env = (
        "HTTP_PROXY=",
        "HTTPS_PROXY=",
        "ALL_PROXY=",
        "AGENT_LAB_SECRETS_MOUNT=",
    )
    if any(item.startswith(forbidden_env) for item in env):
        raise SmokeFailure(
            "runtime inspection: Serena received proxy or secret environment"
        )

    process_table = subprocess.check_output(
        ["docker", "top", container_id, "-eo", "pid,args"],
        text=True,
    )
    if "bash-language-server" not in process_table:
        raise SmokeFailure(
            "runtime inspection: bash-language-server process not found:\n"
            f"{process_table}"
        )

    return (
        f"container={container_id}\n"
        "network=none rootfs=read-only mounts=/workspace:rw,"
        "/workspace/.serena/cache:private-rw,/workspace/.git:masked-ro,"
        f"{len(mounts_by_destination) - 3}-protected-or-state-overlays:ro,"
        "/tmp:tmpfs "
        "user=non-root caps=ALL-dropped ports=none\n"
        f"{process_table}"
    )


def run_context(
    command: list[str],
    context: str,
    repo_root: Path,
    client_cwd: Path,
    full_semantic_smoke: bool,
) -> None:
    context_slug = context.replace("-", "_")
    fixture_token = (
        f"{context_slug}_{os.getpid()}_{time.monotonic_ns()}"
    )
    readiness_fixture = (
        repo_root / f".serena-smoke-readiness-{fixture_token}.sh"
    )
    diagnostics_fixture = (
        repo_root / f".serena-smoke-diagnostics-{fixture_token}.sh"
    )
    readiness_target = f"serena_smoke_target_{fixture_token}"
    readiness_caller = f"serena_smoke_caller_{fixture_token}"
    compose_project_base = os.environ.get(
        "COMPOSE_PROJECT_NAME",
        "agent-lab-serena-smoke",
    )
    compose_project = (
        f"{compose_project_base}-{fixture_token.replace('_', '-')}"
    )
    cleanup_paths = [readiness_fixture]
    if full_semantic_smoke:
        cleanup_paths.append(diagnostics_fixture)

    client: McpClient | None = None
    try:
        readiness_fixture.write_text(
            "#!/usr/bin/env bash\n"
            f"{readiness_target}() {{\n"
            '  printf "%s\\n" "live-readiness"\n'
            "}\n"
            f"{readiness_caller}() {{\n"
            f"  {readiness_target}\n"
            "}\n"
            f"{readiness_caller}\n",
            encoding="utf-8",
        )
        if full_semantic_smoke:
            diagnostics_fixture.write_text(
                "#!/usr/bin/env bash\n"
                "if then\n"
                '  echo "missing condition"\n'
                "fi\n",
                encoding="utf-8",
            )

        client = McpClient(
            command,
            context,
            client_cwd,
            compose_project,
        )
        initialized = client.request(
            "initialize",
            {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {
                    "name": "agent-lab-serena-smoke",
                    "version": "1",
                },
            },
        )
        client.notify("notifications/initialized")
        server_info = initialized.get("serverInfo", {})
        print_evidence(
            f"{context} MCP initialized",
            json.dumps(server_info, sort_keys=True),
        )

        tools_result = client.request("tools/list")
        tools = tools_result.get("tools")
        if not isinstance(tools, list):
            raise SmokeFailure(f"{context}: tools/list returned no tools list")
        tool_names = {
            tool.get("name")
            for tool in tools
            if isinstance(tool, dict) and isinstance(tool.get("name"), str)
        }
        missing_tools = sorted(EXPECTED_TOOLS - tool_names)
        if missing_tools:
            raise SmokeFailure(
                f"{context}: required Serena tools missing: {missing_tools}"
            )
        print(
            f"PASS {context} MCP connected; "
            f"{len(tool_names)} Serena tools exposed"
        )

        before = client.call_tool_error("get_current_config", {})
        require_text(
            f"{context} configuration before activation",
            before,
            "No active project",
            "known projects: []",
        )
        print_evidence(f"{context} configuration before activation", before)

        activation = client.call_tool(
            "activate_project",
            {"project": "/workspace"},
        )
        require_text(
            f"{context} activation",
            activation,
            "agent-lab-dev",
            "/workspace",
            "bash",
            "utf-8",
        )
        print_evidence(f"{context} activation", activation)

        after = client.call_tool("get_current_config", {})
        require_text(
            f"{context} configuration after activation",
            after,
            "agent-lab-dev",
            context,
            "LSP",
        )
        print_evidence(f"{context} configuration after activation", after)

        active_tools = parse_active_tools(after)
        active_forbidden_tools = sorted(FORBIDDEN_TOOLS & active_tools)
        if active_forbidden_tools:
            raise SmokeFailure(
                f"{context}: bounded-write policy left forbidden tools active: "
                f"{active_forbidden_tools}"
            )
        missing_active_edit_tools = sorted(
            REQUIRED_ACTIVE_EDIT_TOOLS - active_tools
        )
        if missing_active_edit_tools:
            raise SmokeFailure(
                f"{context}: required bounded semantic editors are inactive: "
                f"{missing_active_edit_tools}"
            )
        print(
            f"PASS {context} project tool policy: bounded semantic editors active; "
            "broad mutators inactive"
        )

        memories = client.call_tool("list_memories", {})
        print_evidence(f"{context} onboarding memory state", memories)

        readiness_overview = client.call_tool(
            "get_symbols_overview",
            {
                "relative_path": readiness_fixture.name,
                "depth": 0,
            },
        )
        require_text(
            f"{context} uncached live semantic overview",
            readiness_overview,
            readiness_target,
            readiness_caller,
        )
        print_evidence(
            f"{context} uncached live semantic overview",
            readiness_overview,
        )

        readiness_declaration = client.call_tool(
            "find_declaration",
            {
                "relative_path": readiness_fixture.name,
                "regex": (
                    r"\n[ \t]+("
                    + readiness_target
                    + r")[ \t]*\n"
                ),
                "include_body": False,
            },
        )
        require_text(
            f"{context} live definition traversal",
            readiness_declaration,
            readiness_target,
            readiness_fixture.name,
        )
        print_evidence(
            f"{context} live definition traversal",
            readiness_declaration,
        )

        overview = client.call_tool(
            "get_symbols_overview",
            {
                "relative_path": "scripts/lib/config.sh",
                "depth": 0,
            },
        )
        require_text(
            f"{context} semantic overview",
            overview,
            "agent_lab_validate_config",
            "agent_lab_validate_boolean",
        )
        print_evidence(f"{context} semantic overview", overview)
        print(f"PASS {context} Bash language server ready")

        if not full_semantic_smoke:
            return

        print_evidence(
            "live Serena containment and language-server process",
            inspect_runtime(repo_root, client.compose_project),
        )

        semantic_edit = client.call_tool(
            "replace_symbol_body",
            {
                "name_path": readiness_target,
                "relative_path": readiness_fixture.name,
                "body": (
                    f"{readiness_target}() {{\n"
                    "  printf '%s\\n' 'semantic-edit-verified'\n"
                    "}"
                ),
            },
        )
        print_evidence("disposable semantic symbol edit", semantic_edit)

        edited_symbol = client.call_tool(
            "find_symbol",
            {
                "name_path_pattern": readiness_target,
                "relative_path": readiness_fixture.name,
                "include_body": True,
                "max_matches": 1,
            },
        )
        require_text(
            "semantic symbol edit verification",
            edited_symbol,
            readiness_target,
            "semantic-edit-verified",
        )
        print_evidence("semantic symbol edit verification", edited_symbol)

        edited_diagnostics = client.call_tool(
            "get_diagnostics_for_file",
            {
                "relative_path": readiness_fixture.name,
                "min_severity": 1,
            },
        )
        if edited_diagnostics.strip() != "{}":
            raise SmokeFailure(
                "semantic symbol edit verification: edited disposable fixture "
                f"has Error diagnostics:\n{edited_diagnostics}"
            )
        print_evidence(
            "semantic symbol edit Error diagnostics",
            edited_diagnostics,
        )

        symbol = client.call_tool(
            "find_symbol",
            {
                "name_path_pattern": "agent_lab_validate_config",
                "relative_path": "scripts/lib/config.sh",
                "include_body": True,
                "max_matches": 1,
            },
        )
        require_text(
            "symbol extraction",
            symbol,
            "agent_lab_validate_config",
            "agent_lab_validate_boolean",
        )
        print_evidence("representative symbol extraction", symbol)

        declaration = client.call_tool(
            "find_declaration",
            {
                "relative_path": "scripts/lib/config.sh",
                "regex": (
                    r"\n[ \t]+(agent_lab_validate_boolean)"
                    r"[ \t]+\|\|[ \t]+return[ \t]+1"
                ),
                "include_body": False,
            },
        )
        require_text(
            "definition traversal",
            declaration,
            "agent_lab_validate_boolean",
            "scripts/lib/config.sh",
        )
        print_evidence("definition traversal", declaration)

        references = client.call_tool(
            "find_referencing_symbols",
            {
                "name_path": "agent_lab_validate_boolean",
                "relative_path": "scripts/lib/config.sh",
            },
        )
        require_text(
            "reference traversal",
            references,
            "agent_lab_validate_config",
            "agent_lab_validate_boolean",
        )
        print_evidence("reference traversal", references)

        clean_diagnostics = client.call_tool(
            "get_diagnostics_for_file",
            {
                "relative_path": "scripts/lib/config.sh",
                "min_severity": 4,
            },
        )
        if clean_diagnostics.strip() != "{}":
            raise SmokeFailure(
                "diagnostics: lint-clean scripts/lib/config.sh returned "
                f"unexpected diagnostics:\n{clean_diagnostics}"
            )
        print_evidence("clean Bash diagnostics", clean_diagnostics)

        diagnostics = client.call_tool(
            "get_diagnostics_for_file",
            {
                "relative_path": diagnostics_fixture.name,
                "min_severity": 1,
            },
        )
        require_error_diagnostic_codes(
            "controlled invalid Bash diagnostics",
            diagnostics,
            diagnostics_fixture.name,
            {"SC1072", "SC1073"},
        )
        print_evidence("controlled Bash diagnostics", diagnostics)

        readiness_logs = client.readiness_logs()
        if readiness_logs:
            print_evidence("language-server launch log", readiness_logs)
    except Exception as exc:
        failure_logs = (
            client.failure_logs()
            if client is not None
            else "<Serena MCP process was not started>"
        )
        print(
            f"FAIL Serena smoke ({context}): {exc}\n"
            f"--- last Serena/container stderr ---\n"
            f"{failure_logs}",
            file=sys.stderr,
        )
        raise
    finally:
        try:
            if client is not None:
                client.close()
        finally:
            for fixture_path in cleanup_paths:
                fixture_path.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, required=True)
    args = parser.parse_args()

    repo_root = args.repo_root.resolve(strict=True)
    client_cwd = (repo_root / "tests" / "serena").resolve(strict=True)
    os.chdir(repo_root)

    for index, context in enumerate(("codex", "claude-code", "grok")):
        run_context(
            load_client_registration(repo_root, context),
            context,
            repo_root,
            client_cwd,
            full_semantic_smoke=index == 0,
        )

    print("PASS Serena MCP activation and semantic smoke")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SmokeFailure:
        raise SystemExit(1)
