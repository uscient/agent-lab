#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
gate="$repo_root/scripts/dev/security-gate"
gate_helper="$repo_root/scripts/dev/security-gate.py"
lint="$repo_root/scripts/dev/lint-scripts"
policy_probe="$repo_root/tests/agent/policy-verify.sh"
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

expect_nul_manifest_failure() {
  local name="$1" manifest="$2" rc=0
  "$gate" --manifest "$manifest" >"$manifest.stdout" 2>"$manifest.stderr" || rc=$?
  printf 'INFRA security-gate manifest contains a NUL byte: %s\n' "$manifest" \
    >"$manifest.expected"
  if [ "$rc" -eq 125 ] && [ ! -s "$manifest.stdout" ] \
    && cmp -s "$manifest.expected" "$manifest.stderr"; then
    pass "$name"
  else
    fail "$name (rc=$rc)"
    printf '%s\n' '--- stdout ---'
    cat "$manifest.stdout"
    printf '%s\n' '--- stderr ---'
    cat "$manifest.stderr"
  fi
}

expect_invalid_utf8_manifest_failure() {
  local name="$1" manifest="$2" rc=0
  "$gate" --manifest "$manifest" >"$manifest.stdout" 2>"$manifest.stderr" || rc=$?
  printf 'INFRA required manifest cannot be read: %s: invalid UTF-8\n' "$manifest" \
    >"$manifest.expected"
  if [ "$rc" -eq 125 ] && [ ! -s "$manifest.stdout" ] \
    && cmp -s "$manifest.expected" "$manifest.stderr"; then
    pass "$name"
  else
    fail "$name (rc=$rc)"
    printf '%s\n' '--- stdout ---'
    cat "$manifest.stdout"
    printf '%s\n' '--- stderr ---'
    cat "$manifest.stderr"
  fi
}

policy_has_literal_guard_matrix_reference() {
  [ -r "$1" ] || return 2
  awk '
    /^[[:space:]]*#/ { next }
    /tests\/guard\/pretooluse-cases\.sh/ { found=1 }
    END { exit !found }
  ' "$1"
}

if [ ! -x "$gate" ]; then
  fail "strict security gate exists and is executable"
  printf 'SUMMARY failures=%s\n' "$failures"
  exit 1
fi
if [ -r "$gate_helper" ]; then
  pass "stdlib security-gate helper exists and is readable"
else
  fail "stdlib security-gate helper exists and is readable"
fi

wrapper_only="$work/wrapper-only"
mkdir -p "$wrapper_only"
cp "$gate" "$wrapper_only/security-gate"
wrapper_only_rc=0
wrapper_only_out="$("$wrapper_only/security-gate" --help 2>&1)" || wrapper_only_rc=$?
if [ "$wrapper_only_rc" -eq 125 ] &&
  printf '%s\n' "$wrapper_only_out" | grep -Fq \
    "INFRA security-gate Python helper is unavailable: $wrapper_only/security-gate.py"; then
  pass "stable entrypoint fails closed without its Python helper"
else
  fail "stable entrypoint fails closed without its Python helper (rc=$wrapper_only_rc)"
  printf '%s\n' "$wrapper_only_out"
fi

no_python_bin="$work/no-python-bin"
mkdir -p "$no_python_bin"
ln -s "$(command -v bash)" "$no_python_bin/bash"
ln -s "$(command -v dirname)" "$no_python_bin/dirname"
no_python_rc=0
no_python_out="$(PATH="$no_python_bin" "$gate" --help 2>&1)" || no_python_rc=$?
if [ "$no_python_rc" -eq 125 ] &&
  [ "$no_python_out" = "INFRA security-gate requires python3" ]; then
  pass "stable entrypoint fails closed without python3"
else
  fail "stable entrypoint fails closed without python3 (rc=$no_python_rc)"
  printf '%s\n' "$no_python_out"
fi

real_python="$(command -v python3)"
counting_python_bin="$work/counting-python-bin"
counting_python_log="$work/counting-python.log"
counting_python_expected="Usage: $gate [fast|docker] [--manifest PATH]"
mkdir -p "$counting_python_bin"
ln -s "$(command -v bash)" "$counting_python_bin/bash"
ln -s "$(command -v dirname)" "$counting_python_bin/dirname"
cat > "$counting_python_bin/python3" <<'EOF'
#!/usr/bin/env bash
printf 'launch\n' >> "$PYTHON_LAUNCH_LOG"
exec "$REAL_PYTHON" "$@"
EOF
chmod +x "$counting_python_bin/python3"
: > "$counting_python_log"
counting_python_rc=0
counting_python_out="$({
  PATH="$counting_python_bin" \
    PYTHON_LAUNCH_LOG="$counting_python_log" \
    REAL_PYTHON="$real_python" \
    "$gate" --help
} 2>&1)" || counting_python_rc=$?
if [ "$counting_python_rc" -eq 0 ] &&
  [ "$(wc -l < "$counting_python_log")" -eq 1 ] &&
  [ "$counting_python_out" = "$counting_python_expected" ]; then
  pass "stable entrypoint starts one Python interpreter"
else
  fail "stable entrypoint starts one Python interpreter (rc=$counting_python_rc)"
  printf '%s\n' "$counting_python_out"
fi

old_python_bin="$work/old-python-bin"
mkdir -p "$old_python_bin"
ln -s "$(command -v bash)" "$old_python_bin/bash"
ln -s "$(command -v dirname)" "$old_python_bin/dirname"
cat > "$old_python_bin/python3" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "$1" = "-I" ] && [ "$2" = "-c" ]
shift 2
bootstrap="$1"
shift
exec "$REAL_PYTHON" -I -c \
  'import sys; code = sys.argv.pop(1); sys.version_info = (3, 10, 0); exec(code)' \
  "$bootstrap" "$@"
EOF
chmod +x "$old_python_bin/python3"
old_python_rc=0
old_python_out="$(
  PATH="$old_python_bin" REAL_PYTHON="$real_python" "$gate" --help 2>&1
)" || old_python_rc=$?
if [ "$old_python_rc" -eq 125 ] &&
  [ "$old_python_out" = "INFRA security-gate requires Python 3.11 or newer" ]; then
  pass "stable entrypoint fails closed below Python 3.11"
else
  fail "stable entrypoint fails closed below Python 3.11 (rc=$old_python_rc)"
  printf '%s\n' "$old_python_out"
fi

minimum_rc=0
minimum_out="$({ python3 -I - "$gate_helper" <<'PY'
import importlib.util
from pathlib import Path
import sys

path = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("agent_lab_security_gate", path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
module.sys.version_info = (3, 10, 0)
raise SystemExit(module.main([]))
PY
} 2>&1)" || minimum_rc=$?
if [ "$minimum_rc" -eq 125 ] &&
  [ "$minimum_out" = "INFRA security-gate requires Python 3.11 or newer" ]; then
  pass "security-gate enforces its explicit Python 3.11 minimum"
else
  fail "security-gate enforces its explicit Python 3.11 minimum (rc=$minimum_rc)"
  printf '%s\n' "$minimum_out"
fi

expected_suites="$work/expected-fast-suites"
cat > "$expected_suites" <<'EOF'
lint scripts/dev/lint-scripts
gate-contract tests/dev/security-gate-cases.sh
gate-concurrency tests/dev/security-gate-concurrency-cases.sh
ci-workflow-contract tests/dev/ci-workflow-cases.sh
required-gates-contract tests/dev/required-gates-cases.sh
guard-diff tests/dev/guard-diff-cases.sh
workflow-metadata tests/dev/workflow-check-cases.sh
coordination tests/dev/coord-cases.sh
docker-harness-contract tests/dev/docker-harness-cases.sh
guard-command tests/guard/pretooluse-cases.sh
guard-mount tests/guard/cases.sh
config-authority tests/agent/config-guard.sh
config-matrix tests/agent/config-matrix.sh
allowlist-schema tests/agent/allowlist-cases.sh
image-volume-policy tests/agent/image-volume-policy-cases.sh
runtime-inspector tests/agent/runtime-inspector-cases.sh
secret-parser tests/agent/entrypoint-secret-cases.sh
doctor-secret-scan tests/agent/doctor-secret-scan-cases.sh
egress-policy-transition tests/egress/policy-transition-cases.sh
dns-contract-unit tests/egress/dns-contract-cases.sh
wrapper-context tests/wrap-image/context-cases.sh
adapter-idempotence tests/agent/render-adapters-idempotence.sh
serena-config tests/serena/config-cases.sh
policy-probe tests/agent/policy-verify.sh
containment-static tools/containment-lint.sh
EOF
actual_suites="$work/actual-fast-suites"
awk '$1 == "suite" { print $2, $3 }' "$default_manifest" > "$actual_suites"
if cmp -s "$expected_suites" "$actual_suites"; then
  pass "default manifest has the exact required suite contract"
else
  fail "default manifest has the exact required suite contract"
  diff -u "$expected_suites" "$actual_suites" || true
fi

required_tools=(
  awk
  bash
  basename
  cat
  chmod
  cmp
  cp
  diff
  dirname
  env
  file
  find
  git
  grep
  jq
  ln
  mkdir
  mktemp
  mv
  python3
  readlink
  rmdir
  sed
  shellcheck
  sleep
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
write_script "$work/infra.sh" "INFRA fixture" 125

cat > "$work/pass.manifest" <<EOF
tool bash
suite fixture-pass $work/pass.sh PASS fixture
EOF
expect_rc 0 "all-pass manifest succeeds" "$work/pass.manifest" "SECURITY GATE PASS"

for invalid_jobs in 0 5 nope; do
  invalid_jobs_rc=0
  invalid_jobs_out="$(
    AGENT_LAB_SECURITY_GATE_JOBS="$invalid_jobs" \
      "$gate" --manifest "$work/pass.manifest" 2>&1
  )" || invalid_jobs_rc=$?
  if [ "$invalid_jobs_rc" -eq 125 ] &&
    [ "$invalid_jobs_out" = \
      "INFRA AGENT_LAB_SECURITY_GATE_JOBS must be an integer from 1 through 4" ]; then
    pass "invalid fast worker count $invalid_jobs fails closed"
  else
    fail "invalid fast worker count $invalid_jobs fails closed (rc=$invalid_jobs_rc)"
    printf '%s\n' "$invalid_jobs_out"
  fi
done

cat > "$work/cwd.sh" <<EOF
#!/usr/bin/env bash
if [ "\$PWD" != "$repo_root" ]; then
  printf 'FAIL fixture cwd=%s\n' "\$PWD"
  exit 1
fi
printf 'PASS fixture cwd\n'
EOF
chmod +x "$work/cwd.sh"
cat > "$work/cwd.manifest" <<EOF
tool bash
suite fixture-cwd $work/cwd.sh PASS fixture cwd
EOF
foreign_cwd="$work/foreign-cwd"
mkdir -p "$foreign_cwd"
foreign_cwd_rc=0
foreign_cwd_out="$(
  cd "$foreign_cwd" && "$gate" --manifest "$work/cwd.manifest" 2>&1
)" || foreign_cwd_rc=$?
if [ "$foreign_cwd_rc" -eq 0 ] &&
  printf '%s\n' "$foreign_cwd_out" | grep -Fq 'SECURITY GATE PASS'; then
  pass "security-gate suites execute from the repository root"
else
  fail "security-gate suites execute from the repository root (rc=$foreign_cwd_rc)"
  printf '%s\n' "$foreign_cwd_out"
fi

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

cat > "$work/infra.manifest" <<EOF
tool bash
suite fixture-infra $work/infra.sh INFRA fixture
EOF
expect_rc 125 "suite exit 125 is infrastructure failure" \
  "$work/infra.manifest" "reported infrastructure failure"

cat > "$work/mixed.manifest" <<EOF
tool bash
suite fixture-fail $work/skip-output.sh PASS fixture
suite fixture-infra $work/infra.sh INFRA fixture
suite fixture-after $work/pass.sh PASS fixture
EOF
expect_rc 1 "assertion failure takes precedence while every suite still executes" \
  "$work/mixed.manifest" "SECURITY GATE SUMMARY pass=1 fail=1 skip=0 infra=1"

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

printf 'tool ba\0sh\nsuite fixture-pass %s PASS fixture\n' "$work/pass.sh" \
  > "$work/nul-tool.manifest"
expect_nul_manifest_failure \
  "NUL in a tool entry is an exact infrastructure failure" "$work/nul-tool.manifest"

printf 'tool bash\nsuite fixture-pass %s PASS\0 fixture\n' "$work/pass.sh" \
  > "$work/nul-marker.manifest"
expect_nul_manifest_failure \
  "NUL in a suite marker is an exact infrastructure failure" "$work/nul-marker.manifest"

printf 'tool ba\377sh\nsuite fixture-pass %s PASS fixture\n' "$work/pass.sh" \
  > "$work/invalid-utf8.manifest"
expect_invalid_utf8_manifest_failure \
  "invalid UTF-8 in a manifest is an exact infrastructure failure" \
  "$work/invalid-utf8.manifest"

printf 'tool\302\240bash\nsuite fixture-pass %s PASS fixture\n' "$work/pass.sh" \
  > "$work/nbsp-separator.manifest"
expect_rc 125 "NBSP is not accepted as manifest field whitespace" \
  "$work/nbsp-separator.manifest" "INFRA"

printf 'tool\vbash\nsuite fixture-pass %s PASS fixture\n' "$work/pass.sh" \
  > "$work/vertical-tab-separator.manifest"
expect_rc 125 "vertical tab is not accepted as manifest field whitespace" \
  "$work/vertical-tab-separator.manifest" "INFRA"

printf 'tool\fbash\nsuite fixture-pass %s PASS fixture\n' "$work/pass.sh" \
  > "$work/form-feed-separator.manifest"
expect_rc 125 "form feed is not accepted as manifest field whitespace" \
  "$work/form-feed-separator.manifest" "INFRA"

printf 'tool\tbash \t\nsuite  fixture-pass\t%s  PASS fixture \t\n' \
  "$work/pass.sh" > "$work/ascii-whitespace.manifest"
expect_rc 0 "ASCII space and tab parsing retains legacy trailing-whitespace semantics" \
  "$work/ascii-whitespace.manifest" "SECURITY GATE PASS"

printf 'tool bash\r\nsuite fixture-pass %s PASS fixture\r\n' "$work/pass.sh" \
  > "$work/crlf.manifest"
expect_rc 125 "CRLF is not silently normalized by the manifest parser" \
  "$work/crlf.manifest" "missing required tool"

runner_repo="$work/runner-repo"
mkdir -p "$runner_repo/scripts/dev" "$runner_repo/scripts/lib"
cp "$repo_root/scripts/dev/test" "$runner_repo/scripts/dev/test"
cp "$repo_root/scripts/dev/security-gate" "$runner_repo/scripts/dev/security-gate"
cp "$repo_root/scripts/dev/security-gate.py" "$runner_repo/scripts/dev/security-gate.py"
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

lint_bin="$work/lint-bin"
mkdir -p "$lint_bin"
cat > "$lint_bin/shellcheck" <<'EOF'
#!/usr/bin/env bash
printf 'FAIL discovery-only mode invoked ShellCheck\n' >&2
exit 99
EOF
cat > "$lint_bin/head" <<'EOF'
#!/usr/bin/env bash
printf 'FAIL lint invoked poisoned head\n' >&2
exit 99
EOF
chmod +x "$lint_bin/shellcheck" "$lint_bin/head"
lint_rc=0
lint_out="$(PATH="$lint_bin:$PATH" LC_ALL=C "$lint" --list 2>&1)" || lint_rc=$?
printf '%s\n' "$lint_out" > "$work/lint-discovery.actual"
LC_ALL=C sort -u "$work/lint-discovery.actual" > "$work/lint-discovery.sorted"
if [ "$lint_rc" -eq 0 ] \
  && cmp -s "$work/lint-discovery.actual" "$work/lint-discovery.sorted" \
  && grep -Fxq "scripts/dev/lint-scripts" "$work/lint-discovery.actual" \
  && grep -Fxq "tools/bin/git" "$work/lint-discovery.actual" \
  && grep -Fxq "tools/bin/gh" "$work/lint-discovery.actual" \
  && ! grep -Eq '^(== bash -n ==|== shellcheck ==|PASS lint-scripts)$' \
       "$work/lint-discovery.actual"; then
  pass "lint discovery mode is deterministic and skips validation work"
else
  fail "lint discovery mode is deterministic and skips validation work (rc=$lint_rc)"
  printf '%s\n' "$lint_out"
fi

lint_validation_repo="$work/lint-validation-repo"
lint_validation_bin="$work/lint-validation-bin"
mkdir -p \
  "$lint_validation_repo/scripts/dev" \
  "$lint_validation_repo/scripts/lib" \
  "$lint_validation_repo/tests" \
  "$lint_validation_repo/tools" \
  "$lint_validation_bin"
cp "$repo_root/scripts/dev/lint-scripts" "$lint_validation_repo/scripts/dev/lint-scripts"
cp "$repo_root/scripts/lib/dev-common.sh" "$lint_validation_repo/scripts/lib/dev-common.sh"
cat > "$lint_validation_repo/tools/lower-shell" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$lint_validation_repo/tools/upper-shell" <<'EOF'
#!/usr/bin/env BASH
exit 0
EOF
printf '#!/usr/bin/env bash' > "$lint_validation_repo/tools/no-final-newline"
: > "$lint_validation_repo/tools/empty"
git -C "$lint_validation_repo" init -q
git -C "$lint_validation_repo" add scripts tools
cat > "$lint_validation_bin/head" <<'EOF'
#!/usr/bin/env bash
printf 'FAIL lint invoked poisoned head\n' >&2
exit 99
EOF
cat > "$lint_validation_bin/shellcheck" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$lint_validation_bin/head" "$lint_validation_bin/shellcheck"
lint_validation_rc=0
lint_validation_out="$(
  cd "$lint_validation_repo" &&
    env PATH="$lint_validation_bin:$PATH" LC_ALL=C BASHOPTS=nocasematch \
      bash scripts/dev/lint-scripts 2>&1
)" \
  || lint_validation_rc=$?
if [ "$lint_validation_rc" -eq 0 ] \
  && printf '%s\n' "$lint_validation_out" | grep -Fxq "tools/lower-shell" \
  && printf '%s\n' "$lint_validation_out" | grep -Fxq "tools/no-final-newline" \
  && ! printf '%s\n' "$lint_validation_out" | grep -Fxq "tools/upper-shell" \
  && ! printf '%s\n' "$lint_validation_out" | grep -Fxq "tools/empty" \
  && printf '%s\n' "$lint_validation_out" | grep -Fxq "PASS lint-scripts" \
  && ! printf '%s\n' "$lint_validation_out" | grep -Fq "poisoned head"; then
  pass "focused lint classifies shebangs without head or inherited nocasematch"
else
  fail "focused lint classifies shebangs without head or inherited nocasematch (rc=$lint_validation_rc)"
  printf '%s\n' "$lint_validation_out"
fi

lint_git_bin="$work/lint-git-bin"
mkdir -p "$lint_git_bin"
cat > "$lint_git_bin/git" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = ls-files ]; then
  printf 'scripts/dev/lint-scripts\n'
  exit 42
fi
exec "$AGENT_LAB_REAL_GIT" "$@"
EOF
chmod +x "$lint_git_bin/git"
lint_git_rc=0
lint_git_out="$(
  AGENT_LAB_REAL_GIT="$(command -v git)" \
    PATH="$lint_git_bin:$PATH" LC_ALL=C "$lint" --list 2>&1
)" || lint_git_rc=$?
if [ "$lint_git_rc" -eq 125 ] \
  && printf '%s\n' "$lint_git_out" | grep -Fq "INFRA shell script discovery failed" \
  && ! printf '%s\n' "$lint_git_out" | grep -Fxq "scripts/dev/lint-scripts"; then
  pass "failed tracked-file discovery is infrastructure failure with no partial list"
else
  fail "failed tracked-file discovery is infrastructure failure with no partial list (rc=$lint_git_rc)"
  printf '%s\n' "$lint_git_out"
fi

lint_unreadable_bin="$work/lint-unreadable-bin"
mkdir -p "$lint_unreadable_bin"
cat > "$lint_unreadable_bin/git" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = ls-files ]; then
  printf '%s\nscripts/dev/lint-scripts\n' "${AGENT_LAB_UNREADABLE_CANDIDATE:?}"
  exit 0
fi
exec "$AGENT_LAB_REAL_GIT" "$@"
EOF
chmod +x "$lint_unreadable_bin/git"
lint_unreadable_rc=0
: > "$work/lint-unreadable.stdout"
: > "$work/lint-unreadable.stderr"
unreadable_candidate=/proc/1/mem
if [ -r /proc/self/mem ]; then
  unreadable_candidate=/proc/self/mem
fi
(
  cd "$lint_validation_repo" &&
    AGENT_LAB_REAL_GIT="$(command -v git)" \
      AGENT_LAB_UNREADABLE_CANDIDATE="$unreadable_candidate" \
      PATH="$lint_unreadable_bin:$PATH" LC_ALL=C \
      bash scripts/dev/lint-scripts --list \
      > "$work/lint-unreadable.stdout" 2> "$work/lint-unreadable.stderr"
) || lint_unreadable_rc=$?
if [ "$lint_unreadable_rc" -eq 125 ] \
  && [ ! -s "$work/lint-unreadable.stdout" ] \
  && grep -Fq "INFRA cannot read shell candidate: $unreadable_candidate" \
       "$work/lint-unreadable.stderr"; then
  pass "read-failing extensionless candidate fails closed without a partial list"
else
  fail "read-failing extensionless candidate fails closed without a partial list (rc=$lint_unreadable_rc)"
  sed 's/^/  stdout: /' "$work/lint-unreadable.stdout"
  sed 's/^/  stderr: /' "$work/lint-unreadable.stderr"
fi

cat > "$work/nested-policy-mutant.sh" <<'EOF'
#!/usr/bin/env bash
if bash tests/guard/pretooluse-cases.sh; then
  printf 'nested guard matrix passed\n'
fi
EOF
if policy_has_literal_guard_matrix_reference "$work/nested-policy-mutant.sh"; then
  pass "literal nested guard-matrix detector catches a direct delegate"
else
  fail "literal nested guard-matrix detector catches a direct delegate"
fi
policy_scan_rc=0
policy_has_literal_guard_matrix_reference "$policy_probe" || policy_scan_rc=$?
case "$policy_scan_rc" in
  0) fail "policy probe has zero active literal nested guard-suite references" ;;
  1) pass "policy probe has zero active literal nested guard-suite references" ;;
  *) fail "policy probe source is unavailable for nested-suite inspection" ;;
esac

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
