#!/usr/bin/env bash
set -u -o pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
lifecycle="$repo_root/tests/experiment/local-lifecycle-cases.sh"
local_onboarding="$repo_root/tests/experiment/local-onboarding-cases.sh"
catalog_state_lifecycle="$repo_root/tests/experiment/catalog-state-lifecycle-cases.sh"
catalog_resolution_lifecycle="$repo_root/tests/experiment/catalog-resolution-lifecycle-cases.sh"
install_lifecycle="$repo_root/tests/experiment/install-lifecycle-cases.sh"
source_adapters="$repo_root/tests/experiment/source-adapter-cases.sh"
expected_count=25
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
replica_lifecycle="$replica/tests/experiment/local-lifecycle-cases.sh"
replica_local_onboarding="$replica/tests/experiment/local-onboarding-cases.sh"
replica_catalog_state="$replica/tests/experiment/catalog-state-lifecycle-cases.sh"
replica_catalog_resolution="$replica/tests/experiment/catalog-resolution-lifecycle-cases.sh"
replica_install_lifecycle="$replica/tests/experiment/install-lifecycle-cases.sh"
replica_source_adapters="$replica/tests/experiment/source-adapter-cases.sh"
mkdir -p "$replica/tests/experiment" "$replica/tests/install" "$replica/tests/image"
cp "$lifecycle" "$replica_lifecycle"
cp "$source_adapters" "$replica_source_adapters"
chmod +x "$replica_lifecycle" "$replica_source_adapters"

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
  CAT-STATE-013 CAT-STATE-014 CAT-STATE-015 CAT-STATE-016 CAT-STATE-018 CAT-STATE-017
  CAT-BOUND-001 CAT-BOUND-002 CAT-BOUND-003 CAT-BOUND-004
  CAT-CRASH-001 CAT-CRASH-002 CAT-CRASH-003 CAT-CRASH-004 CAT-CRASH-005
  CAT-CRASH-006 CAT-CRASH-007 CAT-CRASH-008 CAT-CRASH-009 CAT-CRASH-010 CAT-CRASH-011 CAT-PLAT-001
  RES-ENTRY-001 RES-SNAP-001 RES-SNAP-002 RES-ENTRY-002 RES-ENTRY-003
  RES-ISOLATE-001 RES-STATE-001 RES-STATE-002 RES-STATE-003 RES-INPUT-001
  RES-SNAP-003 RES-AUTH-001 RES-INSTALL-001 RES-NOEF-001
  M-CAT-OCI-001 M-CAT-SHADOW-001 M-CAT-CAS-001 M-CAT-AUTH-001 M-RES-BIND-001
  M-CAT-NOEF-001 M-CAT-ADMIT-001 M-CAT-ATOM-001 M-CAT-DUR-001 M-CAT-STAGE-001
  INST-HOME-001 INST-UNKNOWN-001 INST-NAME-001 INST-PERMIT-001 INST-RECEIPT-001
  INST-INSPECT-001 INST-RETRY-001 INST-CONFLICT-001 INST-DENY-001
  INST-FORGE-001 INST-NOEF-001 INST-LOCAL-001 INST-RUNTIME-001
  IST-STATE-001 IST-LOCK-001 IST-STATE-002 IST-BOUND-001 IST-STATE-003
  IST-CONC-001 IST-CONC-002 IST-CRASH-001 IST-LIVE-001 IST-PLAT-001 IST-PROV-001
  IST-PREFLIGHT-001 IST-SNAPSHOT-001 IST-CONFIG-001 IST-READ-001 IST-FAULT-001
  IIN-CLEAN-001 IIN-CONTRACT-001 IIN-BUNDLE-001 IIN-LOCK-001
  IIN-SNAPSHOT-001 IIN-PREFLIGHT-001 IIN-PLAN-001
  M-STORE-AUTH-001 M-STORE-SOURCE-001 M-STORE-ATOM-001 M-STORE-RETRY-001
  M-STORE-DUR-001 M-STORE-LAYOUT-001 M-STORE-KEY-001 M-STORE-VERIFY-001
  M-STORE-LIVE-001 M-STORE-UNCERT-001 M-STORE-STAGE-001
)
installer_ids=("${expected_ids[@]:0:5}")
config_ids=("${expected_ids[@]:5:5}")
catalog_base_ids=("${expected_ids[@]:10:18}")
catalog_state_ids=("${expected_ids[@]:28:34}")
catalog_resolution_ids=("${expected_ids[@]:62:14}")
catalog_mutation_ids=("${expected_ids[@]:76:10}")
install_ids=("${expected_ids[@]:86:13}")
state_ids=("${expected_ids[@]:99:16}")
integrity_ids=("${expected_ids[@]:115:7}")
mutation_ids=("${expected_ids[@]:122:11}")

# One rendezvous participant per lane of the compatibility route, one per public
# route, and one per lane of the install route. A participant blocks until every
# peer in its own set has started, so a serialized scheduler can never satisfy
# it whatever the elapsed time is.
lane_barrier_ids=(
  local-install-cases.sh
  catalog-state-cases.py
  catalog-resolution-cases.sh
)
split_barrier_ids=(
  local-install-cases.sh
  catalog-state-cases.py
  catalog-resolution-cases.sh
  install-state-cases.py
)
local_barrier_ids=(
  local-install-cases.sh
  catalog-cases.sh
)
resolution_barrier_ids=(
  catalog-resolution-cases.sh
  catalog-mutation-cases.py
)
install_barrier_ids=(
  install-store-cases.sh
  install-state-cases.py
)

member_of() {
  local needle="$1"
  shift
  local candidate
  for candidate in "$@"; do
    [ "$candidate" = "$needle" ] || continue
    return 0
  done
  return 1
}
source_zip_ids=(
  ZIP-001 ZIP-COMPAT-001 ZIP-USAGE-001 ZIP-PATH-001 ZIP-COUNT-001 ZIP-TYPE-001
  ZIP-META-001 ZIP-FLAG-001 ZIP-METHOD-001 ZIP-ZIP64-001 ZIP-HEADER-001 ZIP-CRC-001
  ZIP-LENGTH-001 ZIP-SIZE-001 ZIP-BOMB-001 ZIP-TRUNC-001 ZIP-TRAIL-001 ZIP-SIZE-002
  ZIP-READ-001 ZIP-READ-002 ZIP-DECODE-001 ZIP-DECODE-003 ZIP-DECODE-002
  ZIP-TIMEOUT-001 ZIP-OUTPUT-001 ZIP-NOEF-001 ZIP-AUTH-001 ZIP-INSTALL-001
  ZIP-RETRY-001 ZIP-DENY-001 ZIP-PLAT-001 ZIP-NOEF-002 ZIP-RUNTIME-001
)
source_mutation_ids=(
  M-ZIP-WATCHDOG-001 M-ZIP-COUNT-001 M-ZIP-NAME-001 M-ZIP-TYPE-001 M-ZIP-FLAG-001
  M-ZIP-METHOD-001 M-ZIP-SIZE-001 M-ZIP-BOMB-001 M-ZIP-CRC-001
  M-ZIP-HEADER-001 M-ZIP-EXTRACT-001 M-ZIP-IDENTITY-001 M-ZIP-AUTH-001
)
source_git_ids=(
  GIT-CLI-001 GIT-USAGE-001 GIT-URL-001 GIT-OID-001 GIT-PLAT-001
  GIT-FIXTURE-001 GIT-PIN-001 GIT-COMMIT-001 GIT-ROOT-001 GIT-TYPE-001
  GIT-BLOB-001 GIT-DRIFT-001 GIT-AUTHORITY-001 GIT-CREDENTIAL-001
  GIT-REDIRECT-001 GIT-CONTENT-001 GIT-TIMEOUT-001 GIT-OUTPUT-001
  GIT-ACQUIRE-001 GIT-PGROUP-001 GIT-CLEANUP-001 GIT-TAXONOMY-001
  GIT-CHECK-001 GIT-AUTH-001 GIT-DENY-001 GIT-INSTALL-001
  GIT-IDENTITY-001 GIT-RETRY-001 GIT-ADAPTER-001 GIT-NOEF-001
  GIT-RUNTIME-001 GIT-DIAG-001
)
source_git_mutation_ids=(
  M-GIT-AUTHORITY-001 M-GIT-REF-001 M-GIT-BOUND-001 M-GIT-IDENTITY-001
  M-GIT-DOWNSTREAM-001
)
source_expected_ids=(
  "${source_zip_ids[@]}"
  "${source_mutation_ids[@]}"
  "${source_git_ids[@]}"
  "${source_git_mutation_ids[@]}"
)

emit_bash_barrier() {
  local variable="$1"
  local execution_id="$2"
  shift 2
  local peer
  local separator='  while '

  member_of "$execution_id" "$@" || return 0
  printf 'if [ -n "${%s:-}" ]; then\n' "$variable"
  printf "  : > \"\$%s/%s.ready\" || exit 125\n" "$variable" "$execution_id"
  printf '  attempts=0\n'
  for peer in "$@"; do
    printf '%s[ ! -f "$%s/%s.ready" ]' "$separator" "$variable" "$peer"
    separator=' ||
        '
  done
  printf '; do\n'
  printf '    attempts=$((attempts + 1))\n'
  printf '    [ "$attempts" -lt 500 ] || exit 125\n'
  printf '    sleep 0.01\n'
  printf '  done\n'
  printf 'fi\n'
}

emit_python_barrier() {
  local variable="$1"
  local execution_id="$2"
  shift 2
  local peer
  local slot="barrier_${variable,,}"

  member_of "$execution_id" "$@" || return 0
  printf "%s = os.environ.get('%s')\n" "$slot" "$variable"
  printf 'if %s:\n' "$slot"
  printf "    Path(%s, '%s.ready').touch()\n" "$slot" "$execution_id"
  printf '    peers = (\n'
  for peer in "$@"; do
    printf "        '%s.ready',\n" "$peer"
  done
  printf '    )\n'
  printf '    deadline = time.monotonic() + 5.0\n'
  printf '    while not all(Path(%s, peer).is_file() for peer in peers):\n' "$slot"
  printf '        if time.monotonic() >= deadline:\n'
  printf '            raise SystemExit(125)\n'
  printf '        time.sleep(0.01)\n'
}

write_fixture() {
  local path="$1"
  local rc="$2"
  shift 2
  local record kind id fixture_failures=0
  local execution_id="${path##*/}"
  {
    printf '#!/usr/bin/env bash\nset -u\n'
    printf 'if [ -n "${AGENT_LAB_AGG_EXEC_LOG:-}" ]; then\n'
    printf "  printf '%%s\\n' '%s' >> \"\$AGENT_LAB_AGG_EXEC_LOG\" || exit 125\n" "$execution_id"
    printf 'fi\n'
    emit_bash_barrier AGENT_LAB_AGG_BARRIER_DIR "$execution_id" \
      "${lane_barrier_ids[@]}"
    emit_bash_barrier AGENT_LAB_AGG_SPLIT_BARRIER_DIR "$execution_id" \
      "${split_barrier_ids[@]}"
    emit_bash_barrier AGENT_LAB_AGG_LOCAL_BARRIER_DIR "$execution_id" \
      "${local_barrier_ids[@]}"
    emit_bash_barrier AGENT_LAB_AGG_RESOLUTION_BARRIER_DIR "$execution_id" \
      "${resolution_barrier_ids[@]}"
    emit_bash_barrier AGENT_LAB_AGG_INSTALL_BARRIER_DIR "$execution_id" \
      "${install_barrier_ids[@]}"
    printf 'if [ -n "${AGENT_LAB_AGG_HOLD_DIR:-}" ] &&\n'
    printf "   [ \"\${AGENT_LAB_AGG_HOLD_ID:-}\" = '%s' ]; then\n" "$execution_id"
    printf '  : > "$AGENT_LAB_AGG_HOLD_DIR/ready" || exit 125\n'
    printf '  attempts=0\n'
    printf '  while [ ! -f "$AGENT_LAB_AGG_HOLD_DIR/release" ]; do\n'
    printf '    attempts=$((attempts + 1))\n'
    printf '    [ "$attempts" -lt 500 ] || exit 125\n'
    printf '    sleep 0.01\n'
    printf '  done\n'
    printf 'fi\n'
    if [ "$execution_id" = "catalog-cases.sh" ]; then
      printf 'if [ -n "${AGENT_LAB_AGG_SIGNAL_DIR:-}" ]; then\n'
      printf '  sleep 30 &\n'
      printf '  descendant_pid=$!\n'
      printf '  printf "%%s\\n" "$descendant_pid" > "$AGENT_LAB_AGG_SIGNAL_DIR/descendant.pid" || exit 125\n'
      printf '  : > "$AGENT_LAB_AGG_SIGNAL_DIR/ready" || exit 125\n'
      printf '  wait "$descendant_pid"\n'
      printf 'fi\n'
      printf 'if [ -n "${AGENT_LAB_AGG_STUBBORN_SIGNAL_DIR:-}" ]; then\n'
      printf '  (\n'
      printf "    trap '' HUP INT QUIT TERM\n"
      printf '    printf "%%s\\n" "$BASHPID" > "$AGENT_LAB_AGG_STUBBORN_SIGNAL_DIR/descendant.pid" || exit 125\n'
      printf '    : > "$AGENT_LAB_AGG_STUBBORN_SIGNAL_DIR/ready" || exit 125\n'
      printf '    sleep 30\n'
      printf '  ) &\n'
      printf '  descendant_pid=$!\n'
      printf '  wait "$descendant_pid"\n'
      printf 'fi\n'
    fi
    for record in "$@"; do
      kind="${record%%:*}"
      id="${record#*:}"
      [ "$kind" = "FAIL" ] && fixture_failures=$((fixture_failures + 1))
      printf "printf '%s %s fixture assertion\\n'\n" "$kind" "$id"
    done
    printf "printf 'SUMMARY assertions=%s expected=%s failures=%s infra=0\\n'\n" \
      "$#" "$#" "$fixture_failures"
    printf 'if [ -n "${AGENT_LAB_AGG_DONE_DIR:-}" ]; then\n'
    printf "  : > \"\$AGENT_LAB_AGG_DONE_DIR/%s.done\" || exit 125\n" "$execution_id"
    printf 'fi\n'
    printf 'exit %s\n' "$rc"
  } > "$path"
  chmod +x "$path"
}

write_python_fixture() {
  local path="$1"
  local rc="$2"
  shift 2
  local record kind id fixture_failures=0
  local execution_id="${path##*/}"
  {
    printf '#!/usr/bin/env python3\n'
    printf 'import os\n'
    printf 'from pathlib import Path\n'
    printf 'import time\n'
    printf 'log = os.environ.get("AGENT_LAB_AGG_EXEC_LOG")\n'
    printf 'if log:\n'
    printf '    with open(log, "a", encoding="ascii") as stream:\n'
    printf "        stream.write('%s\\\\n')\n" "$execution_id"
    printf "hold_dir = os.environ.get('AGENT_LAB_AGG_HOLD_DIR')\n"
    printf "hold_id = os.environ.get('AGENT_LAB_AGG_HOLD_ID')\n"
    printf "if hold_dir and hold_id == '%s':\n" "$execution_id"
    printf "    Path(hold_dir, 'ready').touch()\n"
    printf '    deadline = time.monotonic() + 15.0\n'
    printf "    while not Path(hold_dir, 'release').is_file():\n"
    printf '        if time.monotonic() >= deadline:\n'
    printf '            raise SystemExit(125)\n'
    printf '        time.sleep(0.01)\n'
    emit_python_barrier AGENT_LAB_AGG_BARRIER_DIR "$execution_id" \
      "${lane_barrier_ids[@]}"
    emit_python_barrier AGENT_LAB_AGG_SPLIT_BARRIER_DIR "$execution_id" \
      "${split_barrier_ids[@]}"
    emit_python_barrier AGENT_LAB_AGG_LOCAL_BARRIER_DIR "$execution_id" \
      "${local_barrier_ids[@]}"
    emit_python_barrier AGENT_LAB_AGG_RESOLUTION_BARRIER_DIR "$execution_id" \
      "${resolution_barrier_ids[@]}"
    emit_python_barrier AGENT_LAB_AGG_INSTALL_BARRIER_DIR "$execution_id" \
      "${install_barrier_ids[@]}"
    for record in "$@"; do
      kind="${record%%:*}"
      id="${record#*:}"
      [ "$kind" = "FAIL" ] && fixture_failures=$((fixture_failures + 1))
      printf "print('%s %s fixture assertion')\n" "$kind" "$id"
    done
    printf "print('SUMMARY assertions=%s expected=%s failures=%s infra=0')\n" \
      "$#" "$#" "$fixture_failures"
    printf "done_dir = os.environ.get('AGENT_LAB_AGG_DONE_DIR')\n"
    printf 'if done_dir:\n'
    printf "    Path(done_dir, '%s.done').touch()\n" "$execution_id"
    printf 'raise SystemExit(%s)\n' "$rc"
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
  local installer_records=() config_records=()
  local catalog_base_records=() catalog_state_records=()
  local catalog_resolution_records=() catalog_mutation_records=()
  local install_records=() state_records=() integrity_records=() mutation_records=()
  mapfile -t installer_records < <(pass_records "${installer_ids[@]}")
  mapfile -t config_records < <(pass_records "${config_ids[@]}")
  mapfile -t catalog_base_records < <(pass_records "${catalog_base_ids[@]}")
  mapfile -t catalog_state_records < <(pass_records "${catalog_state_ids[@]}")
  mapfile -t catalog_resolution_records < <(pass_records "${catalog_resolution_ids[@]}")
  mapfile -t catalog_mutation_records < <(pass_records "${catalog_mutation_ids[@]}")
  mapfile -t install_records < <(pass_records "${install_ids[@]}")
  mapfile -t state_records < <(pass_records "${state_ids[@]}")
  mapfile -t integrity_records < <(pass_records "${integrity_ids[@]}")
  mapfile -t mutation_records < <(pass_records "${mutation_ids[@]}")
  write_fixture "$replica/tests/install/local-install-cases.sh" 0 "${installer_records[@]}"
  write_fixture "$replica/tests/experiment/local-config-cases.sh" 0 "${config_records[@]}"
  write_fixture "$replica/tests/image/catalog-cases.sh" 0 "${catalog_base_records[@]}"
  write_python_fixture \
    "$replica/tests/image/catalog-state-cases.py" 0 "${catalog_state_records[@]}"
  write_fixture "$replica/tests/experiment/catalog-resolution-cases.sh" 0 \
    "${catalog_resolution_records[@]}"
  write_python_fixture \
    "$replica/tests/image/catalog-mutation-cases.py" 0 "${catalog_mutation_records[@]}"
  write_fixture "$replica/tests/experiment/install-store-cases.sh" 0 "${install_records[@]}"
  write_python_fixture "$replica/tests/experiment/install-state-cases.py" 0 "${state_records[@]}"
  write_python_fixture "$replica/tests/experiment/install-integrity-cases.py" 0 "${integrity_records[@]}"
  write_python_fixture "$replica/tests/experiment/install-mutation-cases.py" 0 "${mutation_records[@]}"
}

reset_source_fixtures() {
  local zip_records=() mutation_records=() git_records=() git_mutation_records=()
  mapfile -t zip_records < <(pass_records "${source_zip_ids[@]}")
  mapfile -t mutation_records < <(pass_records "${source_mutation_ids[@]}")
  mapfile -t git_records < <(pass_records "${source_git_ids[@]}")
  mapfile -t git_mutation_records < <(pass_records "${source_git_mutation_ids[@]}")
  write_fixture "$replica/tests/experiment/zip-intake-cases.sh" 0 "${zip_records[@]}"
  write_python_fixture \
    "$replica/tests/experiment/zip-mutation-cases.py" 0 "${mutation_records[@]}"
  write_fixture "$replica/tests/experiment/git-intake-cases.sh" 0 "${git_records[@]}"
  write_python_fixture \
    "$replica/tests/experiment/git-mutation-cases.py" 0 "${git_mutation_records[@]}"
}

run_replica() {
  local output="$1"
  shift
  run_selected "$output" "$replica_lifecycle" "$@"
}

run_selected() {
  local output="$1"
  local selected_lifecycle="$2"
  shift 2
  "$@" bash "$selected_lifecycle" > "$output" 2>&1
  return $?
}

run_source_replica() {
  local output="$1"
  shift
  run_selected "$output" "$replica_source_adapters" "$@"
}

route_output_valid() {
  local output="$1"
  local expected_file="$2"
  local expected_assertions="$3"
  local marker="$4"
  local rc="$5"

  [ "$rc" -eq 0 ] &&
    cmp -s "$expected_file" <(awk '/^(PASS|FAIL) [A-Z0-9-]+ / {print $2}' "$output") &&
    [ "$(grep -Fxc \
      "SUMMARY assertions=$expected_assertions expected=$expected_assertions failures=0 infra=0" \
      "$output" || true)" -eq 1 ] &&
    [ "$(awk 'END {print}' "$output")" = "$marker" ] &&
    awk -v summary="SUMMARY assertions=$expected_assertions expected=$expected_assertions failures=0 infra=0" \
      -v marker="$marker" \
      '/^(PASS|FAIL) [A-Z0-9-]+ / {next} $0 == summary {next} $0 == marker {next} {bad=1} END {exit bad}' \
      "$output"
}

infrastructure_output_valid() {
  local output="$1"
  local expected_assertions="$2"
  local rc="$3"

  [ "$rc" -eq 125 ] &&
    [ "$(grep -Fxc \
      "SUMMARY assertions=0 expected=$expected_assertions failures=0 infra=1" \
      "$output" || true)" -eq 1 ] &&
    ! grep -Fq 'EXPERIMENT LOCAL LIFECYCLE PASS' "$output" &&
    ! grep -Fq 'EXPERIMENT CATALOG STATE LIFECYCLE PASS' "$output" &&
    ! grep -Fq 'EXPERIMENT CATALOG RESOLUTION LIFECYCLE PASS' "$output" &&
    ! grep -Fq 'EXPERIMENT INSTALL LIFECYCLE PASS' "$output"
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

wait_for_process_exit() {
  local pid="$1"
  local attempts=0
  while kill -0 "$pid" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 100 ] || return 1
    sleep 0.01
  done
}

wait_for_child_wait() {
  local pid="$1"
  local expected_children="$2"
  local attempts=0
  local wchan child_list
  local children=()

  while [ "$attempts" -lt 100 ]; do
    wchan="$(cat "/proc/$pid/wchan" 2>/dev/null || true)"
    child_list="$(cat "/proc/$pid/task/$pid/children" 2>/dev/null || true)"
    children=()
    read -r -a children <<< "$child_list"
    if [ "$wchan" = "do_wait" ] &&
       [ "${#children[@]}" -eq "$expected_children" ]; then
      return 0
    fi
    attempts=$((attempts + 1))
    sleep 0.01
  done
  return 1
}

reset_fixtures
expected_executions="$work/expected-executions"
baseline_executions="$work/baseline-executions"
mutant_executions="$work/mutant-executions"
printf '%s\n' \
  local-install-cases.sh \
  local-config-cases.sh \
  catalog-cases.sh \
  catalog-state-cases.py \
  catalog-resolution-cases.sh \
  catalog-mutation-cases.py \
  install-store-cases.sh \
  install-state-cases.py \
  install-integrity-cases.py \
  install-mutation-cases.py > "$expected_executions"
: > "$baseline_executions"
baseline_rc=0
run_replica "$work/baseline.out" env \
  AGENT_LAB_AGG_EXEC_LOG="$baseline_executions" || baseline_rc=$?

mutant_lifecycle="$replica/tests/experiment/local-lifecycle-hidden-duplicate.sh"
awk '
  { print }
  $0 == "subcases=(\"${all_subcases[@]:$selected_start:$selected_count}\")" {
    print "\"$repo_root/tests/install/local-install-cases.sh\" >/dev/null 2>&1"
  }
' "$replica_lifecycle" > "$mutant_lifecycle"
chmod +x "$mutant_lifecycle"
mutation_count="$(grep -Fxc '"$repo_root/tests/install/local-install-cases.sh" >/dev/null 2>&1' "$mutant_lifecycle")"
: > "$mutant_executions"
mutant_rc=0
run_selected "$work/mutant.out" "$mutant_lifecycle" env \
  AGENT_LAB_AGG_EXEC_LOG="$mutant_executions" || mutant_rc=$?
mutant_expected="$work/mutant-expected-executions"
printf '%s\n' \
  local-install-cases.sh \
  local-install-cases.sh \
  local-config-cases.sh \
  catalog-cases.sh \
  catalog-state-cases.py \
  catalog-resolution-cases.sh \
  catalog-mutation-cases.py \
  install-store-cases.sh \
  install-state-cases.py \
  install-integrity-cases.py \
  install-mutation-cases.py > "$mutant_expected"

overlap_barrier="$work/overlap-barrier"
overlap_executions="$work/overlap-executions"
mkdir "$overlap_barrier"
: > "$overlap_executions"
overlap_rc=0
run_replica "$work/overlap.out" env \
  AGENT_LAB_AGG_EXEC_LOG="$overlap_executions" \
  AGENT_LAB_AGG_BARRIER_DIR="$overlap_barrier" || overlap_rc=$?

split_routing_contract=0
split_output_contract=0
split_mutation_contract=0
tail_mutation_contract=0
wrapper_infrastructure_contract=0
install_overlap_contract=0
install_isolation_contract=0
install_lane_mutation_contract=0
split_identity_union_contract=0
local_pole_isolation_contract=0
local_lane_mutation_contract=0
if [ -f "$local_onboarding" ] && [ -f "$catalog_state_lifecycle" ] &&
   [ -f "$catalog_resolution_lifecycle" ] && [ -f "$install_lifecycle" ]; then
  cp "$local_onboarding" "$replica_local_onboarding"
  cp "$catalog_state_lifecycle" "$replica_catalog_state"
  cp "$catalog_resolution_lifecycle" "$replica_catalog_resolution"
  cp "$install_lifecycle" "$replica_install_lifecycle"
  chmod +x "$replica_local_onboarding" "$replica_catalog_state" \
    "$replica_catalog_resolution" "$replica_install_lifecycle"

  expected_local_ids="$work/expected-local-ids"
  expected_catalog_state_ids="$work/expected-catalog-state-ids"
  expected_catalog_resolution_ids="$work/expected-catalog-resolution-ids"
  expected_install_ids="$work/expected-install-ids"
  expected_local_executions="$work/expected-local-executions"
  expected_catalog_state_executions="$work/expected-catalog-state-executions"
  expected_catalog_resolution_executions="$work/expected-catalog-resolution-executions"
  expected_install_executions="$work/expected-install-executions"
  printf '%s\n' "${expected_ids[@]:0:28}" > "$expected_local_ids"
  printf '%s\n' "${expected_ids[@]:28:34}" > "$expected_catalog_state_ids"
  printf '%s\n' "${expected_ids[@]:62:24}" > "$expected_catalog_resolution_ids"
  printf '%s\n' "${expected_ids[@]:86:47}" > "$expected_install_ids"
  printf '%s\n' \
    local-install-cases.sh \
    local-config-cases.sh \
    catalog-cases.sh > "$expected_local_executions"
  printf '%s\n' catalog-state-cases.py > "$expected_catalog_state_executions"
  printf '%s\n' \
    catalog-resolution-cases.sh \
    catalog-mutation-cases.py > "$expected_catalog_resolution_executions"
  printf '%s\n' \
    install-store-cases.sh \
    install-state-cases.py \
    install-integrity-cases.py \
    install-mutation-cases.py > "$expected_install_executions"

  # Every public route runs concurrently against one rendezvous: each route
  # parks a participant until all four have started. A route set that cannot
  # run in parallel never satisfies it, whatever the elapsed time is.
  reset_fixtures
  split_barrier="$work/split-barrier"
  local_executions="$work/local-executions"
  catalog_state_executions="$work/catalog-state-executions"
  catalog_resolution_executions="$work/catalog-resolution-executions"
  install_executions="$work/install-executions"
  mkdir "$split_barrier"
  : > "$local_executions"
  : > "$catalog_state_executions"
  : > "$catalog_resolution_executions"
  : > "$install_executions"
  local_route_rc=0
  catalog_state_route_rc=0
  catalog_resolution_route_rc=0
  install_route_rc=0
  env \
    AGENT_LAB_AGG_EXEC_LOG="$local_executions" \
    AGENT_LAB_AGG_SPLIT_BARRIER_DIR="$split_barrier" \
    bash "$replica_local_onboarding" > "$work/local-route.out" 2>&1 &
  local_route_pid=$!
  env \
    AGENT_LAB_AGG_EXEC_LOG="$catalog_state_executions" \
    AGENT_LAB_AGG_SPLIT_BARRIER_DIR="$split_barrier" \
    bash "$replica_catalog_state" > "$work/catalog-state-route.out" 2>&1 &
  catalog_state_route_pid=$!
  env \
    AGENT_LAB_AGG_EXEC_LOG="$catalog_resolution_executions" \
    AGENT_LAB_AGG_SPLIT_BARRIER_DIR="$split_barrier" \
    bash "$replica_catalog_resolution" > "$work/catalog-resolution-route.out" 2>&1 &
  catalog_resolution_route_pid=$!
  env \
    AGENT_LAB_AGG_EXEC_LOG="$install_executions" \
    AGENT_LAB_AGG_SPLIT_BARRIER_DIR="$split_barrier" \
    bash "$replica_install_lifecycle" > "$work/install-route.out" 2>&1 &
  install_route_pid=$!
  wait "$local_route_pid" || local_route_rc=$?
  wait "$catalog_state_route_pid" || catalog_state_route_rc=$?
  wait "$catalog_resolution_route_pid" || catalog_resolution_route_rc=$?
  wait "$install_route_pid" || install_route_rc=$?

  combined_executions="$work/combined-executions"
  LC_ALL=C sort "$local_executions" "$catalog_state_executions" \
    "$catalog_resolution_executions" "$install_executions" > "$combined_executions"
  if [ "$local_route_rc" -eq 0 ] && [ "$catalog_state_route_rc" -eq 0 ] &&
     [ "$catalog_resolution_route_rc" -eq 0 ] && [ "$install_route_rc" -eq 0 ] &&
     cmp -s <(LC_ALL=C sort "$expected_local_executions") \
       <(LC_ALL=C sort "$local_executions") &&
     cmp -s <(LC_ALL=C sort "$expected_catalog_state_executions") \
       <(LC_ALL=C sort "$catalog_state_executions") &&
     cmp -s <(LC_ALL=C sort "$expected_catalog_resolution_executions") \
       <(LC_ALL=C sort "$catalog_resolution_executions") &&
     cmp -s <(LC_ALL=C sort "$expected_install_executions") \
       <(LC_ALL=C sort "$install_executions") &&
     cmp -s <(LC_ALL=C sort "$expected_executions") "$combined_executions"; then
    split_routing_contract=1
  fi
  if route_output_valid \
       "$work/local-route.out" "$expected_local_ids" 28 \
       'EXPERIMENT LOCAL LIFECYCLE PASS' "$local_route_rc" &&
     route_output_valid \
       "$work/catalog-state-route.out" "$expected_catalog_state_ids" 34 \
       'EXPERIMENT CATALOG STATE LIFECYCLE PASS' "$catalog_state_route_rc" &&
     route_output_valid \
       "$work/catalog-resolution-route.out" "$expected_catalog_resolution_ids" 24 \
       'EXPERIMENT CATALOG RESOLUTION LIFECYCLE PASS' "$catalog_resolution_route_rc" &&
     route_output_valid \
       "$work/install-route.out" "$expected_install_ids" 47 \
       'EXPERIMENT INSTALL LIFECYCLE PASS' "$install_route_rc"; then
    split_output_contract=1
  fi

  # The four public routes must partition the frozen 133 identities exactly:
  # concatenated in route order they reproduce the compatibility list, and no
  # identity is dropped or claimed twice.
  union_ids="$work/split-union-ids"
  compatibility_ids="$work/compatibility-ids"
  cat "$expected_local_ids" "$expected_catalog_state_ids" \
    "$expected_catalog_resolution_ids" "$expected_install_ids" > "$union_ids"
  printf '%s\n' "${expected_ids[@]}" > "$compatibility_ids"
  if cmp -s "$compatibility_ids" "$union_ids" &&
     [ "$(wc -l < "$union_ids")" -eq 133 ] &&
     [ "$(LC_ALL=C sort -u "$union_ids" | wc -l)" -eq 133 ]; then
    split_identity_union_contract=1
  fi

  mutant_install_route="$replica/tests/experiment/install-lifecycle-wrong-route.sh"
  mutation_write_rc=0
  awk '
    $0 == "exec bash \"$script_dir/local-lifecycle-cases.sh\" install" {
      print "exec bash \"$script_dir/local-lifecycle-cases.sh\" local"
      changes++
      next
    }
    { print }
    END { if (changes != 1) exit 1 }
  ' "$replica_install_lifecycle" > "$mutant_install_route" || mutation_write_rc=$?
  chmod +x "$mutant_install_route"
  mutant_install_executions="$work/mutant-install-executions"
  : > "$mutant_install_executions"
  mutant_install_rc=0
  env AGENT_LAB_AGG_EXEC_LOG="$mutant_install_executions" \
    bash "$mutant_install_route" > "$work/mutant-install-route.out" 2>&1 || \
    mutant_install_rc=$?
  if [ "$mutation_write_rc" -eq 0 ] && [ "$mutant_install_rc" -eq 0 ] &&
     ! route_output_valid \
       "$work/mutant-install-route.out" "$expected_install_ids" 47 \
       'EXPERIMENT INSTALL LIFECYCLE PASS' "$mutant_install_rc" &&
     ! cmp -s <(LC_ALL=C sort "$expected_install_executions") \
       <(LC_ALL=C sort "$mutant_install_executions"); then
    split_mutation_contract=1
  fi

  tail_subcase_mutant="$replica/tests/experiment/local-lifecycle-tail-subcase.sh"
  tail_subcase_write_rc=0
  awk '
    $0 == "all_subcases=(" { in_subcases=1 }
    in_subcases && $0 == ")" {
      print "  \"$repo_root/tests/install/local-install-cases.sh\" # tail-orphan mutant"
      changes++
      in_subcases=0
    }
    { print }
    END { if (changes != 1) exit 1 }
  ' "$replica_lifecycle" > "$tail_subcase_mutant" || tail_subcase_write_rc=$?
  chmod +x "$tail_subcase_mutant"
  reset_fixtures
  tail_subcase_executions="$work/tail-subcase-executions"
  : > "$tail_subcase_executions"
  tail_subcase_rc=0
  env AGENT_LAB_AGG_EXEC_LOG="$tail_subcase_executions" \
    bash "$tail_subcase_mutant" > "$work/tail-subcase.out" 2>&1 || \
    tail_subcase_rc=$?

  tail_id_mutant="$replica/tests/experiment/local-lifecycle-tail-id.sh"
  tail_id_write_rc=0
  awk '
    { print }
    $0 == "  M-STORE-LIVE-001 M-STORE-UNCERT-001 M-STORE-STAGE-001 > \"$expected\"" {
      print "printf '\''%s\\n'\'' ORPHAN-134 >> \"$expected\""
      changes++
    }
    END { if (changes != 1) exit 1 }
  ' "$replica_lifecycle" > "$tail_id_mutant" || tail_id_write_rc=$?
  chmod +x "$tail_id_mutant"
  reset_fixtures
  tail_id_executions="$work/tail-id-executions"
  : > "$tail_id_executions"
  tail_id_rc=0
  env AGENT_LAB_AGG_EXEC_LOG="$tail_id_executions" \
    bash "$tail_id_mutant" > "$work/tail-id.out" 2>&1 || tail_id_rc=$?

  if [ "$tail_subcase_write_rc" -eq 0 ] &&
     infrastructure_output_valid "$work/tail-subcase.out" 133 "$tail_subcase_rc" &&
     [ ! -s "$tail_subcase_executions" ] &&
     [ "$tail_id_write_rc" -eq 0 ] &&
     infrastructure_output_valid "$work/tail-id.out" 133 "$tail_id_rc" &&
     [ ! -s "$tail_id_executions" ]; then
    tail_mutation_contract=1
  fi

  saved_lifecycle="$work/local-lifecycle-core.saved"
  mv "$replica_lifecycle" "$saved_lifecycle"
  missing_local_core_rc=0
  missing_catalog_state_core_rc=0
  missing_catalog_resolution_core_rc=0
  missing_install_core_rc=0
  bash "$replica_local_onboarding" > "$work/missing-local-core.out" 2>&1 || \
    missing_local_core_rc=$?
  bash "$replica_catalog_state" > "$work/missing-catalog-state-core.out" 2>&1 || \
    missing_catalog_state_core_rc=$?
  bash "$replica_catalog_resolution" \
    > "$work/missing-catalog-resolution-core.out" 2>&1 || \
    missing_catalog_resolution_core_rc=$?
  bash "$replica_install_lifecycle" > "$work/missing-install-core.out" 2>&1 || \
    missing_install_core_rc=$?
  mv "$saved_lifecycle" "$replica_lifecycle"
  if infrastructure_output_valid \
       "$work/missing-local-core.out" 28 "$missing_local_core_rc" &&
     grep -Fxq 'INFRA shared lifecycle core unavailable' \
       "$work/missing-local-core.out" &&
     infrastructure_output_valid \
       "$work/missing-catalog-state-core.out" 34 "$missing_catalog_state_core_rc" &&
     grep -Fxq 'INFRA shared lifecycle core unavailable' \
       "$work/missing-catalog-state-core.out" &&
     infrastructure_output_valid \
       "$work/missing-catalog-resolution-core.out" 24 \
       "$missing_catalog_resolution_core_rc" &&
     grep -Fxq 'INFRA shared lifecycle core unavailable' \
       "$work/missing-catalog-resolution-core.out" &&
     infrastructure_output_valid \
       "$work/missing-install-core.out" 47 "$missing_install_core_rc" &&
     grep -Fxq 'INFRA shared lifecycle core unavailable' \
       "$work/missing-install-core.out"; then
    wrapper_infrastructure_contract=1
  fi

  # The install route must run its long-pole subcase concurrently with the
  # batched short subcases. A rendezvous between the two lanes is the oracle:
  # a serialized route can never satisfy it, whatever the elapsed time is.
  reset_fixtures
  install_barrier="$work/install-barrier"
  install_overlap_executions="$work/install-overlap-executions"
  mkdir "$install_barrier"
  : > "$install_overlap_executions"
  install_overlap_rc=0
  env \
    AGENT_LAB_AGG_EXEC_LOG="$install_overlap_executions" \
    AGENT_LAB_AGG_INSTALL_BARRIER_DIR="$install_barrier" \
    bash "$replica_install_lifecycle" > "$work/install-overlap.out" 2>&1 || \
    install_overlap_rc=$?
  if route_output_valid \
       "$work/install-overlap.out" "$expected_install_ids" 47 \
       'EXPERIMENT INSTALL LIFECYCLE PASS' "$install_overlap_rc" &&
     [ -f "$install_barrier/install-store-cases.sh.ready" ] &&
     [ -f "$install_barrier/install-state-cases.py.ready" ] &&
     cmp -s <(LC_ALL=C sort "$expected_install_executions") \
       <(LC_ALL=C sort "$install_overlap_executions"); then
    install_overlap_contract=1
  fi

  # Holding the long-pole subcase must not hold any other install subcase:
  # every batched subcase completes while the held lane is still parked.
  reset_fixtures
  isolation_hold="$work/install-isolation-hold"
  isolation_done="$work/install-isolation-done"
  isolation_executions="$work/install-isolation-executions"
  mkdir "$isolation_hold" "$isolation_done"
  : > "$isolation_executions"
  isolation_rc=0
  env \
    AGENT_LAB_AGG_EXEC_LOG="$isolation_executions" \
    AGENT_LAB_AGG_HOLD_DIR="$isolation_hold" \
    AGENT_LAB_AGG_HOLD_ID=install-state-cases.py \
    AGENT_LAB_AGG_DONE_DIR="$isolation_done" \
    bash "$replica_install_lifecycle" > "$work/install-isolation.out" 2>&1 &
  isolation_pid=$!
  isolation_case=0
  if wait_for_path "$isolation_hold/ready" &&
     wait_for_path "$isolation_done/install-store-cases.sh.done" &&
     wait_for_path "$isolation_done/install-integrity-cases.py.done" &&
     wait_for_path "$isolation_done/install-mutation-cases.py.done" &&
     wait_for_child_wait "$isolation_pid" 1; then
    isolation_case=1
  fi
  : > "$isolation_hold/release"
  wait "$isolation_pid" || isolation_rc=$?
  if [ "$isolation_case" -eq 1 ] && [ "$isolation_rc" -eq 0 ] &&
     wait_for_path "$isolation_done/install-state-cases.py.done" &&
     route_output_valid \
       "$work/install-isolation.out" "$expected_install_ids" 47 \
       'EXPERIMENT INSTALL LIFECYCLE PASS' "$isolation_rc" &&
     cmp -s <(LC_ALL=C sort "$expected_install_executions") \
       <(LC_ALL=C sort "$isolation_executions"); then
    install_isolation_contract=1
  fi

  # The superseded single-lane routing, a routing that re-serializes the long
  # pole behind a batched subcase, and a routing that drops a subcase are all
  # intended REDs.
  serial_core="$replica/tests/experiment/local-lifecycle-serial-install.sh"
  serial_write_rc=0
  awk '
    $0 == "  install)" { in_install = 1 }
    in_install && $0 == "    lane_count=2" { print "    lane_count=1"; changes++; next }
    in_install && $0 == "    lane_map=(0 1 0 0)" {
      print "    lane_map=(0 0 0 0)"
      changes++
      in_install = 0
      next
    }
    { print }
    END { if (changes != 2) exit 1 }
  ' "$replica_lifecycle" > "$serial_core" || serial_write_rc=$?
  chmod +x "$serial_core"

  shared_core="$replica/tests/experiment/local-lifecycle-shared-install.sh"
  shared_write_rc=0
  awk '
    $0 == "  install)" { in_install = 1 }
    in_install && $0 == "    lane_map=(0 1 0 0)" {
      print "    lane_map=(0 0 0 1)"
      changes++
      in_install = 0
      next
    }
    { print }
    END { if (changes != 1) exit 1 }
  ' "$replica_lifecycle" > "$shared_core" || shared_write_rc=$?
  chmod +x "$shared_core"

  dropped_core="$replica/tests/experiment/local-lifecycle-dropped-install.sh"
  dropped_write_rc=0
  awk '
    $0 == "  install)" { in_install = 1 }
    in_install && $0 == "    selected_count=4" {
      print "    selected_count=3"
      changes++
      in_install = 0
      next
    }
    { print }
    END { if (changes != 1) exit 1 }
  ' "$replica_lifecycle" > "$dropped_core" || dropped_write_rc=$?
  chmod +x "$dropped_core"

  serial_barrier="$work/install-serial-barrier"
  shared_barrier="$work/install-shared-barrier"
  mkdir "$serial_barrier" "$shared_barrier"
  reset_fixtures
  serial_rc=0
  env AGENT_LAB_AGG_INSTALL_BARRIER_DIR="$serial_barrier" \
    bash "$serial_core" install > "$work/install-serial.out" 2>&1 || serial_rc=$?
  shared_rc=0
  env AGENT_LAB_AGG_INSTALL_BARRIER_DIR="$shared_barrier" \
    bash "$shared_core" install > "$work/install-shared.out" 2>&1 || shared_rc=$?
  dropped_executions="$work/install-dropped-executions"
  : > "$dropped_executions"
  dropped_rc=0
  env AGENT_LAB_AGG_EXEC_LOG="$dropped_executions" \
    bash "$dropped_core" install > "$work/install-dropped.out" 2>&1 || dropped_rc=$?
  if [ "$serial_write_rc" -eq 0 ] && [ "$shared_write_rc" -eq 0 ] &&
     [ "$dropped_write_rc" -eq 0 ] &&
     [ "$serial_rc" -ne 0 ] && [ "$shared_rc" -ne 0 ] &&
     ! grep -Fq 'EXPERIMENT INSTALL LIFECYCLE PASS' "$work/install-serial.out" &&
     ! grep -Fq 'EXPERIMENT INSTALL LIFECYCLE PASS' "$work/install-shared.out" &&
     infrastructure_output_valid "$work/install-dropped.out" 47 "$dropped_rc" &&
     [ ! -s "$dropped_executions" ]; then
    install_lane_mutation_contract=1
  fi

  # The corrected local partition: the local route overlaps its two lanes, the
  # catalog-resolution route overlaps its two lanes, and the catalog-state route
  # carries the indivisible pole and nothing else.
  reset_fixtures
  local_lane_barrier="$work/local-lane-barrier"
  resolution_lane_barrier="$work/resolution-lane-barrier"
  local_lane_executions="$work/local-lane-executions"
  resolution_lane_executions="$work/resolution-lane-executions"
  pole_executions="$work/pole-executions"
  mkdir "$local_lane_barrier" "$resolution_lane_barrier"
  : > "$local_lane_executions"
  : > "$resolution_lane_executions"
  : > "$pole_executions"
  local_lane_rc=0
  resolution_lane_rc=0
  pole_rc=0
  env \
    AGENT_LAB_AGG_EXEC_LOG="$local_lane_executions" \
    AGENT_LAB_AGG_LOCAL_BARRIER_DIR="$local_lane_barrier" \
    bash "$replica_local_onboarding" > "$work/local-lane.out" 2>&1 || local_lane_rc=$?
  env \
    AGENT_LAB_AGG_EXEC_LOG="$resolution_lane_executions" \
    AGENT_LAB_AGG_RESOLUTION_BARRIER_DIR="$resolution_lane_barrier" \
    bash "$replica_catalog_resolution" > "$work/resolution-lane.out" 2>&1 || \
    resolution_lane_rc=$?
  env AGENT_LAB_AGG_EXEC_LOG="$pole_executions" \
    bash "$replica_catalog_state" > "$work/pole.out" 2>&1 || pole_rc=$?
  if route_output_valid \
       "$work/local-lane.out" "$expected_local_ids" 28 \
       'EXPERIMENT LOCAL LIFECYCLE PASS' "$local_lane_rc" &&
     [ -f "$local_lane_barrier/local-install-cases.sh.ready" ] &&
     [ -f "$local_lane_barrier/catalog-cases.sh.ready" ] &&
     cmp -s <(LC_ALL=C sort "$expected_local_executions") \
       <(LC_ALL=C sort "$local_lane_executions") &&
     route_output_valid \
       "$work/resolution-lane.out" "$expected_catalog_resolution_ids" 24 \
       'EXPERIMENT CATALOG RESOLUTION LIFECYCLE PASS' "$resolution_lane_rc" &&
     [ -f "$resolution_lane_barrier/catalog-resolution-cases.sh.ready" ] &&
     [ -f "$resolution_lane_barrier/catalog-mutation-cases.py.ready" ] &&
     cmp -s <(LC_ALL=C sort "$expected_catalog_resolution_executions") \
       <(LC_ALL=C sort "$resolution_lane_executions") &&
     route_output_valid \
       "$work/pole.out" "$expected_catalog_state_ids" 34 \
       'EXPERIMENT CATALOG STATE LIFECYCLE PASS' "$pole_rc" &&
     cmp -s "$expected_catalog_state_executions" "$pole_executions"; then
    local_pole_isolation_contract=1
  fi

  # The superseded local routing that swallowed the pole, a dropped public
  # route, routings that re-serialize either corrected local route, and a route
  # slice that overlaps its neighbour are all intended REDs.
  predecessor_core="$replica/tests/experiment/local-lifecycle-predecessor-local.sh"
  predecessor_write_rc=0
  awk '
    $0 == "  local)" { in_local = 1 }
    in_local && $0 == "    selected_count=3" { print "    selected_count=6"; changes++; next }
    in_local && $0 == "    expected_count=28" { print "    expected_count=86"; changes++; next }
    in_local && $0 == "    lane_map=(0 0 1)" {
      print "    lane_map=(0 0 1 1 1 1)"
      changes++
      in_local = 0
      next
    }
    { print }
    END { if (changes != 3) exit 1 }
  ' "$replica_lifecycle" > "$predecessor_core" || predecessor_write_rc=$?
  chmod +x "$predecessor_core"

  dropped_route_core="$replica/tests/experiment/local-lifecycle-dropped-route.sh"
  dropped_route_write_rc=0
  awk '
    $0 == "  catalog-state)" { dropping = 1; changes++ }
    dropping && $0 == "    ;;" { dropping = 0; next }
    dropping { next }
    { print }
    END { if (changes != 1) exit 1 }
  ' "$replica_lifecycle" > "$dropped_route_core" || dropped_route_write_rc=$?
  chmod +x "$dropped_route_core"

  serial_local_core="$replica/tests/experiment/local-lifecycle-serial-local.sh"
  serial_local_write_rc=0
  awk '
    $0 == "  local)" { in_local = 1 }
    in_local && $0 == "    lane_count=2" { print "    lane_count=1"; changes++; next }
    in_local && $0 == "    lane_map=(0 0 1)" {
      print "    lane_map=(0 0 0)"
      changes++
      in_local = 0
      next
    }
    { print }
    END { if (changes != 2) exit 1 }
  ' "$replica_lifecycle" > "$serial_local_core" || serial_local_write_rc=$?
  chmod +x "$serial_local_core"

  serial_resolution_core="$replica/tests/experiment/local-lifecycle-serial-resolution.sh"
  serial_resolution_write_rc=0
  awk '
    $0 == "  catalog-resolution)" { in_resolution = 1 }
    in_resolution && $0 == "    lane_count=2" { print "    lane_count=1"; changes++; next }
    in_resolution && $0 == "    lane_map=(0 1)" {
      print "    lane_map=(0 0)"
      changes++
      in_resolution = 0
      next
    }
    { print }
    END { if (changes != 2) exit 1 }
  ' "$replica_lifecycle" > "$serial_resolution_core" || serial_resolution_write_rc=$?
  chmod +x "$serial_resolution_core"

  overlap_slice_core="$replica/tests/experiment/local-lifecycle-overlap-slice.sh"
  overlap_slice_write_rc=0
  awk '
    $0 == "  catalog-resolution)" { in_resolution = 1 }
    in_resolution && $0 == "    expected_start=63" {
      print "    expected_start=62"
      changes++
      in_resolution = 0
      next
    }
    { print }
    END { if (changes != 1) exit 1 }
  ' "$replica_lifecycle" > "$overlap_slice_core" || overlap_slice_write_rc=$?
  chmod +x "$overlap_slice_core"

  reset_fixtures
  predecessor_executions="$work/predecessor-executions"
  : > "$predecessor_executions"
  predecessor_rc=0
  env AGENT_LAB_AGG_EXEC_LOG="$predecessor_executions" \
    bash "$predecessor_core" local > "$work/predecessor-local.out" 2>&1 || \
    predecessor_rc=$?
  dropped_route_rc=0
  bash "$dropped_route_core" catalog-state > "$work/dropped-route.out" 2>&1 || \
    dropped_route_rc=$?
  serial_local_barrier="$work/serial-local-barrier"
  serial_resolution_barrier="$work/serial-resolution-barrier"
  mkdir "$serial_local_barrier" "$serial_resolution_barrier"
  serial_local_rc=0
  env AGENT_LAB_AGG_LOCAL_BARRIER_DIR="$serial_local_barrier" \
    bash "$serial_local_core" local > "$work/serial-local.out" 2>&1 || serial_local_rc=$?
  serial_resolution_rc=0
  env AGENT_LAB_AGG_RESOLUTION_BARRIER_DIR="$serial_resolution_barrier" \
    bash "$serial_resolution_core" catalog-resolution \
    > "$work/serial-resolution.out" 2>&1 || serial_resolution_rc=$?
  overlap_slice_rc=0
  bash "$overlap_slice_core" catalog-resolution > "$work/overlap-slice.out" 2>&1 || \
    overlap_slice_rc=$?
  if [ "$predecessor_write_rc" -eq 0 ] && [ "$dropped_route_write_rc" -eq 0 ] &&
     [ "$serial_local_write_rc" -eq 0 ] && [ "$serial_resolution_write_rc" -eq 0 ] &&
     [ "$overlap_slice_write_rc" -eq 0 ] &&
     ! route_output_valid \
       "$work/predecessor-local.out" "$expected_local_ids" 28 \
       'EXPERIMENT LOCAL LIFECYCLE PASS' "$predecessor_rc" &&
     ! cmp -s <(LC_ALL=C sort "$expected_local_executions") \
       <(LC_ALL=C sort "$predecessor_executions") &&
     [ "$dropped_route_rc" -eq 2 ] &&
     ! grep -Fq 'EXPERIMENT CATALOG STATE LIFECYCLE PASS' "$work/dropped-route.out" &&
     [ "$serial_local_rc" -ne 0 ] && [ "$serial_resolution_rc" -ne 0 ] &&
     ! grep -Fq 'EXPERIMENT LOCAL LIFECYCLE PASS' "$work/serial-local.out" &&
     ! grep -Fq 'EXPERIMENT CATALOG RESOLUTION LIFECYCLE PASS' \
       "$work/serial-resolution.out" &&
     [ "$overlap_slice_rc" -ne 0 ] &&
     ! grep -Fq 'EXPERIMENT CATALOG RESOLUTION LIFECYCLE PASS' \
       "$work/overlap-slice.out"; then
    local_lane_mutation_contract=1
  fi
fi

if [ "$baseline_rc" -eq 0 ] &&
   cmp -s <(LC_ALL=C sort "$expected_executions") <(LC_ALL=C sort "$baseline_executions") &&
   [ "$mutation_count" -eq 1 ] &&
   [ "$mutant_rc" -eq 0 ] &&
   cmp -s "$work/baseline.out" "$work/mutant.out" &&
   cmp -s <(LC_ALL=C sort "$mutant_expected") <(LC_ALL=C sort "$mutant_executions") &&
   ! cmp -s <(LC_ALL=C sort "$expected_executions") <(LC_ALL=C sort "$mutant_executions") &&
   [ "$overlap_rc" -eq 0 ] &&
   cmp -s <(LC_ALL=C sort "$expected_executions") <(LC_ALL=C sort "$overlap_executions") &&
   [ -f "$overlap_barrier/local-install-cases.sh.ready" ] &&
   [ -f "$overlap_barrier/catalog-state-cases.py.ready" ] &&
   [ -f "$overlap_barrier/catalog-resolution-cases.sh.ready" ] &&
   [ "$split_routing_contract" -eq 1 ] &&
   [ "$split_mutation_contract" -eq 1 ] &&
   [ "$tail_mutation_contract" -eq 1 ]; then
  pass AGG-001 "execution ledgers prove exact routing and reject wrong-route or orphan-tail mutants"
else
  fail AGG-001 "execution ledgers prove exact routing and reject wrong-route or orphan-tail mutants"
fi

reset_fixtures
success_output="$work/success.out"
success_rc=0
run_replica "$success_output" env || success_rc=$?
if [ "$success_rc" -eq 0 ] &&
   [ "$(grep -Ec '^(PASS|FAIL) [A-Z0-9-]+ ' "$success_output")" -eq 133 ] &&
   [ "$(grep -Fxc 'SUMMARY assertions=133 expected=133 failures=0 infra=0' "$success_output")" -eq 1 ] &&
   [ "$(tail -n 1 "$success_output")" = 'EXPERIMENT LOCAL LIFECYCLE PASS' ] &&
   awk '/^(PASS|FAIL) [A-Z0-9-]+ / {next} /^SUMMARY assertions=133 expected=133 failures=0 infra=0$/ {next} /^EXPERIMENT LOCAL LIFECYCLE PASS$/ {next} {bad=1} END {exit bad}' "$success_output" &&
   [ "$split_output_contract" -eq 1 ] &&
   [ "$split_identity_union_contract" -eq 1 ]; then
  pass AGG-002 "compatibility and split routes emit exact summaries and markers"
else
  fail AGG-002 "compatibility and split routes emit exact summaries and markers"
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
   grep -Fxq 'SUMMARY assertions=133 expected=133 failures=1 infra=0' "$work/assertion.out" &&
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
mixed_failed_records=()
mixed_uncertain_records=()
mapfile -t mixed_failed_records < <(pass_records "${installer_ids[@]}")
mixed_failed_records[0]='FAIL:PKG-001'
mapfile -t mixed_uncertain_records < <(pass_records "${config_ids[@]}")
write_fixture "$replica/tests/install/local-install-cases.sh" 1 "${mixed_failed_records[@]}"
write_fixture "$replica/tests/experiment/local-config-cases.sh" 125 "${mixed_uncertain_records[@]}"
mixed_executions="$work/mixed-executions"
: > "$mixed_executions"
mixed_rc=0
run_replica "$work/mixed.out" env \
  AGENT_LAB_AGG_EXEC_LOG="$mixed_executions" || mixed_rc=$?
reset_fixtures
find "$replica/tests/install/local-install-cases.sh" -delete
setup_infra_rc=0
run_replica "$work/setup-infra.out" env || setup_infra_rc=$?
if [ "$subcase_infra_rc" -eq 125 ] && [ "$setup_infra_rc" -eq 125 ] &&
   [ "$mixed_rc" -eq 125 ] &&
   grep -Fxq 'SUMMARY assertions=133 expected=133 failures=1 infra=1' "$work/mixed.out" &&
   cmp -s <(LC_ALL=C sort "$expected_executions") <(LC_ALL=C sort "$mixed_executions") &&
   ! grep -Fxq 'EXPERIMENT LOCAL LIFECYCLE PASS' "$work/subcase-infra.out" &&
   ! grep -Fxq 'EXPERIMENT LOCAL LIFECYCLE PASS' "$work/mixed.out" &&
   ! grep -Fxq 'EXPERIMENT LOCAL LIFECYCLE PASS' "$work/setup-infra.out"; then
  pass AGG-007 "all lanes finish and uncertainty dominates assertion failure"
else
  fail AGG-007 "all lanes finish and uncertainty dominates assertion failure"
fi

reset_fixtures
shim="$work/shim"
mkdir "$shim"
printf '#!/usr/bin/env bash\nexit 1\n' > "$shim/rmdir"
chmod +x "$shim/rmdir"
cleanup_rc=0
run_replica "$work/cleanup.out" env PATH="$shim:$PATH" || cleanup_rc=$?
if [ "$cleanup_rc" -eq 125 ] &&
   grep -Fxq 'SUMMARY assertions=133 expected=133 failures=0 infra=1' "$work/cleanup.out" &&
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
   [ "$wrapper_infrastructure_contract" -eq 1 ] &&
   ! grep -Fxq 'EXPERIMENT LOCAL LIFECYCLE PASS' "$work/summaryless.out"; then
  pass AGG-009 "missing summaries or shared core map to infrastructure"
else
  fail AGG-009 "missing summaries or shared core map to infrastructure"
fi

lane_assignment_count="$(grep -Ec '^[[:space:]]+lane_count=[0-9]+$' \
  "$replica_lifecycle" || true)"
if [ "$lane_assignment_count" -eq 5 ] &&
   [ "$(grep -Fxc '    lane_count=3' "$replica_lifecycle")" -eq 1 ] &&
   [ "$(grep -Fxc '    lane_count=2' "$replica_lifecycle")" -eq 3 ] &&
   [ "$(grep -Fxc '    lane_count=1' "$replica_lifecycle")" -eq 1 ] &&
   [ "$(grep -Fxc '    lane_map=(1 1 1 0 2 2 2 1 2 2)' "$replica_lifecycle")" -eq 1 ] &&
   [ "$(grep -Fxc '    lane_map=(0 0 1)' "$replica_lifecycle")" -eq 1 ] &&
   [ "$(grep -Fxc '    lane_map=(0)' "$replica_lifecycle")" -eq 1 ] &&
   [ "$(grep -Fxc '    lane_map=(0 1)' "$replica_lifecycle")" -eq 1 ] &&
   [ "$(grep -Fxc '    lane_map=(0 1 0 0)' "$replica_lifecycle")" -eq 1 ] &&
   [ "$(grep -Fxc '    lane_map=(0 0 0)' "$replica_lifecycle")" -eq 0 ] &&
   [ "$(grep -Fxc '    lane_map=(0 0)' "$replica_lifecycle")" -eq 0 ] &&
   [ "$(grep -Fxc '    lane_map=(0 0 0 0)' "$replica_lifecycle")" -eq 0 ] &&
   [ "$(grep -Fxc 'readonly lane_count' "$replica_lifecycle")" -eq 1 ] &&
   [ "$(grep -Fxc 'readonly lane_map' "$replica_lifecycle")" -eq 1 ] &&
   [ "$(grep -Fxc 'for ((lane = 0; lane < lane_count; lane++)); do' \
     "$replica_lifecycle")" -eq 1 ] &&
   [ "$(grep -Fxc '    [ "${lane_map[$index]}" -eq "$lane" ] || continue' \
     "$replica_lifecycle")" -eq 1 ] &&
   [ "$(grep -Fxc '  run_lane "$lane" &' "$replica_lifecycle")" -eq 1 ] &&
   [ -f "$replica_local_onboarding" ] &&
   [ -f "$replica_catalog_state" ] &&
   [ -f "$replica_catalog_resolution" ] &&
   [ -f "$replica_install_lifecycle" ] &&
   [ "$(grep -Fxc 'exec bash "$script_dir/local-lifecycle-cases.sh" local' \
     "$replica_local_onboarding" || true)" -eq 1 ] &&
   [ "$(grep -Fxc 'exec bash "$script_dir/local-lifecycle-cases.sh" catalog-state' \
     "$replica_catalog_state" || true)" -eq 1 ] &&
   [ "$(grep -Fxc \
     'exec bash "$script_dir/local-lifecycle-cases.sh" catalog-resolution' \
     "$replica_catalog_resolution" || true)" -eq 1 ] &&
   [ "$(grep -Fxc 'exec bash "$script_dir/local-lifecycle-cases.sh" install' \
     "$replica_install_lifecycle" || true)" -eq 1 ]; then
  pass AGG-010 "split routes declare measured lane bounds through one scheduler"
else
  fail AGG-010 "split routes declare measured lane bounds through one scheduler"
fi

# One hold per compatibility lane. Holding any lane must leave the parent
# waiting on exactly that lane while the last subcase of every other lane
# completes, and the held lane must still finish once released.
hold_ids=(
  catalog-state-cases.py
  local-install-cases.sh
  catalog-resolution-cases.sh
)
peer_done_one=(
  install-state-cases.py.done
  catalog-state-cases.py.done
  catalog-state-cases.py.done
)
peer_done_two=(
  install-mutation-cases.py.done
  install-mutation-cases.py.done
  install-state-cases.py.done
)
target_done=(
  catalog-state-cases.py.done
  install-state-cases.py.done
  install-mutation-cases.py.done
)
expected_wait_children=(1 1 1)
wait_contract=1
for hold_index in "${!hold_ids[@]}"; do
  reset_fixtures
  hold_dir="$work/lane-hold-$hold_index"
  done_dir="$work/lane-done-$hold_index"
  wait_executions="$work/wait-executions-$hold_index"
  mkdir "$hold_dir" "$done_dir"
  : > "$wait_executions"
  wait_rc=0
  env \
    AGENT_LAB_AGG_EXEC_LOG="$wait_executions" \
    AGENT_LAB_AGG_HOLD_DIR="$hold_dir" \
    AGENT_LAB_AGG_HOLD_ID="${hold_ids[$hold_index]}" \
    AGENT_LAB_AGG_DONE_DIR="$done_dir" \
    bash "$replica_lifecycle" > "$work/wait-$hold_index.out" 2>&1 &
  wait_pid=$!
  wait_case_contract=0
  if wait_for_path "$hold_dir/ready" &&
     wait_for_path "$done_dir/${peer_done_one[$hold_index]}" &&
     wait_for_path "$done_dir/${peer_done_two[$hold_index]}" &&
     wait_for_child_wait "$wait_pid" "${expected_wait_children[$hold_index]}"; then
    wait_case_contract=1
  fi
  : > "$hold_dir/release"
  wait "$wait_pid" || wait_rc=$?
  if [ "$wait_case_contract" -ne 1 ] || [ "$wait_rc" -ne 0 ] ||
     ! wait_for_path "$done_dir/${target_done[$hold_index]}" ||
     ! cmp -s <(LC_ALL=C sort "$expected_executions") \
       <(LC_ALL=C sort "$wait_executions"); then
    wait_contract=0
  fi
done
if [ "$wait_contract" -eq 1 ]; then
  pass AGG-011 "parent waits every lane through controlled completion"
else
  fail AGG-011 "parent waits every lane through controlled completion"
fi

reset_fixtures
signal_dir="$work/signal"
signal_tmp="$work/signal-tmp"
mkdir "$signal_dir" "$signal_tmp"
AGENT_LAB_AGG_SIGNAL_DIR="$signal_dir" \
  TMPDIR="$signal_tmp" \
  python3 -I -B -c \
    'import os, sys; os.setsid(); os.execvpe("bash", ["bash", sys.argv[1]], os.environ)' \
    "$replica_lifecycle" > "$work/signal.out" 2>&1 &
signal_pid=$!
signal_rc=0
descendant_pid=""
if wait_for_path "$signal_dir/ready" &&
   IFS= read -r descendant_pid < "$signal_dir/descendant.pid" &&
   [[ "$descendant_pid" =~ ^[0-9]+$ ]] &&
   kill -0 "$descendant_pid" 2>/dev/null; then
  kill -TERM "$signal_pid" 2>/dev/null || true
else
  signal_rc=125
  kill -TERM "$signal_pid" 2>/dev/null || true
fi
observed_signal_rc=0
wait "$signal_pid" || observed_signal_rc=$?
descendant_gone=0
if [ -n "$descendant_pid" ] && wait_for_process_exit "$descendant_pid"; then
  descendant_gone=1
fi
if [ "$descendant_gone" -ne 1 ]; then
  surviving_group="$(ps -o pgid= -p "$descendant_pid" 2>/dev/null || true)"
  surviving_group="${surviving_group//[[:space:]]/}"
  if [ "$surviving_group" = "$signal_pid" ]; then
    kill -KILL -- "-$signal_pid" 2>/dev/null || true
    wait_for_process_exit "$descendant_pid" || true
  fi
fi
if [ "$signal_rc" -eq 0 ] && [ "$observed_signal_rc" -eq 143 ] &&
   [ "$descendant_gone" -eq 1 ]; then
  pass AGG-012 "owned-session termination reaches cooperative descendants"
else
  fail AGG-012 "owned-session termination reaches cooperative descendants"
fi

reset_fixtures
stubborn_dir="$work/stubborn-signal"
stubborn_tmp="$work/stubborn-tmp"
mkdir "$stubborn_dir" "$stubborn_tmp"
AGENT_LAB_AGG_STUBBORN_SIGNAL_DIR="$stubborn_dir" \
  TMPDIR="$stubborn_tmp" \
  python3 -I -B -c \
    'import os, sys; os.setsid(); os.execvpe("bash", ["bash", sys.argv[1]], os.environ)' \
    "$replica_lifecycle" > "$work/stubborn-signal.out" 2>&1 &
stubborn_leader=$!
stubborn_rc=0
stubborn_pid=""
if wait_for_path "$stubborn_dir/ready" &&
   IFS= read -r stubborn_pid < "$stubborn_dir/descendant.pid" &&
   [[ "$stubborn_pid" =~ ^[0-9]+$ ]] &&
   kill -0 "$stubborn_pid" 2>/dev/null; then
  kill -TERM "$stubborn_leader" 2>/dev/null || true
else
  stubborn_rc=125
  kill -TERM "$stubborn_leader" 2>/dev/null || true
fi
observed_stubborn_rc=0
wait "$stubborn_leader" || observed_stubborn_rc=$?
stubborn_alive=0
stubborn_output_preserved=0
if [ -n "$stubborn_pid" ] && kill -0 "$stubborn_pid" 2>/dev/null; then
  stubborn_alive=1
  stubborn_output="$(readlink "/proc/$stubborn_pid/fd/1" 2>/dev/null || true)"
  if [ -n "$stubborn_output" ] && [ -e "$stubborn_output" ]; then
    stubborn_output_preserved=1
  fi
fi
stubborn_group="$(ps -o pgid= -p "$stubborn_pid" 2>/dev/null || true)"
stubborn_group="${stubborn_group//[[:space:]]/}"
if [ "$stubborn_group" = "$stubborn_leader" ]; then
  kill -KILL -- "-$stubborn_leader" 2>/dev/null || true
  wait_for_process_exit "$stubborn_pid" || true
fi
if [ "$stubborn_rc" -eq 0 ] && [ "$observed_stubborn_rc" -eq 143 ] &&
   [ "$stubborn_alive" -eq 1 ] && [ "$stubborn_output_preserved" -eq 1 ]; then
  pass AGG-013 "signal exit preserves work owned by an uncooperative descendant"
else
  fail AGG-013 "signal exit preserves work owned by an uncooperative descendant"
fi

if [ "$install_overlap_contract" -eq 1 ] &&
   [ "$install_isolation_contract" -eq 1 ] &&
   [ "$install_lane_mutation_contract" -eq 1 ]; then
  pass AGG-031 "the install route overlaps an isolated long-pole lane and rejects serializing or dropping mutants"
else
  fail AGG-031 "the install route overlaps an isolated long-pole lane and rejects serializing or dropping mutants"
fi

if [ "$local_pole_isolation_contract" -eq 1 ] &&
   [ "$local_lane_mutation_contract" -eq 1 ]; then
  pass AGG-032 "the local partition isolates the catalog-state pole and rejects predecessor, dropped, serializing, or overlapping mutants"
else
  fail AGG-032 "the local partition isolates the catalog-state pole and rejects predecessor, dropped, serializing, or overlapping mutants"
fi

reset_source_fixtures
source_expected_executions="$work/source-expected-executions"
source_baseline_executions="$work/source-baseline-executions"
source_mutant_executions="$work/source-mutant-executions"
printf '%s\n' \
  zip-intake-cases.sh \
  zip-mutation-cases.py \
  git-intake-cases.sh \
  git-mutation-cases.py > "$source_expected_executions"
: > "$source_baseline_executions"
source_baseline_rc=0
run_source_replica "$work/source-baseline.out" env \
  AGENT_LAB_AGG_EXEC_LOG="$source_baseline_executions" || source_baseline_rc=$?

mutant_source_adapters="$replica/tests/experiment/source-adapter-hidden-duplicate.sh"
awk '
  { print }
  $0 == "subcases=(" { in_subcases=1; next }
  in_subcases && $0 == ")" {
    print "\"$repo_root/tests/experiment/zip-intake-cases.sh\" >/dev/null 2>&1"
    in_subcases=0
  }
' "$replica_source_adapters" > "$mutant_source_adapters"
chmod +x "$mutant_source_adapters"
source_mutation_count="$(grep -Fxc \
  '"$repo_root/tests/experiment/zip-intake-cases.sh" >/dev/null 2>&1' \
  "$mutant_source_adapters")"
: > "$source_mutant_executions"
source_mutant_rc=0
run_selected "$work/source-mutant.out" "$mutant_source_adapters" env \
  AGENT_LAB_AGG_EXEC_LOG="$source_mutant_executions" || source_mutant_rc=$?
source_mutant_expected="$work/source-mutant-expected-executions"
printf '%s\n' \
  zip-intake-cases.sh \
  zip-intake-cases.sh \
  zip-mutation-cases.py \
  git-intake-cases.sh \
  git-mutation-cases.py > "$source_mutant_expected"
if [ "$source_baseline_rc" -eq 0 ] &&
   cmp -s "$source_expected_executions" "$source_baseline_executions" &&
   [ "$source_mutation_count" -eq 1 ] && [ "$source_mutant_rc" -eq 0 ] &&
   cmp -s "$work/source-baseline.out" "$work/source-mutant.out" &&
   cmp -s "$source_mutant_expected" "$source_mutant_executions"; then
  pass AGG-021 "source-adapter execution ledger proves ordered exact-once routing"
else
  fail AGG-021 "source-adapter execution ledger proves ordered exact-once routing"
fi

source_success_expected="$work/source-success-expected"
{
  for id in "${source_expected_ids[@]}"; do
    printf 'PASS %s fixture assertion\n' "$id"
  done
  printf 'SUMMARY assertions=83 expected=83 failures=0 infra=0\n'
  printf 'EXPERIMENT SOURCE ADAPTERS PASS\n'
} > "$source_success_expected"
if [ "$source_baseline_rc" -eq 0 ] &&
   cmp -s "$source_success_expected" "$work/source-baseline.out"; then
  pass AGG-022 "source-adapter success forwards exact assertions, summary, and final marker"
else
  fail AGG-022 "source-adapter success forwards exact assertions, summary, and final marker"
fi

reset_source_fixtures
source_missing_records=()
mapfile -t source_missing_records < <(pass_records \
  "${source_zip_ids[@]:0:${#source_zip_ids[@]}-1}")
write_fixture "$replica/tests/experiment/zip-intake-cases.sh" 0 \
  "${source_missing_records[@]}"
source_missing_rc=0
run_source_replica "$work/source-missing.out" env || source_missing_rc=$?
if [ "$source_missing_rc" -eq 1 ] &&
   grep -Fxq 'SUMMARY assertions=82 expected=83 failures=1 infra=0' \
     "$work/source-missing.out" &&
   ! grep -Fxq 'EXPERIMENT SOURCE ADAPTERS PASS' "$work/source-missing.out"; then
  pass AGG-023 "source-adapter missing assertion identity maps to one"
else
  fail AGG-023 "source-adapter missing assertion identity maps to one"
fi

reset_source_fixtures
source_duplicate_records=()
mapfile -t source_duplicate_records < <(pass_records \
  "${source_zip_ids[@]}" "${source_zip_ids[-1]}")
write_fixture "$replica/tests/experiment/zip-intake-cases.sh" 0 \
  "${source_duplicate_records[@]}"
source_duplicate_rc=0
run_source_replica "$work/source-duplicate.out" env || source_duplicate_rc=$?
if [ "$source_duplicate_rc" -eq 1 ] &&
   grep -Fxq 'SUMMARY assertions=84 expected=83 failures=1 infra=0' \
     "$work/source-duplicate.out" &&
   ! grep -Fxq 'EXPERIMENT SOURCE ADAPTERS PASS' "$work/source-duplicate.out"; then
  pass AGG-024 "source-adapter duplicate assertion identity maps to one"
else
  fail AGG-024 "source-adapter duplicate assertion identity maps to one"
fi

reset_source_fixtures
source_substituted_records=()
mapfile -t source_substituted_records < <(pass_records "${source_zip_ids[@]}")
source_substituted_records[-1]='PASS:BAD-001'
write_fixture "$replica/tests/experiment/zip-intake-cases.sh" 0 \
  "${source_substituted_records[@]}"
source_substituted_rc=0
run_source_replica "$work/source-substituted.out" env || source_substituted_rc=$?
if [ "$source_substituted_rc" -eq 1 ] &&
   grep -Fxq 'SUMMARY assertions=83 expected=83 failures=1 infra=0' \
     "$work/source-substituted.out" &&
   ! grep -Fxq 'EXPERIMENT SOURCE ADAPTERS PASS' "$work/source-substituted.out"; then
  pass AGG-025 "source-adapter substituted assertion identity maps to one"
else
  fail AGG-025 "source-adapter substituted assertion identity maps to one"
fi

reset_source_fixtures
source_failed_records=()
mapfile -t source_failed_records < <(pass_records "${source_zip_ids[@]}")
source_failed_records[0]='FAIL:ZIP-001'
write_fixture "$replica/tests/experiment/zip-intake-cases.sh" 1 \
  "${source_failed_records[@]}"
source_assertion_rc=0
run_source_replica "$work/source-assertion.out" env || source_assertion_rc=$?
if [ "$source_assertion_rc" -eq 1 ] &&
   grep -Fxq 'SUMMARY assertions=83 expected=83 failures=1 infra=0' \
     "$work/source-assertion.out" &&
   ! grep -Fxq 'EXPERIMENT SOURCE ADAPTERS PASS' "$work/source-assertion.out"; then
  pass AGG-026 "source-adapter subcase assertion failure maps to one"
else
  fail AGG-026 "source-adapter subcase assertion failure maps to one"
fi

reset_source_fixtures
source_uncertain_records=()
mapfile -t source_uncertain_records < <(pass_records "${source_zip_ids[@]}")
write_fixture "$replica/tests/experiment/zip-intake-cases.sh" 125 \
  "${source_uncertain_records[@]}"
source_subcase_infra_rc=0
run_source_replica "$work/source-subcase-infra.out" env || source_subcase_infra_rc=$?
if [ "$source_subcase_infra_rc" -eq 125 ] &&
   grep -Fxq 'SUMMARY assertions=83 expected=83 failures=0 infra=1' \
     "$work/source-subcase-infra.out" &&
   ! grep -Fxq 'EXPERIMENT SOURCE ADAPTERS PASS' "$work/source-subcase-infra.out"; then
  pass AGG-027 "source-adapter subcase uncertainty maps to one hundred twenty-five"
else
  fail AGG-027 "source-adapter subcase uncertainty maps to one hundred twenty-five"
fi

reset_source_fixtures
find "$replica/tests/experiment/zip-mutation-cases.py" -delete
source_setup_infra_rc=0
run_source_replica "$work/source-setup-infra.out" env || source_setup_infra_rc=$?
if [ "$source_setup_infra_rc" -eq 125 ] &&
   grep -Fxq 'SUMMARY assertions=70 expected=83 failures=1 infra=1' \
     "$work/source-setup-infra.out" &&
   ! grep -Fxq 'EXPERIMENT SOURCE ADAPTERS PASS' "$work/source-setup-infra.out"; then
  pass AGG-028 "source-adapter setup uncertainty maps to one hundred twenty-five"
else
  fail AGG-028 "source-adapter setup uncertainty maps to one hundred twenty-five"
fi

reset_source_fixtures
source_shim="$work/source-shim"
mkdir "$source_shim"
printf '#!/usr/bin/env bash\nexit 1\n' > "$source_shim/rmdir"
chmod +x "$source_shim/rmdir"
source_cleanup_rc=0
run_source_replica "$work/source-cleanup.out" env \
  PATH="$source_shim:$PATH" || source_cleanup_rc=$?
if [ "$source_cleanup_rc" -eq 125 ] &&
   grep -Fxq 'SUMMARY assertions=83 expected=83 failures=0 infra=1' \
     "$work/source-cleanup.out" &&
   ! grep -Fxq 'EXPERIMENT SOURCE ADAPTERS PASS' "$work/source-cleanup.out"; then
  pass AGG-029 "source-adapter cleanup uncertainty suppresses the final marker"
else
  fail AGG-029 "source-adapter cleanup uncertainty suppresses the final marker"
fi

reset_source_fixtures
source_summaryless="$replica/tests/experiment/zip-intake-cases.sh"
{
  printf '#!/usr/bin/env bash\nset -u\n'
  for id in "${source_zip_ids[@]}"; do
    printf "printf 'PASS %s fixture assertion\\n'\n" "$id"
  done
  printf 'exit 0\n'
} > "$source_summaryless"
chmod +x "$source_summaryless"
source_summaryless_rc=0
run_source_replica "$work/source-summaryless.out" env || source_summaryless_rc=$?
if [ "$source_summaryless_rc" -eq 125 ] &&
   grep -Fxq 'SUMMARY assertions=83 expected=83 failures=0 infra=1' \
     "$work/source-summaryless.out" &&
   ! grep -Fxq 'EXPERIMENT SOURCE ADAPTERS PASS' "$work/source-summaryless.out"; then
  pass AGG-030 "source-adapter missing subcase summary maps to one hundred twenty-five"
else
  fail AGG-030 "source-adapter missing subcase summary maps to one hundred twenty-five"
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
