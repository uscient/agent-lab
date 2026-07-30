#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
reducer="$repo_root/scripts/dev/required-gates"
manifest="$repo_root/tests/security/ci.manifest"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

pass() {
  printf 'PASS %s\n' "$1"
}

fail() {
  printf 'FAIL %s\n' "$1"
  failures=$((failures + 1))
}

run_reducer() {
  local json="$1" summary_path="${2:-}"
  if [ -n "$summary_path" ]; then
    CI_NEEDS_JSON="$json" GITHUB_STEP_SUMMARY="$summary_path" "$reducer"
  else
    CI_NEEDS_JSON="$json" "$reducer"
  fi
}

expect_rc() {
  local expected="$1" name="$2" json="$3" marker="$4" rc=0 out
  out="$(run_reducer "$json" 2>&1)" || rc=$?
  if [ "$rc" -eq "$expected" ] && printf '%s\n' "$out" | grep -Fq "$marker"; then
    pass "$name"
  else
    fail "$name (rc=$rc, expected=$expected, marker=$marker)"
    printf '%s\n' "$out"
  fi
}

if [ -x "$reducer" ]; then
  pass "required-gates reducer exists and is executable"
else
  fail "required-gates reducer exists and is executable"
fi

expected_manifest="$work/expected.manifest"
cat > "$expected_manifest" <<'EOF'
version 1
gate fast ./scripts/dev/check default quick
gate static ./tools/validate.sh --strict
gate docker ./scripts/dev/docker-gate
EOF
actual_manifest="$work/actual.manifest"
awk '!/^#/ && NF { print }' "$manifest" > "$actual_manifest"
if cmp -s "$expected_manifest" "$actual_manifest"; then
  pass "versioned manifest defines exactly the required gates and replay commands"
else
  fail "versioned manifest defines exactly the required gates and replay commands"
  diff -u "$expected_manifest" "$actual_manifest" || true
fi

success_json='{
  "fast": {"result": "success", "outputs": {"diff-base": "1111111111111111111111111111111111111111"}},
  "static": {"result": "success", "outputs": {}},
  "docker": {"result": "success", "outputs": {}}
}'
reordered_json='{
  "docker": {"outputs": {"ignored": "failure"}, "result": "success"},
  "fast": {"outputs": {"result": "cancelled", "nested": {"x": 1}, "diff-base": "1111111111111111111111111111111111111111"}, "result": "success"},
  "static": {"result": "success", "outputs": ["ignored"]}
}'

expected_summary="$work/expected-summary.md"
cat > "$expected_summary" <<'EOF'
## Required CI gates

| Gate | Result | Local replay command |
| --- | --- | --- |
| `fast` | `success` | `AGENT_LAB_DIFF_BASE=1111111111111111111111111111111111111111 ./scripts/dev/check default quick` |
| `static` | `success` | `./tools/validate.sh --strict` |
| `docker` | `success` | `./scripts/dev/docker-gate` |

Outcome: **pass** — all required jobs completed successfully.

REQUIRED GATES PASS
EOF

summary_path="$work/step-summary.md"
success_rc=0
success_out="$(run_reducer "$success_json" "$summary_path")" || success_rc=$?
printf '%s\n' "$success_out" > "$work/stdout.md"
if [ "$success_rc" -eq 0 ] &&
  cmp -s "$expected_summary" "$work/stdout.md" &&
  cmp -s "$expected_summary" "$summary_path"; then
  pass "success emits the exact Markdown summary to stdout and GitHub summary"
else
  fail "success emits the exact Markdown summary to stdout and GitHub summary"
  diff -u "$expected_summary" "$work/stdout.md" || true
  diff -u "$expected_summary" "$summary_path" || true
fi

reordered_rc=0
reordered_out="$(run_reducer "$reordered_json")" || reordered_rc=$?
printf '%s\n' "$reordered_out" > "$work/reordered.md"
if [ "$reordered_rc" -eq 0 ] &&
  cmp -s "$expected_summary" "$work/reordered.md"; then
  pass "JSON key reordering and arbitrary outputs do not affect reduction"
else
  fail "JSON key reordering and arbitrary outputs do not affect reduction"
  diff -u "$expected_summary" "$work/reordered.md" || true
fi

expect_rc 1 "failure blocks the required gate" \
  '{"fast":{"result":"failure"},"static":{"result":"success"},"docker":{"result":"success"}}' \
  "REQUIRED GATES FAIL"
expect_rc 1 "cancelled blocks the required gate" \
  '{"fast":{"result":"success"},"static":{"result":"cancelled"},"docker":{"result":"success"}}' \
  "REQUIRED GATES FAIL"
expect_rc 1 "skipped blocks the required gate" \
  '{"fast":{"result":"success"},"static":{"result":"success"},"docker":{"result":"skipped"}}' \
  "REQUIRED GATES FAIL"

expect_rc 125 "missing required job is infrastructure failure" \
  '{"fast":{"result":"success"},"static":{"result":"success"}}' \
  "REQUIRED GATES INFRA"
expect_rc 125 "extra job is infrastructure failure" \
  '{"fast":{"result":"success"},"static":{"result":"success"},"docker":{"result":"success"},"other":{"result":"success"}}' \
  "REQUIRED GATES INFRA"
expect_rc 125 "malformed JSON is infrastructure failure" \
  '{"fast":' \
  "REQUIRED GATES INFRA"
expect_rc 125 "non-object JSON is infrastructure failure" \
  '["fast","static","docker"]' \
  "REQUIRED GATES INFRA"
expect_rc 125 "missing result is infrastructure failure" \
  '{"fast":{},"static":{"result":"success"},"docker":{"result":"success"}}' \
  "REQUIRED GATES INFRA"
expect_rc 125 "non-string result is infrastructure failure" \
  '{"fast":{"result":true},"static":{"result":"success"},"docker":{"result":"success"}}' \
  "REQUIRED GATES INFRA"
expect_rc 125 "unknown result is infrastructure failure" \
  '{"fast":{"result":"pending"},"static":{"result":"success"},"docker":{"result":"success"}}' \
  "REQUIRED GATES INFRA"
expect_rc 125 "successful fast gate without its immutable base is infrastructure failure" \
  '{"fast":{"result":"success","outputs":{}},"static":{"result":"success"},"docker":{"result":"success"}}' \
  "REQUIRED GATES INFRA"

unset_rc=0
unset_out="$(env -u CI_NEEDS_JSON "$reducer" 2>&1)" || unset_rc=$?
if [ "$unset_rc" -eq 125 ] &&
  printf '%s\n' "$unset_out" | grep -Fq 'REQUIRED GATES INFRA' &&
  printf '%s\n' "$unset_out" | grep -Fq '`CI_NEEDS_JSON` is unset.'; then
  pass "unset CI_NEEDS_JSON is infrastructure failure"
else
  fail "unset CI_NEEDS_JSON is infrastructure failure (rc=$unset_rc)"
  printf '%s\n' "$unset_out"
fi

printf 'SUMMARY failures=%s\n' "$failures"
if [ "$failures" -ne 0 ]; then
  exit 1
fi
