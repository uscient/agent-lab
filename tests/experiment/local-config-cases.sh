#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
work="$(mktemp -d)"
trap 'find "$work" -type f -delete 2>/dev/null || true; find "$work" -type l -delete 2>/dev/null || true; find "$work" -depth -type d -exec rmdir {} + 2>/dev/null || true' EXIT
rc=0
"$repo_root/scripts/agent-lab" --home "$work/home" init > "$work/out" 2> "$work/err" || rc=$?
failures=0
if [ "$rc" -eq 0 ] && [ -f "$work/home/home.json" ] && [ -f "$work/home/config.json" ]; then
  printf 'PASS CFG-001 init creates the explicit private home\n'
else
  printf 'FAIL CFG-001 init creates the explicit private home\n'
  failures=1
fi

before="$(find "$work/home" -printf '%P %m %y\n' | LC_ALL=C sort)"
rerun_rc=0
"$repo_root/scripts/agent-lab" --home "$work/home" init > "$work/rerun.out" 2> "$work/rerun.err" || rerun_rc=$?
after="$(find "$work/home" -printf '%P %m %y\n' | LC_ALL=C sort)"
if [ "$rerun_rc" -eq 0 ] && [ "$before" = "$after" ] && grep -Fxq 'changed:false' "$work/rerun.out"; then
  printf 'PASS CFG-002 exact init retry is idempotent\n'
else
  printf 'FAIL CFG-002 exact init retry is idempotent\n'
  failures=$((failures + 1))
fi

python3 - "$work/home/config.json" <<'PY'
from pathlib import Path
import json
import sys
path = Path(sys.argv[1])
value = json.loads(path.read_text())
value["paths"]["cache"] = "other-cache"
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
PY
drift_rc=0
"$repo_root/scripts/agent-lab" --home "$work/home" config check > "$work/drift.out" 2> "$work/drift.err" || drift_rc=$?
if [ "$drift_rc" -eq 125 ] && [ ! -s "$work/drift.out" ]; then
  printf 'PASS CFG-003 post-init configuration drift is infrastructure uncertainty\n'
else
  printf 'FAIL CFG-003 post-init configuration drift is infrastructure uncertainty\n'
  failures=$((failures + 1))
fi

absent="$work/absent"
absent_rc=0
"$repo_root/scripts/agent-lab" --home "$absent" config check > "$work/absent.out" 2> "$work/absent.err" || absent_rc=$?
if [ "$absent_rc" -eq 1 ] && [ ! -e "$absent" ]; then
  printf 'PASS CFG-004 config check does not initialize an absent home\n'
else
  printf 'FAIL CFG-004 config check does not initialize an absent home\n'
  failures=$((failures + 1))
fi

printf 'SUMMARY assertions=4 expected=4 failures=%s infra=0\n' "$failures"
[ "$failures" -eq 0 ]
