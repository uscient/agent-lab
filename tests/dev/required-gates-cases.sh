#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
reducer="${REQUIRED_GATES_REDUCER_UNDER_TEST:-$repo_root/scripts/dev/required-gates}"
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

capture_reducer() {
  local case_id="$1" json="$2" summary_path="${3:-}" manifest_path="${4:-}"
  local path_override="${5:-$PATH}"
  local -a args=()

  CAPTURE_STDOUT="$work/$case_id.stdout"
  CAPTURE_STDERR="$work/$case_id.stderr"
  CAPTURE_RC=0
  if [ -n "$manifest_path" ]; then
    args+=(--manifest "$manifest_path")
  fi

  if [ -n "$summary_path" ]; then
    env PATH="$path_override" CI_NEEDS_JSON="$json" \
      GITHUB_STEP_SUMMARY="$summary_path" \
      "$reducer" "${args[@]}" > "$CAPTURE_STDOUT" 2> "$CAPTURE_STDERR" || CAPTURE_RC=$?
  else
    env -u GITHUB_STEP_SUMMARY PATH="$path_override" CI_NEEDS_JSON="$json" \
      "$reducer" "${args[@]}" > "$CAPTURE_STDOUT" 2> "$CAPTURE_STDERR" || CAPTURE_RC=$?
  fi
}

expect_capture_files() {
  local name="$1" expected_rc="$2" expected_stdout="$3" expected_stderr="$4"
  if [ "$CAPTURE_RC" -eq "$expected_rc" ] &&
    cmp -s "$expected_stdout" "$CAPTURE_STDOUT" &&
    cmp -s "$expected_stderr" "$CAPTURE_STDERR"; then
    pass "$name"
  else
    fail "$name (rc=$CAPTURE_RC, expected=$expected_rc)"
    diff -u "$expected_stdout" "$CAPTURE_STDOUT" || true
    diff -u "$expected_stderr" "$CAPTURE_STDERR" || true
  fi
}

write_default_summary() {
  local target="$1" fast_result="$2" static_result="$3" docker_result="$4"
  local fast_replay="$5" outcome="$6" detail="$7" marker="$8"
  {
    printf '## Required CI gates\n\n'
    printf '| Gate | Result | Local replay command |\n'
    printf '| --- | --- | --- |\n'
    printf '| `fast` | `%s` | `%s` |\n' "$fast_result" "$fast_replay"
    printf '| `static` | `%s` | `./tools/validate.sh --strict` |\n' "$static_result"
    printf '| `docker` | `%s` | `./scripts/dev/docker-gate` |\n' "$docker_result"
    printf '\nOutcome: **%s** — %s\n\n%s\n' "$outcome" "$detail" "$marker"
  } > "$target"
}

if [ -x "$reducer" ]; then
  pass "required-gates reducer exists and is executable"
else
  fail "required-gates reducer exists and is executable"
fi

expected_manifest="$work/expected.manifest"
cat > "$expected_manifest" <<'EOF'
version 1
gate fast ./scripts/dev/ci-fast
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
| `fast` | `success` | `AGENT_LAB_DIFF_BASE=1111111111111111111111111111111111111111 ./scripts/dev/ci-fast` |
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

empty_file="$work/empty"
: > "$empty_file"
base40="1111111111111111111111111111111111111111"
zero40="0000000000000000000000000000000000000000"
zero64="0000000000000000000000000000000000000000000000000000000000000000"
base64="${zero64//0/a}"
upper40="${zero40//0/A}"
upper64="${zero64//0/A}"

expected_success40="$work/exact-success-40.md"
write_default_summary "$expected_success40" success success success \
  "AGENT_LAB_DIFF_BASE=$base40 ./scripts/dev/ci-fast" \
  pass "all required jobs completed successfully." "REQUIRED GATES PASS"
exact_summary_path="$work/exact-step-summary.md"
capture_reducer exact_success_40 "$success_json" "$exact_summary_path"
expect_capture_files "exit 0 has exact stdout and empty stderr" 0 \
  "$expected_success40" "$empty_file"
if cmp -s "$expected_success40" "$exact_summary_path"; then
  pass "exit 0 appends the exact GitHub step summary"
else
  fail "exit 0 appends the exact GitHub step summary"
  diff -u "$expected_success40" "$exact_summary_path" || true
fi

success64_json="{\"fast\":{\"result\":\"success\",\"outputs\":{\"diff-base\":\"$base64\"}},\"static\":{\"result\":\"success\"},\"docker\":{\"result\":\"success\"}}"
expected_success64="$work/exact-success-64.md"
write_default_summary "$expected_success64" success success success \
  "AGENT_LAB_DIFF_BASE=$base64 ./scripts/dev/ci-fast" \
  pass "all required jobs completed successfully." "REQUIRED GATES PASS"
capture_reducer exact_success_64 "$success64_json"
expect_capture_files "64-character lowercase SHA is accepted exactly" 0 \
  "$expected_success64" "$empty_file"

failed_fast_json='{"fast":{"result":"failure"},"static":{"result":"success"},"docker":{"result":"success"}}'
expected_failed_fast="$work/exact-failed-fast.md"
write_default_summary "$expected_failed_fast" failure success success \
  "unavailable: immutable diff base did not resolve" \
  blocked 'required job result: `fast` (`failure`).' "REQUIRED GATES FAIL"
capture_reducer exact_failed_fast "$failed_fast_json"
expect_capture_files "failed fast gate needs no diff base and has exact exit 1 contract" 1 \
  "$expected_failed_fast" "$empty_file"

unknown_static_json="{\"fast\":{\"result\":\"success\",\"outputs\":{\"diff-base\":\"$base40\"}},\"static\":{\"result\":\"pending\"},\"docker\":{\"result\":\"success\"}}"
expected_unknown_static="$work/exact-unknown-static.md"
write_default_summary "$expected_unknown_static" success pending unknown \
  "unavailable: immutable diff base did not resolve" \
  "infrastructure error" 'job `static` has a missing, malformed, or unknown result.' \
  "REQUIRED GATES INFRA"
capture_reducer exact_unknown_static "$unknown_static_json"
expect_capture_files "unknown result has exact exit 125 contract" 125 \
  "$expected_unknown_static" "$empty_file"

missing_docker_result_json="{\"fast\":{\"result\":\"success\",\"outputs\":{\"diff-base\":\"$base40\"}},\"static\":{\"result\":\"success\"},\"docker\":{}}"
expected_missing_docker_result="$work/exact-missing-docker-result.md"
write_default_summary "$expected_missing_docker_result" success success unknown \
  "unavailable: immutable diff base did not resolve" \
  "infrastructure error" 'job `docker` has a missing, malformed, or unknown result.' \
  "REQUIRED GATES INFRA"
capture_reducer exact_missing_docker_result "$missing_docker_result_json"
expect_capture_files "incomplete result has exact exit 125 contract" 125 \
  "$expected_missing_docker_result" "$empty_file"

expected_invalid_base="$work/exact-invalid-base.md"
write_default_summary "$expected_invalid_base" success success success \
  "unavailable: immutable diff base did not resolve" \
  "infrastructure error" 'successful `fast` job did not publish a valid immutable diff base.' \
  "REQUIRED GATES INFRA"
invalid_base_index=0
for invalid_base in "$zero40" "$zero64" "$upper40" "$upper64"; do
  invalid_base_index=$((invalid_base_index + 1))
  invalid_base_json="{\"fast\":{\"result\":\"success\",\"outputs\":{\"diff-base\":\"$invalid_base\"}},\"static\":{\"result\":\"success\"},\"docker\":{\"result\":\"success\"}}"
  capture_reducer "invalid_base_$invalid_base_index" "$invalid_base_json"
  expect_capture_files "zero or uppercase SHA form $invalid_base_index is rejected exactly" 125 \
    "$expected_invalid_base" "$empty_file"
done

append_path="$work/append-summary.md"
printf 'pre-existing summary\n' > "$append_path"
capture_reducer append_summary "$success_json" "$append_path"
expected_appended="$work/expected-appended.md"
{
  printf 'pre-existing summary\n'
  cat "$expected_success40"
} > "$expected_appended"
if [ "$CAPTURE_RC" -eq 0 ] &&
  cmp -s "$expected_success40" "$CAPTURE_STDOUT" &&
  cmp -s "$empty_file" "$CAPTURE_STDERR" &&
  cmp -s "$expected_appended" "$append_path"; then
  pass "GitHub step summary is appended without replacing existing content"
else
  fail "GitHub step summary is appended without replacing existing content"
  diff -u "$expected_success40" "$CAPTURE_STDOUT" || true
  diff -u "$empty_file" "$CAPTURE_STDERR" || true
  diff -u "$expected_appended" "$append_path" || true
fi

summary_directory="$work/summary-directory"
mkdir "$summary_directory"
expected_append_error="$work/expected-append-error"
printf 'INFRA could not append required-gates summary: %s\n' \
  "$summary_directory" > "$expected_append_error"
capture_reducer append_failure "$success_json" "$summary_directory"
expect_capture_files "step-summary append failure has exact exit 125 and diagnostic" 125 \
  "$expected_success40" "$expected_append_error"

capture_reducer append_blocked "$failed_fast_json" "$summary_directory"
expect_capture_files "append failure overrides a blocked result with exit 125" 125 \
  "$expected_failed_fast" "$expected_append_error"

capture_reducer append_infra "$unknown_static_json" "$summary_directory"
expect_capture_files "append failure preserves infrastructure exit 125" 125 \
  "$expected_unknown_static" "$expected_append_error"

failure_then_unknown_json="{\"fast\":{\"result\":\"failure\"},\"static\":{\"result\":\"pending\"},\"docker\":{\"result\":\"success\"}}"
expected_failure_then_unknown="$work/exact-failure-then-unknown.md"
write_default_summary "$expected_failure_then_unknown" failure pending unknown \
  "unavailable: immutable diff base did not resolve" \
  "infrastructure error" 'job `static` has a missing, malformed, or unknown result.' \
  "REQUIRED GATES INFRA"
capture_reducer failure_then_unknown "$failure_then_unknown_json"
expect_capture_files "malformed result takes infrastructure precedence over failure" 125 \
  "$expected_failure_then_unknown" "$empty_file"

invalid_sha_with_failure_json='{"fast":{"result":"success","outputs":{}},"static":{"result":"failure"},"docker":{"result":"success"}}'
expected_invalid_sha_with_failure="$work/exact-invalid-sha-with-failure.md"
write_default_summary "$expected_invalid_sha_with_failure" success failure success \
  "unavailable: immutable diff base did not resolve" \
  blocked 'required job result: `static` (`failure`).' "REQUIRED GATES FAIL"
capture_reducer invalid_sha_with_failure "$invalid_sha_with_failure_json"
expect_capture_files "known failure takes precedence over an unavailable fast replay base" 1 \
  "$expected_invalid_sha_with_failure" "$empty_file"

custom_manifest="$work/custom.manifest"
{
  printf 'version 1\n'
  printf 'gate docker ./docker\\runner | tee out\n'
  printf '%s\n' 'gate fast ./fast --literal `tick` and ``ticks`` | check'
  printf 'gate static ./static\\check\r\n'
} > "$custom_manifest"
custom_base="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
custom_json="{\"fast\":{\"result\":\"success\",\"outputs\":{\"diff-base\":\"$custom_base\"}},\"static\":{\"result\":\"success\"},\"docker\":{\"result\":\"success\"}}"
expected_custom="$work/expected-custom.md"
cat > "$expected_custom" <<'EOF'
## Required CI gates

| Gate | Result | Local replay command |
| --- | --- | --- |
| `docker` | `success` | `./docker\runner \| tee out` |
| `fast` | `success` | ``` AGENT_LAB_DIFF_BASE=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ./fast --literal `tick` and ``ticks`` \| check ``` |
| `static` | `success` | `./static\check ` |

Outcome: **pass** — all required jobs completed successfully.

REQUIRED GATES PASS
EOF
capture_reducer custom_manifest "$custom_json" "" "$custom_manifest"
expect_capture_files "custom manifest order and Markdown metacharacters render safely" 0 \
  "$expected_custom" "$empty_file"

nul_index=0
for nul_location in gate_id replay; do
  nul_index=$((nul_index + 1))
  nul_manifest="$work/nul-$nul_location.manifest"
  {
    printf 'version 1\n'
    if [ "$nul_location" = gate_id ]; then
      printf 'gate fa\000st ./fast\n'
    else
      printf 'gate fast ./fa\000st\n'
    fi
    printf 'gate static ./static\n'
    printf 'gate docker ./docker\n'
  } > "$nul_manifest"
  expected_nul_error="$work/expected-nul-$nul_index.error"
  printf 'INFRA required-gates manifest contains a NUL byte: %s\n' \
    "$nul_manifest" > "$expected_nul_error"
  capture_reducer "nul_$nul_index" "$success_json" "" "$nul_manifest"
  expect_capture_files "NUL in $nul_location fails closed without normalization" 125 \
    "$empty_file" "$expected_nul_error"
done

lf_manifest="$work/embedded-lf.manifest"
{
  printf 'version 1\n'
  printf 'gate fast ./fast\ninjected record\n'
  printf 'gate static ./static\n'
  printf 'gate docker ./docker\n'
} > "$lf_manifest"
expected_lf_error="$work/expected-lf.error"
printf 'INFRA unknown manifest entry at %s:3: injected\n' \
  "$lf_manifest" > "$expected_lf_error"
capture_reducer embedded_lf "$success_json" "" "$lf_manifest"
expect_capture_files "LF creates a new record and cannot hide injected manifest data" 125 \
  "$empty_file" "$expected_lf_error"

missing_manifest="$work/does-not-exist.manifest"
expected_missing_manifest_error="$work/expected-missing-manifest-error"
printf 'INFRA required-gates manifest is missing: %s\n' \
  "$missing_manifest" > "$expected_missing_manifest_error"
capture_reducer missing_manifest "$success_json" "" "$missing_manifest"
expect_capture_files "missing manifest fails before reduction with exact stderr" 125 \
  "$empty_file" "$expected_missing_manifest_error"

failed_wc_bin="$work/failed-wc-bin"
mkdir "$failed_wc_bin"
cat > "$failed_wc_bin/wc" <<'EOF'
#!/usr/bin/env bash
printf 'NATIVE WC LEAK\n' >&2
exit 70
EOF
chmod +x "$failed_wc_bin/wc"
expected_unreadable_manifest_error="$work/expected-unreadable-manifest-error"
printf 'INFRA required-gates manifest cannot be read: %s\n' \
  "$custom_manifest" > "$expected_unreadable_manifest_error"
capture_reducer unreadable_manifest "$success_json" "" "$custom_manifest" \
  "$failed_wc_bin:$PATH"
expect_capture_files "manifest read failure has exact suppressed diagnostics" 125 \
  "$empty_file" "$expected_unreadable_manifest_error"

bad_version_manifest="$work/bad-version.manifest"
{
  printf 'version 2\n'
  printf 'gate fast ./fast\n'
  printf 'gate static ./static\n'
  printf 'gate docker ./docker\n'
} > "$bad_version_manifest"
expected_bad_version_error="$work/expected-bad-version-error"
{
  printf 'INFRA unsupported or malformed manifest version at %s:1\n' "$bad_version_manifest"
  printf 'INFRA manifest version is missing: %s\n' "$bad_version_manifest"
} > "$expected_bad_version_error"
capture_reducer bad_version_manifest "$success_json" "" "$bad_version_manifest"
expect_capture_files "malformed manifest version has exact fail-closed diagnostics" 125 \
  "$empty_file" "$expected_bad_version_error"

duplicate_manifest="$work/duplicate.manifest"
{
  printf 'version 1\n'
  printf 'gate fast ./fast-one\n'
  printf 'gate fast ./fast-two\n'
  printf 'gate static ./static\n'
} > "$duplicate_manifest"
expected_duplicate_error="$work/expected-duplicate-error"
{
  printf 'INFRA duplicate gate ID in %s: fast\n' "$duplicate_manifest"
  printf 'INFRA manifest must define exactly the fast, static, and docker gates: %s\n' \
    "$duplicate_manifest"
  printf 'INFRA manifest is missing required gate: docker\n'
} > "$expected_duplicate_error"
capture_reducer duplicate_manifest "$success_json" "" "$duplicate_manifest"
expect_capture_files "duplicate and incomplete manifest errors are exact" 125 \
  "$empty_file" "$expected_duplicate_error"

unknown_entry_manifest="$work/unknown-entry.manifest"
{
  printf 'version 1\n'
  printf 'include surprise\n'
  printf 'gate fast ./fast\n'
  printf 'gate static ./static\n'
  printf 'gate docker ./docker\n'
} > "$unknown_entry_manifest"
expected_unknown_entry_error="$work/expected-unknown-entry-error"
printf 'INFRA unknown manifest entry at %s:2: include\n' \
  "$unknown_entry_manifest" > "$expected_unknown_entry_error"
capture_reducer unknown_entry_manifest "$success_json" "" "$unknown_entry_manifest"
expect_capture_files "unknown manifest entry has exact fail-closed diagnostic" 125 \
  "$empty_file" "$expected_unknown_entry_error"

no_jq_path="$work/no-jq-bin"
mkdir "$no_jq_path"
ln -s "$(command -v bash)" "$no_jq_path/bash"
ln -s "$(command -v dirname)" "$no_jq_path/dirname"
ln -s "$(command -v tr)" "$no_jq_path/tr"
ln -s "$(command -v wc)" "$no_jq_path/wc"
expected_no_jq="$work/expected-no-jq.md"
write_default_summary "$expected_no_jq" unknown unknown unknown \
  "unavailable: immutable diff base did not resolve" \
  "infrastructure error" 'required tool `jq` is unavailable.' "REQUIRED GATES INFRA"
capture_reducer missing_jq "$success_json" "" "" "$no_jq_path"
expect_capture_files "missing jq has exact exit 125 contract" 125 \
  "$expected_no_jq" "$empty_file"

usage_stdout="$work/usage.stdout"
usage_stderr="$work/usage.stderr"
usage_expected="$work/usage.expected"
usage_rc=0
env CI_NEEDS_JSON="$success_json" "$reducer" --unknown \
  > "$usage_stdout" 2> "$usage_stderr" || usage_rc=$?
printf 'Usage: %s [--manifest PATH]\n' "$reducer" > "$usage_expected"
if [ "$usage_rc" -eq 2 ] &&
  cmp -s "$empty_file" "$usage_stdout" &&
  cmp -s "$usage_expected" "$usage_stderr"; then
  pass "malformed command line has exact exit 2 usage contract"
else
  fail "malformed command line has exact exit 2 usage contract (rc=$usage_rc)"
  diff -u "$empty_file" "$usage_stdout" || true
  diff -u "$usage_expected" "$usage_stderr" || true
fi

printf 'SUMMARY failures=%s\n' "$failures"
if [ "$failures" -ne 0 ]; then
  exit 1
fi
