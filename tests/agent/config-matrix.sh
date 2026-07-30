#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/secrets"
docker_log="$work/docker.log"

cat > "$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_DOCKER_LOG:?}"
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
  if { [ "$expected" = pass ] && [ "$rc" -eq 0 ]; } ||
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

for value in 64m 1g 4g 64g; do
  expect_shell_value pass "memory limit [$value] is accepted" \
    AGENT_LAB_AGENT_MEM "$value" "PASS preflight"
done
for value in '' 0 63m 65537m 65g 4G 1.5g -1g unlimited; do
  expect_shell_value fail "memory limit [$value] is rejected" \
    AGENT_LAB_AGENT_MEM "$value" "AGENT_LAB_AGENT_MEM"
done

for value in 0.1 1 1.5 2 64; do
  expect_shell_value pass "CPU limit [$value] is accepted" \
    AGENT_LAB_AGENT_CPUS "$value" "PASS preflight"
done
for value in '' 0 0.01 -1 +1 65 1.0000 1. x; do
  expect_shell_value fail "CPU limit [$value] is rejected" \
    AGENT_LAB_AGENT_CPUS "$value" "AGENT_LAB_AGENT_CPUS"
done

expect_env_file() {
  local expected="$1" name="$2" content="$3" marker="$4"
  local file="$work/case.env" rc=0 out
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
  if { [ "$expected" = pass ] && [ "$rc" -eq 0 ]; } ||
     { [ "$expected" = fail ] && [ "$rc" -ne 0 ] &&
       printf '%s\n' "$out" | grep -Fq "$marker"; }; then
    pass "$name"
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
expect_env_file pass "missing final newline is accepted explicitly" \
  'AGENT_LAB_EPHEMERAL_HOME=1' "PASS preflight"
expect_env_file fail "env-file metacharacters remain fail-closed" \
  'AGENT_LAB_EPHEMERAL_HOME=$(touch nope)\n' "shell metacharacters"

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
