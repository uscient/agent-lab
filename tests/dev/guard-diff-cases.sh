#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
test_repo="$work/repo"
failures=0

pass() {
  printf 'PASS %s\n' "$1"
}

fail() {
  printf 'FAIL %s\n' "$1"
  failures=$((failures + 1))
}

make_commit() {
  git -C "$test_repo" add -A
  git -C "$test_repo" commit -q -m "$1"
}

run_guard() {
  local base="$1"
  (
    cd "$test_repo"
    AGENT_LAB_DIFF_BASE="$base" bash scripts/dev/guard-diff default
  )
}

expect_pass_with_file() {
  local name="$1" base="$2" expected_file="$3" rc=0 out
  out="$(run_guard "$base" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -Fxq "$expected_file"; then
    pass "$name"
  else
    fail "$name (rc=$rc; expected changed file $expected_file)"
    printf '%s\n' "$out"
  fi
}

expect_fail_with() {
  local name="$1" base="$2" expected="$3" rc=0 out
  out="$(run_guard "$base" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -Fq "$expected"; then
    pass "$name"
  else
    fail "$name (rc=$rc; expected output containing: $expected)"
    printf '%s\n' "$out"
  fi
}

mkdir -p "$test_repo/scripts/dev" "$test_repo/scripts/lib" "$test_repo/.devguard"
cp "$repo_root/scripts/dev/guard-diff" "$test_repo/scripts/dev/guard-diff"
cp "$repo_root/scripts/lib/dev-common.sh" "$test_repo/scripts/lib/dev-common.sh"
cp "$repo_root/.devguard/forbid-default.txt" "$test_repo/.devguard/forbid-default.txt"

git -C "$test_repo" init -q
git -C "$test_repo" config user.name "agent-lab test"
git -C "$test_repo" config user.email "test@example.invalid"
printf 'baseline\n' > "$test_repo/README.md"
make_commit "baseline"

base="$(git -C "$test_repo" rev-parse HEAD)"
printf 'committed change\n' > "$test_repo/committed.txt"
make_commit "ordinary committed change"
expect_pass_with_file \
  "committed merge-base change is included" \
  "$base" \
  "committed.txt"

base="$(git -C "$test_repo" rev-parse HEAD)"
printf 'AKIA0000000000000000\n' > "$test_repo/credential.txt"
make_commit "fake credential sentinel"
expect_fail_with \
  "committed fake-secret sentinel is rejected" \
  "$base" \
  "possible high-confidence secret"

base="$(git -C "$test_repo" rev-parse HEAD)"
printf 'LOCAL_ONLY=true\n' > "$test_repo/.env.local"
make_commit "forbidden path sentinel"
expect_fail_with \
  "committed forbidden path is rejected" \
  "$base" \
  "forbidden path pattern"

base="$(git -C "$test_repo" rev-parse HEAD)"
printf 'trailing whitespace \n' > "$test_repo/whitespace.txt"
make_commit "whitespace sentinel"
expect_fail_with \
  "committed whitespace error is rejected" \
  "$base" \
  "trailing whitespace"

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
