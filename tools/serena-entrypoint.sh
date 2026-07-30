#!/usr/bin/env bash
set -euo pipefail

: "${SERENA_HOME:=/tmp/serena}"
: "${HOME:=/tmp/serena-home}"

install -d -m 0700 "$SERENA_HOME" "$HOME"

# Keep mutable config/log state in tmpfs while reusing image-baked LS resources
# read-only. If Serena tries to install anything at runtime, it fails closed.
if [ ! -e "$SERENA_HOME/language_servers" ]; then
  ln -s /opt/serena-assets/language_servers "$SERENA_HOME/language_servers"
fi

exec /opt/serena/bin/serena "$@"
