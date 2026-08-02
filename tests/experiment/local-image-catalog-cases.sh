#!/usr/bin/env bash
set -u -o pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
expected_count=76
work=""
declare -a lane_pids=()
declare -a signal_descendants=()
current_lane_pid=""

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

collect_descendants() {
  local parent_pid="$1"
  local children=""
  local child
  if [ -r "/proc/$parent_pid/task/$parent_pid/children" ]; then
    IFS= read -r children < "/proc/$parent_pid/task/$parent_pid/children" || true
  fi
  for child in $children; do
    if [[ ! "$child" =~ ^[0-9]+$ ]]; then
      continue
    fi
    signal_descendants[${#signal_descendants[@]}]="$child"
    collect_descendants "$child"
  done
}

catalog_signal() {
  local signal_name="$1"
  local signal_number="$2"
  local lane_pid
  local index
  trap '' HUP INT QUIT TERM
  trap - EXIT
  signal_descendants=()
  if [[ "$current_lane_pid" =~ ^[0-9]+$ ]]; then
    signal_descendants[${#signal_descendants[@]}]="$current_lane_pid"
    collect_descendants "$current_lane_pid"
  fi
  for lane_pid in "${lane_pids[@]}"; do
    if [[ ! "$lane_pid" =~ ^[0-9]+$ ]]; then
      continue
    fi
    signal_descendants[${#signal_descendants[@]}]="$lane_pid"
    collect_descendants "$lane_pid"
  done
  for ((index = ${#signal_descendants[@]} - 1; index >= 0; index--)); do
    kill "-$signal_name" -- "${signal_descendants[index]}" 2>/dev/null || true
  done
  exit $((128 + signal_number))
}

if ! work="$(mktemp -d)"; then
  printf 'SUMMARY assertions=0 expected=%s failures=0 infra=1\n' "$expected_count"
  exit 125
fi
trap 'cleanup_work >/dev/null 2>&1 || true' EXIT
trap 'catalog_signal HUP 1' HUP
trap 'catalog_signal INT 2' INT
trap 'catalog_signal QUIT 3' QUIT
trap 'catalog_signal TERM 15' TERM

subcases=(
  "$repo_root/tests/image/catalog-cases.sh"
  "$repo_root/tests/image/catalog-state-cases.py"
  "$repo_root/tests/experiment/catalog-resolution-cases.sh"
  "$repo_root/tests/image/catalog-mutation-cases.py"
)
expected="$work/expected"
observed="$work/observed"
: > "$observed"
printf '%s\n' \
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
  M-CAT-NOEF-001 M-CAT-ADMIT-001 M-CAT-ATOM-001 M-CAT-DUR-001 M-CAT-STAGE-001 > "$expected"
declared_count="$(wc -l < "$expected")"
if [ "$declared_count" -ne "$expected_count" ]; then
  printf 'INFRA catalog aggregate expected-count drift\n' >&2
  exit 125
fi
infrastructure=0
readonly lane_count=2

run_subcase() {
  local index="$1"
  local subcase="${subcases[$index]}"
  local output="$work/subcase-$index.out"
  local status="$work/subcase-$index.status"
  local rc=0

  if [ ! -f "$subcase" ]; then
    printf 'INFRA required catalog subcase is missing: %s\n' "$subcase" > "$output"
    printf '125\n' > "$status"
    return 0
  fi
  case "$subcase" in
    *.py)
      python3 -I -B "$subcase" > "$output" 2>&1 || rc=$?
      ;;
    *)
      bash "$subcase" > "$output" 2>&1 || rc=$?
      ;;
  esac
  printf '%s\n' "$rc" > "$status"
}

run_lane() {
  local lane="$1"
  local index
  local lane_subcases=()
  case "$lane" in
    0)
      lane_subcases=(1)
      ;;
    1)
      lane_subcases=(0 2 3)
      ;;
    *)
      return 125
      ;;
  esac
  for index in "${lane_subcases[@]}"; do
    run_subcase "$index" || return 125
  done
  return 0
}

for ((lane = 0; lane < lane_count; lane++)); do
  run_lane "$lane" &
  lane_pids[lane]=$!
done
for lane in "${!lane_pids[@]}"; do
  lane_rc=0
  current_lane_pid="${lane_pids[lane]}"
  lane_pids[lane]=""
  wait "$current_lane_pid" || lane_rc=$?
  current_lane_pid=""
  if [ "$lane_rc" -ne 0 ]; then
    infrastructure=1
  fi
done

failures=0
for index in "${!subcases[@]}"; do
  subcase="${subcases[$index]}"
  output="$work/subcase-$index.out"
  status="$work/subcase-$index.status"
  rc=125
  if [ ! -f "$output" ]; then
    printf 'INFRA catalog subcase output is missing: %s\n' "$subcase" >&2
    infrastructure=1
    continue
  fi
  if [ ! -f "$status" ] || [ "$(wc -l < "$status")" -ne 1 ] ||
     ! IFS= read -r rc < "$status"; then
    printf 'INFRA catalog subcase status is missing or invalid: %s\n' "$subcase" >&2
    rc=125
    infrastructure=1
  else
    case "$rc" in
      0 | 1 | 125)
        ;;
      *)
        printf 'INFRA catalog subcase status is missing or invalid: %s\n' "$subcase" >&2
        rc=125
        infrastructure=1
        ;;
    esac
  fi
  awk '/^(PASS|FAIL) [A-Z0-9-]+ /' "$output"
  awk '/^(PASS|FAIL) [A-Z0-9-]+ / {print $2}' "$output" >> "$observed"
  subcase_assertions="$(awk '/^(PASS|FAIL) [A-Z0-9-]+ / {count++} END {print count + 0}' "$output")"
  subcase_failures="$(awk '/^FAIL [A-Z0-9-]+ / {count++} END {print count + 0}' "$output")"
  failures=$((failures + subcase_failures))
  summary="SUMMARY assertions=$subcase_assertions expected=$subcase_assertions failures=$subcase_failures infra=0"
  summary_count="$(grep -Fxc "$summary" "$output" || true)"
  all_summary_count="$(grep -c '^SUMMARY ' "$output" || true)"
  if [ "$summary_count" -ne 1 ] || [ "$all_summary_count" -ne 1 ]; then
    printf 'INFRA catalog subcase summary is absent or inconsistent: %s\n' "$subcase" >&2
    awk '!/^(PASS|FAIL) [A-Z0-9-]+ / {print}' "$output" >&2
    infrastructure=1
  elif { [ "$rc" -eq 0 ] && [ "$subcase_failures" -ne 0 ]; } \
    || { [ "$rc" -eq 1 ] && [ "$subcase_failures" -eq 0 ]; } \
    || { [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; }; then
    printf 'INFRA catalog subcase status is inconsistent: rc=%s path=%s\n' "$rc" "$subcase" >&2
    awk '!/^(PASS|FAIL) [A-Z0-9-]+ / {print}' "$output" >&2
    infrastructure=1
  fi
done

assertions="$(wc -l < "$observed")"
if ! cmp -s "$expected" "$observed"; then
  printf 'FAIL catalog aggregate assertion identity drift\n' >&2
  diff -u "$expected" "$observed" >&2 || true
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
printf 'EXPERIMENT LOCAL IMAGE CATALOG PASS\n'
