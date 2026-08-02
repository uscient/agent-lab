#!/usr/bin/env bash
set -u -o pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
all_subcases=(
  "$repo_root/tests/install/local-install-cases.sh"
  "$repo_root/tests/experiment/local-config-cases.sh"
  "$repo_root/tests/experiment/local-image-catalog-cases.sh"
  "$repo_root/tests/experiment/install-store-cases.sh"
  "$repo_root/tests/experiment/install-state-cases.py"
  "$repo_root/tests/experiment/install-integrity-cases.py"
  "$repo_root/tests/experiment/install-mutation-cases.py"
)
readonly all_subcases

if [ "$#" -eq 0 ]; then
  route=all
elif [ "$#" -eq 1 ]; then
  route="$1"
else
  printf 'Usage: %s [local|install]\n' "${BASH_SOURCE[0]}" >&2
  exit 2
fi

case "$route" in
  all)
    selected_start=0
    selected_count=7
    expected_start=1
    expected_count=133
    lane_count=3
    lane_map=(0 1 2 0 1 2 0)
    final_marker='EXPERIMENT LOCAL LIFECYCLE PASS'
    ;;
  local)
    selected_start=0
    selected_count=3
    expected_start=1
    expected_count=86
    lane_count=2
    lane_map=(0 0 1)
    final_marker='EXPERIMENT LOCAL LIFECYCLE PASS'
    ;;
  install)
    selected_start=3
    selected_count=4
    expected_start=87
    expected_count=47
    lane_count=1
    lane_map=(0 0 0 0)
    final_marker='EXPERIMENT INSTALL LIFECYCLE PASS'
    ;;
  *)
    printf 'Usage: %s [local|install]\n' "${BASH_SOURCE[0]}" >&2
    exit 2
    ;;
esac
readonly route selected_start selected_count expected_start expected_count
readonly lane_count
readonly lane_map
readonly final_marker
subcases=("${all_subcases[@]:$selected_start:$selected_count}")
readonly subcases

infrastructure_exit() {
  printf 'SUMMARY assertions=0 expected=%s failures=0 infra=1\n' "$expected_count"
  exit 125
}

if [ "${#all_subcases[@]}" -ne 7 ] ||
   [ "${#subcases[@]}" -ne "$selected_count" ] ||
   [ "${#lane_map[@]}" -ne "$selected_count" ]; then
  infrastructure_exit
fi

for mapped_lane in "${lane_map[@]}"; do
  case "$mapped_lane" in
    '' | *[!0-9]*) infrastructure_exit ;;
  esac
  if ((10#$mapped_lane >= lane_count)); then
    infrastructure_exit
  fi
done
for ((required_lane = 0; required_lane < lane_count; required_lane++)); do
  lane_present=0
  for mapped_lane in "${lane_map[@]}"; do
    if ((10#$mapped_lane == required_lane)); then
      lane_present=1
      break
    fi
  done
  [ "$lane_present" -eq 1 ] || infrastructure_exit
done

work=""
lane_pids=()
lifecycle_pid="$$"
lifecycle_pgid=""
lifecycle_sid=""
lifecycle_identity="$(ps -o pgid=,sid= -p "$lifecycle_pid" 2>/dev/null || true)"
read -r lifecycle_pgid lifecycle_sid <<< "$lifecycle_identity"

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

wait_lanes() {
  local lane pid
  local wait_infrastructure=0
  for lane in "${!lane_pids[@]}"; do
    pid="${lane_pids[$lane]}"
    [ -n "$pid" ] || continue
    lane_pids[lane]=""
    wait "$pid" 2>/dev/null || wait_infrastructure=1
  done
  lane_pids=()
  [ "$wait_infrastructure" -eq 0 ]
}

signal_lanes() {
  local pid
  for pid in "${lane_pids[@]}"; do
    [ -n "$pid" ] || continue
    kill -TERM "$pid" 2>/dev/null || true
  done
}

handle_signal() {
  local status="$1"

  trap '' HUP INT QUIT TERM
  trap - EXIT
  # A dedicated session can cancel its group without signaling an unrelated caller.
  if [ "$lifecycle_pgid" = "$lifecycle_pid" ] &&
     [ "$lifecycle_sid" = "$lifecycle_pid" ]; then
    kill -TERM -- "-$lifecycle_pgid" 2>/dev/null || true
  else
    signal_lanes
  fi
  # Descendants may ignore TERM; signal exits deliberately preserve the private work tree.
  exit "$status"
}

if ! work="$(mktemp -d)"; then
  printf 'SUMMARY assertions=0 expected=%s failures=0 infra=1\n' "$expected_count"
  exit 125
fi
trap 'cleanup_work >/dev/null 2>&1 || true' EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 131' QUIT
trap 'handle_signal 143' TERM

expected_all="$work/expected-all"
expected="$work/expected"
observed="$work/observed"
printf '%s\n' \
  PKG-001 PKG-002 PKG-003 PKG-004 PKG-005 \
  CFG-001 CFG-002 CFG-003 CFG-004 TOOL-001 \
  CAT-NAME-001 CAT-NAME-002 CAT-OCI-001 CAT-OCI-002 \
  CAT-ADD-001 CAT-ADD-002 CAT-ADD-003 CAT-ADD-004 CAT-NS-001 \
  CAT-CAS-001 CAT-CAS-002 CAT-CAS-003 CAT-CAS-004 \
  CAT-READ-001 CAT-READ-002 CAT-NOEF-001 CAT-CONC-001 CAT-CONC-002 \
  CAT-STATE-001 CAT-STATE-002 CAT-STATE-003 CAT-STATE-004 \
  CAT-STATE-005 CAT-STATE-006 CAT-STATE-007 CAT-STATE-008 \
  CAT-STATE-009 CAT-STATE-010 CAT-STATE-011 CAT-STATE-012 \
  CAT-STATE-013 CAT-STATE-014 CAT-STATE-015 CAT-STATE-016 CAT-STATE-018 CAT-STATE-017 \
  CAT-BOUND-001 CAT-BOUND-002 CAT-BOUND-003 CAT-BOUND-004 \
  CAT-CRASH-001 CAT-CRASH-002 CAT-CRASH-003 CAT-CRASH-004 CAT-CRASH-005 \
  CAT-CRASH-006 CAT-CRASH-007 CAT-CRASH-008 CAT-CRASH-009 CAT-CRASH-010 \
  CAT-CRASH-011 CAT-PLAT-001 \
  RES-ENTRY-001 RES-SNAP-001 RES-SNAP-002 RES-ENTRY-002 RES-ENTRY-003 \
  RES-ISOLATE-001 RES-STATE-001 RES-STATE-002 RES-STATE-003 RES-INPUT-001 \
  RES-SNAP-003 RES-AUTH-001 RES-INSTALL-001 RES-NOEF-001 \
  M-CAT-OCI-001 M-CAT-SHADOW-001 M-CAT-CAS-001 M-CAT-AUTH-001 M-RES-BIND-001 \
  M-CAT-NOEF-001 M-CAT-ADMIT-001 M-CAT-ATOM-001 M-CAT-DUR-001 M-CAT-STAGE-001 \
  INST-HOME-001 INST-UNKNOWN-001 INST-NAME-001 INST-PERMIT-001 INST-RECEIPT-001 \
  INST-INSPECT-001 INST-RETRY-001 INST-CONFLICT-001 INST-DENY-001 \
  INST-FORGE-001 INST-NOEF-001 INST-LOCAL-001 INST-RUNTIME-001 \
  IST-STATE-001 IST-LOCK-001 IST-STATE-002 IST-BOUND-001 IST-STATE-003 \
  IST-CONC-001 IST-CONC-002 IST-CRASH-001 IST-LIVE-001 IST-PLAT-001 \
  IST-PROV-001 IST-PREFLIGHT-001 IST-SNAPSHOT-001 IST-CONFIG-001 IST-READ-001 \
  IST-FAULT-001 \
  IIN-CLEAN-001 IIN-CONTRACT-001 IIN-BUNDLE-001 IIN-LOCK-001 \
  IIN-SNAPSHOT-001 IIN-PREFLIGHT-001 IIN-PLAN-001 \
  M-STORE-AUTH-001 M-STORE-SOURCE-001 M-STORE-ATOM-001 M-STORE-RETRY-001 \
  M-STORE-DUR-001 M-STORE-LAYOUT-001 M-STORE-KEY-001 M-STORE-VERIFY-001 \
  M-STORE-LIVE-001 M-STORE-UNCERT-001 M-STORE-STAGE-001 > "$expected"
mv "$expected" "$expected_all"
expected_all_count="$(wc -l < "$expected_all" 2>/dev/null || true)"
if [ "$expected_all_count" != 133 ]; then
  infrastructure_exit
fi
if ! awk -v start="$expected_start" -v count="$expected_count" \
  'NR >= start && NR < start + count {print}' "$expected_all" > "$expected"; then
  infrastructure_exit
fi
expected_selected_count="$(wc -l < "$expected" 2>/dev/null || true)"
if [ "$expected_selected_count" != "$expected_count" ]; then
  infrastructure_exit
fi
: > "$observed"

run_subcase() {
  local index="$1"
  local subcase="${subcases[$index]}"
  local output="$work/subcase-$index.out"
  local status_file="$work/subcase-$index.status"
  local rc

  if ! : > "$output"; then
    printf '125\n' > "$status_file" 2>/dev/null || true
    return 125
  fi
  if [ ! -f "$subcase" ]; then
    rc=125
  else
    case "$subcase" in
      *.py)
        if python3 -I -B "$subcase" > "$output" 2>&1; then
          rc=0
        else
          rc=$?
        fi
        ;;
      *)
        if bash "$subcase" > "$output" 2>&1; then
          rc=0
        else
          rc=$?
        fi
        ;;
    esac
  fi
  printf '%s\n' "$rc" > "$status_file"
}

run_lane() {
  local lane="$1"
  local index
  local lane_infrastructure=0

  for index in "${!subcases[@]}"; do
    [ "${lane_map[$index]}" -eq "$lane" ] || continue
    run_subcase "$index" || lane_infrastructure=1
  done
  [ "$lane_infrastructure" -eq 0 ]
}

infrastructure=0
for ((lane = 0; lane < lane_count; lane++)); do
  run_lane "$lane" &
  lane_pids+=("$!")
done
if ! wait_lanes; then
  infrastructure=1
fi

failures=0
for index in "${!subcases[@]}"; do
  output="$work/subcase-$index.out"
  status_file="$work/subcase-$index.status"
  rc=125
  if [ ! -f "$status_file" ] ||
     [ "$(wc -l < "$status_file" 2>/dev/null)" -ne 1 ] ||
     ! IFS= read -r rc < "$status_file"; then
    infrastructure=1
    rc=125
  fi
  if [ ! -f "$output" ]; then
    infrastructure=1
    continue
  fi
  awk '/^(PASS|FAIL) [A-Z0-9-]+ / {print}' "$output"
  awk '/^(PASS|FAIL) [A-Z0-9-]+ / {print $2}' "$output" >> "$observed"
  reported_assertions="$(awk '/^(PASS|FAIL) [A-Z0-9-]+ / {count++} END {print count + 0}' "$output")"
  reported_failures="$(awk '/^FAIL [A-Z0-9-]+ / {count++} END {print count + 0}' "$output")"
  failures=$((failures + reported_failures))
  expected_summary="SUMMARY assertions=$reported_assertions expected=$reported_assertions failures=$reported_failures infra=0"
  matching_summaries="$(grep -Fxc "$expected_summary" "$output" || true)"
  all_summaries="$(grep -c '^SUMMARY ' "$output" || true)"
  if [ "$matching_summaries" -ne 1 ] || [ "$all_summaries" -ne 1 ]; then
    infrastructure=1
  fi
  case "$rc" in
    0)
      if [ "$reported_failures" -ne 0 ]; then
        infrastructure=1
      fi
      ;;
    1)
      if [ "$reported_failures" -eq 0 ]; then
        infrastructure=1
      fi
      ;;
    *)
      infrastructure=1
      ;;
  esac
done

assertions="$(wc -l < "$observed")"
if ! cmp -s "$expected" "$observed"; then
  failures=$((failures + 1))
fi

if ! cleanup_work; then
  infrastructure=1
fi
trap - EXIT

printf 'SUMMARY assertions=%s expected=%s failures=%s infra=%s\n' \
  "$assertions" "$expected_count" "$failures" "$infrastructure"
if [ "$infrastructure" -ne 0 ]; then
  exit 125
fi
if [ "$failures" -ne 0 ]; then
  exit 1
fi
printf '%s\n' "$final_marker"
