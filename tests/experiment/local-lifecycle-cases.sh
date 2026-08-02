#!/usr/bin/env bash
set -u -o pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
subcases=(
  "$repo_root/tests/install/local-install-cases.sh"
  "$repo_root/tests/experiment/local-config-cases.sh"
  "$repo_root/tests/experiment/local-image-catalog-cases.sh"
  "$repo_root/tests/experiment/install-store-cases.sh"
  "$repo_root/tests/experiment/install-state-cases.py"
  "$repo_root/tests/experiment/install-mutation-cases.py"
)
expected_count=121
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
  IST-PROV-001 \
  M-STORE-AUTH-001 M-STORE-SOURCE-001 M-STORE-ATOM-001 M-STORE-RETRY-001 \
  M-STORE-DUR-001 M-STORE-LAYOUT-001 M-STORE-KEY-001 M-STORE-VERIFY-001 \
  M-STORE-LIVE-001 M-STORE-UNCERT-001 M-STORE-STAGE-001 > "$expected"
: > "$observed"

infrastructure=0
for index in "${!subcases[@]}"; do
  subcase="${subcases[$index]}"
  output="$work/subcase-$index.out"
  if [ ! -f "$subcase" ]; then
    infrastructure=1
    continue
  fi
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
  awk '/^(PASS|FAIL) [A-Z0-9-]+ / {print}' "$output"
  awk '/^(PASS|FAIL) [A-Z0-9-]+ / {print $2}' "$output" >> "$observed"
  reported_assertions="$(awk '/^(PASS|FAIL) [A-Z0-9-]+ / {count++} END {print count + 0}' "$output")"
  reported_failures="$(awk '/^FAIL [A-Z0-9-]+ / {count++} END {print count + 0}' "$output")"
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
failures="$(awk '/^FAIL [A-Z0-9-]+ / {count++} END {print count + 0}' "$work"/subcase-*.out 2>/dev/null)"
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
printf 'EXPERIMENT LOCAL LIFECYCLE PASS\n'
