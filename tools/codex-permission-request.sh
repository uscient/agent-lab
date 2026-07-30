#!/usr/bin/env bash
# Codex PermissionRequest approver. Codex fires PermissionRequest when a tool call wants to escalate
# past the sandbox. This keeps the allowed set prompt-free WITHOUT a global bypass: approve the
# allow-set, deny whatever the authoritative guard denies, otherwise emit NO decision (defer).
#
# Response shape verified against Codex docs (2026-06-15):
#   approve: {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
#   deny:    {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":...}}}
#   "any deny wins; if no hook decides, the normal approval flow proceeds."
# Probe: echo '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' | tools/codex-permission-request.sh
set -uo pipefail
root="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)" || exit 0
pol="$root/policy"

input="$(cat)"
cmd=""
command -v jq >/dev/null 2>&1 && cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -z "$cmd" ] && exit 0 # no command (file edits etc.) -> defer to sandbox + the PreToolUse guard

active_patterns() { grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null || true; }
allow_match() {
  local c="$1" entry
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    case "$entry" in
      */) case "$c" in "$entry"*) return 0 ;; esac ;;     # path prefix (e.g. ./scripts/dev/)
      *) case "$c " in "$entry "*) return 0 ;; esac ;;     # command, word-boundary (e.g. git commit)
    esac
  done < <(active_patterns "$pol/allow.commands")
  return 1
}
allow() { printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}\n'; exit 0; }
deny() { printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"%s"}}}\n' "$1"; exit 0; }

# Deny anything the guard denies.
guard_rc=0
printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
  "$(jq -Rn --arg c "$cmd" '$c')" \
  | "$root/tools/pretooluse-guard.sh" >/dev/null 2>&1 || guard_rc=$?
[ "$guard_rc" -eq 2 ] \
  && deny "agent-lab: operation is outside the AGENTS.md autonomy boundary"
[ "$guard_rc" -ne 0 ] \
  && deny "agent-lab: policy guard failed closed"
# Approve the allow-set (frictionless commit / local-git / work commands).
allow_match "$cmd" && allow
# Otherwise: no decision -> defer to Codex's normal flow.
exit 0
