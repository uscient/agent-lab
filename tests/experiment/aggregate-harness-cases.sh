#!/usr/bin/env bash
set -u -o pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
lifecycle="$repo_root/tests/experiment/local-lifecycle-cases.sh"
local_onboarding="$repo_root/tests/experiment/local-onboarding-cases.sh"
install_lifecycle="$repo_root/tests/experiment/install-lifecycle-cases.sh"
source_adapters="$repo_root/tests/experiment/source-adapter-cases.sh"
expected_count=23
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
replica_install_lifecycle="$replica/tests/experiment/install-lifecycle-cases.sh"
replica_source_adapters="$replica/tests/experiment/source-adapter-cases.sh"
mkdir -p "$replica/tests/experiment" "$replica/tests/install"
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
catalog_ids=("${expected_ids[@]:10:76}")
install_ids=("${expected_ids[@]:86:13}")
state_ids=("${expected_ids[@]:99:16}")
integrity_ids=("${expected_ids[@]:115:7}")
mutation_ids=("${expected_ids[@]:122:11}")
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
    case "$execution_id" in
      local-install-cases.sh | local-image-catalog-cases.sh)
        printf 'if [ -n "${AGENT_LAB_AGG_BARRIER_DIR:-}" ]; then\n'
        printf "  : > \"\$AGENT_LAB_AGG_BARRIER_DIR/%s.ready\" || exit 125\n" "$execution_id"
        printf '  attempts=0\n'
        printf '  while [ ! -f "$AGENT_LAB_AGG_BARRIER_DIR/local-install-cases.sh.ready" ] ||\n'
        printf '        [ ! -f "$AGENT_LAB_AGG_BARRIER_DIR/local-image-catalog-cases.sh.ready" ] ||\n'
        printf '        [ ! -f "$AGENT_LAB_AGG_BARRIER_DIR/install-state-cases.py.ready" ]; do\n'
        printf '    attempts=$((attempts + 1))\n'
        printf '    [ "$attempts" -lt 200 ] || exit 125\n'
        printf '    sleep 0.01\n'
        printf '  done\n'
        printf 'fi\n'
        ;;
    esac
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
    if [ "$execution_id" = "local-image-catalog-cases.sh" ]; then
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
    printf '    deadline = time.monotonic() + 5.0\n'
    printf "    while not Path(hold_dir, 'release').is_file():\n"
    printf '        if time.monotonic() >= deadline:\n'
    printf '            raise SystemExit(125)\n'
    printf '        time.sleep(0.01)\n'
    if [ "$execution_id" = "install-state-cases.py" ]; then
      printf 'barrier = os.environ.get("AGENT_LAB_AGG_BARRIER_DIR")\n'
      printf 'if barrier:\n'
      printf "    Path(barrier, '%s.ready').touch()\n" "$execution_id"
      printf '    peers = (\n'
      printf "        'local-install-cases.sh.ready',\n"
      printf "        'local-image-catalog-cases.sh.ready',\n"
      printf "        'install-state-cases.py.ready',\n"
      printf '    )\n'
      printf '    deadline = time.monotonic() + 2.0\n'
      printf '    while not all(Path(barrier, peer).is_file() for peer in peers):\n'
      printf '        if time.monotonic() >= deadline:\n'
      printf '            raise SystemExit(125)\n'
      printf '        time.sleep(0.01)\n'
    fi
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
  local installer_records=() config_records=() catalog_records=()
  local install_records=() state_records=() integrity_records=() mutation_records=()
  mapfile -t installer_records < <(pass_records "${installer_ids[@]}")
  mapfile -t config_records < <(pass_records "${config_ids[@]}")
  mapfile -t catalog_records < <(pass_records "${catalog_ids[@]}")
  mapfile -t install_records < <(pass_records "${install_ids[@]}")
  mapfile -t state_records < <(pass_records "${state_ids[@]}")
  mapfile -t integrity_records < <(pass_records "${integrity_ids[@]}")
  mapfile -t mutation_records < <(pass_records "${mutation_ids[@]}")
  write_fixture "$replica/tests/install/local-install-cases.sh" 0 "${installer_records[@]}"
  write_fixture "$replica/tests/experiment/local-config-cases.sh" 0 "${config_records[@]}"
  write_fixture "$replica/tests/experiment/local-image-catalog-cases.sh" 0 "${catalog_records[@]}"
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
  local-image-catalog-cases.sh \
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
  local-image-catalog-cases.sh \
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
if [ -f "$local_onboarding" ] && [ -f "$install_lifecycle" ]; then
  cp "$local_onboarding" "$replica_local_onboarding"
  cp "$install_lifecycle" "$replica_install_lifecycle"
  chmod +x "$replica_local_onboarding" "$replica_install_lifecycle"

  expected_local_ids="$work/expected-local-ids"
  expected_install_ids="$work/expected-install-ids"
  expected_local_executions="$work/expected-local-executions"
  expected_install_executions="$work/expected-install-executions"
  printf '%s\n' "${expected_ids[@]:0:86}" > "$expected_local_ids"
  printf '%s\n' "${expected_ids[@]:86:47}" > "$expected_install_ids"
  printf '%s\n' \
    local-install-cases.sh \
    local-config-cases.sh \
    local-image-catalog-cases.sh > "$expected_local_executions"
  printf '%s\n' \
    install-store-cases.sh \
    install-state-cases.py \
    install-integrity-cases.py \
    install-mutation-cases.py > "$expected_install_executions"

  reset_fixtures
  split_barrier="$work/split-barrier"
  local_executions="$work/local-executions"
  install_executions="$work/install-executions"
  mkdir "$split_barrier"
  : > "$local_executions"
  : > "$install_executions"
  local_route_rc=0
  install_route_rc=0
  env \
    AGENT_LAB_AGG_EXEC_LOG="$local_executions" \
    AGENT_LAB_AGG_BARRIER_DIR="$split_barrier" \
    bash "$replica_local_onboarding" > "$work/local-route.out" 2>&1 &
  local_route_pid=$!
  env \
    AGENT_LAB_AGG_EXEC_LOG="$install_executions" \
    AGENT_LAB_AGG_BARRIER_DIR="$split_barrier" \
    bash "$replica_install_lifecycle" > "$work/install-route.out" 2>&1 &
  install_route_pid=$!
  wait "$local_route_pid" || local_route_rc=$?
  wait "$install_route_pid" || install_route_rc=$?

  combined_executions="$work/combined-executions"
  LC_ALL=C sort "$local_executions" "$install_executions" > "$combined_executions"
  if [ "$local_route_rc" -eq 0 ] && [ "$install_route_rc" -eq 0 ] &&
     cmp -s <(LC_ALL=C sort "$expected_local_executions") \
       <(LC_ALL=C sort "$local_executions") &&
     cmp -s <(LC_ALL=C sort "$expected_install_executions") \
       <(LC_ALL=C sort "$install_executions") &&
     cmp -s <(LC_ALL=C sort "$expected_executions") "$combined_executions"; then
    split_routing_contract=1
  fi
  if route_output_valid \
       "$work/local-route.out" "$expected_local_ids" 86 \
       'EXPERIMENT LOCAL LIFECYCLE PASS' "$local_route_rc" &&
     route_output_valid \
       "$work/install-route.out" "$expected_install_ids" 47 \
       'EXPERIMENT INSTALL LIFECYCLE PASS' "$install_route_rc"; then
    split_output_contract=1
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
  missing_install_core_rc=0
  bash "$replica_local_onboarding" > "$work/missing-local-core.out" 2>&1 || \
    missing_local_core_rc=$?
  bash "$replica_install_lifecycle" > "$work/missing-install-core.out" 2>&1 || \
    missing_install_core_rc=$?
  mv "$saved_lifecycle" "$replica_lifecycle"
  if infrastructure_output_valid \
       "$work/missing-local-core.out" 86 "$missing_local_core_rc" &&
     infrastructure_output_valid \
       "$work/missing-install-core.out" 47 "$missing_install_core_rc"; then
    wrapper_infrastructure_contract=1
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
   [ -f "$overlap_barrier/local-image-catalog-cases.sh.ready" ] &&
   [ -f "$overlap_barrier/install-state-cases.py.ready" ] &&
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
   [ "$split_output_contract" -eq 1 ]; then
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
if [ "$lane_assignment_count" -eq 3 ] &&
   [ "$(grep -Fxc '    lane_count=3' "$replica_lifecycle")" -eq 1 ] &&
   [ "$(grep -Fxc '    lane_count=2' "$replica_lifecycle")" -eq 1 ] &&
   [ "$(grep -Fxc '    lane_count=1' "$replica_lifecycle")" -eq 1 ] &&
   [ "$(grep -Fxc '    lane_map=(0 1 2 0 1 2 0)' "$replica_lifecycle")" -eq 1 ] &&
   [ "$(grep -Fxc '    lane_map=(0 0 1)' "$replica_lifecycle")" -eq 1 ] &&
   [ "$(grep -Fxc '    lane_map=(0 0 0 0)' "$replica_lifecycle")" -eq 1 ] &&
   [ "$(grep -Fxc 'readonly lane_count' "$replica_lifecycle")" -eq 1 ] &&
   [ "$(grep -Fxc 'readonly lane_map' "$replica_lifecycle")" -eq 1 ] &&
   [ "$(grep -Fxc 'for ((lane = 0; lane < lane_count; lane++)); do' \
     "$replica_lifecycle")" -eq 1 ] &&
   [ "$(grep -Fxc '    [ "${lane_map[$index]}" -eq "$lane" ] || continue' \
     "$replica_lifecycle")" -eq 1 ] &&
   [ "$(grep -Fxc '  run_lane "$lane" &' "$replica_lifecycle")" -eq 1 ] &&
   [ -f "$replica_local_onboarding" ] &&
   [ -f "$replica_install_lifecycle" ] &&
   [ "$(grep -Fxc 'exec bash "$script_dir/local-lifecycle-cases.sh" local' \
     "$replica_local_onboarding" || true)" -eq 1 ] &&
   [ "$(grep -Fxc 'exec bash "$script_dir/local-lifecycle-cases.sh" install' \
     "$replica_install_lifecycle" || true)" -eq 1 ]; then
  pass AGG-010 "split routes preserve three measured aggregate lanes through one scheduler"
else
  fail AGG-010 "split routes preserve three measured aggregate lanes through one scheduler"
fi

hold_ids=(
  local-install-cases.sh
  local-config-cases.sh
  local-image-catalog-cases.sh
)
peer_done_one=(
  install-state-cases.py.done
  install-mutation-cases.py.done
  install-mutation-cases.py.done
)
peer_done_two=(
  install-integrity-cases.py.done
  install-integrity-cases.py.done
  install-state-cases.py.done
)
target_done=(
  install-mutation-cases.py.done
  install-state-cases.py.done
  install-integrity-cases.py.done
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
