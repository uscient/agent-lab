#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
# shellcheck source=../../scripts/lib/allowlist.sh
source "$repo_root/scripts/lib/allowlist.sh"

declare -F agent_lab_validate_allowlist_recipes >/dev/null || {
  printf 'INFRA allowlist validator is missing\n' >&2
  exit 125
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/policies/recipes"
cp "$repo_root"/policies/recipes/*.allowlist "$work/policies/recipes/"

# shellcheck disable=SC2034 # consumed by functions from the sourced allowlist library.
REPO_ROOT="$work"
failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

expect_recipes() {
  local expected="$1" name="$2" recipes="$3" marker="$4" rc=0 out
  # shellcheck disable=SC2034 # consumed by the sourced validator.
  AGENT_LAB_ALLOWLIST_RECIPES="$recipes"
  out="$(agent_lab_validate_allowlist_recipes 2>&1)" || rc=$?
  if { [ "$expected" = pass ] && [ "$rc" -eq 0 ] &&
       printf '%s\n' "$out" | grep -Fq "$marker"; } ||
     { [ "$expected" = fail ] && [ "$rc" -eq 1 ] &&
       printf '%s\n' "$out" | grep -Fq "$marker"; }; then
    if [ ! -e "$work/.cache" ]; then
      pass "$name"
    else
      fail "$name (pure validation created cache state)"
    fi
  else
    fail "$name (rc=$rc)"
  fi
}

expect_recipes pass "single base recipe is valid" base "PASS allowlist"
expect_recipes pass "ordered distinct recipes are valid" base,node-dev "PASS allowlist"
expect_recipes fail "empty recipe list is rejected" "" "empty item"
expect_recipes fail "leading empty recipe item is rejected" ,base "empty item"
expect_recipes fail "trailing empty recipe item is rejected" base, "empty item"
expect_recipes fail "middle empty recipe item is rejected" base,,node-dev "empty item"
expect_recipes fail "whitespace separator is rejected" "base node-dev" "invalid allowlist recipe name"
expect_recipes fail "duplicate recipe is rejected" base,base "duplicate allowlist recipe"
expect_recipes fail "traversal recipe is rejected" ../recipes/base "invalid allowlist recipe name"
expect_recipes fail "scheme recipe is rejected" https://example.com "invalid allowlist recipe name"
expect_recipes fail "IP recipe is rejected" 1.2.3.4 "invalid allowlist recipe name"
expect_recipes fail "port recipe is rejected" base:443 "invalid allowlist recipe name"
expect_recipes fail "wildcard recipe is rejected" '*' "invalid allowlist recipe name"
expect_recipes fail "uppercase recipe is rejected" Base "invalid allowlist recipe name"
expect_recipes fail "double-hyphen recipe is rejected" base--dev "invalid allowlist recipe name"
expect_recipes fail "unknown recipe is rejected" unknown "unknown or unsafe"

printf 'https://bad.example\n' > "$work/policies/recipes/invalid.allowlist"
expect_recipes fail "URL entries in fragments are rejected" invalid "invalid domain"
printf '1.2.3.4\n' > "$work/policies/recipes/invalid.allowlist"
expect_recipes fail "IP entries in fragments are rejected" invalid "invalid domain"
printf '*.example.com\n' > "$work/policies/recipes/invalid.allowlist"
expect_recipes fail "wildcard entries in fragments are rejected" invalid "invalid domain"
printf 'api.example.com # comment\n' > "$work/policies/recipes/invalid.allowlist"
expect_recipes fail "inline fragment comments are rejected" invalid "invalid domain"
printf ' api.example.com\n' > "$work/policies/recipes/invalid.allowlist"
expect_recipes fail "fragment whitespace is rejected" invalid "invalid domain"
printf 'api.example.com\r\n' > "$work/policies/recipes/invalid.allowlist"
expect_recipes fail "fragment CRLF is rejected" invalid "carriage return"
printf '# comment\r\napi.example.com\n' > "$work/policies/recipes/invalid.allowlist"
expect_recipes fail "fragment comment CRLF is rejected" invalid "carriage return"
printf '.npm\0js.org\n' > "$work/policies/recipes/invalid.allowlist"
expect_recipes fail "fragment NUL bytes cannot disappear during parsing" invalid "NUL byte"
printf 'api..example.com\n' > "$work/policies/recipes/invalid.allowlist"
expect_recipes fail "consecutive domain dots are rejected" invalid "invalid domain"
printf '%s.example.com\n' \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  > "$work/policies/recipes/invalid.allowlist"
expect_recipes fail "overlong domain labels are rejected" invalid "invalid domain"
printf '.example.com\n.example.com\n' > "$work/policies/recipes/invalid.allowlist"
expect_recipes fail "duplicate fragment entries are rejected" invalid "duplicate allowlist domain"
printf '.example.com' > "$work/policies/recipes/invalid.allowlist"
expect_recipes pass "canonical suffix without final newline is accepted" invalid "PASS allowlist"

printf 'shared.example.com\n' > "$work/policies/recipes/one.allowlist"
printf 'shared.example.com\n' > "$work/policies/recipes/two.allowlist"
expect_recipes fail "duplicates across fragments are rejected" one,two "duplicate allowlist domain"

ln -s base.allowlist "$work/policies/recipes/symlink.allowlist"
expect_recipes fail "symlinked recipe fragments are rejected" symlink "unknown or unsafe"

# A failed or stale plan can never be published through the lower-level phase API.
# shellcheck disable=SC2034 # consumed by the sourced validator/publisher.
AGENT_LAB_ALLOWLIST_RECIPES=base
agent_lab_validate_allowlist_recipes >/dev/null
AGENT_LAB_ALLOWLIST_RECIPES=node-dev
rc=0
out="$(agent_lab_publish_validated_allowlist 2>&1)" || rc=$?
if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -Fq "changed after validation" &&
   [ ! -e "$work/.cache" ]; then
  pass "recipe selection cannot change between validation and publication"
else
  fail "recipe selection cannot change between validation and publication"
fi
AGENT_LAB_ALLOWLIST_RECIPES=base,unknown
agent_lab_validate_allowlist_recipes >/dev/null 2>&1 || true
rc=0
out="$(agent_lab_publish_validated_allowlist 2>&1)" || rc=$?
if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -Fq "no validated" &&
   [ ! -e "$work/.cache" ]; then
  pass "failed validation leaves no publishable partial plan"
else
  fail "failed validation leaves no publishable partial plan"
fi

# The public builder must also validate before creating cache state or exports.
# shellcheck disable=SC2034 # consumed by the sourced builder.
AGENT_LAB_ALLOWLIST_RECIPES=base,unknown
unset AGENT_LAB_EGRESS_ALLOWLIST AGENT_LAB_EGRESS_POLICY_SHA256 || true
rc=0
builder_out="$work/builder-invalid.out"
agent_lab_build_allowlist >"$builder_out" 2>&1 || rc=$?
out="$(cat "$builder_out")"
if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -Fq "unknown or unsafe" &&
   [ ! -e "$work/.cache" ] &&
   [ -z "${AGENT_LAB_EGRESS_ALLOWLIST+x}" ] &&
   [ -z "${AGENT_LAB_EGRESS_POLICY_SHA256+x}" ]; then
  pass "invalid builder input creates no cache or exported policy"
else
  fail "invalid builder input creates no cache or exported policy"
fi

# Cache symlinks and destination-directory races fail before policy exports.
symlink_root="$work/symlink-root"
mkdir -p "$symlink_root/policies/recipes" "$symlink_root/cache-target"
cp "$repo_root"/policies/recipes/base.allowlist "$symlink_root/policies/recipes/"
ln -s "$symlink_root/cache-target" "$symlink_root/.cache"
REPO_ROOT="$symlink_root"
AGENT_LAB_ALLOWLIST_RECIPES=base
rc=0
out="$(agent_lab_build_allowlist 2>&1)" || rc=$?
if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -Fq "cache path"; then
  pass "symlinked cache roots are rejected before publication"
else
  fail "symlinked cache roots are rejected before publication"
fi

race_root="$work/race-root"
mkdir -p "$race_root/policies/recipes"
cp "$repo_root"/policies/recipes/base.allowlist "$race_root/policies/recipes/"
rc=0
out="$(
  REPO_ROOT="$race_root"
  AGENT_LAB_ALLOWLIST_RECIPES=base
  agent_lab_validate_allowlist_recipes >/dev/null
  # shellcheck disable=SC2317 # invoked indirectly by the sourced publisher.
  mv() {
    mkdir -p "$2"
    command mv "$1" "$2"
  }
  agent_lab_publish_validated_allowlist 2>&1
)" || rc=$?
if [ "$rc" -eq 1 ] &&
   printf '%s\n' "$out" | grep -Fq "publication target is not the validated file"; then
  pass "destination-directory race cannot be reported or exported as a policy file"
else
  fail "destination-directory race cannot be reported or exported as a policy file"
fi

# A positive build consumes the validated in-memory records in recipe order and is stable.
# shellcheck disable=SC2034 # consumed by the sourced builder.
REPO_ROOT="$work"
# shellcheck disable=SC2034 # consumed by the sourced builder.
AGENT_LAB_ALLOWLIST_RECIPES=base,node-dev
rc=0
builder_out="$work/builder-valid.out"
agent_lab_build_allowlist >"$builder_out" 2>&1 || rc=$?
out="$(cat "$builder_out")"
first_path="${AGENT_LAB_EGRESS_ALLOWLIST:-}"
first_hash="${AGENT_LAB_EGRESS_POLICY_SHA256:-}"
if [ "$rc" -eq 0 ] && [ -f "$first_path" ] &&
   grep -Fxq '# --- recipe: base ---' "$first_path" &&
   grep -Fxq '# --- recipe: node-dev ---' "$first_path" &&
   grep -Fxq '.npmjs.org' "$first_path" &&
   [ "$(agent_lab_sha256_file "$first_path")" = "$first_hash" ]; then
  pass "positive builder publishes exact content-addressed recipe bytes"
else
  fail "positive builder publishes exact content-addressed recipe bytes"
fi
agent_lab_build_allowlist >/dev/null
if [ "${AGENT_LAB_EGRESS_ALLOWLIST:-}" = "$first_path" ] &&
   [ "${AGENT_LAB_EGRESS_POLICY_SHA256:-}" = "$first_hash" ]; then
  pass "identical recipe input produces a stable policy identity"
else
  fail "identical recipe input produces a stable policy identity"
fi

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
