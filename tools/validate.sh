#!/usr/bin/env bash
# agent-lab read-only validation: compose syntax + agent overlays + invariants + containment
# lint + config-authority preflight. NEVER brings a stack up.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$here" || exit 1
rc=0
strict=0

case "${1:-}" in
  "") ;;
  --strict) strict=1 ;;
  *) echo "Usage: $0 [--strict]" >&2; exit 2 ;;
esac

if [ "$strict" -eq 1 ]; then
  required_inputs=(
    compose.yaml
    compose.egress.yaml
    compose.agent.yaml
    compose.agent.persist.yaml
    compose.agent.ephemeral.yaml
    compose.serena.yaml
    .serena/project.yml
    tests/agent/invariants.sh
    tests/dev/fast-suite-isolation-cases.sh
  )
  missing_inputs=0
  for input in "${required_inputs[@]}"; do
    if [ ! -f "$input" ]; then
      echo "INFRA required validation input is missing: $input" >&2
      missing_inputs=1
    fi
  done

  if [ "$missing_inputs" -ne 0 ]; then
    exit 125
  fi

  if ! command -v docker >/dev/null 2>&1; then
    echo "INFRA docker is required for strict validation" >&2
    exit 125
  fi
  if ! docker compose version >/dev/null 2>&1; then
    echo "INFRA Docker Compose v2 is required for strict validation" >&2
    exit 125
  fi
fi

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

  if [ -f compose.serena.yaml ]; then
    echo ">> docker compose (Serena development helper) config"
    if AGENT_LAB_SERENA_IMAGE="agent-lab/serena:validation" \
         AGENT_LAB_SERENA_PROJECT_DIR="$here" \
         AGENT_LAB_SERENA_GIT_MASK_SOURCE="$here/.git" \
         AGENT_LAB_SERENA_CACHE_DIR="$here/.serena/cache" \
         AGENT_LAB_SERENA_UID="$(id -u)" \
         AGENT_LAB_SERENA_GID="$(id -g)" \
         docker compose \
           --env-file /dev/null \
           -f compose.serena.yaml \
           --profile serena \
           config --quiet >/dev/null 2>&1; then
      echo "   OK"
    else
      echo "   FAIL: Serena development helper" >&2
      rc=1
    fi
  fi

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

if [ "$strict" -eq 1 ]; then
  echo ">> tests/dev/fast-suite-isolation-cases.sh"
  isolation_rc=0
  bash tests/dev/fast-suite-isolation-cases.sh || isolation_rc=$?
  if [ "$isolation_rc" -eq 125 ]; then
    [ "$rc" -ne 0 ] || rc=125
  elif [ "$isolation_rc" -ne 0 ]; then
    rc=1
  fi
fi

echo "----"; [ "$rc" -eq 0 ] && echo "validate: PASS" || echo "validate: FAIL"
exit "$rc"
