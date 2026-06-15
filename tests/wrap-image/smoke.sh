#!/usr/bin/env bash
set -euo pipefail

# Smoke test for scripts/wrap-image: wrap a tiny public image, then confirm the wrapped image
# loads a file-based secret into the environment and execs the command we pass it.
# Requires a Docker daemon and the ability to pull the base image.
#   bash tests/wrap-image/smoke.sh [BASE_IMAGE]

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"

base="${1:-busybox:1.36}"
wrapped="agent-lab/wrap-smoke:test"

"${repo_root}/scripts/wrap-image" "$base" "$wrapped"

secrets_tmp="$(mktemp -d)"
trap 'rm -rf "$secrets_tmp"' EXIT
printf 'bar' > "${secrets_tmp}/FOO"

# The wrapper's ENTRYPOINT is agent-entrypoint; the trailing argv overrides CMD and becomes
# "$@" that the entrypoint execs after loading secrets.
out="$(docker run --rm \
  -e AGENT_LAB_SECRETS_MOUNT=/run/agent-secrets \
  -v "${secrets_tmp}:/run/agent-secrets:ro" \
  "$wrapped" sh -c 'printf "FOO=%s\n" "${FOO:-<unset>}"')"

printf '%s\n' "$out"
case "$out" in
  *"FOO=bar"*) printf 'PASS wrap-image loads the secret into env and execs the command\n' ;;
  *)           printf 'FAIL expected FOO=bar in wrapped-image output\n' >&2; exit 1 ;;
esac
