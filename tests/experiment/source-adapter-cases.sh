#!/usr/bin/env bash
set -u -o pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
subcases=(
  "$repo_root/tests/experiment/zip-intake-cases.sh"
  "$repo_root/tests/experiment/zip-mutation-cases.py"
  "$repo_root/tests/experiment/git-intake-cases.sh"
  "$repo_root/tests/experiment/git-mutation-cases.py"
)
expected_count=82
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
  ZIP-001 ZIP-COMPAT-001 ZIP-USAGE-001 ZIP-PATH-001 ZIP-COUNT-001 ZIP-TYPE-001 ZIP-META-001 \
  ZIP-FLAG-001 ZIP-METHOD-001 ZIP-ZIP64-001 ZIP-HEADER-001 ZIP-CRC-001 \
  ZIP-LENGTH-001 ZIP-SIZE-001 ZIP-BOMB-001 ZIP-TRUNC-001 ZIP-TRAIL-001 \
  ZIP-SIZE-002 ZIP-READ-001 ZIP-READ-002 ZIP-DECODE-001 ZIP-DECODE-003 ZIP-DECODE-002 ZIP-TIMEOUT-001 \
  ZIP-OUTPUT-001 ZIP-NOEF-001 ZIP-AUTH-001 ZIP-INSTALL-001 ZIP-RETRY-001 \
  ZIP-DENY-001 ZIP-PLAT-001 ZIP-NOEF-002 ZIP-RUNTIME-001 \
  M-ZIP-COUNT-001 M-ZIP-NAME-001 M-ZIP-TYPE-001 M-ZIP-FLAG-001 \
  M-ZIP-METHOD-001 M-ZIP-SIZE-001 M-ZIP-BOMB-001 M-ZIP-CRC-001 M-ZIP-HEADER-001 \
  M-ZIP-EXTRACT-001 M-ZIP-IDENTITY-001 M-ZIP-AUTH-001 \
  GIT-CLI-001 GIT-USAGE-001 GIT-URL-001 GIT-OID-001 GIT-PLAT-001 \
  GIT-FIXTURE-001 GIT-PIN-001 GIT-COMMIT-001 GIT-ROOT-001 GIT-TYPE-001 \
  GIT-BLOB-001 GIT-DRIFT-001 GIT-AUTHORITY-001 GIT-CREDENTIAL-001 \
  GIT-REDIRECT-001 GIT-CONTENT-001 GIT-TIMEOUT-001 GIT-OUTPUT-001 \
  GIT-ACQUIRE-001 GIT-PGROUP-001 GIT-CLEANUP-001 GIT-TAXONOMY-001 \
  GIT-CHECK-001 GIT-AUTH-001 GIT-DENY-001 GIT-INSTALL-001 GIT-IDENTITY-001 \
  GIT-RETRY-001 GIT-ADAPTER-001 GIT-NOEF-001 GIT-RUNTIME-001 GIT-DIAG-001 \
  M-GIT-AUTHORITY-001 M-GIT-REF-001 M-GIT-BOUND-001 M-GIT-IDENTITY-001 \
  M-GIT-DOWNSTREAM-001 > "$expected"
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
