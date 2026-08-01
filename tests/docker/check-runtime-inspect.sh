#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 6 ]; then
  printf 'Usage: %s INSPECT_JSON persistent|ephemeral UID GID PROJECT PROCESS_EVIDENCE\n' \
    "$0" >&2
  exit 2
fi

inspect="$1"
mode="$2"
expected_uid="$3"
expected_gid="$4"
project="$5"
process_evidence="$6"
failures=0

pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

assert_jq() {
  local name="$1" expression="$2"
  if jq -e \
       --arg user "${expected_uid}:${expected_gid}" \
       --arg network "${project}_agents" \
       "$expression" "$inspect" >/dev/null; then
    pass "$name"
  else
    fail "$name"
  fi
}

evidence() {
  sed -n "s/^$1=//p" "$process_evidence" | tail -n 1
}

has_mount_option() {
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

backend="${AGENT_LAB_RUNTIME_INSPECT_BACKEND:-bash}"
case "$backend" in
  bash) ;;
  python)
    helper="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/check-runtime-inspect.py"
    command -v python3 >/dev/null 2>&1 || {
      printf 'INFRA runtime-inspect Python helper requires python3\n' >&2
      exit 125
    }
    [ -r "$helper" ] || {
      printf 'INFRA runtime-inspect Python helper is unavailable\n' >&2
      exit 125
    }
    helper_rc=0
    python3 -I "$helper" \
      "$inspect" "$mode" "$expected_uid" "$expected_gid" "$project" ||
      helper_rc=$?
    case "$helper_rc" in
      64)
        backend=bash
        ;;
      80|81|82|83|84|85|86|87|88|89|90|91|92)
        failures=$((helper_rc - 80))
        ;;
      *)
        printf 'INFRA runtime-inspect Python helper failed (status %s)\n' \
          "$helper_rc" >&2
        exit 125
        ;;
    esac
    ;;
  *)
    printf 'FAIL unknown runtime-inspect backend: %s\n' "$backend" >&2
    exit 2
    ;;
esac

if [ "$backend" = bash ]; then
assert_jq "root filesystem is structurally read-only" \
  'length == 1 and .[0].HostConfig.ReadonlyRootfs == true'
assert_jq "configured user is the exact numeric UID:GID" \
  '.[0].Config.User == $user'
assert_jq "all capabilities are dropped and none are added" \
  '((.[0].HostConfig.CapDrop // []) | index("ALL")) != null and
   ((.[0].HostConfig.CapAdd // []) | length) == 0'
assert_jq "no-new-privileges is configured" \
  '((.[0].HostConfig.SecurityOpt // []) | index("no-new-privileges:true")) != null'
assert_jq "PID, memory, and CPU limits are exact" \
  '.[0].HostConfig.PidsLimit == 512 and
   .[0].HostConfig.Memory == 1073741824 and
   .[0].HostConfig.NanoCpus == 1000000000'
assert_jq "privilege, device, and extra-host surfaces are empty" \
  '.[0].HostConfig.Privileged == false and
   ((.[0].HostConfig.Devices // []) | length) == 0 and
   ((.[0].HostConfig.DeviceRequests // []) | length) == 0 and
   ((.[0].HostConfig.DeviceCgroupRules // []) | length) == 0 and
   ((.[0].HostConfig.ExtraHosts // []) | length) == 0'
assert_jq "no host ports are published or exposed" \
  '((.[0].HostConfig.PortBindings // {}) | length) == 0 and
   .[0].HostConfig.PublishAllPorts == false and
   ((.[0].Config.ExposedPorts // {}) | length) == 0 and
   ((.[0].NetworkSettings.Ports // {}) |
      all(.[]; . == null or length == 0))'
assert_jq "agent is attached only to its project-scoped internal network" \
  '((.[0].NetworkSettings.Networks | keys) == [$network])'
assert_jq "Docker socket is absent from every configured mount" \
  'all(.[0].Mounts[]?;
      ((.Source // "") | contains("docker.sock") | not) and
      ((.Destination // "") | contains("docker.sock") | not)) and
   all(.[0].HostConfig.Binds[]?;
      contains("docker.sock") | not)'

mount_targets="$(jq -r '.[0].Mounts[].Destination' "$inspect" | sort)"
tmpfs_targets="$(jq -r '.[0].HostConfig.Tmpfs // {} | keys[]' "$inspect" | sort)"
case "$mode" in
  ephemeral)
    expected_mounts=$'/run/agent-secrets\n/workspace'
    expected_tmpfs=$'/home/agent\n/tmp'
    ;;
  persistent)
    expected_mounts=$'/home/agent\n/run/agent-secrets\n/workspace'
    expected_tmpfs='/tmp'
    ;;
  *)
    printf 'FAIL unknown HOME mode: %s\n' "$mode" >&2
    exit 2
    ;;
esac
if [ "$mount_targets" = "$expected_mounts" ] &&
   [ "$tmpfs_targets" = "$expected_tmpfs" ]; then
  pass "user-controlled mounts and tmpfs targets are exact for $mode HOME"
else
  fail "user-controlled mounts and tmpfs targets are exact for $mode HOME"
fi

assert_jq "workspace is read-write and secrets are read-only" \
  'any(.[0].Mounts[];
      .Destination == "/workspace" and .RW == true) and
   any(.[0].Mounts[];
      .Destination == "/run/agent-secrets" and .RW == false)'
if [ "$mode" = persistent ]; then
  assert_jq "persistent HOME is a read-write named volume" \
    'any(.[0].Mounts[];
        .Destination == "/home/agent" and .Type == "volume" and .RW == true)'
fi
fi

runtime_uid="$(evidence uid)"
runtime_gid="$(evidence gid)"
cap_eff="$(evidence cap_eff)"
no_new_privs="$(evidence no_new_privs)"
root_mount_opts="$(evidence root_mount_opts)"
secret_mount_opts="$(evidence secret_mount_opts)"
pids_max="$(evidence pids_max)"
memory_max="$(evidence memory_max)"
cpu_max="$(evidence cpu_max)"

if [ "$runtime_uid" = "$expected_uid" ] && [ "$runtime_gid" = "$expected_gid" ]; then
  pass "in-process UID and GID match the configured numeric identity"
else
  fail "in-process UID and GID match the configured numeric identity"
fi
if printf '%s\n' "$cap_eff" | grep -Eq '^0+$' && [ "$no_new_privs" = 1 ]; then
  pass "in-process CapEff is zero and NoNewPrivs is one"
else
  fail "in-process CapEff is zero and NoNewPrivs is one"
fi
if has_mount_option "$root_mount_opts" ro &&
   has_mount_option "$secret_mount_opts" ro; then
  pass "mountinfo reports read-only root and secret mounts"
else
  fail "mountinfo reports read-only root and secret mounts"
fi
if [ "$pids_max" = 512 ] && [ "$memory_max" = 1073741824 ]; then
  pass "in-process cgroup PID and memory limits are exact"
else
  fail "in-process cgroup PID and memory limits are exact"
fi
read -r cpu_quota cpu_period <<< "$cpu_max"
if [ "$cpu_quota" != max ] &&
   [ -n "$cpu_quota" ] &&
   [ "$cpu_quota" = "$cpu_period" ]; then
  pass "in-process cgroup CPU quota is exactly one CPU"
else
  fail "in-process cgroup CPU quota is exactly one CPU"
fi

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
