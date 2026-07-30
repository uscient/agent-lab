#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  printf 'Usage: %s SENTINEL LABEL=FILE...\n' "$0" >&2
  exit 2
fi

sentinel="$1"
shift
failures=0
for item in "$@"; do
  label="${item%%=*}"
  path="${item#*=}"
  if [ ! -f "$path" ]; then
    printf 'FAIL missing secret-scan artifact: %s\n' "$label"
    failures=$((failures + 1))
  elif grep -Fq -- "$sentinel" "$path"; then
    printf 'FAIL secret disclosed in channel: %s\n' "$label"
    failures=$((failures + 1))
  else
    printf 'PASS secret absent from channel: %s\n' "$label"
  fi
done

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
