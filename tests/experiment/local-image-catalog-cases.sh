#!/usr/bin/env bash
set -u -o pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
work="$(mktemp -d)"
trap 'find "$work" -type f -delete 2>/dev/null || true; find "$work" -type l -delete 2>/dev/null || true; find "$work" -depth -type d -exec rmdir {} + 2>/dev/null || true' EXIT

subcases=(
  "$repo_root/tests/image/catalog-cases.sh"
  "$repo_root/tests/image/catalog-state-cases.py"
  "$repo_root/tests/experiment/catalog-resolution-cases.sh"
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
  CAT-BOUND-001 CAT-BOUND-002 CAT-CRASH-001 CAT-CRASH-002 \
  CAT-CRASH-003 CAT-PLAT-001 \
  RES-ENTRY-001 RES-SNAP-001 RES-SNAP-002 RES-ENTRY-002 RES-ENTRY-003 \
  RES-ISOLATE-001 RES-STATE-001 RES-STATE-002 RES-STATE-003 RES-INPUT-001 \
  RES-SNAP-003 RES-AUTH-001 RES-INSTALL-001 RES-NOEF-001 > "$expected"
expected_count="$(wc -l < "$expected")"
infrastructure=0

for index in "${!subcases[@]}"; do
  subcase="${subcases[$index]}"
  output="$work/subcase-$index.out"
  if [ ! -f "$subcase" ]; then
    printf 'INFRA required catalog subcase is missing: %s\n' "$subcase" >&2
    infrastructure=1
    continue
  fi
  case "$subcase" in
    *.py)
      python3 -I "$subcase" > "$output" 2>&1
      rc=$?
      ;;
    *)
      bash "$subcase" > "$output" 2>&1
      rc=$?
      ;;
  esac
  cat "$output"
  awk '/^(PASS|FAIL) [A-Z0-9-]+ / {print $2}' "$output" >> "$observed"
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
    printf 'INFRA catalog subcase returned %s: %s\n' "$rc" "$subcase" >&2
    infrastructure=1
  fi
done

assertions="$(wc -l < "$observed")"
failures="$(awk '/^FAIL [A-Z0-9-]+ / {count++} END {print count + 0}' "$work"/subcase-*.out 2>/dev/null)"
if ! cmp -s "$expected" "$observed"; then
  printf 'INFRA catalog aggregate assertion identity drift\n' >&2
  diff -u "$expected" "$observed" >&2 || true
  infrastructure=1
fi

printf 'SUMMARY assertions=%s expected=%s failures=%s infra=%s\n' \
  "$assertions" "$expected_count" "$failures" "$infrastructure"
if [ "$infrastructure" -ne 0 ]; then
  exit 125
fi
if [ "$failures" -ne 0 ]; then
  exit 1
fi
printf 'EXPERIMENT LOCAL IMAGE CATALOG PASS\n'
