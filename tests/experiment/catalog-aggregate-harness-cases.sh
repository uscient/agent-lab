#!/usr/bin/env bash
set -u -o pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
catalog_aggregate="$repo_root/tests/experiment/local-image-catalog-cases.sh"
expected_count=7
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
    if [ "$execution_id" = catalog-cases.sh ]; then
      printf 'if [ "${AGENT_LAB_CATALOG_AGG_SIGNAL_MODE:-}" = cooperative ]; then\n'
      printf '  sleep 30 &\n'
      printf '  descendant_pid=$!\n'
      printf '  printf "%%s\\n" "$descendant_pid" > "$control/bash-descendant.pid" || exit 125\n'
      printf '  touch "$control/bash-signal.ready" || exit 125\n'
      printf '  wait "$descendant_pid"\n'
      printf 'fi\n'
      printf 'if [ "${AGENT_LAB_CATALOG_AGG_SIGNAL_MODE:-}" = stubborn ]; then\n'
      printf '  (\n'
      printf "    trap '' HUP INT QUIT TERM\n"
      printf '    printf "%%s\\n" "$BASHPID" > "$control/stubborn-descendant.pid" || exit 125\n'
      printf '    touch "$control/stubborn-signal.ready" || exit 125\n'
      printf '    sleep 30\n'
      printf '  ) &\n'
      printf '  descendant_pid=$!\n'
      printf '  wait "$descendant_pid"\n'
      printf 'fi\n'
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
    printf 'import subprocess\n'
    printf 'import sys\n'
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
      printf 'if os.environ.get("AGENT_LAB_CATALOG_AGG_SIGNAL_MODE") == "cooperative":\n'
      printf '    descendant = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])\n'
      printf '    (control / "python-descendant.pid").write_text(str(descendant.pid), encoding="ascii")\n'
      printf '    (control / "python-signal.ready").touch()\n'
      printf '    descendant.wait()\n'
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

wait_for_process_exit() {
  local pid="$1"
  local attempts=0
  while kill -0 "$pid" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 200 ] || return 1
    sleep 0.01
  done
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

status_contract=1
reset_fixtures 1 0 FAIL:CAT-NAME-001
assertion_control="$work/assertion-control"
mkdir "$assertion_control"
assertion_rc=0
run_aggregate "$work/assertion.out" "$assertion_control" || assertion_rc=$?
if [ "$assertion_rc" -ne 1 ] ||
   ! grep -Fxq 'SUMMARY assertions=76 expected=76 failures=1 infra=0' \
     "$work/assertion.out" ||
   grep -Fxq 'EXPERIMENT LOCAL IMAGE CATALOG PASS' "$work/assertion.out" ||
   ! cmp -s <(LC_ALL=C sort "$expected_executions") \
     <(LC_ALL=C sort "$assertion_control/executions") ||
   [ "$(find "$assertion_control" -name '*.done' -type f | wc -l)" -ne 4 ]; then
  status_contract=0
fi

reset_fixtures 0 125
infra_control="$work/infra-control"
mkdir "$infra_control"
infra_rc=0
run_aggregate "$work/infra.out" "$infra_control" || infra_rc=$?
if [ "$infra_rc" -ne 125 ] ||
   ! grep -Fxq 'SUMMARY assertions=76 expected=76 failures=0 infra=1' \
     "$work/infra.out" ||
   grep -Fxq 'EXPERIMENT LOCAL IMAGE CATALOG PASS' "$work/infra.out" ||
   ! cmp -s <(LC_ALL=C sort "$expected_executions") \
     <(LC_ALL=C sort "$infra_control/executions") ||
   [ "$(find "$infra_control" -name '*.done' -type f | wc -l)" -ne 4 ]; then
  status_contract=0
fi

reset_fixtures 1 125 FAIL:CAT-NAME-001
mixed_control="$work/mixed-control"
mkdir "$mixed_control"
mixed_rc=0
run_aggregate "$work/mixed.out" "$mixed_control" || mixed_rc=$?
mixed_assertions="$(grep -Ec '^(PASS|FAIL) [A-Z0-9-]+ ' "$work/mixed.out" || true)"
if [ "$status_contract" -eq 1 ] && [ "$mixed_rc" -eq 125 ] &&
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

wait_contract=1
for hold_index in 0 1; do
  reset_fixtures
  wait_control="$work/wait-control-$hold_index"
  mkdir "$wait_control"
  : > "$wait_control/executions"
  if [ "$hold_index" -eq 0 ]; then
    hold_id=catalog-state-cases.py
    peer_done=(
      catalog-cases.sh.done
      catalog-resolution-cases.sh.done
      catalog-mutation-cases.py.done
    )
  else
    hold_id=catalog-mutation-cases.py
    peer_done=(
      catalog-state-cases.py.done
      catalog-cases.sh.done
      catalog-resolution-cases.sh.done
    )
  fi
  AGENT_LAB_CATALOG_AGG_CONTROL="$wait_control" \
  AGENT_LAB_CATALOG_AGG_HOLD="$hold_id" \
    bash "$replica_aggregate" > "$work/wait-$hold_index.out" 2>&1 &
  wait_pid=$!
  wait_case_contract=0
  if wait_for_path "$wait_control/hold.ready" &&
     wait_for_path "$wait_control/${peer_done[0]}" &&
     wait_for_path "$wait_control/${peer_done[1]}" &&
     wait_for_path "$wait_control/${peer_done[2]}" &&
     wait_for_child_wait "$wait_pid"; then
    wait_case_contract=1
  fi
  touch "$wait_control/hold.release"
  wait_rc=0
  wait "$wait_pid" || wait_rc=$?
  if [ "$wait_case_contract" -ne 1 ] || [ "$wait_rc" -ne 0 ] ||
     ! cmp -s "$expected_success" "$work/wait-$hold_index.out" ||
     ! cmp -s <(LC_ALL=C sort "$expected_executions") \
       <(LC_ALL=C sort "$wait_control/executions"); then
    wait_contract=0
  fi
done
if [ "$wait_contract" -eq 1 ]; then
  pass AGG-017 "catalog parent reaps both lanes before publishing success"
else
  fail AGG-017 "catalog parent reaps both lanes before publishing success"
fi

malformed_aggregate="$replica/tests/experiment/local-image-catalog-malformed-status.sh"
awk '
  index($0, "printf") && index($0, "$rc") && index($0, "$status") {
    print "  printf \"999999999999999999999999999999999999999999999999\\\\n\" > \"$status\""
    changed++
    next
  }
  { print }
  END { if (changed != 1) exit 42 }
' "$replica_aggregate" > "$malformed_aggregate"
malformed_mutation_rc=$?
chmod +x "$malformed_aggregate"
reset_fixtures
malformed_control="$work/malformed-control"
mkdir "$malformed_control"
: > "$malformed_control/executions"
malformed_rc=0
AGENT_LAB_CATALOG_AGG_CONTROL="$malformed_control" \
  bash "$malformed_aggregate" > "$work/malformed.out" 2>&1 || malformed_rc=$?
if [ "$malformed_mutation_rc" -eq 0 ] && [ "$malformed_rc" -eq 125 ] &&
   grep -Fxq 'SUMMARY assertions=76 expected=76 failures=0 infra=1' \
     "$work/malformed.out" &&
   ! grep -Fxq 'EXPERIMENT LOCAL IMAGE CATALOG PASS' "$work/malformed.out" &&
   cmp -s <(LC_ALL=C sort "$expected_executions") \
     <(LC_ALL=C sort "$malformed_control/executions"); then
  pass AGG-018 "malformed lane status fails closed before success"
else
  fail AGG-018 "malformed lane status fails closed before success"
fi

reset_fixtures
signal_control="$work/signal-control"
signal_tmp="$work/signal-tmp"
mkdir "$signal_control" "$signal_tmp"
: > "$signal_control/executions"
AGENT_LAB_CATALOG_AGG_CONTROL="$signal_control" \
AGENT_LAB_CATALOG_AGG_SIGNAL_MODE=cooperative \
TMPDIR="$signal_tmp" \
  bash "$replica_aggregate" > "$work/signal.out" 2>&1 &
signal_pid=$!
signal_setup=0
bash_descendant=""
python_descendant=""
if wait_for_path "$signal_control/bash-signal.ready" &&
   wait_for_path "$signal_control/python-signal.ready" &&
   IFS= read -r bash_descendant < "$signal_control/bash-descendant.pid" &&
   IFS= read -r python_descendant < "$signal_control/python-descendant.pid" &&
   [[ "$bash_descendant" =~ ^[0-9]+$ ]] &&
   [[ "$python_descendant" =~ ^[0-9]+$ ]] &&
   kill -0 "$bash_descendant" 2>/dev/null &&
   kill -0 "$python_descendant" 2>/dev/null; then
  signal_setup=1
fi
kill -TERM "$signal_pid" 2>/dev/null || true
signal_rc=0
wait "$signal_pid" || signal_rc=$?
bash_descendant_gone=0
python_descendant_gone=0
if [ -n "$bash_descendant" ] && wait_for_process_exit "$bash_descendant"; then
  bash_descendant_gone=1
fi
if [ -n "$python_descendant" ] && wait_for_process_exit "$python_descendant"; then
  python_descendant_gone=1
fi
if [ "$bash_descendant_gone" -ne 1 ] && [ -n "$bash_descendant" ]; then
  kill -KILL "$bash_descendant" 2>/dev/null || true
  wait_for_process_exit "$bash_descendant" || true
fi
if [ "$python_descendant_gone" -ne 1 ] && [ -n "$python_descendant" ]; then
  kill -KILL "$python_descendant" 2>/dev/null || true
  wait_for_process_exit "$python_descendant" || true
fi
if [ "$signal_setup" -eq 1 ] && [ "$signal_rc" -eq 143 ] &&
   [ "$bash_descendant_gone" -eq 1 ] && [ "$python_descendant_gone" -eq 1 ] &&
   ! grep -Fxq 'EXPERIMENT LOCAL IMAGE CATALOG PASS' "$work/signal.out"; then
  pass AGG-019 "catalog cancellation reaches cooperative lane descendants"
else
  fail AGG-019 "catalog cancellation reaches cooperative lane descendants"
fi

reset_fixtures
stubborn_control="$work/stubborn-control"
stubborn_tmp="$work/stubborn-tmp"
mkdir "$stubborn_control" "$stubborn_tmp"
: > "$stubborn_control/executions"
AGENT_LAB_CATALOG_AGG_CONTROL="$stubborn_control" \
AGENT_LAB_CATALOG_AGG_SIGNAL_MODE=stubborn \
TMPDIR="$stubborn_tmp" \
  bash "$replica_aggregate" > "$work/stubborn.out" 2>&1 &
stubborn_leader=$!
stubborn_setup=0
stubborn_pid=""
if wait_for_path "$stubborn_control/stubborn-signal.ready" &&
   IFS= read -r stubborn_pid < "$stubborn_control/stubborn-descendant.pid" &&
   [[ "$stubborn_pid" =~ ^[0-9]+$ ]] &&
   kill -0 "$stubborn_pid" 2>/dev/null; then
  stubborn_setup=1
fi
kill -TERM "$stubborn_leader" 2>/dev/null || true
stubborn_rc=0
wait "$stubborn_leader" || stubborn_rc=$?
stubborn_alive=0
stubborn_output_preserved=0
if [ -n "$stubborn_pid" ] && kill -0 "$stubborn_pid" 2>/dev/null; then
  stubborn_alive=1
  stubborn_output="$(readlink "/proc/$stubborn_pid/fd/1" 2>/dev/null || true)"
  if [ -n "$stubborn_output" ] && [ -e "$stubborn_output" ]; then
    stubborn_output_preserved=1
  fi
fi
if [ -n "$stubborn_pid" ]; then
  kill -KILL "$stubborn_pid" 2>/dev/null || true
  wait_for_process_exit "$stubborn_pid" || true
fi
if [ "$stubborn_setup" -eq 1 ] && [ "$stubborn_rc" -eq 143 ] &&
   [ "$stubborn_alive" -eq 1 ] && [ "$stubborn_output_preserved" -eq 1 ] &&
   ! grep -Fxq 'EXPERIMENT LOCAL IMAGE CATALOG PASS' "$work/stubborn.out"; then
  pass AGG-020 "catalog cancellation preserves stubborn descendant evidence"
else
  fail AGG-020 "catalog cancellation preserves stubborn descendant evidence"
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
