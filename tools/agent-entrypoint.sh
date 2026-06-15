#!/usr/bin/env sh
# Pure POSIX sh (runs in whatever shell the agent image ships): no `local`, no bashisms.
# Loads file-based secrets into the environment at runtime, then execs the real command.
#
# `docker inspect` shows Config.Env (image env, compose `environment:`, --env-file) but NOT
# runtime-exported vars. So loading files -> env here keeps secrets out of `docker inspect`
# and out of every tracked/local file. Residual exposure: the values are readable in /proc
# inside the container, i.e. by the agent that already holds the key.
set -eu
SECRETS_DIR="${AGENT_LAB_SECRETS_MOUNT:-/run/agent-secrets}"
if [ -d "$SECRETS_DIR" ]; then
  [ -w "$SECRETS_DIR" ] && printf 'agent-entrypoint: WARN secrets mount is writable; expected read-only\n' >&2
  for f in "$SECRETS_DIR"/*; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    case "$name" in *.env) continue ;; .*) continue ;; esac
    case "$name" in [A-Za-z_][A-Za-z0-9_]*) : ;; *) printf 'agent-entrypoint: skip non-identifier secret file: %s\n' "$name" >&2; continue ;; esac
    val=$(cat "$f"); export "$name=$val"
  done
  for ef in "$SECRETS_DIR"/*.env; do
    [ -f "$ef" ] || continue
    # shellcheck disable=SC1090
    set -a; . "$ef"; set +a
  done
fi
[ "$#" -eq 0 ] && { command -v bash >/dev/null 2>&1 && set -- bash || set -- sh; }
exec "$@"
