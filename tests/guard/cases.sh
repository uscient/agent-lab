#!/usr/bin/env bash
set -euo pipefail

# Unit test for scripts/lib/guard.sh: a table of project-dir paths -> expected PASS/FAIL.
# Pure shell; no Docker daemon required. Run: bash tests/guard/cases.sh

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
# shellcheck source=scripts/lib/guard.sh
source "$repo_root/scripts/lib/guard.sh"

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

# expect_guard <pass|fail> <name> <dir-arg>
expect_guard() {
  local expected="$1" name="$2" arg="$3" rc=0
  agent_lab_guard_project_dir "$arg" >/dev/null 2>&1 || rc=$?
  if [ "$expected" = pass ]; then
    if [ "$rc" -eq 0 ]; then pass "$name"; else fail "$name (expected PASS, got rc=$rc)"; fi
  else
    if [ "$rc" -ne 0 ]; then pass "$name"; else fail "$name (expected FAIL, got rc=0)"; fi
  fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export HOME="$work/home"
mkdir -p "$HOME"

clean="$work/clean";            mkdir -p "$clean"
with_ssh="$work/with_ssh";      mkdir -p "$with_ssh/.ssh"
npmrc_tok="$work/npmrc_tok";    mkdir -p "$npmrc_tok"; printf '//registry.npmjs.org/:_authToken=deadbeef\n' > "$npmrc_tok/.npmrc"
npmrc_plain="$work/npmrc_plain"; mkdir -p "$npmrc_plain"; printf 'registry=https://registry.npmjs.org/\n' > "$npmrc_plain/.npmrc"

expect_guard pass "empty arg -> PASS (ephemeral workspace)"   ""
expect_guard fail "filesystem root -> FAIL"                   "/"
expect_guard fail "HOME -> FAIL"                              "$HOME"
expect_guard fail "nonexistent dir -> FAIL"                   "$work/does-not-exist"
expect_guard fail ".ssh present -> FAIL"                      "$with_ssh"
expect_guard fail ".npmrc with _authToken -> FAIL"           "$npmrc_tok"
expect_guard pass ".npmrc without token -> PASS (with WARN)"  "$npmrc_plain"
expect_guard pass "clean project dir -> PASS"                 "$clean"

# --- secrets dir guard (agent_lab_guard_secrets_dir) ---
REPO_ROOT="$repo_root"   # the secrets guard resolves relative paths against REPO_ROOT

expect_secrets_guard() {
  local expected="$1" name="$2" arg="$3" rc=0
  agent_lab_guard_secrets_dir "$arg" >/dev/null 2>&1 || rc=$?
  if [ "$expected" = pass ]; then
    if [ "$rc" -eq 0 ]; then pass "$name"; else fail "$name (expected PASS, got rc=$rc)"; fi
  else
    if [ "$rc" -ne 0 ]; then pass "$name"; else fail "$name (expected FAIL, got rc=0)"; fi
  fi
}

sec_ssh="$work/sec_ssh"; mkdir -p "$sec_ssh/.ssh"
sec_aws="$work/sec_aws"; mkdir -p "$sec_aws/.aws"
sec_npm="$work/sec_npm"; mkdir -p "$sec_npm"; printf '//r/:_authToken=deadbeef\n' > "$sec_npm/.npmrc"
sec_ok="$work/sec_ok";   mkdir -p "$sec_ok"

expect_secrets_guard fail "secrets=/ -> FAIL"                      "/"
expect_secrets_guard fail "secrets=HOME -> FAIL"                   "$HOME"
expect_secrets_guard fail "secrets dir with .ssh -> FAIL"         "$sec_ssh"
expect_secrets_guard fail "secrets dir with .aws -> FAIL"         "$sec_aws"
expect_secrets_guard fail "secrets dir with token .npmrc -> FAIL" "$sec_npm"
expect_secrets_guard pass "clean out-of-repo secrets dir -> PASS" "$sec_ok"

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
