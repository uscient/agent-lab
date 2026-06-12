#!/usr/bin/env bash
# agent-lab read-only validation: compose syntax + containment lint. NEVER brings a stack up.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"; cd "$here"
rc=0
if command -v docker >/dev/null 2>&1; then
  for f in compose.yaml compose.egress.yaml; do
    [ -f "$f" ] || continue
    echo ">> docker compose -f $f config"
    if docker compose -f "$f" config >/dev/null 2>&1; then echo "   OK"; else echo "   FAIL: $f" >&2; rc=1; fi
  done
else
  echo ">> docker not available — skipping 'compose config' (validate during implementation)"
fi
echo ">> containment-lint"
"$here/tools/containment-lint.sh" || rc=1
echo "----"; [ "$rc" -eq 0 ] && echo "validate: PASS" || echo "validate: FAIL"
exit "$rc"
