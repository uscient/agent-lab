#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$test_dir/lib.sh"
checker="$test_dir/check-runtime-inspect.sh"

trap docker_test_cleanup EXIT
docker_test_init "runtime" || exit $?

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

collect_process_evidence() {
  local container_id="$1" output="$2"
  docker exec "$container_id" sh -c '
    uid=$(id -u)
    gid=$(id -g)
    cap_eff=$(awk "/^CapEff:/ { print \$2 }" /proc/self/status)
    no_new_privs=$(awk "/^NoNewPrivs:/ { print \$2 }" /proc/self/status)
    root_mount_opts=$(awk "\$5 == \"/\" { print \$6; exit }" /proc/self/mountinfo)
    secret_mount_opts=$(awk "\$5 == \"/run/agent-secrets\" { print \$6; exit }" /proc/self/mountinfo)
    if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
      pids_max=$(cat /sys/fs/cgroup/pids.max)
      memory_max=$(cat /sys/fs/cgroup/memory.max)
      cpu_max=$(cat /sys/fs/cgroup/cpu.max)
    else
      pids_max=$(cat /sys/fs/cgroup/pids/pids.max)
      memory_max=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
      cpu_quota=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)
      cpu_period=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
      cpu_max="$cpu_quota $cpu_period"
    fi
    printf "uid=%s\n" "$uid"
    printf "gid=%s\n" "$gid"
    printf "cap_eff=%s\n" "$cap_eff"
    printf "no_new_privs=%s\n" "$no_new_privs"
    printf "root_mount_opts=%s\n" "$root_mount_opts"
    printf "secret_mount_opts=%s\n" "$secret_mount_opts"
    printf "pids_max=%s\n" "$pids_max"
    printf "memory_max=%s\n" "$memory_max"
    printf "cpu_max=%s\n" "$cpu_max"
  ' > "$output"
}

last_inspect=""
last_evidence=""
inspect_mode() {
  local mode="$1" launcher output container_id inspect evidence attempt rc
  output="$LAB_WORK/agent-${mode}.out"
  inspect="$LAB_WORK/inspect-${mode}.json"
  evidence="$LAB_WORK/process-${mode}.env"
  case "$mode" in
    ephemeral) LAB_EPHEMERAL_HOME=1 ;;
    persistent) LAB_EPHEMERAL_HOME=0 ;;
  esac
  export LAB_EPHEMERAL_HOME

  docker_test_agent "base" sh -c \
    'printf "AGENT_READY\n"; while :; do sleep 5; done' >"$output" 2>&1 &
  launcher=$!
  container_id=""
  attempt=0
  while [ "$attempt" -lt 30 ]; do
    container_id="$(
      docker ps -q \
        --filter "label=com.docker.compose.project=${LAB_PROJECT}" \
        --filter "label=com.docker.compose.service=agent"
    )"
    [ -n "$container_id" ] && break
    if ! kill -0 "$launcher" 2>/dev/null; then
      docker_test_infra "agent launcher exited before runtime inspection ($mode)"
      return 125
    fi
    sleep 1
    attempt=$((attempt + 1))
  done
  [ -n "$container_id" ] || {
    docker_test_infra "could not discover one-off agent container ($mode)"
    return 125
  }

  docker inspect "$container_id" > "$inspect"
  collect_process_evidence "$container_id" "$evidence"
  if "$checker" "$inspect" "$mode" "$LAB_AGENT_UID" "$LAB_AGENT_GID" \
       "$LAB_PROJECT" "$evidence"; then
    pass "direct runtime hardening inspection passes for $mode HOME"
  else
    fail "direct runtime hardening inspection passes for $mode HOME"
  fi

  docker stop "$container_id" >/dev/null
  rc=0
  wait "$launcher" || rc=$?
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 137 ] || [ "$rc" -eq 143 ]; then
    :
  else
    fail "agent launcher terminates cleanly after $mode inspection"
  fi
  last_inspect="$inspect"
  last_evidence="$evidence"
}

inspect_mode ephemeral || exit $?
inspect_mode persistent || exit $?

mutation_rejected() {
  local name="$1" filter="$2" mutated="$LAB_WORK/mutation.json"
  jq "$filter" "$last_inspect" > "$mutated"
  if "$checker" "$mutated" persistent "$LAB_AGENT_UID" "$LAB_AGENT_GID" \
       "$LAB_PROJECT" "$last_evidence" >/dev/null 2>&1; then
    fail "$name"
  else
    pass "$name"
  fi
}

mutation_rejected "writable-root sensitivity mutation is detected" \
  '.[0].HostConfig.ReadonlyRootfs=false'
mutation_rejected "extra-volume sensitivity mutation is detected" \
  '.[0].Mounts += [{"Type":"volume","Source":"fixture","Destination":"/opt/extra","RW":true}]'
mutation_rejected "writable-secret sensitivity mutation is detected" \
  '(.[0].Mounts[] | select(.Destination=="/run/agent-secrets") | .RW)=true'
mutation_rejected "root-user sensitivity mutation is detected" '.[0].Config.User="0:0"'
mutation_rejected "capability sensitivity mutation is detected" \
  '.[0].HostConfig.CapAdd=["NET_ADMIN"]'
mutation_rejected "no-new-privileges sensitivity mutation is detected" \
  '.[0].HostConfig.SecurityOpt=[]'
mutation_rejected "unlimited-resource sensitivity mutation is detected" \
  '.[0].HostConfig.PidsLimit=0 | .[0].HostConfig.Memory=0 | .[0].HostConfig.NanoCpus=0'
mutation_rejected "fake Docker-socket bind sensitivity mutation is detected" \
  '.[0].Mounts += [{"Type":"bind","Source":"/tmp/fake-docker.sock","Destination":"/safe/socket","RW":true}]'
mutation_rejected "extra-network sensitivity mutation is detected" \
  '.[0].NetworkSettings.Networks.fixture_escape={}'
mutation_rejected "published-port sensitivity mutation is detected" \
  '.[0].HostConfig.PortBindings={"8080/tcp":[{"HostPort":"49152"}]}'

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
