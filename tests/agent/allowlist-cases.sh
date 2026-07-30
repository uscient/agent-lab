#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
# shellcheck source=../../scripts/lib/allowlist.sh
source "$repo_root/scripts/lib/allowlist.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/policies/recipes"
cp "$repo_root"/policies/recipes/*.allowlist "$work/policies/recipes/"

original_root="$repo_root"
REPO_ROOT="$work"
failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

expect_recipes() {
  local expected="$1" name="$2" recipes="$3" rc=0
  AGENT_LAB_ALLOWLIST_RECIPES="$recipes"
  agent_lab_validate_allowlist_recipes >/dev/null 2>&1 || rc=$?
  if { [ "$expected" = pass ] && [ "$rc" -eq 0 ]; } ||
     { [ "$expected" = fail ] && [ "$rc" -ne 0 ]; }; then
    pass "$name"
  else
    fail "$name"
  fi
}

expect_recipes pass "single base recipe is valid" base
expect_recipes pass "ordered distinct recipes are valid" base,node-dev
expect_recipes fail "empty recipe list is rejected" ""
expect_recipes fail "empty recipe item is rejected" base,,node-dev
expect_recipes fail "whitespace separator is rejected" "base node-dev"
expect_recipes fail "duplicate recipe is rejected" base,base
expect_recipes fail "traversal recipe is rejected" ../recipes/base
expect_recipes fail "scheme recipe is rejected" https://example.com
expect_recipes fail "IP recipe is rejected" 1.2.3.4
expect_recipes fail "port recipe is rejected" base:443
expect_recipes fail "wildcard recipe is rejected" '*'
expect_recipes fail "unknown recipe is rejected" unknown

printf 'https://bad.example\n' > "$work/policies/recipes/invalid.allowlist"
expect_recipes fail "URL entries in fragments are rejected" invalid
printf '1.2.3.4\n' > "$work/policies/recipes/invalid.allowlist"
expect_recipes fail "IP entries in fragments are rejected" invalid
printf '*.example.com\n' > "$work/policies/recipes/invalid.allowlist"
expect_recipes fail "wildcard entries in fragments are rejected" invalid
printf '.example.com\n.example.com\n' > "$work/policies/recipes/invalid.allowlist"
expect_recipes fail "duplicate fragment entries are rejected" invalid
printf '.example.com\n' > "$work/policies/recipes/invalid.allowlist"
expect_recipes pass "canonical domain suffix entries are accepted" invalid

ln -s base.allowlist "$work/policies/recipes/symlink.allowlist"
expect_recipes fail "symlinked recipe fragments are rejected" symlink

REPO_ROOT="$original_root"
printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
