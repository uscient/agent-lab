#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/home" "$work/secrets"
docker_log="$work/docker.log"

cat > "$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_DOCKER_LOG:?}"
printf 'ENV mem=%s image=%s project_dir=%s\n' \
  "${AGENT_LAB_AGENT_MEM-<unset>}" \
  "${AGENT_LAB_AGENT_IMAGE-<unset>}" \
  "${AGENT_LAB_PROJECT_DIR-<unset>}" >> "${FAKE_DOCKER_LOG:?}"
exit 99
EOF
chmod +x "$work/bin/docker"

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

run_check() {
  local env_file="$1"
  shift
  : > "$docker_log"
  env -i \
    PATH="$work/bin:/usr/bin:/bin" \
    HOME="$work/home" \
    FAKE_DOCKER_LOG="$docker_log" \
    AGENT_LAB_ENV_FILE="$env_file" \
    AGENT_LAB_PROJECT_DIR="" \
    AGENT_LAB_SECRETS_DIR="$work/secrets" \
    AGENT_LAB_AGENT_IMAGE="fixture:test" \
    AGENT_LAB_ALLOWLIST_RECIPES="base" \
    AGENT_LAB_EPHEMERAL_HOME="1" \
    AGENT_LAB_AGENT_UID="1000" \
    AGENT_LAB_AGENT_GID="1000" \
    AGENT_LAB_AGENT_MEM="1g" \
    AGENT_LAB_AGENT_CPUS="1" \
    "$@" "$repo_root/scripts/agent" --check
}

empty_env="$work/empty.env"
: > "$empty_env"

expect_shell_value() {
  local expected="$1" name="$2" key="$3" value="$4" marker="$5"
  local rc=0 out
  out="$(run_check "$empty_env" "env" "$key=$value" 2>&1)" || rc=$?
  if { [ "$expected" = pass ] && [ "$rc" -eq 0 ] &&
       printf '%s\n' "$out" | grep -Fq "$marker"; } ||
     { [ "$expected" = fail ] && [ "$rc" -ne 0 ] &&
       printf '%s\n' "$out" | grep -Fq "$marker"; }; then
    if [ ! -s "$docker_log" ]; then
      pass "$name"
    else
      fail "$name (Docker was reached)"
    fi
  else
    fail "$name (rc=$rc)"
  fi
}

expect_shell_value pass "boolean 0 is accepted" AGENT_LAB_EPHEMERAL_HOME 0 \
  "EFFECTIVE AGENT_LAB_EPHEMERAL_HOME=0"
expect_shell_value pass "boolean 1 is accepted" AGENT_LAB_EPHEMERAL_HOME 1 \
  "EFFECTIVE AGENT_LAB_EPHEMERAL_HOME=1"
for value in true 2 ' 1' '"1"'; do
  expect_shell_value fail "malformed boolean [$value] is rejected" \
    AGENT_LAB_EPHEMERAL_HOME "$value" "AGENT_LAB_EPHEMERAL_HOME"
done
expect_shell_value fail "explicitly empty boolean is rejected" \
  AGENT_LAB_EPHEMERAL_HOME "" "AGENT_LAB_EPHEMERAL_HOME"

for value in 1 1000 2147483647; do
  expect_shell_value pass "canonical UID [$value] is accepted" \
    AGENT_LAB_AGENT_UID "$value" "EFFECTIVE AGENT_LAB_AGENT_UID=$value"
done
for value in 0 -1 +1 01 ' 1' 2147483648 999999999999999999999 x; do
  expect_shell_value fail "malformed UID [$value] is rejected" \
    AGENT_LAB_AGENT_UID "$value" "AGENT_LAB_AGENT_UID"
done
for value in 0 -1 +1 01 '1 ' 2147483648 x; do
  expect_shell_value fail "malformed GID [$value] is rejected" \
    AGENT_LAB_AGENT_GID "$value" "AGENT_LAB_AGENT_GID"
done
for value in 1 1000 2147483647; do
  expect_shell_value pass "canonical GID [$value] is accepted" \
    AGENT_LAB_AGENT_GID "$value" "EFFECTIVE AGENT_LAB_AGENT_GID=$value"
done

for value in 64m 1g 4g 64g; do
  expect_shell_value pass "memory limit [$value] is accepted" \
    AGENT_LAB_AGENT_MEM "$value" "EFFECTIVE AGENT_LAB_AGENT_MEM=$value"
done
expect_shell_value pass "maximum MiB memory limit is accepted" \
  AGENT_LAB_AGENT_MEM 65536m "EFFECTIVE AGENT_LAB_AGENT_MEM=65536m"
for value in '' 0 63m 65537m 65g 4G 1.5g -1g unlimited; do
  expect_shell_value fail "memory limit [$value] is rejected" \
    AGENT_LAB_AGENT_MEM "$value" "AGENT_LAB_AGENT_MEM"
done

for value in 0.1 1 1.5 2 64; do
  expect_shell_value pass "CPU limit [$value] is accepted" \
    AGENT_LAB_AGENT_CPUS "$value" "EFFECTIVE AGENT_LAB_AGENT_CPUS=$value"
done
for value in '' 0 0.01 0.10 -1 +1 65 1.0 1.00 1.000 1.0000 64.000 1. x; do
  expect_shell_value fail "CPU limit [$value] is rejected" \
    AGENT_LAB_AGENT_CPUS "$value" "AGENT_LAB_AGENT_CPUS"
done

expect_env_file() {
  local expected="$1" name="$2" content="$3" marker="$4"
  local file="$work/case.env" rc=0 out
  : > "$docker_log"
  printf '%b' "$content" > "$file"
  out="$(
    env -i \
      PATH="$work/bin:/usr/bin:/bin" \
      HOME="$work/home" \
      FAKE_DOCKER_LOG="$docker_log" \
      AGENT_LAB_ENV_FILE="$file" \
      AGENT_LAB_PROJECT_DIR="" \
      AGENT_LAB_SECRETS_DIR="$work/secrets" \
      AGENT_LAB_AGENT_IMAGE="fixture:test" \
      AGENT_LAB_ALLOWLIST_RECIPES="base" \
      AGENT_LAB_AGENT_UID="1000" \
      AGENT_LAB_AGENT_GID="1000" \
      AGENT_LAB_AGENT_MEM="1g" \
      AGENT_LAB_AGENT_CPUS="1" \
      "$repo_root/scripts/agent" --check 2>&1
  )" || rc=$?
  if { [ "$expected" = pass ] && [ "$rc" -eq 0 ] &&
       printf '%s\n' "$out" | grep -Fq "$marker"; } ||
     { [ "$expected" = fail ] && [ "$rc" -ne 0 ] &&
       printf '%s\n' "$out" | grep -Fq "$marker"; }; then
    if [ ! -s "$docker_log" ]; then
      pass "$name"
    else
      fail "$name (Docker was reached)"
    fi
  else
    fail "$name (rc=$rc)"
  fi
}

expect_env_file fail "duplicate env-file assignments are rejected" \
  'AGENT_LAB_EPHEMERAL_HOME=0\nAGENT_LAB_EPHEMERAL_HOME=1\n' "duplicate"
expect_env_file fail "quoted env-file values are rejected" \
  'AGENT_LAB_EPHEMERAL_HOME="1"\n' "AGENT_LAB_EPHEMERAL_HOME"
expect_env_file fail "whitespace around env-file keys is rejected" \
  ' AGENT_LAB_EPHEMERAL_HOME=1\n' "malformed"
expect_env_file fail "whitespace around env-file equals is rejected" \
  'AGENT_LAB_EPHEMERAL_HOME =1\n' "malformed"
expect_env_file fail "inline comments are rejected" \
  'AGENT_LAB_EPHEMERAL_HOME=1 # ambiguous\n' "AGENT_LAB_EPHEMERAL_HOME"
expect_env_file fail "CRLF assignments are rejected" \
  'AGENT_LAB_EPHEMERAL_HOME=1\r\n' "carriage return"
expect_env_file fail "CRLF comments are rejected" \
  '# comment\r\nAGENT_LAB_EPHEMERAL_HOME=1\n' "carriage return"
expect_env_file fail "NUL bytes cannot disappear during parsing" \
  'AGENT_LAB_EPHEMERAL_\0HOME=1\n' "NUL byte"
expect_env_file pass "missing final newline is accepted explicitly" \
  'AGENT_LAB_EPHEMERAL_HOME=1' "PASS preflight"
expect_env_file fail "env-file metacharacters remain fail-closed" \
  'AGENT_LAB_EPHEMERAL_HOME=$(touch nope)\n' "shell metacharacters"

expect_env_file pass "blank lines and column-one comments are accepted" \
  '# comment\n\nAGENT_LAB_EPHEMERAL_HOME=1\n' "EFFECTIVE AGENT_LAB_EPHEMERAL_HOME=1"
expect_env_file fail "export syntax is explicitly rejected" \
  'export AGENT_LAB_EPHEMERAL_HOME=1\n' "malformed"
expect_env_file fail "unsupported env-file keys are rejected" \
  'UNVALIDATED_SECURITY_SEAM=value\n' "unsupported env-file key"
expect_env_file pass "tracked legacy direct-policy default is safely ignored" \
  'AGENT_LAB_EGRESS_ALLOWLIST=./policies/egress.allowlist.example\n' "PASS preflight"
expect_env_file fail "arbitrary direct-policy overrides are rejected" \
  'AGENT_LAB_EGRESS_ALLOWLIST=/tmp/unvalidated.allowlist\n' \
  "AGENT_LAB_EGRESS_ALLOWLIST"

# Shell-set values, including explicit invalid empties, take precedence over file values.
precedence_env="$work/precedence.env"
printf 'AGENT_LAB_EPHEMERAL_HOME=0\n' > "$precedence_env"
rc=0
out="$(run_check "$precedence_env" env AGENT_LAB_EPHEMERAL_HOME=1 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] &&
   printf '%s\n' "$out" | grep -Fq "EFFECTIVE AGENT_LAB_EPHEMERAL_HOME=1" &&
   [ ! -s "$docker_log" ]; then
  pass "shell value takes exact precedence over env-file value"
else
  fail "shell value takes exact precedence over env-file value"
fi
rc=0
out="$(run_check "$precedence_env" env AGENT_LAB_EPHEMERAL_HOME= 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] &&
   printf '%s\n' "$out" | grep -Fq "AGENT_LAB_EPHEMERAL_HOME" &&
   [ ! -s "$docker_log" ]; then
  pass "explicitly empty shell value does not fall back to a valid file value"
else
  fail "explicitly empty shell value does not fall back to a valid file value"
fi

# A malformed env file remains fatal even when the shell shadows the affected key.
printf 'AGENT_LAB_EPHEMERAL_HOME=0\nAGENT_LAB_EPHEMERAL_HOME=1\n' > "$precedence_env"
rc=0
out="$(run_check "$precedence_env" env AGENT_LAB_EPHEMERAL_HOME=1 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -Fq "duplicate" &&
   [ ! -s "$docker_log" ]; then
  pass "shell precedence cannot hide malformed duplicate file state"
else
  fail "shell precedence cannot hide malformed duplicate file state"
fi

# Remaining Compose-consumed security inputs are schema checked too.
expect_shell_value fail "non-network CIDR is rejected" \
  AGENT_LAB_AGENTS_SUBNET 172.30.0.1/24 "AGENT_LAB_AGENTS_SUBNET"
expect_shell_value fail "DNS outside the agent subnet is rejected" \
  AGENT_LAB_DNS_IP 172.31.0.10 "inside AGENT_LAB_AGENTS_SUBNET"
expect_shell_value fail "IPv4 trailing-dot spelling is rejected" \
  AGENT_LAB_DNS_IP 172.30.0.10. "AGENT_LAB_DNS_IP"
expect_shell_value fail "proxy port differing from Squid is rejected" \
  AGENT_LAB_PROXY_PORT 8080 "AGENT_LAB_PROXY_PORT"
expect_shell_value fail "external HTTP proxy override is rejected" \
  HTTP_PROXY http://proxy.example:3128 "validated lab proxy"
expect_shell_value fail "broad NO_PROXY override is rejected" \
  NO_PROXY '*' "NO_PROXY"
expect_shell_value fail "suffix form is not a valid positive-control hostname" \
  AGENT_LAB_ALLOWED_TEST_DOMAIN .example.com "hostname, not a suffix"
expect_shell_value fail "loopback is not a valid direct-test target" \
  AGENT_LAB_DIRECT_TEST_IP 127.0.0.1 "usable non-local host"
expect_shell_value fail "option-like image reference is rejected" \
  AGENT_LAB_AGENT_IMAGE --pull "AGENT_LAB_AGENT_IMAGE"
colon_project="$work/project:ambiguous"
mkdir "$colon_project"
expect_shell_value fail "colon-bearing project paths are rejected before Compose" \
  AGENT_LAB_PROJECT_DIR "$colon_project" "ambiguous in a Compose short mount"
expect_shell_value fail "control-bearing mount paths are rejected" \
  AGENT_LAB_SECRETS_DIR $'/tmp/secret\a' "control characters"
expect_shell_value fail "explicitly empty image does not select an implicit default" \
  AGENT_LAB_AGENT_IMAGE "" "AGENT_LAB_AGENT_IMAGE"
for value in /repo repo/ repo: repo@ repo@@x UPPER/repo a//b . .. \
             registry.example:70000/repo repo@sha256:abc; do
  expect_shell_value fail "malformed image reference [$value] is rejected" \
    AGENT_LAB_AGENT_IMAGE "$value" "AGENT_LAB_AGENT_IMAGE"
done
valid_digest="repo@sha256:$(printf '%064d' 0)"
expect_shell_value pass "canonical image digest is accepted" \
  AGENT_LAB_AGENT_IMAGE "$valid_digest" \
  "EFFECTIVE AGENT_LAB_AGENT_IMAGE=$valid_digest"

# With no image in either source, the documented local devbox is the exact effective value.
: > "$docker_log"
rc=0
out="$(
  env -i \
    PATH="$work/bin:/usr/bin:/bin" \
    HOME="$work/home" \
    FAKE_DOCKER_LOG="$docker_log" \
    AGENT_LAB_ENV_FILE="$empty_env" \
    AGENT_LAB_PROJECT_DIR="" \
    AGENT_LAB_SECRETS_DIR="$work/secrets" \
    AGENT_LAB_ALLOWLIST_RECIPES="base" \
    AGENT_LAB_EPHEMERAL_HOME="1" \
    AGENT_LAB_AGENT_UID="1000" \
    AGENT_LAB_AGENT_GID="1000" \
    AGENT_LAB_AGENT_MEM="1g" \
    AGENT_LAB_AGENT_CPUS="1" \
    "$repo_root/scripts/agent" --check 2>&1
)" || rc=$?
if [ "$rc" -eq 0 ] &&
   printf '%s\n' "$out" |
     grep -Fq "EFFECTIVE AGENT_LAB_AGENT_IMAGE=agent-lab/devbox:local" &&
   [ ! -s "$docker_log" ]; then
  pass "absent image resolves to the explicit local devbox default"
else
  fail "absent image resolves to the explicit local devbox default"
fi

# Metacharacter payloads are treated as bytes and never executed.
payload_marker="$work/must-not-exist"
payload_env="$work/payload.env"
printf 'AGENT_LAB_EPHEMERAL_HOME=$(touch %s)\n' "$payload_marker" > "$payload_env"
rc=0
run_check "$payload_env" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$payload_marker" ] && [ ! -s "$docker_log" ]; then
  pass "rejected env-file metacharacters are never executed"
else
  fail "rejected env-file metacharacters are never executed"
fi

# Normal-run sensitivity: a valid plan reaches the Docker spy, while malformed config
# fails before the exact same invocation can perform any Docker operation.
: > "$docker_log"
rc=0
env -i \
  PATH="$work/bin:/usr/bin:/bin" \
  HOME="$work/home" \
  FAKE_DOCKER_LOG="$docker_log" \
  AGENT_LAB_ENV_FILE="$empty_env" \
  AGENT_LAB_PROJECT_DIR="" \
  AGENT_LAB_SECRETS_DIR="$work/secrets" \
  AGENT_LAB_AGENT_IMAGE="fixture:test" \
  AGENT_LAB_ALLOWLIST_RECIPES="base" \
  AGENT_LAB_EPHEMERAL_HOME="1" \
  AGENT_LAB_AGENT_UID="1000" \
  AGENT_LAB_AGENT_GID="1000" \
  AGENT_LAB_AGENT_MEM="1g" \
  AGENT_LAB_AGENT_CPUS="1" \
  "$repo_root/scripts/agent" -- true >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 99 ] && [ -s "$docker_log" ]; then
  pass "valid normal-run configuration reaches the Docker spy"
else
  fail "valid normal-run configuration reaches the Docker spy"
fi

: > "$docker_log"
rc=0
env -i \
  PATH="$work/bin:/usr/bin:/bin" \
  HOME="$work/home" \
  FAKE_DOCKER_LOG="$docker_log" \
  AGENT_LAB_ENV_FILE="$empty_env" \
  AGENT_LAB_PROJECT_DIR="" \
  AGENT_LAB_SECRETS_DIR="$work/secrets" \
  AGENT_LAB_AGENT_IMAGE="fixture:test" \
  AGENT_LAB_ALLOWLIST_RECIPES="base" \
  AGENT_LAB_EPHEMERAL_HOME="true" \
  AGENT_LAB_AGENT_UID="1000" \
  AGENT_LAB_AGENT_GID="1000" \
  AGENT_LAB_AGENT_MEM="1g" \
  AGENT_LAB_AGENT_CPUS="1" \
  "$repo_root/scripts/agent" -- true >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 1 ] && [ ! -s "$docker_log" ]; then
  pass "malformed normal-run configuration is rejected before Docker"
else
  fail "malformed normal-run configuration is rejected before Docker"
fi

# Teardown deliberately ignores malformed run configuration and still reaches only the
# scoped Compose down operation with safe interpolation defaults.
: > "$docker_log"
rc=0
env -i \
  PATH="$work/bin:/usr/bin:/bin" \
  HOME="$work/home" \
  FAKE_DOCKER_LOG="$docker_log" \
  AGENT_LAB_AGENT_MEM="not-a-limit" \
  AGENT_LAB_AGENT_IMAGE="--hostile-option" \
  AGENT_LAB_PROJECT_DIR='$HOME' \
  "$repo_root/scripts/agent" down >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 99 ] &&
   grep -Fq "compose --project-name agent-lab --env-file /dev/null" "$docker_log" &&
   grep -Fq "down" "$docker_log" &&
   grep -Fq "ENV mem=<unset> image=<unset> project_dir=<unset>" "$docker_log"; then
  pass "teardown ignores malformed run config and uses safe Compose interpolation"
else
  fail "teardown ignores malformed run config and uses safe Compose interpolation"
fi

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
