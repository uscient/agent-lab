#!/usr/bin/env sh
# Pure POSIX sh (runs in whatever shell the agent image ships): no `local`, no bashisms.
# Loads file-based secrets into the environment at runtime, then execs the real command.
#
# `docker inspect` shows Config.Env (image env, compose `environment:`, --env-file) but NOT
# runtime-exported vars. So loading files -> env here keeps secrets out of `docker inspect`
# and out of every tracked/local file. Residual exposure: the values are readable in /proc
# inside the container, i.e. by the agent that already holds the key.
#
# One-file-per-secret values are read verbatim. `*.env` files are parsed strictly as
# KEY=VALUE and are NEVER sourced (sourcing would execute attacker-controlled shell).
set -eu
SECRETS_DIR="${AGENT_LAB_SECRETS_MOUNT:-/run/agent-secrets}"
if [ -d "$SECRETS_DIR" ]; then
  [ -w "$SECRETS_DIR" ] && printf 'agent-entrypoint: WARN secrets mount is writable; expected read-only\n' >&2
  for f in "$SECRETS_DIR"/*; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    case "$name" in *.env) continue ;; .*) continue ;; esac
    case "$name" in
      ''|[0-9]*|*[!A-Za-z0-9_]*) printf 'agent-entrypoint: skip non-identifier secret file: %s\n' "$name" >&2; continue ;;
    esac
    val=$(cat "$f"); export "$name=$val"
  done
  for ef in "$SECRETS_DIR"/*.env; do
    [ -f "$ef" ] || continue
    # Strict, non-executing KEY=VALUE parse. NEVER `.`/source this file.
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      case "$line" in *=*) : ;; *) continue ;; esac
      ekey=${line%%=*}
      case "$ekey" in 'export '*) ekey=${ekey#export } ;; esac
      case "$ekey" in
        ''|[0-9]*|*[!A-Za-z0-9_]*) printf 'agent-entrypoint: skip non-identifier in %s: %s\n' "$ef" "$ekey" >&2 ;;
        *) export "$ekey=${line#*=}" ;;
      esac
    done < "$ef"
  done
fi
if [ "$#" -eq 0 ]; then
  if command -v bash >/dev/null 2>&1; then set -- bash; else set -- sh; fi
fi
exec "$@"
