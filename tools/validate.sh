#!/usr/bin/env bash
# agent-lab read-only validation: compose syntax + agent overlays + invariants + containment
# lint + config-authority preflight. NEVER brings a stack up.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$here" || exit 1
rc=0

if command -v docker >/dev/null 2>&1; then
  for f in compose.yaml compose.egress.yaml; do
    [ -f "$f" ] || continue
    echo ">> docker compose -f $f config"
    if docker compose -f "$f" config >/dev/null 2>&1; then echo "   OK"; else echo "   FAIL: $f" >&2; rc=1; fi
  done

  # Agent profile + each HOME overlay must render.
  for overlay in compose.agent.persist.yaml compose.agent.ephemeral.yaml; do
    [ -f "$overlay" ] || continue
    echo ">> docker compose (agent + $overlay) config"
    if docker compose -f compose.yaml -f compose.egress.yaml -f compose.agent.yaml -f "$overlay" \
         --profile core --profile egress --profile agent config --quiet >/dev/null 2>&1; then
      echo "   OK"
    else
      echo "   FAIL: agent + $overlay" >&2; rc=1
    fi
  done

  # §3 agent-service invariants (static; config-only).
  if [ -f tests/agent/invariants.sh ]; then
    echo ">> tests/agent/invariants.sh"
    bash tests/agent/invariants.sh || rc=1
  fi
else
  echo ">> docker not available — skipping compose config + agent invariants"
fi

echo ">> containment-lint"
"$here/tools/containment-lint.sh" || rc=1

# Config-authority preflight regression (Docker-free).
if [ -f tests/agent/config-guard.sh ]; then
  echo ">> tests/agent/config-guard.sh"
  bash tests/agent/config-guard.sh || rc=1
fi

echo "----"; [ "$rc" -eq 0 ] && echo "validate: PASS" || echo "validate: FAIL"
exit "$rc"
