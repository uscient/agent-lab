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

required_tools=(
  awk
  bash
  basename
  cat
  chmod
  cmp
  cp
  dirname
  env
  file
  find
  git
  grep
  head
  jq
  ln
  mkdir
  mktemp
  mv
  readlink
  rmdir
  sed
  shellcheck
  sort
  stat
  tr
  wc
)
for tool in "${required_tools[@]}"; do
  if awk -v wanted="$tool" '$1 == "tool" && $2 == wanted { found=1 } END { exit !found }' "$default_manifest"; then
    pass "default manifest requires tool $tool"
  else
    fail "default manifest is missing required tool $tool"
  fi
done
if awk '$1 == "tool-any" &&
        (($2 == "sha256sum" && $3 == "shasum") ||
         ($2 == "shasum" && $3 == "sha256sum")) { found=1 }
        END { exit !found }' "$default_manifest"; then
  pass "default manifest requires a SHA-256 provider"
else
  fail "default manifest is missing its SHA-256 provider contract"
fi

write_script "$work/pass.sh" "PASS fixture" 0
write_script "$work/empty.sh" "" 0
write_script "$work/skip-exit.sh" "SKIP fixture" 77
write_script "$work/skip-output.sh" "SKIP fixture" 0
write_script "$work/todo-output.sh" "NOT_IMPLEMENTED fixture" 0
write_script "$work/warn-output.sh" "WARN fixture" 0

cat > "$work/pass.manifest" <<EOF
tool bash
suite fixture-pass $work/pass.sh PASS fixture
EOF
expect_rc 0 "all-pass manifest succeeds" "$work/pass.manifest" "SECURITY GATE PASS"

cat > "$work/empty.manifest" <<EOF
tool bash
suite fixture-empty $work/empty.sh PASS fixture
EOF
expect_rc 1 "empty zero-exit suite blocks the gate" "$work/empty.manifest" "missing completion marker"

cat > "$work/missing-tool.manifest" <<EOF
tool agent_lab_missing_tool_for_test
suite fixture-pass $work/pass.sh PASS fixture
EOF
expect_rc 125 "missing prerequisite is infrastructure failure" "$work/missing-tool.manifest" "INFRA"

cat > "$work/tool-any-pass.manifest" <<EOF
tool-any agent_lab_missing_tool_for_test bash
suite fixture-pass $work/pass.sh PASS fixture
EOF
expect_rc 0 "one available alternative satisfies tool-any" \
  "$work/tool-any-pass.manifest" "SECURITY GATE PASS"

cat > "$work/tool-any-missing.manifest" <<EOF
tool-any agent_lab_missing_tool_a agent_lab_missing_tool_b
suite fixture-pass $work/pass.sh PASS fixture
EOF
expect_rc 125 "missing tool-any alternatives are infrastructure failure" \
  "$work/tool-any-missing.manifest" "need one of"

cat > "$work/missing-suite.manifest" <<EOF
tool bash
suite fixture-missing $work/does-not-exist.sh PASS fixture
EOF
expect_rc 125 "missing required suite is infrastructure failure" "$work/missing-suite.manifest" "INFRA"

cat > "$work/skip-exit.manifest" <<EOF
tool bash
suite fixture-skip $work/skip-exit.sh PASS fixture
EOF
expect_rc 1 "suite exit 77 blocks the gate" "$work/skip-exit.manifest" "SKIP"

cat > "$work/skip-output.manifest" <<EOF
tool bash
suite fixture-skip-output $work/skip-output.sh PASS fixture
EOF
expect_rc 1 "SKIP output blocks the gate" "$work/skip-output.manifest" "forbidden status output"

cat > "$work/todo-output.manifest" <<EOF
tool bash
suite fixture-todo-output $work/todo-output.sh PASS fixture
EOF
expect_rc 1 "NOT_IMPLEMENTED output blocks the gate" "$work/todo-output.manifest" "forbidden status output"

cat > "$work/warn-output.manifest" <<EOF
tool bash
suite fixture-warn-output $work/warn-output.sh PASS fixture
EOF
expect_rc 1 "WARN output blocks the gate" "$work/warn-output.manifest" "forbidden status output"

cat > "$work/no-suite.manifest" <<EOF
tool bash
EOF
expect_rc 125 "manifest with no suites is infrastructure failure" "$work/no-suite.manifest" "INFRA"

cat > "$work/duplicate.manifest" <<EOF
tool bash
suite duplicate $work/pass.sh PASS fixture
suite duplicate $work/pass.sh PASS fixture
EOF
expect_rc 125 "duplicate suite ID is infrastructure failure" "$work/duplicate.manifest" "INFRA"

runner_repo="$work/runner-repo"
mkdir -p "$runner_repo/scripts/dev" "$runner_repo/scripts/lib"
cp "$repo_root/scripts/dev/test" "$runner_repo/scripts/dev/test"
cp "$repo_root/scripts/dev/security-gate" "$runner_repo/scripts/dev/security-gate"
cp "$repo_root/scripts/dev/lint-scripts" "$runner_repo/scripts/dev/lint-scripts"
cp "$repo_root/scripts/lib/dev-common.sh" "$runner_repo/scripts/lib/dev-common.sh"
git -C "$runner_repo" init -q
runner_rc=0
runner_out="$(cd "$runner_repo" && bash scripts/dev/test quick 2>&1)" || runner_rc=$?
if [ "$runner_rc" -eq 125 ] && printf '%s\n' "$runner_out" | grep -Fq "required manifest is missing"; then
  pass "canonical test runner fails closed without its manifest"
else
  fail "canonical test runner fails closed without its manifest (rc=$runner_rc)"
  printf '%s\n' "$runner_out"
fi

validator_repo="$work/validator-repo"
mkdir -p "$validator_repo/tools"
cp "$repo_root/tools/validate.sh" "$validator_repo/tools/validate.sh"
validator_rc=0
validator_out="$(cd "$validator_repo" && bash tools/validate.sh --strict 2>&1)" || validator_rc=$?
if [ "$validator_rc" -eq 125 ] \
  && printf '%s\n' "$validator_out" | grep -Fq "required validation input is missing"; then
  pass "strict validation fails closed when required evidence is missing"
else
  fail "strict validation fails closed when required evidence is missing (rc=$validator_rc)"
  printf '%s\n' "$validator_out"
fi

mkdir -p "$work/no-docker-bin"
ln -s "$(command -v dirname)" "$work/no-docker-bin/dirname"
docker_rc=0
docker_out="$(
  cd "$repo_root" \
    && PATH="$work/no-docker-bin" /bin/bash tools/validate.sh --strict 2>&1
)" || docker_rc=$?
if [ "$docker_rc" -eq 125 ] && printf '%s\n' "$docker_out" | grep -Fq "docker is required"; then
  pass "strict validation reports missing Docker as infrastructure failure"
else
  fail "strict validation reports missing Docker as infrastructure failure (rc=$docker_rc)"
  printf '%s\n' "$docker_out"
fi

adapter_fixture="$work/adapter-source"
mkdir -p \
  "$adapter_fixture/.claude" \
  "$adapter_fixture/.codex/rules" \
  "$adapter_fixture/.grok" \
  "$adapter_fixture/policy" \
  "$adapter_fixture/tools"
cp "$repo_root/.claude/settings.json" "$adapter_fixture/.claude/settings.json"
cp "$repo_root/.codex/rules/agent-lab.rules" "$adapter_fixture/.codex/rules/agent-lab.rules"
cp "$repo_root/.grok/config.toml" "$adapter_fixture/.grok/config.toml"
cp "$repo_root/policy/allow.commands" "$adapter_fixture/policy/allow.commands"
cp "$repo_root/policy/protected.paths" "$adapter_fixture/policy/protected.paths"
cp "$repo_root/tools/render-adapters.sh" "$adapter_fixture/tools/render-adapters.sh"
printf '\n' >> "$adapter_fixture/.claude/settings.json"
adapter_rc=0
adapter_out="$(
  bash "$repo_root/tests/agent/render-adapters-idempotence.sh" "$adapter_fixture" 2>&1
)" || adapter_rc=$?
if [ "$adapter_rc" -ne 0 ] && printf '%s\n' "$adapter_out" | grep -Fq "generated adapter drift"; then
  pass "generated-adapter mutation turns the idempotence test red"
else
  fail "generated-adapter mutation turns the idempotence test red (rc=$adapter_rc)"
  printf '%s\n' "$adapter_out"
fi

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
