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
    if [ "$rc" -eq 1 ]; then pass "$name"; else fail "$name (expected FAIL, got rc=$rc)"; fi
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
docker_auth="$work/docker_auth"; mkdir -p "$docker_auth/.docker"; printf '{}\n' > "$docker_auth/.docker/config.json"

expect_guard pass "empty arg -> PASS (ephemeral workspace)"   ""
expect_guard fail "filesystem root -> FAIL"                   "/"
expect_guard fail "broad shared temp root -> FAIL"            "/tmp"
[ ! -d /var/tmp ] || expect_guard fail "broad var temp root -> FAIL" "/var/tmp"
expect_guard fail "HOME -> FAIL"                              "$HOME"
expect_guard fail "nonexistent dir -> FAIL"                   "$work/does-not-exist"
expect_guard fail ".ssh present -> FAIL"                      "$with_ssh"
expect_guard fail ".npmrc with _authToken -> FAIL"           "$npmrc_tok"
expect_guard pass ".npmrc without token -> PASS (with WARN)"  "$npmrc_plain"
expect_guard fail ".docker/config.json present -> FAIL"       "$docker_auth"
expect_guard pass "clean project dir -> PASS"                 "$clean"

# Canonical path consumption and credential-bearing ancestor coverage.
clean_link="$work/clean-link"; ln -s "$clean" "$clean_link"
agent_lab_guard_project_dir "$clean_link" >/dev/null
if [ "$AGENT_LAB_PROJECT_DIR" = "$(cd "$clean" && pwd -P)" ]; then
  pass "project symlink spelling is replaced by the vetted canonical target"
else
  fail "project symlink spelling is replaced by the vetted canonical target"
fi
home_link="$work/home-link"; ln -s "$HOME" "$home_link"
expect_guard fail "project symlink resolving to HOME -> FAIL" "$home_link"
broken_link="$work/broken-link"; ln -s "$work/missing-target" "$broken_link"
expect_guard fail "broken project symlink -> FAIL" "$broken_link"
colon_target="$work/canonical:colon"; mkdir "$colon_target"
colon_link="$work/colon-link"; ln -s "$colon_target" "$colon_link"
expect_guard fail "symlink to colon-bearing canonical mount -> FAIL" "$colon_link"
mkdir -p "$HOME/.ssh/nested"
expect_guard fail "path inside credential-bearing ancestor -> FAIL" "$HOME/.ssh/nested"
mkdir -p "$HOME/.config"
expect_guard fail "direct credential/config directory -> FAIL" "$HOME/.config"

# A failed guard never leaves a previously-vetted path available to a careless caller.
agent_lab_guard_project_dir "$clean" >/dev/null
if agent_lab_guard_project_dir / >/dev/null 2>&1; then
  fail "failed project guard clears stale canonical state"
elif [ -z "$AGENT_LAB_PROJECT_DIR" ] && [ -z "$AGENT_LAB_PROJECT_IDENTITY" ]; then
  pass "failed project guard clears stale canonical state"
else
  fail "failed project guard clears stale canonical state"
fi

# --- secrets dir guard (agent_lab_guard_secrets_dir) ---
REPO_ROOT="$repo_root"   # the secrets guard resolves relative paths against REPO_ROOT

expect_secrets_guard() {
  local expected="$1" name="$2" arg="$3" rc=0
  agent_lab_guard_secrets_dir "$arg" >/dev/null 2>&1 || rc=$?
  if [ "$expected" = pass ]; then
    if [ "$rc" -eq 0 ]; then pass "$name"; else fail "$name (expected PASS, got rc=$rc)"; fi
  else
    if [ "$rc" -eq 1 ]; then pass "$name"; else fail "$name (expected FAIL, got rc=$rc)"; fi
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

# Missing repo-local secrets paths are planned canonically but never created by the guard.
fixture_repo="$work/repo"; mkdir -p "$fixture_repo/project" "$fixture_repo/other-secrets"
REPO_ROOT="$fixture_repo"
expect_secrets_guard fail "repository root cannot be used as the secrets directory" "$fixture_repo"
future_secrets="$fixture_repo/future-secrets"
expect_secrets_guard pass "missing repo-local secrets leaf can be planned" "./future-secrets"
if [ ! -e "$future_secrets" ] && [ "$AGENT_LAB_SECRETS_DIR" = "$future_secrets" ]; then
  pass "secrets preflight exports the canonical plan without creating it"
else
  fail "secrets preflight exports the canonical plan without creating it"
fi

if (
  agent_lab_dir_identity() { return 1; }
  agent_lab_guard_secrets_dir "./another-future-secret" >/dev/null 2>&1
); then
  fail "missing-path identity failures are fail-closed"
else
  pass "missing-path identity failures are fail-closed"
fi

created_secret="$fixture_repo/materialized-secret"
agent_lab_guard_secrets_dir "$created_secret" >/dev/null
created_plan_identity="$AGENT_LAB_SECRETS_IDENTITY"
if agent_lab_materialize_secrets_dir "$created_secret" "$created_plan_identity" &&
   [ -d "$created_secret" ]; then
  if stat -c '%a' "$created_secret" >/dev/null 2>&1; then
    created_mode="$(stat -c '%a' "$created_secret")"
  else
    created_mode="$(stat -f '%Lp' "$created_secret")"
  fi
  if [ "$created_mode" = 700 ]; then
    pass "missing secrets plan creates exactly one mode-0700 directory"
  else
    fail "missing secrets plan creates exactly one mode-0700 directory"
  fi
else
  fail "missing secrets plan creates exactly one mode-0700 directory"
fi

raced_missing="$fixture_repo/raced-missing"
agent_lab_guard_secrets_dir "$raced_missing" >/dev/null
raced_missing_identity="$AGENT_LAB_SECRETS_IDENTITY"
mkdir "$raced_missing"
if agent_lab_materialize_secrets_dir "$raced_missing" "$raced_missing_identity" \
     >/dev/null 2>&1; then
  fail "unexpected EEXIST cannot satisfy a missing secrets plan"
else
  pass "unexpected EEXIST cannot satisfy a missing secrets plan"
fi

replaced_secret="$fixture_repo/replaced-secret"
mkdir "$replaced_secret"
agent_lab_guard_secrets_dir "$replaced_secret" >/dev/null
replaced_identity="$AGENT_LAB_SECRETS_IDENTITY"
mv "$replaced_secret" "$fixture_repo/replaced-secret-old"
mkdir "$replaced_secret"
if agent_lab_materialize_secrets_dir "$replaced_secret" "$replaced_identity" \
     >/dev/null 2>&1; then
  fail "replaced existing secrets identity is rejected"
else
  pass "replaced existing secrets identity is rejected"
fi

planned_parent="$fixture_repo/planned-parent"
mkdir "$planned_parent"
agent_lab_guard_secrets_dir "$planned_parent/leaf" >/dev/null
planned_parent_identity="$AGENT_LAB_SECRETS_IDENTITY"
mv "$planned_parent" "$fixture_repo/planned-parent-old"
mkdir "$planned_parent"
if agent_lab_materialize_secrets_dir "$planned_parent/leaf" "$planned_parent_identity" \
     >/dev/null 2>&1; then
  fail "replaced missing-path parent identity is rejected"
else
  pass "replaced missing-path parent identity is rejected"
fi

safe_secret_link="$fixture_repo/safe-secret-link"
ln -s "$fixture_repo/other-secrets" "$safe_secret_link"
agent_lab_guard_secrets_dir "$safe_secret_link" >/dev/null
if [ "$AGENT_LAB_SECRETS_DIR" = "$(cd "$fixture_repo/other-secrets" && pwd -P)" ]; then
  pass "existing secrets symlink is consumed only as its canonical target"
else
  fail "existing secrets symlink is consumed only as its canonical target"
fi
broken_secret_link="$fixture_repo/broken-secret-link"
ln -s "$fixture_repo/no-secret-target" "$broken_secret_link"
expect_secrets_guard fail "broken secrets symlink -> FAIL" "$broken_secret_link"

# Relative project paths resolve against REPO_ROOT, never the caller's working directory.
if (
  cd /
  agent_lab_guard_project_dir ./project >/dev/null
  [ "$AGENT_LAB_PROJECT_DIR" = "$fixture_repo/project" ]
); then
  pass "relative project path is canonicalized against the Compose repository root"
else
  fail "relative project path is canonicalized against the Compose repository root"
fi

# A read-only secrets mount must never also be reachable through the writable project bind.
mkdir -p "$fixture_repo/project/secrets" "$fixture_repo/other-secrets/child"
agent_lab_guard_project_dir "$fixture_repo/project" >/dev/null
agent_lab_guard_secrets_dir "$fixture_repo/project/secrets" >/dev/null
if agent_lab_guard_mount_relationship >/dev/null 2>&1; then
  fail "secrets nested under project are rejected as overlapping mounts"
else
  pass "secrets nested under project are rejected as overlapping mounts"
fi
agent_lab_guard_project_dir "$fixture_repo/other-secrets/child" >/dev/null
agent_lab_guard_secrets_dir "$fixture_repo/other-secrets" >/dev/null
if agent_lab_guard_mount_relationship >/dev/null 2>&1; then
  fail "project nested under secrets is rejected as overlapping mounts"
else
  pass "project nested under secrets is rejected as overlapping mounts"
fi
agent_lab_guard_project_dir "$fixture_repo/project" >/dev/null
agent_lab_guard_secrets_dir "$fixture_repo/other-secrets" >/dev/null
if agent_lab_guard_mount_relationship >/dev/null 2>&1; then
  pass "disjoint canonical project and secrets paths are accepted"
else
  fail "disjoint canonical project and secrets paths are accepted"
fi

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
