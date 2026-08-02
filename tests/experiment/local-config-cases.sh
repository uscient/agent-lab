#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
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
  printf 'SUMMARY assertions=0 expected=5 failures=0 infra=1\n'
  exit 125
fi
trap 'cleanup_work >/dev/null 2>&1 || true' EXIT
rc=0
"$repo_root/scripts/agent-lab" --home "$work/home" init > "$work/out" 2> "$work/err" || rc=$?
failures=0
lock_receipt_ok=false
if python3 - "$work/home" <<'PY'
from pathlib import Path
import json
import os
import stat
import sys

home = Path(sys.argv[1])
receipt = json.loads((home / "home.json").read_bytes())
locks = receipt.get("locks")
expected = {
    "imageCatalog": (
        "state/locks/image-catalog.lock",
        "agent-lab.image-catalog-lock/v0alpha1",
    ),
    "experiments": (
        "state/locks/experiments.lock",
        "agent-lab.experiments-lock/v0alpha1",
    ),
}
if not isinstance(locks, dict) or set(locks) != set(expected):
    raise SystemExit(1)
for key, (relative, schema) in expected.items():
    record = locks.get(key)
    path = home / relative
    metadata = path.lstat()
    if (
        not isinstance(record, dict)
        or set(record) != {"device", "inode", "path", "schema"}
        or record != {
            "device": metadata.st_dev,
            "inode": metadata.st_ino,
            "path": relative,
            "schema": schema,
        }
        or not stat.S_ISREG(metadata.st_mode)
        or stat.S_IMODE(metadata.st_mode) != 0o600
        or metadata.st_nlink != 1
        or path.read_bytes() != (schema + "\n").encode("ascii")
    ):
        raise SystemExit(1)
PY
then
  lock_receipt_ok=true
fi
if [ "$rc" -eq 0 ] && [ -f "$work/home/home.json" ] && [ -f "$work/home/config.json" ] && $lock_receipt_ok; then
  printf 'PASS CFG-001 init creates the explicit private home and bound locks\n'
else
  printf 'FAIL CFG-001 init creates the explicit private home and bound locks\n'
  failures=1
fi

before="$(find "$work/home" -printf '%P %m %y\n' | LC_ALL=C sort)"
rerun_rc=0
"$repo_root/scripts/agent-lab" --home "$work/home" init > "$work/rerun.out" 2> "$work/rerun.err" || rerun_rc=$?
after="$(find "$work/home" -printf '%P %m %y\n' | LC_ALL=C sort)"
printf 'initialized\n' >> "$work/home/state/locks/image-catalog.lock"
initialized_rc=0
"$repo_root/scripts/agent-lab" --home "$work/home" config check > "$work/initialized.out" 2> "$work/initialized.err" || initialized_rc=$?
mv "$work/home/state/locks/experiments.lock" "$work/replaced-experiments.lock"
printf 'agent-lab.experiments-lock/v0alpha1\n' > "$work/home/state/locks/experiments.lock"
chmod 600 "$work/home/state/locks/experiments.lock"
replacement_check_rc=0
"$repo_root/scripts/agent-lab" --home "$work/home" config check > "$work/replacement-check.out" 2> "$work/replacement-check.err" || replacement_check_rc=$?
replacement_init_rc=0
"$repo_root/scripts/agent-lab" --home "$work/home" init > "$work/replacement-init.out" 2> "$work/replacement-init.err" || replacement_init_rc=$?
fifo_home="$work/fifo-home"
"$repo_root/scripts/agent-lab" --home "$fifo_home" init > "$work/fifo-init.out" 2> "$work/fifo-init.err"
mv "$fifo_home/state/locks/experiments.lock" "$work/fifo-experiments.lock"
mkfifo -m 600 "$fifo_home/state/locks/experiments.lock"
fifo_check_rc=0
timeout --signal=TERM --kill-after=1s 2s \
  "$repo_root/scripts/agent-lab" --home "$fifo_home" config check \
  > "$work/fifo-check.out" 2> "$work/fifo-check.err" || fifo_check_rc=$?
unlink "$fifo_home/state/locks/experiments.lock"
if [ "$rerun_rc" -eq 0 ] && [ "$before" = "$after" ] && grep -Fxq 'changed:false' "$work/rerun.out" &&
   [ "$initialized_rc" -eq 0 ] && [ "$replacement_check_rc" -eq 125 ] && [ "$replacement_init_rc" -eq 125 ] &&
   [ "$fifo_check_rc" -eq 125 ]; then
  printf 'PASS CFG-002 exact init retry and bound-lock verification are fail-closed\n'
else
  printf 'FAIL CFG-002 exact init retry and bound-lock verification are fail-closed\n'
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

tool_home="$work/tool-home"
"$repo_root/scripts/agent-lab" --home "$tool_home" init >/dev/null
cp -a "$repo_root/.cache/dev/tools/cue/." "$tool_home/cache/tools/cue/"
cp -a "$repo_root/.cache/dev/tools/cedar/." "$tool_home/cache/tools/cedar/"
tools_rc=0
"$repo_root/scripts/agent-lab" --home "$tool_home" tools provision > "$work/tools.out" 2> "$work/tools.err" || tools_rc=$?
if [ "$tools_rc" -eq 0 ] && grep -Fxq 'tools:ready' "$work/tools.out"; then
  printf 'PASS TOOL-001 explicit provisioning verifies the pinned user tools\n'
else
  printf 'FAIL TOOL-001 explicit provisioning verifies the pinned user tools\n'
  failures=$((failures + 1))
fi

infrastructure=0
if ! cleanup_work; then
  infrastructure=1
fi
trap - EXIT
printf 'SUMMARY assertions=5 expected=5 failures=%s infra=%s\n' "$failures" "$infrastructure"
if [ "$infrastructure" -ne 0 ]; then
  exit 125
fi
[ "$failures" -eq 0 ]
