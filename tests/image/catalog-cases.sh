#!/usr/bin/env bash
set -u -o pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
agent_lab="$repo_root/scripts/agent-lab"
bounded_helper="$repo_root/tests/helpers/run-bounded.py"
expected_count=18
work=""
failures=0
infrastructure=0

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

finish() {
  local assertions=0
  if [ -n "${observed:-}" ] && [ -f "$observed" ]; then
    assertions="$(wc -l < "$observed")"
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
}

if ! work="$(mktemp -d)"; then
  printf 'SUMMARY assertions=0 expected=%s failures=0 infra=1\n' "$expected_count"
  exit 125
fi
trap 'cleanup_work >/dev/null 2>&1 || true' EXIT
observed="$work/observed"
: > "$observed"

if [ ! -x "$agent_lab" ] || [ ! -f "$bounded_helper" ] || ! command -v jq >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  printf 'INFRA catalog public-contract prerequisites are unavailable\n' >&2
  infrastructure=1
  finish
fi
if ! python3 -I -B "$bounded_helper" --self-test > "$work/bounded-self-test.out" 2> "$work/bounded-self-test.err"; then
  printf 'INFRA bounded command helper self-test failed\n' >&2
  infrastructure=1
  finish
fi

pass() { printf 'PASS %s %s\n' "$1" "$2"; printf '%s\n' "$1" >> "$observed"; }
fail() { printf 'FAIL %s %s\n' "$1" "$2"; printf '%s\n' "$1" >> "$observed"; failures=$((failures + 1)); }
run_bounded() {
  local output="$1"
  local errors="$2"
  local expectation="$3"
  local status="${output}.status"
  local rc=0
  local status_line=""
  shift 3
  find "$status" -delete 2>/dev/null || true
  python3 -I -B "$bounded_helper" \
    --timeout 5 --status "$status" --stdout "$output" --stderr "$errors" -- "$@" || rc=$?
  if [ -f "$status" ]; then
    status_line="$(cat "$status")"
  fi
  if [ "$status_line" != "child:$rc" ]; then
    infrastructure=1
    rc=125
  else
    case "$rc" in
      0|1)
        ;;
      125)
        [ "$expectation" = expected-125 ] || infrastructure=1
        ;;
      *)
        infrastructure=1
        ;;
    esac
  fi
  return "$rc"
}
capture() {
  CAPTURE_RC=0
  run_bounded "$work/stdout" "$work/stderr" normal "$@" || CAPTURE_RC=$?
}
subject_a="registry.example/operator/worker@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
subject_b="registry.example/operator/other@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

init_home() {
  local home="$1"
  capture "$agent_lab" --home "$home" init
  if [ "$CAPTURE_RC" -ne 0 ]; then
    printf 'INFRA temporary Agent Lab home initialization failed: %s\n' "$(tr '\n' ' ' < "$work/stderr")" >&2
    infrastructure=1
    finish
  fi
}

grammar_home="$work/grammar-home"
init_home "$grammar_home"
valid_names=(
  "a.b"
  "vendor-one.image-2"
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
)
valid_names_ok=true
for name in "${valid_names[@]}"; do
  capture "$agent_lab" --home "$grammar_home" image add "$name" "$subject_a"
  if [ "$CAPTURE_RC" -ne 0 ] || ! jq -e '.changed == true and .generation == 1' "$work/stdout" >/dev/null 2>&1; then
    valid_names_ok=false
  fi
done
if $valid_names_ok; then
  pass CAT-NAME-001 "valid minimum, hyphenated, and maximum-length names are accepted"
else
  fail CAT-NAME-001 "valid minimum, hyphenated, and maximum-length names are accepted"
fi

invalid_names=(
  "Agent.image"
  "vendor.Image"
  "vendor.image.extra"
  "vendor_1.image"
  ".image"
  "vendor."
  "vendor.-image"
  "vendor.image-"
  "vendor..image"
  "vendor--one.image"
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.image"
  "vendor/one.image"
  "vendor:image"
  "vendor@one.image"
  "vendor.é"
  $'vendor.im\nage'
)
invalid_names_ok=true
capture "$agent_lab" --home "$grammar_home" image list --all
before_invalid="$(jq -r 'length' "$work/stdout" 2>/dev/null || printf invalid)"
for name in "${invalid_names[@]}"; do
  capture "$agent_lab" --home "$grammar_home" image add "$name" "$subject_a"
  if [ "$CAPTURE_RC" -ne 1 ] || [ -s "$work/stdout" ]; then
    invalid_names_ok=false
  fi
done
capture "$agent_lab" --home "$grammar_home" image list --all
after_invalid="$(jq -r 'length' "$work/stdout" 2>/dev/null || printf invalid)"
if $invalid_names_ok && [ "$before_invalid" = "$after_invalid" ]; then
  pass CAT-NAME-002 "invalid ASCII, Unicode, separator, control, and length boundaries are rejected without mutation"
else
  fail CAT-NAME-002 "invalid ASCII, Unicode, separator, control, and length boundaries are rejected without mutation"
fi

oci_home="$work/oci-home"
init_home "$oci_home"
port_subject="registry.example:443/team/image@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
capture "$agent_lab" --home "$oci_home" image add valid.port "$port_subject"
if [ "$CAPTURE_RC" -eq 0 ] && jq -e --arg subject "$port_subject" '.changed == true' "$work/stdout" >/dev/null 2>&1; then
  capture "$agent_lab" --home "$oci_home" image inspect valid.port
  if [ "$CAPTURE_RC" -eq 0 ] && jq -e --arg subject "$port_subject" '.subject == $subject' "$work/stdout" >/dev/null 2>&1; then
    pass CAT-OCI-001 "the shared digest-reference grammar accepts a bounded registry port"
  else
    fail CAT-OCI-001 "the shared digest-reference grammar accepts a bounded registry port"
  fi
else
  fail CAT-OCI-001 "the shared digest-reference grammar accepts a bounded registry port"
fi

digest="sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
overlong="$(printf 'a%.0s' {1..256})@$digest"
invalid_subjects=(
  "registry.example/team/image:latest"
  "$digest"
  "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  "/tmp/image@$digest"
  "user:password@registry.example/team/image@$digest"
  "registry.example/team//image@$digest"
  "registry.example/team/../image@$digest"
  "registry.example/team/_image@$digest"
  "registry.example/team/image@$digest?query=1"
  "registry.example/team/image@sha256:DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"
  "$overlong"
)
invalid_subjects_ok=true
index=0
for subject in "${invalid_subjects[@]}"; do
  index=$((index + 1))
  capture "$agent_lab" --home "$oci_home" image add "invalid.case$index" "$subject"
  if [ "$CAPTURE_RC" -ne 1 ] || [ -s "$work/stdout" ]; then
    invalid_subjects_ok=false
  fi
done
capture "$agent_lab" --home "$oci_home" image list --all
if $invalid_subjects_ok && jq -e 'length == 1 and .[0].name == "valid.port"' "$work/stdout" >/dev/null 2>&1; then
  pass CAT-OCI-002 "mutable, bare, path-like, credentialed, ambiguous, and overlong subjects are rejected without mutation"
else
  fail CAT-OCI-002 "mutable, bare, path-like, credentialed, ambiguous, and overlong subjects are rejected without mutation"
fi

semantics_home="$work/semantics-home"
init_home "$semantics_home"
capture "$agent_lab" --home "$semantics_home" image add vendor.worker "$subject_a"
if [ "$CAPTURE_RC" -eq 0 ] && jq -e '.changed == true and .generation == 1 and (.entryDigest | test("^sha256:[0-9a-f]{64}$"))' "$work/stdout" >/dev/null 2>&1; then
  active_entry="$(jq -r '.entryDigest' "$work/stdout")"
  pass CAT-ADD-001 "first add publishes one generation-one immutable binding"
else
  active_entry="sha256:$(printf '0%.0s' {1..64})"
  fail CAT-ADD-001 "first add publishes one generation-one immutable binding"
fi

entry_count_before="$(find "$semantics_home/images/catalog/entries" -maxdepth 1 -type f 2>/dev/null | wc -l)"
snapshot_count_before="$(find "$semantics_home/images/catalog/snapshots" -maxdepth 1 -type f 2>/dev/null | wc -l)"
capture "$agent_lab" --home "$semantics_home" image add vendor.worker "$subject_a"
entry_count_after="$(find "$semantics_home/images/catalog/entries" -maxdepth 1 -type f 2>/dev/null | wc -l)"
snapshot_count_after="$(find "$semantics_home/images/catalog/snapshots" -maxdepth 1 -type f 2>/dev/null | wc -l)"
if [ "$CAPTURE_RC" -eq 0 ] && jq -e --arg entry "$active_entry" '.changed == false and .entryDigest == $entry and .generation == 1' "$work/stdout" >/dev/null 2>&1 &&
   [ "$entry_count_before" = "$entry_count_after" ] && [ "$snapshot_count_before" = "$snapshot_count_after" ]; then
  pass CAT-ADD-002 "same-subject retry is idempotent and publishes no records"
else
  fail CAT-ADD-002 "same-subject retry is idempotent and publishes no records"
fi

capture "$agent_lab" --home "$semantics_home" image add vendor.worker "$subject_b"
conflict_rc="$CAPTURE_RC"
capture "$agent_lab" --home "$semantics_home" image inspect vendor.worker
if [ "$conflict_rc" -eq 1 ] && [ "$CAPTURE_RC" -eq 0 ] && jq -e --arg subject "$subject_a" --arg entry "$active_entry" '.state == "active" and .subject == $subject and .entryDigest == $entry' "$work/stdout" >/dev/null 2>&1; then
  pass CAT-ADD-003 "different-subject add conflicts without overwriting"
else
  fail CAT-ADD-003 "different-subject add conflicts without overwriting"
fi

capture "$agent_lab" --home "$semantics_home" image add vendor.second "$subject_a"
if [ "$CAPTURE_RC" -eq 0 ] && jq -e '.changed == true and .generation == 1' "$work/stdout" >/dev/null 2>&1; then
  pass CAT-ADD-004 "distinct names may bind the same immutable subject"
else
  fail CAT-ADD-004 "distinct names may bind the same immutable subject"
fi

capture "$agent_lab" --home "$semantics_home" image add agent-lab.worker "$subject_a"
reserved_add_rc="$CAPTURE_RC"
capture "$agent_lab" --home "$semantics_home" image remove agent-lab.worker --expect "$active_entry"
reserved_remove_rc="$CAPTURE_RC"
if [ "$reserved_add_rc" -eq 1 ] && [ "$reserved_remove_rc" -eq 1 ]; then
  pass CAT-NS-001 "release-owned names cannot be added, removed, or shadowed locally"
else
  fail CAT-NS-001 "release-owned names cannot be added, removed, or shadowed locally"
fi

stale="sha256:$(printf 'e%.0s' {1..64})"
capture "$agent_lab" --home "$semantics_home" image remove vendor.worker --expect "$stale"
stale_rc="$CAPTURE_RC"
capture "$agent_lab" --home "$semantics_home" image inspect vendor.worker
if [ "$stale_rc" -eq 1 ] && [ "$CAPTURE_RC" -eq 0 ] && jq -e --arg entry "$active_entry" '.state == "active" and .entryDigest == $entry and .generation == 1' "$work/stdout" >/dev/null 2>&1; then
  pass CAT-CAS-001 "stale remove CAS changes no state"
else
  fail CAT-CAS-001 "stale remove CAS changes no state"
fi

capture "$agent_lab" --home "$semantics_home" image remove vendor.worker --expect "$active_entry"
if [ "$CAPTURE_RC" -eq 0 ] && jq -e --arg previous "$active_entry" '.changed == true and .generation == 2 and .state == "removed"' "$work/stdout" >/dev/null 2>&1; then
  tombstone_entry="$(jq -r '.entryDigest' "$work/stdout")"
  pass CAT-CAS-002 "exact CAS publishes a generation-two tombstone"
else
  tombstone_entry="sha256:$(printf '0%.0s' {1..64})"
  fail CAT-CAS-002 "exact CAS publishes a generation-two tombstone"
fi

capture "$agent_lab" --home "$semantics_home" image remove vendor.worker --expect "$active_entry"
retry_rc="$CAPTURE_RC"
retry_output="$(cat "$work/stdout")"
capture "$agent_lab" --home "$semantics_home" image remove vendor.worker --expect "$tombstone_entry"
wrong_retry_rc="$CAPTURE_RC"
if [ "$retry_rc" -eq 0 ] && printf '%s' "$retry_output" | jq -e --arg entry "$tombstone_entry" '.changed == false and .entryDigest == $entry and .generation == 2' >/dev/null 2>&1 &&
   [ "$wrong_retry_rc" -eq 1 ]; then
  pass CAT-CAS-003 "original-token retry is idempotent and every other tombstone token conflicts"
else
  fail CAT-CAS-003 "original-token retry is idempotent and every other tombstone token conflicts"
fi

capture "$agent_lab" --home "$semantics_home" image add vendor.worker "$subject_a"
same_reuse_rc="$CAPTURE_RC"
capture "$agent_lab" --home "$semantics_home" image add vendor.worker "$subject_b"
other_reuse_rc="$CAPTURE_RC"
if [ "$same_reuse_rc" -eq 1 ] && [ "$other_reuse_rc" -eq 1 ]; then
  pass CAT-CAS-004 "a tombstoned v0 name cannot be reused or restored"
else
  fail CAT-CAS-004 "a tombstoned v0 name cannot be reused or restored"
fi

ordering_home="$work/ordering-home"
init_home "$ordering_home"
capture "$agent_lab" --home "$ordering_home" image add zeta.one "$subject_a"
capture "$agent_lab" --home "$ordering_home" image add alpha.two "$subject_b"
capture "$agent_lab" --home "$ordering_home" image list
if [ "$CAPTURE_RC" -eq 0 ] && [ "$(jq -c '[.[].name]' "$work/stdout" 2>/dev/null)" = '["alpha.two","zeta.one"]' ] &&
   [ "$(python3 -I -c 'import json,sys; print(json.dumps(json.load(sys.stdin),ensure_ascii=True,separators=(",",":"),sort_keys=True))' < "$work/stdout" 2>/dev/null)" = "$(tr -d '\n' < "$work/stdout")" ]; then
  pass CAT-READ-001 "list output is canonical and byte-sorted"
else
  fail CAT-READ-001 "list output is canonical and byte-sorted"
fi

capture "$agent_lab" --home "$semantics_home" image list
active_list="$(cat "$work/stdout")"
capture "$agent_lab" --home "$semantics_home" image list --all
all_list="$(cat "$work/stdout")"
capture "$agent_lab" --home "$semantics_home" image inspect vendor.worker
if printf '%s' "$active_list" | jq -e 'all(.[]; .state == "active") and all(.[]; .name != "vendor.worker")' >/dev/null 2>&1 &&
   printf '%s' "$all_list" | jq -e 'any(.[]; .name == "vendor.worker" and .state == "removed")' >/dev/null 2>&1 &&
   [ "$CAPTURE_RC" -eq 0 ] && jq -e --arg entry "$tombstone_entry" '.state == "removed" and .entryDigest == $entry and .generation == 2' "$work/stdout" >/dev/null 2>&1; then
  pass CAT-READ-002 "list and inspect distinguish active and removed state without repair"
else
  fail CAT-READ-002 "list and inspect distinguish active and removed state without repair"
fi

canary_home="$work/canary-home"
canary_bin="$work/canary-bin"
canary_marks="$work/canary-marks"
mkdir "$canary_bin" "$canary_marks"
init_home "$canary_home"
for command in docker git curl wget; do
  printf '%s\n' '#!/bin/sh' 'set -eu' ': > "$CANARY_DIR/${0##*/}"' > "$canary_bin/$command"
  chmod 700 "$canary_bin/$command"
  CANARY_DIR="$canary_marks" "$canary_bin/$command"
done
calibrated="$(find "$canary_marks" -type f | wc -l)"
find "$canary_marks" -type f -delete
canary_rc=0
run_bounded "$work/canary.out" "$work/canary.err" normal \
  env -i PATH="$canary_bin:/usr/bin:/bin" LANG=C LC_ALL=C CANARY_DIR="$canary_marks" \
  "$agent_lab" --home "$canary_home" image add noeffect.mapping "$subject_a" || canary_rc=$?
if [ "$calibrated" -eq 4 ] && [ "$canary_rc" -eq 0 ] && [ -z "$(find "$canary_marks" -type f -print -quit)" ]; then
  pass CAT-NOEF-001 "calibrated Docker, Git, downloader, and network-tool canaries remain silent"
else
  fail CAT-NOEF-001 "calibrated Docker, Git, downloader, and network-tool canaries remain silent"
fi

concurrent_home="$work/concurrent-home"
init_home "$concurrent_home"
run_bounded "$work/race-first-1.out" "$work/race-first-1.err" normal \
  "$agent_lab" --home "$concurrent_home" image add race.first "$subject_a" &
pid_one=$!
run_bounded "$work/race-first-2.out" "$work/race-first-2.err" normal \
  "$agent_lab" --home "$concurrent_home" image add race.first "$subject_a" &
pid_two=$!
wait "$pid_one"; rc_one=$?
wait "$pid_two"; rc_two=$?
case "$rc_one:$rc_two" in
  0:0)
    ;;
  *)
    [ "$rc_one" -eq 0 ] || [ "$rc_one" -eq 1 ] || infrastructure=1
    [ "$rc_two" -eq 0 ] || [ "$rc_two" -eq 1 ] || infrastructure=1
    ;;
esac
first_outcomes="$(jq -r '.changed' "$work/race-first-1.out" "$work/race-first-2.out" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')"
if [ "$rc_one" -eq 0 ] && [ "$rc_two" -eq 0 ] && [ "$first_outcomes" = "false true " ] &&
   [ "$(find "$concurrent_home/images/catalog/entries" -maxdepth 1 -type f | wc -l)" -eq 1 ] &&
   [ "$(find "$concurrent_home/images/catalog/snapshots" -maxdepth 1 -type f | wc -l)" -eq 1 ]; then
  pass CAT-CONC-001 "concurrent first add linearizes once with one idempotent observer"
else
  fail CAT-CONC-001 "concurrent first add linearizes once with one idempotent observer"
fi

capture "$agent_lab" --home "$concurrent_home" image inspect race.first
race_entry="$(jq -r '.entryDigest // empty' "$work/stdout" 2>/dev/null)"
run_bounded "$work/race-add.out" "$work/race-add.err" normal \
  "$agent_lab" --home "$concurrent_home" image add race.first "$subject_a" &
pid_add=$!
run_bounded "$work/race-remove.out" "$work/race-remove.err" normal \
  "$agent_lab" --home "$concurrent_home" image remove race.first --expect "$race_entry" &
pid_remove=$!
wait "$pid_add"; rc_add=$?
wait "$pid_remove"; rc_remove=$?
[ "$rc_add" -eq 0 ] || [ "$rc_add" -eq 1 ] || infrastructure=1
[ "$rc_remove" -eq 0 ] || [ "$rc_remove" -eq 1 ] || infrastructure=1
capture "$agent_lab" --home "$concurrent_home" image inspect race.first
if [ "$rc_remove" -eq 0 ] && { [ "$rc_add" -eq 0 ] || [ "$rc_add" -eq 1 ]; } &&
   [ "$CAPTURE_RC" -eq 0 ] && jq -e '.state == "removed" and .generation == 2' "$work/stdout" >/dev/null 2>&1 &&
   [ "$(find "$concurrent_home/images/catalog/entries" -maxdepth 1 -type f | wc -l)" -eq 2 ]; then
  pass CAT-CONC-002 "concurrent add and remove have one legal linearized tombstone outcome"
else
  fail CAT-CONC-002 "concurrent add and remove have one legal linearized tombstone outcome"
fi

expected="$work/expected"
printf '%s\n' \
  CAT-NAME-001 CAT-NAME-002 CAT-OCI-001 CAT-OCI-002 \
  CAT-ADD-001 CAT-ADD-002 CAT-ADD-003 CAT-ADD-004 CAT-NS-001 \
  CAT-CAS-001 CAT-CAS-002 CAT-CAS-003 CAT-CAS-004 \
  CAT-READ-001 CAT-READ-002 CAT-NOEF-001 CAT-CONC-001 CAT-CONC-002 > "$expected"
if ! cmp -s "$expected" "$observed"; then
  printf 'INFRA catalog public assertion identity drift\n' >&2
  infrastructure=1
fi
finish
