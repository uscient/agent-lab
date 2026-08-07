#!/usr/bin/env bash
# G1 contract-growth aggregate registration.
#
# This is the explicit G1 entry point the existing required experiment-contract
# suite calls.  It owns no assertion of its own: it runs each G1 focused suite,
# republishes that suite's assertion lines unchanged, and refuses to report a
# clean result it cannot account for.
#
# Three ways a registration can lie are refused here rather than absorbed:
#
#   * a focused suite that is not run at all, or whose file is missing,
#   * a focused suite whose assertion identities drift from the frozen
#     inventory, in either direction, and
#   * a focused suite that reports failures but exits 0, or exits 0 with no
#     assertions at all.
#
# Every non-assertion line the focused suite prints is forwarded to the
# diagnostic channel with a fixed prefix, so a caller that harvests assertion
# and summary lines can never mistake a diagnostic for a result.
#
# Exit contract: 0 with the final marker when every assertion passes, 1 on
# assertion failure, 125 on setup, harness, or registration uncertainty.
set -u -o pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
repo_root="$(cd -- "$script_dir/../../.." >/dev/null 2>&1 && pwd)"

subcases=(
  "$repo_root/tests/flow/g1-contract-growth/plan-authority/cases.sh"
)

# The frozen G1 assertion inventory, in the frozen emission order.
expected_ids=(
  WF-PLAN-LEGACY-INSPECTABLE
  SEC-PLAN-EXECUTABLE
  REC-PLAN-AUTHORITY-DENIAL
  SEC-PLAN-INLINE-SECRET
  SEC-PLAN-SECRET-QUIET
  WF-PLAN-SECRET-REFERENCE
  SEC-PLAN-SECRET-GRANT
  WF-PLAN-GRANT-NEIGHBOR
  SEC-PLAN-GRANT-UNKNOWN
)
expected_count="${#expected_ids[@]}"
work=""
infrastructure=0
failures=0

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
printf '%s\n' "${expected_ids[@]}" > "$expected" || infrastructure=1
: > "$observed"

for index in "${!subcases[@]}"; do
  subcase="${subcases[$index]}"
  output="$work/subcase-$index.out"
  if [ ! -f "$subcase" ]; then
    printf 'G1 | missing focused suite: %s\n' "$subcase" >&2
    infrastructure=1
    continue
  fi
  if bash "$subcase" > "$output" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  # Assertion lines are republished verbatim; everything else, including the
  # focused suite's own summary and marker, becomes a prefixed diagnostic.
  awk '/^(PASS|FAIL) [A-Z0-9-]+ / {print; next} {printf "G1 | %s\n", $0 > "/dev/stderr"}' \
    "$output"
  awk '/^(PASS|FAIL) [A-Z0-9-]+ / {print $2}' "$output" >> "$observed"
  reported_assertions="$(awk '/^(PASS|FAIL) [A-Z0-9-]+ / {count++} END {print count + 0}' "$output")"
  reported_failures="$(awk '/^FAIL [A-Z0-9-]+ / {count++} END {print count + 0}' "$output")"
  failures=$((failures + reported_failures))
  expected_summary="SUMMARY assertions=$reported_assertions expected=$reported_assertions failures=$reported_failures infra=0"
  matching_summaries="$(grep -Fxc "$expected_summary" "$output" || true)"
  all_summaries="$(grep -c '^SUMMARY ' "$output" || true)"
  if [ "$matching_summaries" -ne 1 ] || [ "$all_summaries" -ne 1 ]; then
    printf 'G1 | focused suite summary is not exactly one accounted line: %s\n' "$subcase" >&2
    infrastructure=1
  fi
  case "$rc" in
    0)
      if [ "$reported_failures" -ne 0 ] || [ "$reported_assertions" -eq 0 ]; then
        printf 'G1 | focused suite reported success it cannot account for: %s\n' "$subcase" >&2
        infrastructure=1
      fi
      ;;
    1)
      if [ "$reported_failures" -eq 0 ]; then
        printf 'G1 | focused suite failed without a named assertion: %s\n' "$subcase" >&2
        infrastructure=1
      fi
      ;;
    *)
      printf 'G1 | focused suite reported uncertainty: %s rc=%s\n' "$subcase" "$rc" >&2
      infrastructure=1
      ;;
  esac
done

assertions="$(wc -l < "$observed")"
if ! cmp -s "$expected" "$observed"; then
  printf 'G1 | assertion identity drift against the frozen inventory\n' >&2
  infrastructure=1
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
printf 'FLOW G1 CONTRACT GROWTH PASS\n'
