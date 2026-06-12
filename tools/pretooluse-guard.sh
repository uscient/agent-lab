#!/usr/bin/env bash
# agent-lab PreToolUse guard (matcher: Bash). Same mutation policy as the workspace
# top level, PLUS agent-lab containment hard-stops. Exit 2 blocks and returns the reason.
# Standalone: echo '{"tool_input":{"command":"git commit -m x"}}' | tools/pretooluse-guard.sh
set -uo pipefail
input="$(cat)"
cmd=""
command -v jq >/dev/null 2>&1 && cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
hay="${cmd:-$input}"
block(){ echo "BLOCKED by agent-lab policy: $1" >&2; exit 2; }

# ---- mutation policy (same as top level) ----
printf '%s' "$hay" | grep -Eq '(^|[^[:alnum:]_])git[[:space:]]+(add|commit|push|merge|rebase|reset|tag|cherry-pick)([[:space:]]|$)' \
  && block "git mutation is forbidden — the human commits."
printf '%s' "$hay" | grep -Eq 'gh[[:space:]]+pr([[:space:]]|$)' && block "opening PRs is forbidden."
printf '%s' "$hay" | grep -Eq 'sed[[:space:]]+-i' && block "in-place 'sed -i' edits are forbidden — use the sanctioned edit path."
printf '%s' "$hay" | grep -Eq '(^|[[:space:]])rm[[:space:]]+-[rR]f?' && block "'rm -rf' is forbidden."
printf '%s' "$hay" | grep -Eq '(^|[[:space:]])sudo([[:space:]]|$)' && block "sudo is forbidden."
if printf '%s' "$hay" | grep -Eq '(\.claude|\.codex|\.grok|\.devguard)/'; then
  printf '%s' "$hay" | grep -Eq '(>>?|[[:space:]]tee[[:space:]]|sed[[:space:]]+-i|[[:space:]]rm[[:space:]]|[[:space:]]mv[[:space:]]|[[:space:]]cp[[:space:]]|truncate)' \
    && block "control-plane mutation (.claude/.codex/.grok/.devguard) is forbidden."
fi

# ---- agent-lab containment (AGENTS.md hard stops) ----
printf '%s' "$hay" | grep -Eq 'docker\.sock' && block "mounting the Docker socket is forbidden (host-escape surface)."
printf '%s' "$hay" | grep -Eq '(--privileged|privileged[[:space:]]*:[[:space:]]*true)' && block "privileged containers are forbidden."
printf '%s' "$hay" | grep -Eq '(--network[=[:space:]]host|--net[=[:space:]]host|network_mode[[:space:]]*:[[:space:]]*.?host)' \
  && block "host networking is forbidden (breaks default-deny)."
if printf '%s' "$hay" | grep -Eq '(\.env([^a-zA-Z]|$)|secrets/|\.pem|\.key|\.kdbx)'; then
  printf '%s' "$hay" | grep -Eq '(>>?|[[:space:]]tee[[:space:]]|sed[[:space:]]+-i|[[:space:]]cp[[:space:]]|[[:space:]]mv[[:space:]])' \
    && block "writing to .env / secrets / key material via shell is forbidden."
fi
exit 0
