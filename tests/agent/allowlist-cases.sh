#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
# shellcheck source=../../scripts/lib/allowlist.sh
source "$repo_root/scripts/lib/allowlist.sh"
# shellcheck source=../../scripts/lib/config.sh
source "$repo_root/scripts/lib/config.sh"

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

for bare_library in config.sh allowlist.sh; do
  if (cd "$repo_root/scripts/lib" && bash -e -c "source $bare_library; declare -F agent_lab_domain_valid >/dev/null"); then
    pass "$bare_library resolves the shared validator when sourced by bare name"
  else
    fail "$bare_library resolves the shared validator when sourced by bare name"
  fi
done
missing_domain_dir="$work/missing-domain"
mkdir -p "$missing_domain_dir"
cp "$repo_root/scripts/lib/config.sh" "$missing_domain_dir/config.sh"
if (cd "$missing_domain_dir" && bash -c 'source ./config.sh' >/dev/null 2>&1); then
  fail "config source fails closed when the shared validator is missing"
else
  pass "config source fails closed when the shared validator is missing"
fi

expect_allowlist_stat_snapshot() {
  local helper="$1" name="$2" gnu_format="$3" bsd_format="$4" expected="$5"
  local stat_log="$work/${helper}.stat.log" output rc

  : > "$stat_log"
  rc=0
  output="$(
    # shellcheck disable=SC2317 # invoked indirectly by the sourced identity helper.
    stat() {
      printf '%s|%s|%s\n' "${1:-}" "${2:-}" "${3:-}" >> "$stat_log"
      if [ "$#" -eq 3 ] && [ "$1" = -c ] && [ "$2" = "$gnu_format" ] && [ "$3" = /fixture ]; then
        printf '%s\n' "$expected"
      else
        return 1
      fi
    }
    "$helper" /fixture
  )" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$output" = "$expected" ] &&
     [ "$(cat "$stat_log")" = "-c|$gnu_format|/fixture" ]; then
    pass "$name captures one successful GNU stat snapshot"
  else
    fail "$name captures one successful GNU stat snapshot"
  fi

  : > "$stat_log"
  rc=0
  output="$(
    # shellcheck disable=SC2317 # invoked indirectly by the sourced identity helper.
    stat() {
      printf '%s|%s|%s\n' "${1:-}" "${2:-}" "${3:-}" >> "$stat_log"
      if [ "$#" -eq 3 ] && [ "$1" = -f ] && [ "$2" = "$bsd_format" ] && [ "$3" = /fixture ]; then
        printf '%s\n' "$expected"
      else
        return 1
      fi
    }
    "$helper" /fixture
  )" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$output" = "$expected" ] &&
     [ "$(cat "$stat_log")" = "-c|$gnu_format|/fixture"$'\n'"-f|$bsd_format|/fixture" ]; then
    pass "$name falls back with one BSD stat snapshot"
  else
    fail "$name falls back with one BSD stat snapshot"
  fi
}

expect_allowlist_stat_snapshot \
  agent_lab_allowlist_dir_identity "allowlist directory identity" '%d:%i' '%d:%i' 7:11
expect_allowlist_stat_snapshot \
  agent_lab_allowlist_file_mode "allowlist file mode" '%a' '%Lp' 444

if declare -F agent_lab_domain_valid >/dev/null; then
  pass "one shared domain validator is available"
else
  fail "one shared domain validator is available"
fi
if declare -f agent_lab_domain_valid | grep -Eq 'local[[:space:]]+LC_ALL=C'; then
  pass "shared domain validator pins bytewise C locale semantics"
else
  fail "shared domain validator pins bytewise C locale semantics"
fi
if grep -Eq '\$\{[^}]*,,[^}]*\}' "$repo_root/scripts/lib/domain.sh"; then
  fail "shared domain validator remains compatible with Bash 3.2 parameter expansion"
else
  pass "shared domain validator remains compatible with Bash 3.2 parameter expansion"
fi

for public_validator in agent_lab_validate_domain agent_lab_allowlist_domain_valid; do
  delegate_rc=0
  (
    # shellcheck disable=SC2317 # invoked indirectly by the public validator wrapper.
    agent_lab_domain_valid() { return 42; }
    "$public_validator" example.com
  ) || delegate_rc=$?
  if [ "$delegate_rc" -eq 42 ]; then
    pass "$public_validator delegates to the shared domain validator"
  else
    fail "$public_validator delegates to the shared domain validator"
  fi
done

expect_domain() {
  local expected="$1" name="$2" value="$3" validator rc
  for validator in agent_lab_validate_domain agent_lab_allowlist_domain_valid; do
    rc=0
    "$validator" "$value" || rc=$?
    if { [ "$expected" = pass ] && [ "$rc" -eq 0 ]; } ||
       { [ "$expected" = fail ] && [ "$rc" -eq 1 ]; }; then
      :
    else
      fail "$name through $validator (rc=$rc)"
      return
    fi
  done
  pass "$name through both public domain validators"
}

printf -v label63 '%*s' 63 ''
label63="${label63// /a}"
printf -v label64 '%*s' 64 ''
label64="${label64// /a}"
printf -v label61 '%*s' 61 ''
label61="${label61// /a}"
printf -v label62 '%*s' 62 ''
label62="${label62// /a}"
domain253="${label63}.${label63}.${label63}.${label61}"
domain254="${label63}.${label63}.${label63}.${label62}"

expect_domain pass "ordinary hostname is accepted" example.com
expect_domain pass "allowlist suffix spelling is accepted by the shared primitive" .example.com
expect_domain pass "63-byte domain label is accepted" "${label63}.example"
expect_domain pass "253-byte domain is accepted" "$domain253"
expect_domain fail "empty domain is rejected" ""
expect_domain fail "single-label name is rejected" localhost
expect_domain fail "numeric-only dotted name is rejected" 123.456
expect_domain fail "consecutive domain dots are rejected" api..example.com
expect_domain fail "double-leading suffix dots are rejected" ..example.com
expect_domain fail "trailing domain dot is rejected" api.example.com.
expect_domain fail "leading label hyphen is rejected" -api.example.com
expect_domain fail "trailing label hyphen is rejected" api-.example.com
expect_domain fail "uppercase domain is rejected" API.example.com
expect_domain fail "underscore domain is rejected" api_name.example.com
expect_domain fail "wildcard domain is rejected" '*.example.com'
expect_domain fail "64-byte domain label is rejected" "${label64}.example"
expect_domain fail "254-byte domain is rejected" "$domain254"
expect_domain fail "domain whitespace is rejected" 'api .example.com'
expect_domain fail "domain newline is rejected" $'api\n.example.com'
globasciiranges_was_set=0
shopt -q globasciiranges && globasciiranges_was_set=1
shopt -u globasciiranges
expect_domain fail "non-ASCII compatibility character is rejected" 'K.example'
expect_domain fail "non-ASCII domain is rejected" 'éxample.com'
[ "$globasciiranges_was_set" -eq 0 ] || shopt -s globasciiranges
nocasematch_was_set=0
shopt -q nocasematch && nocasematch_was_set=1
shopt -s nocasematch
expect_domain fail "uppercase stays rejected with inherited nocasematch" 'API.example.com'
if shopt -q nocasematch; then
  pass "domain validation restores inherited nocasematch"
else
  fail "domain validation restores inherited nocasematch"
fi
[ "$nocasematch_was_set" -eq 1 ] || shopt -u nocasematch

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
