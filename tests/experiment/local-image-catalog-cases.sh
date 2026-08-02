#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
work="$(mktemp -d)"
trap 'find "$work" -type f -delete 2>/dev/null || true; find "$work" -type l -delete 2>/dev/null || true; find "$work" -depth -type d -exec rmdir {} + 2>/dev/null || true' EXIT
home="$work/home"
agent_lab="$repo_root/scripts/agent-lab"
"$agent_lab" --home "$home" init >/dev/null
subject="registry.example/operator/worker@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
other="registry.example/operator/other@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
failures=0
capture() { RC=0; "$@" > "$work/out" 2> "$work/err" || RC=$?; }
pass() { printf 'PASS %s %s\n' "$1" "$2"; }
fail() { printf 'FAIL %s %s\n' "$1" "$2"; failures=$((failures + 1)); }

capture "$agent_lab" --home "$home" image add vendor.worker "$subject"
if [ "$RC" -eq 0 ] && jq -e '.changed == true and .generation == 1 and (.entryDigest | startswith("sha256:"))' "$work/out" >/dev/null 2>&1; then
  pass CAT-001 "first add publishes a generation-one digest binding"
  entry="$(jq -r '.entryDigest' "$work/out")"
else
  fail CAT-001 "first add publishes a generation-one digest binding"
  entry="sha256:$(printf '0%.0s' {1..64})"
fi

capture "$agent_lab" --home "$home" image add vendor.worker "$subject"
if [ "$RC" -eq 0 ] && jq -e --arg entry "$entry" '.changed == false and .entryDigest == $entry' "$work/out" >/dev/null 2>&1; then
  pass CAT-002 "same-subject add is idempotent"
else
  fail CAT-002 "same-subject add is idempotent"
fi

capture "$agent_lab" --home "$home" image add vendor.worker "$other"
if [ "$RC" -eq 1 ] && [ ! -s "$work/out" ]; then
  pass CAT-003 "different-subject add never overwrites"
else
  fail CAT-003 "different-subject add never overwrites"
fi

capture "$agent_lab" --home "$home" image remove vendor.worker --expect "$entry"
if [ "$RC" -eq 0 ] && jq -e '.changed == true and .generation == 2 and .state == "removed"' "$work/out" >/dev/null 2>&1; then
  pass CAT-004 "exact CAS removal publishes a generation-two tombstone"
else
  fail CAT-004 "exact CAS removal publishes a generation-two tombstone"
fi

capture "$agent_lab" --home "$home" image add agent-lab.worker "$subject"
if [ "$RC" -eq 1 ] && [ ! -s "$work/out" ]; then
  pass CAT-005 "release-owned names cannot be claimed locally"
else
  fail CAT-005 "release-owned names cannot be claimed locally"
fi

capture "$agent_lab" --home "$home" image list --all
if [ "$RC" -eq 0 ] && jq -e '.[0].name == "vendor.worker" and .[0].state == "removed"' "$work/out" >/dev/null 2>&1; then
  pass CAT-006 "list all reports the immutable tombstone"
else
  fail CAT-006 "list all reports the immutable tombstone"
fi

printf 'SUMMARY assertions=6 expected=6 failures=%s infra=0\n' "$failures"
[ "$failures" -eq 0 ]
