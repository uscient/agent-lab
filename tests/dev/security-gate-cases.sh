#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
gate="$repo_root/scripts/dev/security-gate"
default_manifest="$repo_root/tests/security/fast.manifest"
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

write_script() {
  local path="$1" output="$2" rc="$3"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf '\''%%s\\n'\'' %q\n' "$output"
    printf 'exit %s\n' "$rc"
  } > "$path"
  chmod +x "$path"
}

run_gate() {
  local manifest="$1"
  "$gate" --manifest "$manifest"
}

expect_rc() {
  local expected="$1" name="$2" manifest="$3" marker="${4:-}" rc=0 out
  out="$(run_gate "$manifest" 2>&1)" || rc=$?
  if [ "$rc" -eq "$expected" ] && {
    [ -z "$marker" ] || printf '%s\n' "$out" | grep -Fq "$marker"
  }; then
    pass "$name"
  else
    fail "$name (rc=$rc, expected=$expected, marker=$marker)"
    printf '%s\n' "$out"
  fi
}

if [ ! -x "$gate" ]; then
  fail "strict security gate exists and is executable"
  printf 'SUMMARY failures=%s\n' "$failures"
  exit 1
fi

required_ids=(
  lint
  guard-diff
  guard-command
  guard-mount
  config-authority
  adapter-idempotence
  policy-probe
  containment-static
)
for id in "${required_ids[@]}"; do
  if awk -v wanted="$id" '$1 == "suite" && $2 == wanted { found=1 } END { exit !found }' "$default_manifest"; then
    pass "default manifest requires $id"
  else
    fail "default manifest is missing required suite $id"
  fi
done

write_script "$work/pass.sh" "PASS fixture" 0
write_script "$work/skip-exit.sh" "SKIP fixture" 77
write_script "$work/skip-output.sh" "SKIP fixture" 0
write_script "$work/todo-output.sh" "NOT_IMPLEMENTED fixture" 0
write_script "$work/warn-output.sh" "WARN fixture" 0

cat > "$work/pass.manifest" <<EOF
tool bash
suite fixture-pass $work/pass.sh
EOF
expect_rc 0 "all-pass manifest succeeds" "$work/pass.manifest" "SECURITY GATE PASS"

cat > "$work/missing-tool.manifest" <<EOF
tool agent_lab_missing_tool_for_test
suite fixture-pass $work/pass.sh
EOF
expect_rc 125 "missing prerequisite is infrastructure failure" "$work/missing-tool.manifest" "INFRA"

cat > "$work/missing-suite.manifest" <<EOF
tool bash
suite fixture-missing $work/does-not-exist.sh
EOF
expect_rc 125 "missing required suite is infrastructure failure" "$work/missing-suite.manifest" "INFRA"

cat > "$work/skip-exit.manifest" <<EOF
tool bash
suite fixture-skip $work/skip-exit.sh
EOF
expect_rc 1 "suite exit 77 blocks the gate" "$work/skip-exit.manifest" "SKIP"

cat > "$work/skip-output.manifest" <<EOF
tool bash
suite fixture-skip-output $work/skip-output.sh
EOF
expect_rc 1 "SKIP output blocks the gate" "$work/skip-output.manifest" "forbidden status output"

cat > "$work/todo-output.manifest" <<EOF
tool bash
suite fixture-todo-output $work/todo-output.sh
EOF
expect_rc 1 "NOT_IMPLEMENTED output blocks the gate" "$work/todo-output.manifest" "forbidden status output"

cat > "$work/warn-output.manifest" <<EOF
tool bash
suite fixture-warn-output $work/warn-output.sh
EOF
expect_rc 1 "WARN output blocks the gate" "$work/warn-output.manifest" "forbidden status output"

cat > "$work/no-suite.manifest" <<EOF
tool bash
EOF
expect_rc 125 "manifest with no suites is infrastructure failure" "$work/no-suite.manifest" "INFRA"

cat > "$work/duplicate.manifest" <<EOF
tool bash
suite duplicate $work/pass.sh
suite duplicate $work/pass.sh
EOF
expect_rc 125 "duplicate suite ID is infrastructure failure" "$work/duplicate.manifest" "INFRA"

default_rc=0
default_out="$("$gate" 2>&1)" || default_rc=$?
if [ "$default_rc" -eq 0 ] && printf '%s\n' "$default_out" | grep -Fq "SECURITY GATE PASS"; then
  pass "default strict gate passes"
else
  fail "default strict gate passes (rc=$default_rc)"
  printf '%s\n' "$default_out"
fi

lint_rc=0
lint_out="$("$repo_root/scripts/dev/lint-scripts" 2>&1)" || lint_rc=$?
if [ "$lint_rc" -eq 0 ] \
  && printf '%s\n' "$lint_out" | grep -Fxq "tools/bin/git" \
  && printf '%s\n' "$lint_out" | grep -Fxq "tools/bin/gh"; then
  pass "lint discovers extensionless shell shims"
else
  fail "lint discovers extensionless shell shims (rc=$lint_rc)"
  printf '%s\n' "$lint_out"
fi

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
