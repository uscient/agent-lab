#!/usr/bin/env bash
set -u -o pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
subcases=(
  "$repo_root/tests/experiment/zip-intake-cases.sh"
)
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

expected="$work/expected"
observed="$work/observed"
printf '%s\n' \
  ZIP-001 ZIP-PATH-001 ZIP-COUNT-001 ZIP-TYPE-001 ZIP-META-001 \
  ZIP-FLAG-001 ZIP-METHOD-001 ZIP-ZIP64-001 ZIP-HEADER-001 ZIP-CRC-001 \
  ZIP-LENGTH-001 ZIP-SIZE-001 ZIP-BOMB-001 ZIP-TRUNC-001 ZIP-TRAIL-001 \
  ZIP-SIZE-002 ZIP-READ-001 ZIP-READ-002 ZIP-DECODE-001 ZIP-TIMEOUT-001 \
  ZIP-OUTPUT-001 ZIP-NOEF-001 ZIP-AUTH-001 ZIP-INSTALL-001 ZIP-RETRY-001 > "$expected"
: > "$observed"

infrastructure=0
failures=0
for index in "${!subcases[@]}"; do
  subcase="${subcases[$index]}"
  output="$work/subcase-$index.out"
  if [ ! -f "$subcase" ]; then
    infrastructure=1
    continue
  fi
  if bash "$subcase" > "$output" 2>&1; then
    rc=0
  else
    rc=$?
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
      [ "$reported_failures" -eq 0 ] || infrastructure=1
      ;;
    1)
      [ "$reported_failures" -ne 0 ] || infrastructure=1
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
printf 'EXPERIMENT SOURCE ADAPTERS PASS\n'
