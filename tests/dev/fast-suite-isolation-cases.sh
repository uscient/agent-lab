#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
if ! work="$(mktemp -d)"; then
  printf 'INFRA fast-suite isolation cannot create isolated work directory\n' >&2
  exit 125
fi
active_groups=()
watcher_stop="$work/stop-sensitive-watcher"

terminate_group() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  kill -TERM -- "-$pid" >/dev/null 2>&1 || kill -TERM "$pid" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" >/dev/null 2>&1 || break
    sleep 0.1
  done
  kill -KILL -- "-$pid" >/dev/null 2>&1 || kill -KILL "$pid" >/dev/null 2>&1 || true
}

cleanup() {
  local pid
  : > "$watcher_stop" 2>/dev/null || true
  for pid in "${active_groups[@]}"; do
    terminate_group "$pid"
  done
  for pid in "${active_groups[@]}"; do
    [ -z "$pid" ] || wait "$pid" >/dev/null 2>&1 || true
  done
  find "$work" -xdev -depth -delete >/dev/null 2>&1 || true
}
handle_signal() { exit 125; }
trap cleanup EXIT
trap handle_signal INT TERM

failures=0
ready=1
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

agent_fixture_is_coherent() {
  local suite="$1" all_invocations fixture_invocations fixture_input occurrences
  all_invocations="$(
    awk 'index($0, "scripts/agent\" --") { count++ } END { print count + 0 }' \
      "$suite"
  )"
  fixture_invocations="$(
    awk 'index($0, "\"$agent_root/scripts/agent\" --") { count++ } END { print count + 0 }' \
      "$suite"
  )"
  grep -Fq 'agent_root="$work/agent-root"' "$suite" &&
    [ "$all_invocations" -gt 0 ] &&
    [ "$all_invocations" -eq "$fixture_invocations" ] || return 1
  for fixture_input in \
    scripts/agent scripts/common \
    scripts/lib/allowlist.sh scripts/lib/config.sh scripts/lib/domain.sh \
    scripts/lib/egress.sh scripts/lib/guard.sh scripts/lib/image.sh \
    compose.yaml compose.egress.yaml compose.agent.yaml \
    compose.agent.ephemeral.yaml compose.agent.persist.yaml; do
    occurrences="$(
      awk -v needle="$fixture_input" \
        'index($0, needle) { count++ } END { print count + 0 }' "$suite"
    )"
    [ "$occurrences" -ge 2 ] || return 1
  done
}

require_agent_fixture() {
  local suite="$1" label="$2"
  if agent_fixture_is_coherent "$suite"; then
    pass "$label declares a suite-local agent root"
  else
    fail "$label declares a suite-local agent root"
    ready=0
  fi
}

policy_suite="$repo_root/tests/agent/policy-verify.sh"
config_suite="$repo_root/tests/agent/config-matrix.sh"
image_suite="$repo_root/tests/agent/image-volume-policy-cases.sh"
egress_suite="$repo_root/tests/egress/policy-transition-cases.sh"
validator="$repo_root/tools/validate.sh"

if grep -Fq 'tests/dev/fast-suite-isolation-cases.sh' "$validator"; then
  pass "strict validation requires the fast-suite isolation contract"
else
  fail "strict validation requires the fast-suite isolation contract"
  ready=0
fi

fixed_temp_rule="(^|[;[:space:]])[[:alpha:]_][[:alnum:]_]*=[\"']?/tmp(/|[\"']|[[:space:]]|\$)|(^|[;&|()[:space:]])[0-9]*>{1,2}[[:space:]]*[\"']?/tmp/"
source_has_fixed_temp_mutation() {
  grep -Fq '/tmp/pol_render.out' "$1" || grep -Eq "$fixed_temp_rule" "$1"
}

fixed_temp_source_failure=0
for suite in "$policy_suite" "$config_suite" "$image_suite" "$egress_suite"; do
  if source_has_fixed_temp_mutation "$suite"; then
    fixed_temp_source_failure=1
    fail "$(basename "$suite") has no fixed absolute temporary output"
  fi
done
if [ "$fixed_temp_source_failure" -eq 0 ]; then
  pass "fast suites have no fixed absolute temporary outputs"
else
  ready=0
fi

fixed_temp_mutant="$work/fixed-temp-mutant.sh"
cp "$policy_suite" "$fixed_temp_mutant"
printf '%s\n' 'legacy_output=/tmp/pol_render.out' ': > /tmp/pol_render.out' \
  >> "$fixed_temp_mutant"
if source_has_fixed_temp_mutation "$fixed_temp_mutant"; then
  pass "fixed-temp source contract rejects the historical mutation"
else
  fail "fixed-temp source contract rejects the historical mutation"
  ready=0
fi
require_agent_fixture "$config_suite" "config matrix"
require_agent_fixture "$image_suite" "image-volume policy"
require_agent_fixture "$egress_suite" "egress policy transition"

partial_fixture_mutant="$work/partial-fixture-mutant.sh"
if awk '
  !changed && index($0, "\"$agent_root/scripts/agent\" --") {
    sub(/"\$agent_root\/scripts\/agent" --/, "\"$repo_root/scripts/agent\" --")
    changed = 1
  }
  { print }
  END { if (!changed) exit 1 }
' "$config_suite" > "$partial_fixture_mutant" &&
   ! agent_fixture_is_coherent "$partial_fixture_mutant"; then
  pass "agent fixture contract rejects a partial invocation reversion"
else
  fail "agent fixture contract rejects a partial invocation reversion"
  ready=0
fi

missing_overlay_mutant="$work/missing-overlay-mutant.sh"
if awk '
  !changed && index($0, "\"$repo_root/compose.agent.persist.yaml\"") {
    changed = 1
    next
  }
  { print }
  END { if (!changed) exit 1 }
' "$config_suite" > "$missing_overlay_mutant" &&
   ! agent_fixture_is_coherent "$missing_overlay_mutant"; then
  pass "agent fixture contract rejects an omitted Compose dependency"
else
  fail "agent fixture contract rejects an omitted Compose dependency"
  ready=0
fi

failed_mktemp_bin="$work/failed-mktemp-bin"
mkdir -p "$failed_mktemp_bin"
cat > "$failed_mktemp_bin/mktemp" <<'EOF'
#!/usr/bin/env bash
exit 70
EOF
chmod +x "$failed_mktemp_bin/mktemp"
self_mktemp_rc=0
PATH="$failed_mktemp_bin:$PATH" bash "$0" --self-mktemp-probe \
  > "$work/failed-self-mktemp.stdout" 2> "$work/failed-self-mktemp.stderr" ||
  self_mktemp_rc=$?
if [ "$self_mktemp_rc" -eq 125 ] &&
   grep -Fqx 'INFRA fast-suite isolation cannot create isolated work directory' \
     "$work/failed-self-mktemp.stderr"; then
  pass "isolation contract fails closed when its own mktemp fails"
else
  fail "isolation contract fails closed when its own mktemp fails (rc=$self_mktemp_rc)"
  ready=0
fi

mktemp_probe_index=0
for mktemp_probe in \
  "$policy_suite|policy verification|INFRA policy verification cannot create isolated work directory" \
  "$config_suite|config matrix|INFRA config matrix cannot create isolated work directory" \
  "$image_suite|image-volume policy|INFRA image-volume policy cannot create isolated work directory" \
  "$egress_suite|egress policy transition|INFRA egress policy transition cannot create isolated work directory"; do
  mktemp_probe_index=$((mktemp_probe_index + 1))
  probe_suite="${mktemp_probe%%|*}"
  probe_rest="${mktemp_probe#*|}"
  probe_label="${probe_rest%%|*}"
  probe_diagnostic="${probe_rest#*|}"
  failed_mktemp_rc=0
  PATH="$failed_mktemp_bin:$PATH" bash "$probe_suite" \
    > "$work/failed-mktemp-$mktemp_probe_index.stdout" \
    2> "$work/failed-mktemp-$mktemp_probe_index.stderr" ||
    failed_mktemp_rc=$?
  if [ "$failed_mktemp_rc" -eq 125 ] &&
     grep -Fqx "$probe_diagnostic" \
       "$work/failed-mktemp-$mktemp_probe_index.stderr"; then
    pass "$probe_label fails closed when mktemp fails"
  else
    fail "$probe_label fails closed when mktemp fails (rc=$failed_mktemp_rc)"
    ready=0
  fi
done

validate_fixture="$work/validate-fixture"
mkdir -p \
  "$validate_fixture/tools" "$validate_fixture/tests/agent" \
  "$validate_fixture/tests/dev" "$validate_fixture/.serena" \
  "$validate_fixture/bin"
cp "$validator" "$validate_fixture/tools/validate.sh"
for input in \
  compose.yaml compose.egress.yaml compose.agent.yaml \
  compose.agent.persist.yaml compose.agent.ephemeral.yaml compose.serena.yaml; do
  : > "$validate_fixture/$input"
done
: > "$validate_fixture/.serena/project.yml"
cat > "$validate_fixture/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$validate_fixture/tools/containment-lint.sh" <<'EOF'
#!/usr/bin/env bash
exit "${VALIDATE_CONTAINMENT_RC:-0}"
EOF
cat > "$validate_fixture/tests/agent/invariants.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cp "$validate_fixture/tests/agent/invariants.sh" \
  "$validate_fixture/tests/agent/config-guard.sh"
cat > "$validate_fixture/tests/dev/fast-suite-isolation-cases.sh" <<'EOF'
#!/usr/bin/env bash
exit 125
EOF
chmod +x \
  "$validate_fixture/bin/docker" \
  "$validate_fixture/tools/containment-lint.sh" \
  "$validate_fixture/tests/agent/invariants.sh" \
  "$validate_fixture/tests/agent/config-guard.sh" \
  "$validate_fixture/tests/dev/fast-suite-isolation-cases.sh"

validate_infra_rc=0
PATH="$validate_fixture/bin:$PATH" \
  bash "$validate_fixture/tools/validate.sh" --strict \
  > "$work/validate-infra.stdout" 2> "$work/validate-infra.stderr" ||
  validate_infra_rc=$?
if [ "$validate_infra_rc" -eq 125 ]; then
  pass "strict validation preserves isolation infrastructure exit 125"
else
  fail "strict validation preserves isolation infrastructure exit 125 (rc=$validate_infra_rc)"
  ready=0
fi

validate_precedence_rc=0
PATH="$validate_fixture/bin:$PATH" VALIDATE_CONTAINMENT_RC=1 \
  bash "$validate_fixture/tools/validate.sh" --strict \
  > "$work/validate-precedence.stdout" 2> "$work/validate-precedence.stderr" ||
  validate_precedence_rc=$?
if [ "$validate_precedence_rc" -eq 1 ]; then
  pass "strict validation keeps assertion precedence over later infrastructure failure"
else
  fail "strict validation keeps assertion precedence over later infrastructure failure (rc=$validate_precedence_rc)"
  ready=0
fi

if [ "$ready" -ne 1 ]; then
  printf 'SUMMARY failures=%s\n' "$failures"
  exit 1
fi

hash_stream() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

stat_record() {
  if stat -c '%F|%a|%s' "$1" 2>/dev/null; then
    return 0
  fi
  stat -f '%HT|%Lp|%z' "$1"
}

stat_sensitive_root() {
  if stat -c '%F|%a|%s|%y|%z|%h|%d|%i' "$1" 2>/dev/null; then
    return 0
  fi
  stat -f '%HT|%Lp|%z|%m|%c|%l|%d|%i' "$1"
}

stat_sensitivity_root="$work/stat-sensitivity-root"
mkdir "$stat_sensitivity_root"
stat_sensitivity_before="$(stat_sensitive_root "$stat_sensitivity_root")"
mkdir "$stat_sensitivity_root/transient"
rmdir "$stat_sensitivity_root/transient"
stat_sensitivity_after="$(stat_sensitive_root "$stat_sensitivity_root")"
if [ "$stat_sensitivity_before" = "$stat_sensitivity_after" ]; then
  # BSD stat exposes whole-second timestamps. Cross a clock tick before the
  # portability retry so the parent-directory mutation remains observable.
  sleep 1
  mkdir "$stat_sensitivity_root/transient"
  rmdir "$stat_sensitivity_root/transient"
  stat_sensitivity_after="$(stat_sensitive_root "$stat_sensitivity_root")"
fi
if [ "$stat_sensitivity_before" != "$stat_sensitivity_after" ]; then
  pass "sensitive-root fingerprint records create/remove mutations"
else
  fail "sensitive-root fingerprint records create/remove mutations"
fi

fingerprint_sensitive_root() {
  local label="$1" root="$2"
  printf 'ROOT|%s\n' "$label"
  if [ ! -e "$root" ] && [ ! -L "$root" ]; then
    printf 'MISSING\n'
    return 0
  fi
  stat_sensitive_root "$root"
}

fingerprint_cache_path() {
  local label="$1" root="$2" item file_hash path_list fingerprint_rc=0
  printf 'ROOT|%s\n' "$label"
  if [ ! -e "$root" ] && [ ! -L "$root" ]; then
    printf 'MISSING\n'
    return 0
  fi
  path_list="$(mktemp "$work/cache-paths.XXXXXX")" || return 125
  if ! find "$root" -xdev -depth -print | LC_ALL=C sort > "$path_list"; then
    rm -f -- "$path_list"
    return 125
  fi
  while IFS= read -r item; do
    printf 'PATH|%s\n' "${item#"$root"}"
    stat_record "$item"
    if [ -L "$item" ]; then
      printf 'LINK|%s\n' "$(readlink "$item")"
    elif [ -f "$item" ]; then
      if ! file_hash="$(hash_file "$item")"; then
        fingerprint_rc=125
        break
      fi
      printf 'HASH|%s\n' "$file_hash"
    fi
  done < "$path_list"
  rm -f -- "$path_list"
  return "$fingerprint_rc"
}

cache_traversal_probe="$work/cache-traversal-probe"
mkdir "$cache_traversal_probe"
cache_traversal_rc=0
(
  find() { return 1; }
  fingerprint_cache_path cache-traversal-probe "$cache_traversal_probe" >/dev/null
) || cache_traversal_rc=$?
if [ "$cache_traversal_rc" -eq 125 ]; then
  pass "cache fingerprint fails closed when traversal fails"
else
  fail "cache fingerprint fails closed when traversal fails (rc=$cache_traversal_rc)"
fi

fingerprint_checkout() {
  {
    fingerprint_cache_path cache-squid "$repo_root/.cache/squid"
    # Never read secret bytes; root metadata detects the entry creation/removal
    # that these suites could cause if a relative secrets path escaped its fixture.
    fingerprint_sensitive_root checkout-root "$repo_root"
    fingerprint_sensitive_root repo-secrets "$repo_root/secrets"
  } | hash_stream
}

if compgen -G "$repo_root/.image-volume-secrets-*" >/dev/null; then
  printf 'INFRA pre-existing image-volume isolation path prevents safe overlap testing\n' >&2
  exit 125
fi

fingerprint_sensitive_paths() {
  {
    fingerprint_sensitive_root checkout-root "$repo_root"
    fingerprint_sensitive_root repo-secrets "$repo_root/secrets"
  } | hash_stream
}

sensitive_baseline="$(fingerprint_sensitive_paths)"
sensitive_violation="$work/sensitive-path-violation"
watch_sensitive_paths() {
  local current
  while [ ! -e "$watcher_stop" ]; do
    current="$(fingerprint_sensitive_paths)" || {
      : > "$sensitive_violation"
      return 0
    }
    if [ "$current" != "$sensitive_baseline" ] ||
       compgen -G "$repo_root/.image-volume-secrets-*" >/dev/null; then
      : > "$sensitive_violation"
      return 0
    fi
    sleep 0.05
  done
}

completion_valid() {
  local marker_type="$1" output="$2" last marker_count
  if grep -Eq '^[[:space:]]*(FAIL|SKIP|WARN|NOT_IMPLEMENTED)([[:space:]:]|$)' \
       "$output"; then
    return 1
  fi
  last="$(sed -n '$p' "$output")"
  case "$marker_type" in
    failures)
      marker_count="$(grep -Fxc 'SUMMARY failures=0' "$output" || true)"
      [ "$marker_count" -eq 1 ] && [ "$last" = 'SUMMARY failures=0' ]
      ;;
    policy)
      marker_count="$(
        grep -Ec '^SUMMARY pass=[0-9]+ fail=0 skip=0$' "$output" || true
      )"
      [ "$marker_count" -eq 1 ] &&
        [[ "$last" =~ ^SUMMARY\ pass=[0-9]+\ fail=0\ skip=0$ ]]
      ;;
  esac
}

printf '  WARN: hidden\nSUMMARY failures=0\n' > "$work/forbidden-status.out"
if completion_valid failures "$work/forbidden-status.out"; then
  fail "completion validation rejects indented forbidden status output"
else
  pass "completion validation rejects indented forbidden status output"
fi

baseline_fingerprint="$(fingerprint_checkout)"
# Cross a whole-second timestamp boundary before launching children so the BSD
# stat fallback can observe a rapid create/delete beneath a sensitive root.
sleep 1
set -m
watch_sensitive_paths &
sensitive_watcher_pid=$!
set +m
sensitive_watcher_index="${#active_groups[@]}"
active_groups+=("$sensitive_watcher_pid")
run_overlapping_pair() {
  local suite_id="$1" suite="$2" marker_type="$3"
  local pair="$work/$suite_id" go pid_one pid_two watchdog_pid
  local rc_one=0 rc_two=0 overlap_ready=0 current_fingerprint deadline
  local index_one index_two index_watchdog
  mkdir -p "$pair"
  go="$pair/go"

  set -m
  (
    : > "$pair/ready-1"
    while [ ! -e "$go" ]; do sleep 0.01; done
    exec bash "$suite"
  ) > "$pair/one.out" 2>&1 &
  pid_one=$!
  (
    : > "$pair/ready-2"
    while [ ! -e "$go" ]; do sleep 0.01; done
    exec bash "$suite"
  ) > "$pair/two.out" 2>&1 &
  pid_two=$!
  set +m
  index_one="${#active_groups[@]}"
  active_groups+=("$pid_one")
  index_two="${#active_groups[@]}"
  active_groups+=("$pid_two")

  set -m
  (
    sleep 30
    : > "$pair/timed-out"
    terminate_group "$pid_one"
    terminate_group "$pid_two"
  ) &
  watchdog_pid=$!
  set +m
  index_watchdog="${#active_groups[@]}"
  active_groups+=("$watchdog_pid")

  deadline=$((SECONDS + 5))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ -e "$pair/ready-1" ] && [ -e "$pair/ready-2" ]; then
      overlap_ready=1
      break
    fi
    sleep 0.01
  done
  if [ "$overlap_ready" -eq 1 ] &&
     kill -0 "$pid_one" 2>/dev/null && kill -0 "$pid_two" 2>/dev/null; then
    pass "$suite_id pair reaches a shared start barrier"
  else
    fail "$suite_id pair reaches a shared start barrier"
  fi
  : > "$go"

  wait "$pid_one" || rc_one=$?
  wait "$pid_two" || rc_two=$?
  active_groups[index_one]=""
  active_groups[index_two]=""
  terminate_group "$watchdog_pid"
  wait "$watchdog_pid" >/dev/null 2>&1 || true
  active_groups[index_watchdog]=""
  if [ -e "$pair/timed-out" ]; then
    rc_one=124
    rc_two=124
  fi
  if [ "$rc_one" -eq 0 ] && [ "$rc_two" -eq 0 ] &&
     completion_valid "$marker_type" "$pair/one.out" &&
     completion_valid "$marker_type" "$pair/two.out"; then
    pass "$suite_id overlapping runs complete with exact markers"
  else
    fail "$suite_id overlapping runs complete with exact markers (rc=$rc_one/$rc_two)"
    printf '%s\n' "---- $suite_id buffered child 1 ----"
    sed 's/^/  /' "$pair/one.out"
    printf '%s\n' "---- $suite_id buffered child 2 ----"
    sed 's/^/  /' "$pair/two.out"
  fi

  current_fingerprint="$(fingerprint_checkout)"
  if [ "$current_fingerprint" = "$baseline_fingerprint" ]; then
    pass "$suite_id leaves checkout mutable paths unchanged"
  else
    fail "$suite_id leaves checkout mutable paths unchanged"
  fi
}

cancellation_probe="$work/cancellation-probe"
mkdir "$cancellation_probe"
set -m
(
  sleep 60 &
  printf '%s\n' "$!" > "$cancellation_probe/descendant.pid"
  wait
) > "$cancellation_probe/output" 2>&1 &
cancellation_parent=$!
set +m
cancellation_index="${#active_groups[@]}"
active_groups+=("$cancellation_parent")
cancellation_deadline=$((SECONDS + 5))
while [ ! -s "$cancellation_probe/descendant.pid" ] &&
      [ "$SECONDS" -lt "$cancellation_deadline" ]; do
  sleep 0.01
done
cancellation_descendant=""
if [ -s "$cancellation_probe/descendant.pid" ]; then
  read -r cancellation_descendant < "$cancellation_probe/descendant.pid"
fi
terminate_group "$cancellation_parent"
wait "$cancellation_parent" >/dev/null 2>&1 || true
active_groups[cancellation_index]=""
if [ -n "$cancellation_descendant" ] &&
   ! kill -0 "$cancellation_parent" 2>/dev/null &&
   ! kill -0 "$cancellation_descendant" 2>/dev/null; then
  pass "isolation cancellation terminates parent and descendant processes"
else
  fail "isolation cancellation terminates parent and descendant processes"
fi

run_overlapping_pair policy-verify "$policy_suite" policy
run_overlapping_pair config-matrix "$config_suite" failures
run_overlapping_pair image-volume-policy "$image_suite" failures
run_overlapping_pair egress-policy-transition "$egress_suite" failures

: > "$watcher_stop"
wait "$sensitive_watcher_pid" >/dev/null 2>&1 || true
active_groups[sensitive_watcher_index]=""
if [ -e "$sensitive_violation" ]; then
  fail "supplemental polling observed a shared-path mutation"
else
  pass "supplemental polling observed no shared-path mutation"
fi

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
