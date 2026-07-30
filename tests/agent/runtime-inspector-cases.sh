#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
checker="$repo_root/tests/docker/check-runtime-inspect.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

cat > "$work/secure.json" <<'EOF'
[{
  "Config": {"User": "1000:1000", "ExposedPorts": null},
  "HostConfig": {
    "ReadonlyRootfs": true,
    "CapDrop": ["ALL"],
    "CapAdd": null,
    "SecurityOpt": ["no-new-privileges:true"],
    "PidsLimit": 512,
    "Memory": 1073741824,
    "NanoCpus": 1000000000,
    "Privileged": false,
    "Devices": [],
    "DeviceRequests": null,
    "ExtraHosts": null,
    "PortBindings": {},
    "PublishAllPorts": false,
    "Tmpfs": {"/tmp": "", "/home/agent": "mode=1777"},
    "Binds": ["/safe/work:/workspace:rw", "/safe/secrets:/run/agent-secrets:ro"]
  },
  "Mounts": [
    {"Type": "bind", "Source": "/safe/work", "Destination": "/workspace", "RW": true},
    {"Type": "bind", "Source": "/safe/secrets", "Destination": "/run/agent-secrets", "RW": false}
  ],
  "NetworkSettings": {"Ports": {}, "Networks": {"fixture_agents": {}}}
}]
EOF
cat > "$work/process.env" <<'EOF'
uid=1000
gid=1000
cap_eff=0000000000000000
no_new_privs=1
root_mount_opts=ro,relatime
secret_mount_opts=ro,relatime
pids_max=512
memory_max=1073741824
cpu_max=100000 100000
EOF

run_check() {
  "$checker" "$1" ephemeral 1000 1000 fixture "$work/process.env" >/dev/null 2>&1
}

if [ -x "$checker" ] && run_check "$work/secure.json"; then
  pass "secure runtime evidence is accepted"
else
  fail "secure runtime evidence is accepted"
fi

mutate_and_reject() {
  local name="$1" filter="$2" output="$work/mutated.json"
  jq "$filter" "$work/secure.json" > "$output"
  if [ -x "$checker" ] && run_check "$output"; then
    fail "$name"
  else
    pass "$name"
  fi
}

mutate_and_reject "writable-root mutation is detected" '.[0].HostConfig.ReadonlyRootfs=false'
mutate_and_reject "extra-mount mutation is detected" \
  '.[0].Mounts += [{"Type":"volume","Source":"x","Destination":"/opt/extra","RW":true}]'
mutate_and_reject "writable-secret mutation is detected" \
  '(.[0].Mounts[] | select(.Destination=="/run/agent-secrets") | .RW)=true'
mutate_and_reject "added-capability mutation is detected" '.[0].HostConfig.CapAdd=["NET_ADMIN"]'
mutate_and_reject "extra-network mutation is detected" \
  '.[0].NetworkSettings.Networks.fixture_escape={}'
mutate_and_reject "published-port mutation is detected" \
  '.[0].HostConfig.PortBindings={"8080/tcp":[{"HostPort":"49152"}]}'

if [ -f "$repo_root/tests/security/docker.manifest" ] &&
   grep -Fq 'suite runtime-hardening tests/docker/runtime-hardening.sh' \
     "$repo_root/tests/security/docker.manifest"; then
  pass "Docker gate requires direct runtime hardening inspection"
else
  fail "Docker gate requires direct runtime hardening inspection"
fi

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
