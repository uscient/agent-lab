#!/usr/bin/env bash
set -u -o pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
catalog_aggregate="$repo_root/tests/experiment/local-image-catalog-cases.sh"
expected_count=4
work=""

cleanup_work() {
  local failed=0
  if [ -n "$work" ] && [ -e "$work" ]; then
    find "$work" -type f -delete 2>/dev/null || failed=1
    find "$work" -type l -delete 2>/dev/null || failed=1
    find "$work" -depth -type d -exec rmdir {} + 2>/dev/null || failed=1
    [ ! -e "$work" ] || failed=1
  fi
  return "$failed"
}

if ! work="$(mktemp -d)"; then
  printf 'SUMMARY assertions=0 expected=%s failures=0 infra=1\n' "$expected_count"
  exit 125
fi
trap 'cleanup_work >/dev/null 2>&1 || true' EXIT

replica="$work/repo"
replica_aggregate="$replica/tests/experiment/local-image-catalog-cases.sh"
mkdir -p "$replica/tests/experiment" "$replica/tests/image"
cp "$catalog_aggregate" "$replica_aggregate"
chmod +x "$replica_aggregate"

failures=0
pass() { printf 'PASS %s %s\n' "$1" "$2"; }
fail() { printf 'FAIL %s %s\n' "$1" "$2"; failures=$((failures + 1)); }

catalog_ids=(
  CAT-NAME-001 CAT-NAME-002 CAT-OCI-001 CAT-OCI-002
  CAT-ADD-001 CAT-ADD-002 CAT-ADD-003 CAT-ADD-004 CAT-NS-001
  CAT-CAS-001 CAT-CAS-002 CAT-CAS-003 CAT-CAS-004
  CAT-READ-001 CAT-READ-002 CAT-NOEF-001 CAT-CONC-001 CAT-CONC-002
  CAT-STATE-001 CAT-STATE-002 CAT-STATE-003 CAT-STATE-004
  CAT-STATE-005 CAT-STATE-006 CAT-STATE-007 CAT-STATE-008
  CAT-STATE-009 CAT-STATE-010 CAT-STATE-011 CAT-STATE-012
  CAT-STATE-013 CAT-STATE-014 CAT-STATE-015 CAT-STATE-016 CAT-STATE-018 CAT-STATE-017
  CAT-BOUND-001 CAT-BOUND-002 CAT-BOUND-003 CAT-BOUND-004
  CAT-CRASH-001 CAT-CRASH-002 CAT-CRASH-003 CAT-CRASH-004 CAT-CRASH-005
  CAT-CRASH-006 CAT-CRASH-007 CAT-CRASH-008 CAT-CRASH-009 CAT-CRASH-010
  CAT-CRASH-011 CAT-PLAT-001
  RES-ENTRY-001 RES-SNAP-001 RES-SNAP-002 RES-ENTRY-002 RES-ENTRY-003
  RES-ISOLATE-001 RES-STATE-001 RES-STATE-002 RES-STATE-003 RES-INPUT-001
  RES-SNAP-003 RES-AUTH-001 RES-INSTALL-001 RES-NOEF-001
  M-CAT-OCI-001 M-CAT-SHADOW-001 M-CAT-CAS-001 M-CAT-AUTH-001 M-RES-BIND-001
  M-CAT-NOEF-001 M-CAT-ADMIT-001 M-CAT-ATOM-001 M-CAT-DUR-001 M-CAT-STAGE-001
)
base_ids=("${catalog_ids[@]:0:18}")
state_ids=("${catalog_ids[@]:18:34}")
resolution_ids=("${catalog_ids[@]:52:14}")
mutation_ids=("${catalog_ids[@]:66:10}")

write_fixture() {
  local path="$1"
  local rc="$2"
  local role="$3"
  shift 3
  local id record_failures=0
  local execution_id="${path##*/}"
  {
    printf '#!/usr/bin/env bash\nset -u\n'
    printf 'control="${AGENT_LAB_CATALOG_AGG_CONTROL:?}"\n'
    printf "printf '%%s\\n' '%s' >> \"\$control/executions\" || exit 125\n" "$execution_id"
    if [ -n "$role" ]; then
      printf "touch \"\$control/%s.ready\" || exit 125\n" "$role"
      printf 'attempts=0\n'
      printf "while [ ! -f \"\$control/%s.ready\" ]; do\n" \
        "$([ "$role" = state ] && printf peer || printf state)"
      printf '  attempts=$((attempts + 1))\n'
      printf '  [ "$attempts" -lt 300 ] || exit 125\n'
      printf '  sleep 0.01\n'
      printf 'done\n'
    fi
    printf 'if [ "${AGENT_LAB_CATALOG_AGG_HOLD:-}" = "%s" ]; then\n' "$execution_id"
    printf '  touch "$control/hold.ready" || exit 125\n'
    printf '  attempts=0\n'
    printf '  while [ ! -f "$control/hold.release" ]; do\n'
    printf '    attempts=$((attempts + 1))\n'
    printf '    [ "$attempts" -lt 800 ] || exit 125\n'
    printf '    sleep 0.01\n'
    printf '  done\n'
    printf 'fi\n'
    for id in "$@"; do
      if [ "$id" = "FAIL:CAT-NAME-001" ]; then
        printf "printf 'FAIL CAT-NAME-001 fixture assertion\\n'\n"
        record_failures=$((record_failures + 1))
      else
        printf "printf 'PASS %s fixture assertion\\n'\n" "$id"
      fi
    done
    printf "printf 'SUMMARY assertions=%s expected=%s failures=%s infra=0\\n'\n" \
      "$#" "$#" "$record_failures"
    printf "touch \"\$control/%s.done\" || exit 125\n" "$execution_id"
    printf 'exit %s\n' "$rc"
  } > "$path"
  chmod +x "$path"
}

write_python_fixture() {
  local path="$1"
  local rc="$2"
  local role="$3"
  shift 3
  local id
  local execution_id="${path##*/}"
  {
    printf '#!/usr/bin/env python3\n'
    printf 'import os\n'
    printf 'from pathlib import Path\n'
    printf 'import time\n'
    printf 'control = Path(os.environ["AGENT_LAB_CATALOG_AGG_CONTROL"])\n'
    printf 'with (control / "executions").open("a", encoding="ascii") as stream:\n'
    printf '    stream.write("%s\\n")\n' "$execution_id"
    if [ "$role" = state ]; then
      printf '(control / "state.ready").touch()\n'
      printf 'deadline = time.monotonic() + 3.0\n'
      printf 'while not (control / "peer.ready").is_file():\n'
      printf '    if time.monotonic() >= deadline:\n'
      printf '        raise SystemExit(125)\n'
      printf '    time.sleep(0.01)\n'
    fi
    printf 'if os.environ.get("AGENT_LAB_CATALOG_AGG_HOLD") == "%s":\n' "$execution_id"
    printf '    (control / "hold.ready").touch()\n'
    printf '    deadline = time.monotonic() + 8.0\n'
    printf '    while not (control / "hold.release").is_file():\n'
    printf '        if time.monotonic() >= deadline:\n'
    printf '            raise SystemExit(125)\n'
    printf '        time.sleep(0.01)\n'
    for id in "$@"; do
      printf "print('PASS %s fixture assertion')\n" "$id"
    done
    printf "print('SUMMARY assertions=%s expected=%s failures=0 infra=0')\n" "$#" "$#"
    printf '(control / "%s.done").touch()\n' "$execution_id"
    printf 'raise SystemExit(%s)\n' "$rc"
  } > "$path"
  chmod +x "$path"
}

reset_fixtures() {
  local base_rc="${1:-0}"
  local state_rc="${2:-0}"
  local first_record="${3:-CAT-NAME-001}"
  local selected_base_ids=("${base_ids[@]}")
  selected_base_ids[0]="$first_record"
  write_fixture "$replica/tests/image/catalog-cases.sh" "$base_rc" peer \
    "${selected_base_ids[@]}"
  write_python_fixture "$replica/tests/image/catalog-state-cases.py" "$state_rc" state \
    "${state_ids[@]}"
  write_fixture "$replica/tests/experiment/catalog-resolution-cases.sh" 0 "" \
    "${resolution_ids[@]}"
  write_python_fixture "$replica/tests/image/catalog-mutation-cases.py" 0 "" \
    "${mutation_ids[@]}"
}

expected_executions="$work/expected-executions"
printf '%s\n' \
  catalog-cases.sh \
  catalog-state-cases.py \
  catalog-resolution-cases.sh \
  catalog-mutation-cases.py > "$expected_executions"

expected_success="$work/expected-success"
for id in "${catalog_ids[@]}"; do
  printf 'PASS %s fixture assertion\n' "$id"
done > "$expected_success"
printf 'SUMMARY assertions=76 expected=76 failures=0 infra=0\n' >> "$expected_success"
printf 'EXPERIMENT LOCAL IMAGE CATALOG PASS\n' >> "$expected_success"

run_aggregate() {
  local output="$1"
  local control="$2"
  shift 2
  : > "$control/executions"
  env AGENT_LAB_CATALOG_AGG_CONTROL="$control" "$@" \
    bash "$replica_aggregate" > "$output" 2>&1
}

wait_for_path() {
  local path="$1"
  local attempts=0
  while [ ! -e "$path" ]; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 500 ] || return 1
    sleep 0.01
  done
}

wait_for_child_wait() {
  local pid="$1"
  local attempts=0
  local wchan child_list
  local children=()
  while [ "$attempts" -lt 200 ]; do
    wchan="$(cat "/proc/$pid/wchan" 2>/dev/null || true)"
    child_list="$(cat "/proc/$pid/task/$pid/children" 2>/dev/null || true)"
    children=()
    read -r -a children <<< "$child_list"
    if [ "$wchan" = do_wait ] && [ "${#children[@]}" -eq 1 ]; then
      return 0
    fi
    attempts=$((attempts + 1))
    sleep 0.01
  done
  return 1
}

reset_fixtures
baseline_control="$work/baseline-control"
mkdir "$baseline_control"
baseline_rc=0
run_aggregate "$work/baseline.out" "$baseline_control" || baseline_rc=$?
if [ "$baseline_rc" -eq 0 ] &&
   cmp -s "$expected_success" "$work/baseline.out" &&
   cmp -s <(LC_ALL=C sort "$expected_executions") \
     <(LC_ALL=C sort "$baseline_control/executions") &&
   [ -f "$baseline_control/peer.ready" ] &&
   [ -f "$baseline_control/state.ready" ]; then
  pass AGG-014 "catalog subcases overlap with exact-once ordered replay"
else
  fail AGG-014 "catalog subcases overlap with exact-once ordered replay"
fi

lane_assignment_count="$(grep -Ec '^[[:space:]]*(readonly[[:space:]]+)?lane_count=' \
  "$replica_aggregate" || true)"
if [ "$lane_assignment_count" -eq 1 ] &&
   [ "$(grep -Fxc 'readonly lane_count=2' "$replica_aggregate")" -eq 1 ] &&
   [ "$(grep -Fxc 'for ((lane = 0; lane < lane_count; lane++)); do' \
     "$replica_aggregate")" -eq 1 ] &&
   [ "$(grep -Fxc '  run_lane "$lane" &' "$replica_aggregate")" -eq 1 ]; then
  pass AGG-015 "catalog scheduler declares one immutable two-lane bound"
else
  fail AGG-015 "catalog scheduler declares one immutable two-lane bound"
fi

reset_fixtures 1 125 FAIL:CAT-NAME-001
mixed_control="$work/mixed-control"
mkdir "$mixed_control"
mixed_rc=0
run_aggregate "$work/mixed.out" "$mixed_control" || mixed_rc=$?
mixed_assertions="$(grep -Ec '^(PASS|FAIL) [A-Z0-9-]+ ' "$work/mixed.out" || true)"
if [ "$mixed_rc" -eq 125 ] &&
   [ "$mixed_assertions" -eq 76 ] &&
   grep -Fxq 'SUMMARY assertions=76 expected=76 failures=1 infra=1' "$work/mixed.out" &&
   ! grep -Fxq 'EXPERIMENT LOCAL IMAGE CATALOG PASS' "$work/mixed.out" &&
   cmp -s <(LC_ALL=C sort "$expected_executions") \
     <(LC_ALL=C sort "$mixed_control/executions") &&
   [ "$(find "$mixed_control" -name '*.done' -type f | wc -l)" -eq 4 ]; then
  pass AGG-016 "catalog uncertainty dominates after every subcase completes"
else
  fail AGG-016 "catalog uncertainty dominates after every subcase completes"
fi

reset_fixtures
wait_control="$work/wait-control"
mkdir "$wait_control"
: > "$wait_control/executions"
AGENT_LAB_CATALOG_AGG_CONTROL="$wait_control" \
AGENT_LAB_CATALOG_AGG_HOLD=catalog-state-cases.py \
  bash "$replica_aggregate" > "$work/wait.out" 2>&1 &
wait_pid=$!
wait_contract=0
if wait_for_path "$wait_control/hold.ready" &&
   wait_for_path "$wait_control/catalog-cases.sh.done" &&
   wait_for_path "$wait_control/catalog-resolution-cases.sh.done" &&
   wait_for_path "$wait_control/catalog-mutation-cases.py.done" &&
   wait_for_child_wait "$wait_pid"; then
  wait_contract=1
fi
touch "$wait_control/hold.release"
wait_rc=0
wait "$wait_pid" || wait_rc=$?
if [ "$wait_contract" -eq 1 ] && [ "$wait_rc" -eq 0 ] &&
   cmp -s "$expected_success" "$work/wait.out" &&
   cmp -s <(LC_ALL=C sort "$expected_executions") \
     <(LC_ALL=C sort "$wait_control/executions"); then
  pass AGG-017 "catalog parent reaps both lanes before publishing success"
else
  fail AGG-017 "catalog parent reaps both lanes before publishing success"
fi

cleanup_infrastructure=0
if ! cleanup_work; then
  cleanup_infrastructure=1
fi
trap - EXIT

printf 'SUMMARY assertions=%s expected=%s failures=%s infra=%s\n' \
  "$expected_count" "$expected_count" "$failures" "$cleanup_infrastructure"
if [ "$cleanup_infrastructure" -ne 0 ]; then
  exit 125
fi
[ "$failures" -eq 0 ]
