#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
checker="$repo_root/tests/docker/check-runtime-inspect.sh"
helper="$repo_root/tests/docker/check-runtime-inspect.py"
work="$(mktemp -d)"
cleanup() { find "$work" -xdev -depth -delete >/dev/null 2>&1 || true; }
trap cleanup EXIT

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

cat > "$work/secure-ephemeral.json" <<'EOF'
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
    "DeviceCgroupRules": null,
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

jq \
  '.[0].HostConfig.Tmpfs = {"/tmp":""} |
   .[0].Mounts += [{"Type":"volume","Source":"fixture-home","Destination":"/home/agent","RW":true}]' \
  "$work/secure-ephemeral.json" > "$work/secure-persistent.json"
jq '.[0].HostConfig.ReadonlyRootfs = false' \
  "$work/secure-ephemeral.json" > "$work/writable-root.json"
jq \
  '.[0].HostConfig.ReadonlyRootfs = false |
   .[0].HostConfig.CapAdd = ["NET_ADMIN"] |
   .[0].NetworkSettings.Networks.fixture_escape = {}' \
  "$work/secure-ephemeral.json" > "$work/compound-mutation.json"
jq \
  '.[0].Mounts += [{"Type":"volume","Source":"fixture","Destination":"/opt/extra","RW":true}]' \
  "$work/secure-ephemeral.json" > "$work/extra-mount.json"
jq \
  '.[0].Mounts += [{"Type":"bind","Source":"/tmp/docker.sock","Destination":"/safe/socket","RW":true}]' \
  "$work/secure-ephemeral.json" > "$work/docker-socket.json"
jq '.[0].Config.User = "0:0"' \
  "$work/secure-ephemeral.json" > "$work/root-user.json"
jq '.[0].Mounts = "not-an-array"' \
  "$work/secure-ephemeral.json" > "$work/malformed-mounts.json"
jq '.[0].HostConfig.Binds = 0' \
  "$work/secure-ephemeral.json" > "$work/numeric-binds.json"
jq '.[0].HostConfig.Tmpfs = 0' \
  "$work/secure-ephemeral.json" > "$work/numeric-tmpfs.json"
jq '.[0].NetworkSettings.Ports = 0' \
  "$work/secure-ephemeral.json" > "$work/numeric-ports.json"
jq '.[0]' "$work/secure-ephemeral.json" > "$work/malformed-top-level.json"
printf '%s' '{"broken":' > "$work/malformed-syntax.json"
: > "$work/empty.json"
printf -v huge_integer '%*s' 5000 ''
huge_integer="${huge_integer// /1}"
sed "s/\"PidsLimit\": 512/\"PidsLimit\": $huge_integer/" \
  "$work/secure-ephemeral.json" > "$work/huge-integer.json"
sed 's/^cap_eff=.*/cap_eff=0000000000002000/' \
  "$work/process.env" > "$work/mutated-process.env"

run_backend() {
  local backend="$1" case_id="$2" inspect="$3" mode="$4" evidence="$5"
  local prefix="$work/$case_id.$backend" rc=0
  AGENT_LAB_RUNTIME_INSPECT_BACKEND="$backend" \
    "$checker" "$inspect" "$mode" 1000 1000 fixture "$evidence" \
      > "$prefix.stdout" 2> "$prefix.stderr" || rc=$?
  printf '%s\n' "$rc" > "$prefix.status"
}

compare_case() {
  local case_id="$1" expected_rc="$2" inspect="$3" mode="$4" evidence="$5"
  local bash_rc python_rc
  run_backend bash "$case_id" "$inspect" "$mode" "$evidence"
  run_backend python "$case_id" "$inspect" "$mode" "$evidence"
  read -r bash_rc < "$work/$case_id.bash.status"
  read -r python_rc < "$work/$case_id.python.status"

  if [ "$bash_rc" -eq "$expected_rc" ] &&
     [ "$python_rc" -eq "$expected_rc" ] &&
     cmp -s "$work/$case_id.bash.stdout" "$work/$case_id.python.stdout" &&
     cmp -s "$work/$case_id.bash.stderr" "$work/$case_id.python.stderr"; then
    pass "Bash/Python runtime-inspect parity: $case_id"
  else
    fail "Bash/Python runtime-inspect parity: $case_id (bash=$bash_rc python=$python_rc expected=$expected_rc)"
    diff -u "$work/$case_id.bash.stdout" "$work/$case_id.python.stdout" || true
    diff -u "$work/$case_id.bash.stderr" "$work/$case_id.python.stderr" || true
  fi
}

if [ -x "$helper" ]; then
  pass "runtime-inspect Python helper is executable"
else
  fail "runtime-inspect Python helper is executable"
fi

compare_case secure-ephemeral 0 \
  "$work/secure-ephemeral.json" ephemeral "$work/process.env"
compare_case secure-persistent 0 \
  "$work/secure-persistent.json" persistent "$work/process.env"
compare_case writable-root 1 \
  "$work/writable-root.json" ephemeral "$work/process.env"
compare_case compound-mutation 1 \
  "$work/compound-mutation.json" ephemeral "$work/process.env"
compare_case extra-mount 1 \
  "$work/extra-mount.json" ephemeral "$work/process.env"
compare_case docker-socket 1 \
  "$work/docker-socket.json" ephemeral "$work/process.env"
compare_case root-user 1 \
  "$work/root-user.json" ephemeral "$work/process.env"
compare_case mutated-process 1 \
  "$work/secure-ephemeral.json" ephemeral "$work/mutated-process.env"
compare_case empty-inspect 1 \
  "$work/empty.json" ephemeral "$work/process.env"
compare_case malformed-syntax 5 \
  "$work/malformed-syntax.json" ephemeral "$work/process.env"
compare_case malformed-top-level 5 \
  "$work/malformed-top-level.json" ephemeral "$work/process.env"
compare_case malformed-mounts 5 \
  "$work/malformed-mounts.json" ephemeral "$work/process.env"
compare_case huge-integer 1 \
  "$work/huge-integer.json" ephemeral "$work/process.env"
compare_case numeric-binds 0 \
  "$work/numeric-binds.json" ephemeral "$work/process.env"
compare_case numeric-tmpfs 5 \
  "$work/numeric-tmpfs.json" ephemeral "$work/process.env"
compare_case numeric-ports 1 \
  "$work/numeric-ports.json" ephemeral "$work/process.env"

cat > "$work/reset-backend.bash-env" <<'EOF'
export AGENT_LAB_RUNTIME_INSPECT_BACKEND=python
EOF
bash_env_rc=0
BASH_ENV="$work/reset-backend.bash-env" \
  AGENT_LAB_RUNTIME_INSPECT_BACKEND=python \
  timeout 3s "$checker" "$work/malformed-syntax.json" ephemeral \
    1000 1000 fixture "$work/process.env" \
    > "$work/bash-env.stdout" 2> "$work/bash-env.stderr" || bash_env_rc=$?
if [ "$bash_env_rc" -eq 5 ] \
  && cmp -s "$work/malformed-syntax.bash.stdout" "$work/bash-env.stdout" \
  && cmp -s "$work/malformed-syntax.bash.stderr" "$work/bash-env.stderr"; then
  pass "malformed fallback cannot recurse through inherited BASH_ENV"
else
  fail "malformed fallback cannot recurse through inherited BASH_ENV (rc=$bash_env_rc)"
fi

default_rc=0
(
  unset AGENT_LAB_RUNTIME_INSPECT_BACKEND
  "$checker" "$work/secure-ephemeral.json" ephemeral 1000 1000 fixture \
    "$work/process.env"
) > "$work/default.stdout" 2> "$work/default.stderr" || default_rc=$?
if [ "$default_rc" -eq 0 ] &&
   cmp -s "$work/secure-ephemeral.bash.stdout" "$work/default.stdout" &&
   cmp -s "$work/secure-ephemeral.bash.stderr" "$work/default.stderr"; then
  pass "stable runtime-inspect entrypoint defaults to the Bash oracle"
else
  fail "stable runtime-inspect entrypoint defaults to the Bash oracle"
fi

no_python_bin="$work/no-python-bin"
mkdir -p "$no_python_bin"
cat > "$no_python_bin/python3" <<'EOF'
#!/usr/bin/env bash
exit 97
EOF
chmod +x "$no_python_bin/python3"
default_no_python_rc=0
(
  unset AGENT_LAB_RUNTIME_INSPECT_BACKEND
  PATH="$no_python_bin:$PATH" \
    "$checker" "$work/secure-ephemeral.json" ephemeral 1000 1000 fixture \
      "$work/process.env"
) > "$work/default-no-python.stdout" \
  2> "$work/default-no-python.stderr" || default_no_python_rc=$?
if [ "$default_no_python_rc" -eq 0 ] &&
   cmp -s "$work/secure-ephemeral.bash.stdout" \
     "$work/default-no-python.stdout" &&
   cmp -s "$work/secure-ephemeral.bash.stderr" \
     "$work/default-no-python.stderr"; then
  pass "default Bash runtime-inspect path requires no Python"
else
  fail "default Bash runtime-inspect path requires no Python"
fi

fake_bin="$work/fake-bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/jq" <<'EOF'
#!/usr/bin/env bash
exit 97
EOF
chmod +x "$fake_bin/jq"
python_no_jq_rc=0
PATH="$fake_bin:$PATH" AGENT_LAB_RUNTIME_INSPECT_BACKEND=python \
  "$checker" "$work/secure-ephemeral.json" ephemeral 1000 1000 fixture \
    "$work/process.env" > "$work/python-no-jq.stdout" \
    2> "$work/python-no-jq.stderr" || python_no_jq_rc=$?
if [ "$python_no_jq_rc" -eq 0 ] &&
   cmp -s "$work/secure-ephemeral.bash.stdout" "$work/python-no-jq.stdout" &&
   cmp -s "$work/secure-ephemeral.bash.stderr" "$work/python-no-jq.stderr"; then
  pass "Python backend owns supported inspect assertions without jq"
else
  fail "Python backend owns supported inspect assertions without jq"
fi

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
