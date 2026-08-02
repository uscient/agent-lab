#!/usr/bin/env bash
set -u -o pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
lifecycle="$repo_root/tests/experiment/local-lifecycle-cases.sh"
work="$(mktemp -d)"
trap 'find "$work" -type f -delete 2>/dev/null || true; find "$work" -type l -delete 2>/dev/null || true; find "$work" -depth -type d -exec rmdir {} + 2>/dev/null || true' EXIT
replica="$work/repo"
replica_lifecycle="$replica/tests/experiment/local-lifecycle-cases.sh"
mkdir -p "$replica/tests/experiment" "$replica/tests/install"
cp "$lifecycle" "$replica_lifecycle"
chmod +x "$replica_lifecycle"

failures=0
pass() { printf 'PASS %s %s\n' "$1" "$2"; }
fail() { printf 'FAIL %s %s\n' "$1" "$2"; failures=$((failures + 1)); }

expected_ids=(
  PKG-001 PKG-002 PKG-003 PKG-004 PKG-005
  CFG-001 CFG-002 CFG-003 CFG-004 TOOL-001
  CAT-NAME-001 CAT-NAME-002 CAT-OCI-001 CAT-OCI-002
  CAT-ADD-001 CAT-ADD-002 CAT-ADD-003 CAT-ADD-004 CAT-NS-001
  CAT-CAS-001 CAT-CAS-002 CAT-CAS-003 CAT-CAS-004
  CAT-READ-001 CAT-READ-002 CAT-NOEF-001 CAT-CONC-001 CAT-CONC-002
  CAT-STATE-001 CAT-STATE-002 CAT-STATE-003 CAT-STATE-004
  CAT-STATE-005 CAT-STATE-006 CAT-STATE-007 CAT-STATE-008
  CAT-STATE-009 CAT-STATE-010 CAT-STATE-011 CAT-STATE-012
  CAT-STATE-013 CAT-STATE-014 CAT-STATE-015 CAT-STATE-016 CAT-STATE-017
  CAT-BOUND-001 CAT-BOUND-002 CAT-CRASH-001 CAT-CRASH-002
  CAT-CRASH-003 CAT-CRASH-004 CAT-CRASH-005 CAT-CRASH-006 CAT-CRASH-007 CAT-PLAT-001
  RES-ENTRY-001 RES-SNAP-001 RES-SNAP-002 RES-ENTRY-002 RES-ENTRY-003
  RES-ISOLATE-001 RES-STATE-001 RES-STATE-002 RES-STATE-003 RES-INPUT-001
  RES-SNAP-003 RES-AUTH-001 RES-INSTALL-001 RES-NOEF-001
  M-CAT-OCI-001 M-CAT-CAS-001 M-CAT-AUTH-001 M-RES-BIND-001
  M-CAT-NOEF-001 M-CAT-ATOM-001 M-CAT-DUR-001 M-CAT-STAGE-001
)
installer_ids=("${expected_ids[@]:0:5}")
config_ids=("${expected_ids[@]:5:5}")
catalog_ids=("${expected_ids[@]:10}")

write_fixture() {
  local path="$1"
  local rc="$2"
  shift 2
  local record kind id fixture_failures=0
  {
    printf '#!/usr/bin/env bash\nset -u\n'
    for record in "$@"; do
      kind="${record%%:*}"
      id="${record#*:}"
      [ "$kind" = "FAIL" ] && fixture_failures=$((fixture_failures + 1))
      printf "printf '%s %s fixture assertion\\n'\n" "$kind" "$id"
    done
    printf "printf 'SUMMARY assertions=%s expected=%s failures=%s infra=0\\n'\n" \
      "$#" "$#" "$fixture_failures"
    printf 'exit %s\n' "$rc"
  } > "$path"
  chmod +x "$path"
}

pass_records() {
  local id
  for id in "$@"; do
    printf 'PASS:%s\n' "$id"
  done
}

reset_fixtures() {
  local installer_records=() config_records=() catalog_records=()
  mapfile -t installer_records < <(pass_records "${installer_ids[@]}")
  mapfile -t config_records < <(pass_records "${config_ids[@]}")
  mapfile -t catalog_records < <(pass_records "${catalog_ids[@]}")
  write_fixture "$replica/tests/install/local-install-cases.sh" 0 "${installer_records[@]}"
  write_fixture "$replica/tests/experiment/local-config-cases.sh" 0 "${config_records[@]}"
  write_fixture "$replica/tests/experiment/local-image-catalog-cases.sh" 0 "${catalog_records[@]}"
}

run_replica() {
  local output="$1"
  shift
  "$@" bash "$replica_lifecycle" > "$output" 2>&1
  return $?
}

if [ "$(grep -Fxc '  "$repo_root/tests/install/local-install-cases.sh"' "$lifecycle")" -eq 1 ] &&
   [ "$(grep -Fxc '  "$repo_root/tests/experiment/local-config-cases.sh"' "$lifecycle")" -eq 1 ] &&
   [ "$(grep -Fxc '  "$repo_root/tests/experiment/local-image-catalog-cases.sh"' "$lifecycle")" -eq 1 ] &&
   [ "$(grep -nF '  "$repo_root/tests/install/local-install-cases.sh"' "$lifecycle" | cut -d: -f1)" -lt "$(grep -nF '  "$repo_root/tests/experiment/local-config-cases.sh"' "$lifecycle" | cut -d: -f1)" ] &&
   [ "$(grep -nF '  "$repo_root/tests/experiment/local-config-cases.sh"' "$lifecycle" | cut -d: -f1)" -lt "$(grep -nF '  "$repo_root/tests/experiment/local-image-catalog-cases.sh"' "$lifecycle" | cut -d: -f1)" ]; then
  pass AGG-001 "lifecycle subcases are declared exactly once in order"
else
  fail AGG-001 "lifecycle subcases are declared exactly once in order"
fi

reset_fixtures
success_output="$work/success.out"
success_rc=0
run_replica "$success_output" env || success_rc=$?
if [ "$success_rc" -eq 0 ] &&
   [ "$(grep -Ec '^(PASS|FAIL) [A-Z0-9-]+ ' "$success_output")" -eq 77 ] &&
   [ "$(grep -Fxc 'SUMMARY assertions=77 expected=77 failures=0 infra=0' "$success_output")" -eq 1 ] &&
   [ "$(tail -n 1 "$success_output")" = 'EXPERIMENT LOCAL LIFECYCLE PASS' ] &&
   awk '/^(PASS|FAIL) [A-Z0-9-]+ / {next} /^SUMMARY assertions=77 expected=77 failures=0 infra=0$/ {next} /^EXPERIMENT LOCAL LIFECYCLE PASS$/ {next} {bad=1} END {exit bad}' "$success_output"; then
  pass AGG-002 "success forwards only assertions then one summary and marker"
else
  fail AGG-002 "success forwards only assertions then one summary and marker"
fi

missing_records=()
mapfile -t missing_records < <(pass_records "${installer_ids[@]:0:4}")
write_fixture "$replica/tests/install/local-install-cases.sh" 0 "${missing_records[@]}"
missing_rc=0
run_replica "$work/missing.out" env || missing_rc=$?
if [ "$missing_rc" -eq 1 ] && ! grep -Fxq 'EXPERIMENT LOCAL LIFECYCLE PASS' "$work/missing.out"; then
  pass AGG-003 "missing assertion identity maps to failure"
else
  fail AGG-003 "missing assertion identity maps to failure"
fi

reset_fixtures
duplicate_records=()
mapfile -t duplicate_records < <(pass_records "${installer_ids[@]}" PKG-005)
write_fixture "$replica/tests/install/local-install-cases.sh" 0 "${duplicate_records[@]}"
duplicate_rc=0
run_replica "$work/duplicate.out" env || duplicate_rc=$?
if [ "$duplicate_rc" -eq 1 ] && ! grep -Fxq 'EXPERIMENT LOCAL LIFECYCLE PASS' "$work/duplicate.out"; then
  pass AGG-004 "duplicate assertion identity maps to failure"
else
  fail AGG-004 "duplicate assertion identity maps to failure"
fi

reset_fixtures
substituted_records=()
mapfile -t substituted_records < <(pass_records "${installer_ids[@]:0:4}" BAD-001)
write_fixture "$replica/tests/install/local-install-cases.sh" 0 "${substituted_records[@]}"
substituted_rc=0
run_replica "$work/substituted.out" env || substituted_rc=$?
if [ "$substituted_rc" -eq 1 ] && ! grep -Fxq 'EXPERIMENT LOCAL LIFECYCLE PASS' "$work/substituted.out"; then
  pass AGG-005 "substituted assertion identity maps to failure"
else
  fail AGG-005 "substituted assertion identity maps to failure"
fi

reset_fixtures
failed_records=()
mapfile -t failed_records < <(pass_records "${installer_ids[@]}")
failed_records[0]='FAIL:PKG-001'
write_fixture "$replica/tests/install/local-install-cases.sh" 1 "${failed_records[@]}"
assertion_rc=0
run_replica "$work/assertion.out" env || assertion_rc=$?
if [ "$assertion_rc" -eq 1 ] &&
   grep -Fxq 'SUMMARY assertions=77 expected=77 failures=1 infra=0' "$work/assertion.out" &&
   ! grep -Fxq 'EXPERIMENT LOCAL LIFECYCLE PASS' "$work/assertion.out"; then
  pass AGG-006 "subcase assertion failure maps to one"
else
  fail AGG-006 "subcase assertion failure maps to one"
fi

reset_fixtures
uncertain_records=()
mapfile -t uncertain_records < <(pass_records "${installer_ids[@]}")
write_fixture "$replica/tests/install/local-install-cases.sh" 125 "${uncertain_records[@]}"
subcase_infra_rc=0
run_replica "$work/subcase-infra.out" env || subcase_infra_rc=$?
reset_fixtures
find "$replica/tests/install/local-install-cases.sh" -delete
setup_infra_rc=0
run_replica "$work/setup-infra.out" env || setup_infra_rc=$?
if [ "$subcase_infra_rc" -eq 125 ] && [ "$setup_infra_rc" -eq 125 ] &&
   ! grep -Fxq 'EXPERIMENT LOCAL LIFECYCLE PASS' "$work/subcase-infra.out" &&
   ! grep -Fxq 'EXPERIMENT LOCAL LIFECYCLE PASS' "$work/setup-infra.out"; then
  pass AGG-007 "setup and subcase uncertainty map to one hundred twenty-five"
else
  fail AGG-007 "setup and subcase uncertainty map to one hundred twenty-five"
fi

reset_fixtures
shim="$work/shim"
mkdir "$shim"
printf '#!/usr/bin/env bash\nexit 1\n' > "$shim/rmdir"
chmod +x "$shim/rmdir"
cleanup_rc=0
run_replica "$work/cleanup.out" env PATH="$shim:$PATH" || cleanup_rc=$?
if [ "$cleanup_rc" -eq 125 ] &&
   grep -Fxq 'SUMMARY assertions=77 expected=77 failures=0 infra=1' "$work/cleanup.out" &&
   ! grep -Fxq 'EXPERIMENT LOCAL LIFECYCLE PASS' "$work/cleanup.out"; then
  pass AGG-008 "cleanup uncertainty maps to one hundred twenty-five before the marker"
else
  fail AGG-008 "cleanup uncertainty maps to one hundred twenty-five before the marker"
fi

reset_fixtures
summaryless="$replica/tests/install/local-install-cases.sh"
{
  printf '#!/usr/bin/env bash\nset -u\n'
  for id in "${installer_ids[@]}"; do
    printf "printf 'PASS %s fixture assertion\\n'\n" "$id"
  done
  printf 'exit 0\n'
} > "$summaryless"
chmod +x "$summaryless"
summaryless_rc=0
run_replica "$work/summaryless.out" env || summaryless_rc=$?
if [ "$summaryless_rc" -eq 125 ] &&
   ! grep -Fxq 'EXPERIMENT LOCAL LIFECYCLE PASS' "$work/summaryless.out"; then
  pass AGG-009 "missing subcase summary maps to one hundred twenty-five"
else
  fail AGG-009 "missing subcase summary maps to one hundred twenty-five"
fi

printf 'SUMMARY assertions=9 expected=9 failures=%s infra=0\n' "$failures"
[ "$failures" -eq 0 ]
