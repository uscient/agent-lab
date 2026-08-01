#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
coord_source="$repo_root/scripts/dev/coord"
full_expected_assertions=54
assertions=0
failures=0

work=""
if ! work="$(mktemp -d)"; then
  printf 'INFRA coord contract cannot create temporary state\n' >&2
  printf 'SUMMARY assertions=0 expected=%d failures=0 infra=1\n' \
    "$full_expected_assertions"
  exit 125
fi
# Invoked indirectly by the EXIT trap.
# shellcheck disable=SC2317
cleanup() {
  find "$work" -depth -delete >/dev/null 2>&1 || true
}
trap cleanup EXIT

infra_fail() {
  local rc="$1"
  local line="$2"
  trap - ERR
  printf 'INFRA coord contract setup failed rc=%d line=%s\n' "$rc" "$line" >&2
  printf 'SUMMARY assertions=%d expected=%d failures=%d infra=1\n' \
    "$assertions" "$full_expected_assertions" "$failures"
  exit 125
}
trap 'infra_fail "$?" "$LINENO"' ERR

pass() {
  assertions=$((assertions + 1))
  printf 'PASS %s\n' "$1"
}

fail() {
  assertions=$((assertions + 1))
  failures=$((failures + 1))
  printf 'FAIL %s\n' "$1"
}

finish() {
  local expected="$1"
  if ((assertions != expected)); then
    failures=$((failures + 1))
    printf 'FAIL assertion-count expected=%d actual=%d\n' \
      "$expected" "$assertions"
  fi
  printf 'SUMMARY assertions=%d expected=%d failures=%d\n' \
    "$assertions" "$expected" "$failures"
  ((failures == 0))
}

if [[ -x "$coord_source" ]]; then
  pass "coord executable exists"
else
  fail "coord executable exists: scripts/dev/coord"
  if finish 1; then
    exit 0
  fi
  exit 1
fi

make_fixture() {
  local destination="$1"

  mkdir -p "$destination/scripts/dev" "$destination/scripts/lib"
  cp "$coord_source" "$destination/scripts/dev/coord"
  cp "$repo_root/scripts/lib/dev-common.sh" "$destination/scripts/lib/dev-common.sh"
  cp "$repo_root/.gitignore" "$destination/.gitignore"
  chmod +x "$destination/scripts/dev/coord"
  printf 'baseline\n' >"$destination/README.md"
  git -C "$destination" init -q
  git -C "$destination" config user.name "Coord Contract"
  git -C "$destination" config user.email "coord-contract@example.invalid"
  git -C "$destination" add .
  git -C "$destination" commit -qm "fixture baseline"
}

run_coord() {
  local fixture="$1"
  local state_root="$2"
  shift 2
  (
    cd "$fixture"
    AGENT_LAB_COORD_ROOT="$state_root" ./scripts/dev/coord "$@"
  )
}

run_coord_default() {
  local fixture="$1"
  shift
  (
    cd "$fixture"
    env -u AGENT_LAB_COORD_ROOT ./scripts/dev/coord "$@"
  )
}

capture_rc=0
capture_output=""
capture_coord() {
  capture_rc=0
  capture_output="$(run_coord "$@" 2>&1)" || capture_rc=$?
}

expect_success() {
  local name="$1"
  shift
  capture_coord "$@"
  if ((capture_rc == 0)); then
    pass "$name"
  else
    printf '%s\n' "$capture_output" >&2
    fail "$name"
  fi
}

expect_failure() {
  local name="$1"
  shift
  capture_coord "$@"
  if ((capture_rc == 1)); then
    pass "$name"
  else
    printf '%s\n' "$capture_output" >&2
    fail "$name"
  fi
}

fixture="$work/main/repo"
state_root="$work/main/state"
mkdir -p "$(dirname "$fixture")"
make_fixture "$fixture"

expect_success "init records a coordinator" \
  "$fixture" "$state_root" init coordinator

if [[ -e "$state_root" && ! -e "$fixture/.cache/dev/coord" ]]; then
  pass "override keeps coordination state outside the checkout"
else
  fail "override keeps coordination state outside the checkout"
fi

expect_failure "a second init cannot replace an active session" \
  "$fixture" "$state_root" init replacement

expect_success "a writer may claim multiple paths" \
  "$fixture" "$state_root" claim alice writer-main \
  --write docs/alpha docs/beta
expect_failure "the second claimed path also excludes another writer" \
  "$fixture" "$state_root" claim bob equal-conflict --write docs/beta
expect_failure "a descendant write path conflicts with its ancestor" \
  "$fixture" "$state_root" claim bob descendant-conflict \
  --write docs/alpha/child
expect_failure "an ancestor write path conflicts with its descendant" \
  "$fixture" "$state_root" claim bob ancestor-conflict --write docs
expect_success "a lexical sibling path does not conflict" \
  "$fixture" "$state_root" claim bob z-sibling --write docs/alphabet
expect_success "a read-only claim may overlap an active writer" \
  "$fixture" "$state_root" claim carol m-reader --read-only
expect_failure "task identifiers are unique within a session" \
  "$fixture" "$state_root" claim carol writer-main --read-only

summary="$work/main/summary.txt"
marker="$work/main/summary-was-executed"
summary_line="literal shell text: \$(touch $marker)"
printf '%s\n' "$summary_line" >"$summary"

expect_failure "only the claiming actor may hand off a task" \
  "$fixture" "$state_root" handoff intruder writer-main "done" "$summary"
expect_failure "handoff status is limited to done or blocked" \
  "$fixture" "$state_root" handoff alice writer-main complete "$summary"
expect_failure "handoff rejects a missing summary file" \
  "$fixture" "$state_root" handoff alice writer-main "done" "$work/missing-summary"

capture_coord "$fixture" "$state_root" \
  handoff alice writer-main "done" "$summary"
printf 'source changed after handoff\n' >"$summary"
if ((capture_rc == 0)) && [[ ! -e "$marker" ]] && \
  grep -rFq -- "$summary_line" "$state_root"; then
  pass "handoff retains summary bytes as inert data"
else
  fail "handoff retains summary bytes as inert data"
fi

expect_failure "a done handoff retains its write claim" \
  "$fixture" "$state_root" claim dave done-still-owned --write docs/alpha
expect_failure "only the named coordinator may resolve a task" \
  "$fixture" "$state_root" resolve replacement writer-main
expect_success "the coordinator may resolve a handed-off task" \
  "$fixture" "$state_root" resolve coordinator writer-main
expect_success "resolve releases the task's write paths" \
  "$fixture" "$state_root" claim dave writer-reuse --write docs/alpha
expect_success "an actor may hand off a blocked task" \
  "$fixture" "$state_root" handoff dave writer-reuse blocked "$summary"
expect_failure "a blocked handoff retains its write claim" \
  "$fixture" "$state_root" claim erin blocked-still-owned --write docs/alpha
expect_success "resolve releases a blocked task's write paths" \
  "$fixture" "$state_root" resolve coordinator writer-reuse

expect_failure "write paths cannot traverse out of the repository" \
  "$fixture" "$state_root" claim mallory traversal --write docs/../escape
expect_failure "write paths must be repository-relative" \
  "$fixture" "$state_root" claim mallory absolute --write "$work/absolute"
bad_path=$'docs/control\ncharacter'
expect_failure "control characters are rejected" \
  "$fixture" "$state_root" claim mallory control-character --write "$bad_path"

capture_coord "$fixture" "$state_root" \
  claim ../actor invalid-actor-traversal --read-only
actor_traversal_rc=$capture_rc
bad_actor=$'bad\nactor'
capture_coord "$fixture" "$state_root" \
  claim "$bad_actor" invalid-actor-control --read-only
actor_control_rc=$capture_rc
if ((actor_traversal_rc == 1 && actor_control_rc == 1)); then
  pass "actor labels reject traversal and control characters"
else
  fail "actor labels reject traversal and control characters"
fi

capture_coord "$fixture" "$state_root" \
  claim mallory ../invalid-task --read-only
task_traversal_rc=$capture_rc
bad_task=$'bad\ntask'
capture_coord "$fixture" "$state_root" \
  claim mallory "$bad_task" --read-only
task_control_rc=$capture_rc
if ((task_traversal_rc == 1 && task_control_rc == 1)); then
  pass "task labels reject traversal and control characters"
else
  fail "task labels reject traversal and control characters"
fi

capture_coord "$fixture" "$work/invalid-coordinator/traversal" \
  init ../coordinator
coordinator_traversal_rc=$capture_rc
bad_coordinator=$'bad\ncoordinator'
capture_coord "$fixture" "$work/invalid-coordinator/control" \
  init "$bad_coordinator"
coordinator_control_rc=$capture_rc
if ((coordinator_traversal_rc == 1 && coordinator_control_rc == 1)); then
  pass "coordinator labels reject traversal and control characters"
else
  fail "coordinator labels reject traversal and control characters"
fi

expect_success "actor names are cooperative labels, not enrolled identities" \
  "$fixture" "$state_root" claim unregistered-agent a-cooperative --read-only

capture_coord "$fixture" "$state_root" status
status_one="$capture_output"
status_one_rc=$capture_rc
capture_coord "$fixture" "$state_root" status
status_two="$capture_output"
status_two_rc=$capture_rc
if ((status_one_rc == 0 && status_two_rc == 0)) && \
  [[ "$status_one" == "$status_two" ]]; then
  pass "status is byte-for-byte deterministic"
else
  fail "status is byte-for-byte deterministic"
fi

status_task_order="$(
  printf '%s\n' "$status_one" |
    grep -oE 'a-cooperative|m-reader|z-sibling' |
    paste -sd ' ' - || true
)"
if [[ "$status_task_order" == "a-cooperative m-reader z-sibling" ]]; then
  pass "status sorts tasks by task identifier"
else
  fail "status sorts tasks by task identifier"
fi

expect_failure "close rejects unresolved tasks" \
  "$fixture" "$state_root" close coordinator
expect_success "sibling task may hand off" \
  "$fixture" "$state_root" handoff bob z-sibling "done" "$summary"
expect_success "coordinator resolves the sibling task" \
  "$fixture" "$state_root" resolve coordinator z-sibling
expect_success "read-only task may hand off" \
  "$fixture" "$state_root" handoff carol m-reader "done" "$summary"
expect_success "coordinator resolves the read-only task" \
  "$fixture" "$state_root" resolve coordinator m-reader
expect_success "cooperative actor may hand off" \
  "$fixture" "$state_root" handoff unregistered-agent a-cooperative "done" "$summary"
expect_success "coordinator resolves the cooperative task" \
  "$fixture" "$state_root" resolve coordinator a-cooperative
expect_success "coordinator closes a fully resolved session" \
  "$fixture" "$state_root" close coordinator
expect_success "a closed session permits a new init" \
  "$fixture" "$state_root" init successor

symlink_fixture="$work/symlink/repo"
symlink_target="$work/symlink/outside"
symlink_root="$work/symlink/state-link"
mkdir -p "$(dirname "$symlink_fixture")" "$symlink_target"
make_fixture "$symlink_fixture"
ln -s "$symlink_target" "$symlink_root"
capture_coord "$symlink_fixture" "$symlink_root" init coordinator
if ((capture_rc == 1)) && \
  [[ -z "$(find "$symlink_target" -mindepth 1 -print -quit)" ]]; then
  pass "a symlink coordination root is rejected without following it"
else
  fail "a symlink coordination root is rejected without following it"
fi

swapped_fixture="$work/swapped-symlink/repo"
swapped_target="$work/swapped-symlink/outside"
swapped_root="$work/swapped-symlink/state"
mkdir -p "$(dirname "$swapped_fixture")" "$swapped_target"
make_fixture "$swapped_fixture"
run_coord "$swapped_fixture" "$swapped_root" init coordinator >/dev/null
swapped_root_existed=0
[[ -e "$swapped_root" ]] && swapped_root_existed=1
find "$swapped_root" -depth -delete
ln -s "$swapped_target" "$swapped_root"
capture_coord "$swapped_fixture" "$swapped_root" \
  claim actor swapped-state --read-only
if ((swapped_root_existed == 1 && capture_rc == 1)) && \
  [[ -z "$(find "$swapped_target" -mindepth 1 -print -quit)" ]]; then
  pass "a post-init symlink swap is rejected without following it"
else
  fail "a post-init symlink swap is rejected without following it"
fi

ancestor_fixture="$work/ancestor-symlink/repo"
ancestor_link="$work/ancestor-symlink/repo-link"
ancestor_state="$ancestor_link/coord-state"
mkdir -p "$(dirname "$ancestor_fixture")"
make_fixture "$ancestor_fixture"
ln -s "$ancestor_fixture" "$ancestor_link"
capture_coord "$ancestor_fixture" "$ancestor_state" init coordinator
if ((capture_rc == 1)) && [[ ! -e "$ancestor_fixture/coord-state" ]]; then
  pass "a symlink ancestor cannot redirect state into a tracked checkout path"
else
  fail "a symlink ancestor cannot redirect state into a tracked checkout path"
fi

pin_case() {
  local drift="$1"
  local operation="$2"
  local case_root="$work/pin-$drift-$operation"
  local pin_fixture="$case_root/repo"
  local pin_state="$case_root/state"
  local pin_summary="$case_root/summary.txt"

  mkdir -p "$case_root" || return 125
  make_fixture "$pin_fixture" || return 125
  printf 'pinning handoff\n' >"$pin_summary" || return 125
  run_coord "$pin_fixture" "$pin_state" init coordinator \
    >/dev/null 2>&1 || return 125

  case "$operation" in
    handoff | resolve)
      run_coord "$pin_fixture" "$pin_state" \
        claim actor pin-task --read-only >/dev/null 2>&1 || return 125
      ;;
  esac
  if [[ "$operation" == "resolve" ]]; then
    run_coord "$pin_fixture" "$pin_state" \
      handoff actor pin-task "done" "$pin_summary" \
      >/dev/null 2>&1 || return 125
  fi

  case "$drift" in
    branch)
      git -C "$pin_fixture" switch -q -c drifted-branch || return 125
      ;;
    head)
      printf 'move head\n' >"$pin_fixture/new-head.txt" || return 125
      git -C "$pin_fixture" add new-head.txt || return 125
      git -C "$pin_fixture" commit -qm "move fixture head" || return 125
      ;;
    *)
      return 125
      ;;
  esac

  case "$operation" in
    claim)
      capture_coord "$pin_fixture" "$pin_state" \
        claim actor pin-claim --read-only
      ;;
    handoff)
      capture_coord "$pin_fixture" "$pin_state" \
        handoff actor pin-task "done" "$pin_summary"
      ;;
    resolve)
      capture_coord "$pin_fixture" "$pin_state" resolve coordinator pin-task
      ;;
    close)
      capture_coord "$pin_fixture" "$pin_state" close coordinator
      ;;
    status)
      capture_coord "$pin_fixture" "$pin_state" status
      ;;
    *)
      return 125
      ;;
  esac

  if ((capture_rc != 1)); then
    printf 'pinning case drift=%s operation=%s rc=%d\n' \
      "$drift" "$operation" "$capture_rc" >&2
    return 1
  fi
}

pinning_rejects_mutations() {
  local drift="$1"
  local operation
  local rc

  for operation in claim handoff resolve close status; do
    if pin_case "$drift" "$operation"; then
      continue
    else
      rc=$?
    fi
    ((rc == 125)) && return 125
    return 1
  done
}

assert_pinning() {
  local name="$1"
  local drift="$2"
  local rc

  if pinning_rejects_mutations "$drift"; then
    pass "$name"
    return
  else
    rc=$?
  fi
  if ((rc == 125)); then
    infra_fail 125 "pin-$drift"
  fi
  fail "$name"
}

assert_pinning "branch drift rejects every session operation" branch
assert_pinning "HEAD drift rejects operations until the coordinator advances it" head

status_lock_fixture="$work/status-lock/repo"
status_lock_state="$work/status-lock/state"
status_lock_result="$work/status-lock/result"
status_lock_output="$work/status-lock/output"
mkdir -p "$(dirname "$status_lock_fixture")"
make_fixture "$status_lock_fixture"
run_coord "$status_lock_fixture" "$status_lock_state" init coordinator >/dev/null
mkdir "$status_lock_state/.lock"
(
  status_rc=0
  run_coord "$status_lock_fixture" "$status_lock_state" status \
    >"$status_lock_output" 2>&1 || status_rc=$?
  printf '%d\n' "$status_rc" >"$status_lock_result"
) &
status_lock_pid=$!
sleep 0.1
status_returned_early=0
[[ -e "$status_lock_result" ]] && status_returned_early=1
rmdir "$status_lock_state/.lock"
wait "$status_lock_pid" || true
if ((status_returned_early == 0)) && [[ "$(<"$status_lock_result")" == 0 ]]; then
  pass "status takes the coordination lock for a consistent snapshot"
else
  fail "status takes the coordination lock for a consistent snapshot"
fi

advance_fixture="$work/advance/repo"
advance_state="$work/advance/state"
advance_summary="$work/advance/summary.txt"
mkdir -p "$(dirname "$advance_fixture")"
make_fixture "$advance_fixture"
printf 'ready to advance\n' >"$advance_summary"
run_coord "$advance_fixture" "$advance_state" init coordinator >/dev/null
run_coord "$advance_fixture" "$advance_state" \
  claim actor advance-task --read-only >/dev/null
run_coord "$advance_fixture" "$advance_state" \
  handoff actor advance-task "done" "$advance_summary" >/dev/null
printf 'advance head\n' >"$advance_fixture/advance.txt"
git -C "$advance_fixture" add advance.txt
git -C "$advance_fixture" commit -qm "move fixture head"
capture_coord "$advance_fixture" "$advance_state" resolve coordinator advance-task
advance_before_rc=$capture_rc
capture_coord "$advance_fixture" "$advance_state" advance coordinator
advance_rc=$capture_rc
capture_coord "$advance_fixture" "$advance_state" resolve coordinator advance-task
advance_resolve_rc=$capture_rc
capture_coord "$advance_fixture" "$advance_state" close coordinator
advance_close_rc=$capture_rc
if ((advance_before_rc == 1 && advance_rc == 0 && \
  advance_resolve_rc == 0 && advance_close_rc == 0)); then
  pass "coordinator can advance the HEAD pin after every task hands off"
else
  fail "coordinator can advance the HEAD pin after every task hands off"
fi

advance_guard_fixture="$work/advance-guard/repo"
advance_guard_state="$work/advance-guard/state"
mkdir -p "$(dirname "$advance_guard_fixture")"
make_fixture "$advance_guard_fixture"
run_coord "$advance_guard_fixture" "$advance_guard_state" init coordinator >/dev/null
run_coord "$advance_guard_fixture" "$advance_guard_state" \
  claim actor active-task --read-only >/dev/null
printf 'advance guard head\n' >"$advance_guard_fixture/advance.txt"
git -C "$advance_guard_fixture" add advance.txt
git -C "$advance_guard_fixture" commit -qm "move fixture head"
expect_failure "coordinator cannot advance while a task lacks a handoff" \
  "$advance_guard_fixture" "$advance_guard_state" advance coordinator

clean_fixture="$work/clean/repo"
clean_state="$work/clean/state"
clean_summary="$work/clean/summary.txt"
mkdir -p "$(dirname "$clean_fixture")"
make_fixture "$clean_fixture"
printf 'complete\n' >"$clean_summary"
before_head="$(git -C "$clean_fixture" rev-parse HEAD)"
before_branch="$(git -C "$clean_fixture" branch --show-current)"
before_refs="$(git -C "$clean_fixture" for-each-ref \
  --format='%(refname) %(objectname)')"
before_status="$(git -C "$clean_fixture" status --porcelain=v1 --untracked-files=all)"
before_index="$(git -C "$clean_fixture" diff --cached --binary)"
clean_flow_rc=0
run_coord "$clean_fixture" "$clean_state" init coordinator >/dev/null 2>&1 && \
  run_coord "$clean_fixture" "$clean_state" claim actor clean-task --read-only \
    >/dev/null 2>&1 && \
  run_coord "$clean_fixture" "$clean_state" \
    handoff actor clean-task "done" "$clean_summary" >/dev/null 2>&1 && \
  run_coord "$clean_fixture" "$clean_state" resolve coordinator clean-task \
    >/dev/null 2>&1 && \
  run_coord "$clean_fixture" "$clean_state" close coordinator >/dev/null 2>&1 || \
  clean_flow_rc=$?
after_head="$(git -C "$clean_fixture" rev-parse HEAD)"
after_branch="$(git -C "$clean_fixture" branch --show-current)"
after_refs="$(git -C "$clean_fixture" for-each-ref \
  --format='%(refname) %(objectname)')"
after_status="$(git -C "$clean_fixture" status --porcelain=v1 --untracked-files=all)"
after_index="$(git -C "$clean_fixture" diff --cached --binary)"
if ((clean_flow_rc == 0)) && [[ "$before_head" == "$after_head" ]] && \
  [[ "$before_branch" == "$after_branch" ]] && \
  [[ "$before_refs" == "$after_refs" ]] && \
  [[ "$before_status" == "$after_status" ]] && \
  [[ "$before_index" == "$after_index" ]]; then
  pass "coord never mutates Git HEAD, branch, index, or worktree"
else
  fail "coord never mutates Git HEAD, branch, index, or worktree"
fi

default_fixture="$work/default/repo"
mkdir -p "$(dirname "$default_fixture")"
make_fixture "$default_fixture"
default_rc=0
run_coord_default "$default_fixture" init coordinator >/dev/null 2>&1 || default_rc=$?
if ((default_rc == 0)) && [[ -e "$default_fixture/.cache/dev/coord" ]] && \
  git -C "$default_fixture" check-ignore -q .cache/dev/coord/probe; then
  pass "default state lives under ignored .cache/dev/coord"
else
  fail "default state lives under ignored .cache/dev/coord"
fi

root_override_fixture="$work/root-override/repo"
mkdir -p "$(dirname "$root_override_fixture")"
make_fixture "$root_override_fixture"
capture_coord "$root_override_fixture" "$root_override_fixture" init coordinator
if ((capture_rc == 1)) && \
  [[ ! -e "$root_override_fixture/current" ]] && \
  [[ ! -e "$root_override_fixture/archive" ]] && \
  [[ ! -e "$root_override_fixture/.lock" ]]; then
  pass "an override cannot place coordination artifacts at the checkout root"
else
  fail "an override cannot place coordination artifacts at the checkout root"
fi

relative_override_fixture="$work/relative-override/repo"
mkdir -p "$(dirname "$relative_override_fixture")"
make_fixture "$relative_override_fixture"
capture_coord "$relative_override_fixture" . init coordinator
if ((capture_rc == 1)) && \
  [[ ! -e "$relative_override_fixture/current" ]] && \
  [[ ! -e "$relative_override_fixture/archive" ]] && \
  [[ ! -e "$relative_override_fixture/.lock" ]]; then
  pass "coordination root overrides must be absolute"
else
  fail "coordination root overrides must be absolute"
fi

tracked_override_fixture="$work/tracked-override/repo"
tracked_override_root="$tracked_override_fixture/coord-state"
mkdir -p "$(dirname "$tracked_override_fixture")"
make_fixture "$tracked_override_fixture"
capture_coord "$tracked_override_fixture" "$tracked_override_root" init coordinator
if ((capture_rc == 1)) && [[ ! -e "$tracked_override_root" ]]; then
  pass "an override cannot create coordination artifacts in tracked checkout paths"
else
  fail "an override cannot create coordination artifacts in tracked checkout paths"
fi

race_fixture="$work/race/repo"
race_state="$work/race/state"
race_results="$work/race/results"
mkdir -p "$(dirname "$race_fixture")" "$race_results"
make_fixture "$race_fixture"
run_coord "$race_fixture" "$race_state" init coordinator >/dev/null
(
  race_rc=0
  run_coord "$race_fixture" "$race_state" \
    claim actor-one race-one --write shared/path >/dev/null 2>&1 || race_rc=$?
  printf '%d\n' "$race_rc" >"$race_results/one"
) &
race_pid_one=$!
(
  race_rc=0
  run_coord "$race_fixture" "$race_state" \
    claim actor-two race-two --write shared/path >/dev/null 2>&1 || race_rc=$?
  printf '%d\n' "$race_rc" >"$race_results/two"
) &
race_pid_two=$!
wait "$race_pid_one" || true
wait "$race_pid_two" || true
race_one_rc="$(<"$race_results/one")"
race_two_rc="$(<"$race_results/two")"
if [[ "$race_one_rc:$race_two_rc" == "0:1" || \
  "$race_one_rc:$race_two_rc" == "1:0" ]]; then
  pass "concurrent equal-path claims admit one writer and reject the other"
else
  fail "concurrent equal-path claims admit one writer and reject the other"
fi

if finish "$full_expected_assertions"; then
  exit 0
fi
exit 1
