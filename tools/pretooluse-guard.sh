#!/usr/bin/env bash
# agent-lab PreToolUse guard — DEFENSE-IN-DEPTH for an agent *developing* this repo.
#
# It makes the safe path automatic and catches mistakes + casual evasion. It is NOT the security
# boundary: a hostile agent is contained by the sandbox/network posture (SECURITY.md /
# THREAT_MODEL.md), not by these string matches. See doctrine/containment.md.
#
# Matchers: Bash (inspect tool_input.command) and Edit/Write/apply_patch (inspect file_path).
# Policy lives as data in policy/*.patterns (single source; also consumed by render-adapters.sh).
# Exit 2 blocks and prints the reason (cites the relevant doctrine/ file). Exit 0 defers.
#
# Standalone probes:
#   echo '{"tool_input":{"command":"git push"}}'                | tools/pretooluse-guard.sh   # ->2
#   echo '{"tool_name":"Edit","tool_input":{"file_path":"AGENTS.md"}}' | tools/pretooluse-guard.sh # ->2 (unless AGENT_LAB_MAINTENANCE=1)
#   echo '{"tool_input":{"command":"git commit -m x"}}'         | tools/pretooluse-guard.sh   # ->0
set -uo pipefail

root="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)" || exit 0
pol="$root/policy"

input="$(cat)"
tool_name="" cmd="" fpath=""
if command -v jq >/dev/null 2>&1; then
  tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"
  cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
  fpath="$(printf '%s' "$input" | jq -r '(.tool_input.file_path // .tool_input.path // .tool_input.notebook_path // empty)' 2>/dev/null || true)"
fi

block() { # block <reason> <doctrine-file>
  echo "BLOCKED by agent-lab policy: $1 (see doctrine/$2)" >&2
  exit 2
}

# active_patterns <file>: strip comments + blank lines
active_patterns() { grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null || true; }

# match_any <haystack> <patterns-file>: 0 if any active pattern matches
match_any() {
  local hay="$1" file="$2" pats
  pats="$(active_patterns "$file")"
  [ -z "$pats" ] && return 1
  printf '%s' "$hay" | grep -Eq -f <(printf '%s\n' "$pats")
}

# path_is_protected <path>: 0 if path matches any policy/protected.paths entry (at a / boundary)
path_is_protected() {
  local p="$1" entry esc re
  [ -z "$p" ] && return 1
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    esc="$(printf '%s' "$entry" | sed -e 's/[.[\*^$()+?{}|]/\\&/g')"
    case "$entry" in
      */) re="(^|/)${esc}" ;;          # directory prefix
      *)  re="(^|/)${esc}($|/)" ;;      # exact file (or that path as a dir)
    esac
    printf '%s' "$p" | grep -Eq "$re" && return 0
  done < <(active_patterns "$pol/protected.paths")
  return 1
}

# protected_alternation: regex OR of all protected entries, for the Bash control-plane check
protected_alternation() {
  active_patterns "$pol/protected.paths" \
    | sed -e 's/[.[\*^$()+?{}|]/\\&/g' \
    | paste -sd '|' -
}

maint="${AGENT_LAB_MAINTENANCE:-}"

# ---------------------------------------------------------------------------
# Edit/Write/apply_patch path: protect the rails from file-tool edits.
# ---------------------------------------------------------------------------
case "$tool_name" in
  Edit | Write | MultiEdit | NotebookEdit | apply_patch | str_replace_editor)
    if [ "$maint" != 1 ] && path_is_protected "$fpath"; then
      block "editing a protected rail ($fpath) is a maintenance-only action — set AGENT_LAB_MAINTENANCE=1 for sanctioned maintenance" "meta.md"
    fi
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# Bash path. When tool_name is absent but a command is present, treat as Bash.
# ---------------------------------------------------------------------------
hay="${cmd:-$input}"

# scan = hay with safe message-flag DATA removed. The quoted literal argument of -m / --message / -F
# is message text, not an operation, so it must not be matched as one. Strip it ONLY when it is a
# plain quoted literal with no command substitution / expansion ($(  `  ${ ) — so anything that can
# execute stays fully matched. -c (e.g. `sh -c "git push"`) is NOT a message flag and is never stripped.
scan="$hay"
scan="$(printf '%s' "$scan" | sed -E "s/(--message|-m|-F)[[:space:]]*'[^'\$\`]*'/\1 /g")"
scan="$(printf '%s' "$scan" | sed -E "s/(--message|-m|-F)[[:space:]]*\"[^\"\$\`]*\"/\1 /g")"

q="[\"']"                    # an optional quote in front of a redirect target
fw='(^|[^0-9&])>>?([^&]|$)'  # a FILE-write redirect (> or >>), excluding fd forms (2>, N>, >&N, &>)

# 1) remote integrity: push / pull / remote merge-rebase / PR / remote-config
match_any "$scan" "$pol/deny.patterns" \
  && block "remote git operation (push / pull / remote merge or rebase / PR / remote-config) is forbidden — the human owns the remote and the merge gate" "git-workflow.md"

# 2) destructive / integrity carve-out
match_any "$scan" "$pol/carveout.patterns" \
  && block "destructive/integrity operation is forbidden under autonomy — ask the human first" "destructive-ops.md"

# 3) containment hard-stops (always on; not maintenance-gated) — kept verbatim from the substrate
printf '%s' "$scan" | grep -Eq 'docker\.sock' \
  && block "mounting the Docker socket is forbidden (host-escape surface)" "containment.md"
printf '%s' "$scan" | grep -Eq '(--privileged|privileged[[:space:]]*:[[:space:]]*true)' \
  && block "privileged containers are forbidden" "containment.md"
printf '%s' "$scan" | grep -Eq '(--network[=[:space:]]host|--net[=[:space:]]host|network_mode[[:space:]]*:[[:space:]]*.?host)' \
  && block "host networking is forbidden (breaks default-deny)" "containment.md"
# secret/key material: block a FILE-write redirect, a redirect whose TARGET is a secret, or a
# mutating command acting on one. A stderr-only redirect (`2>/dev/null`) is not a write, and reads
# are not blocked here (Read-deny is enforced by the per-tool adapters).
if printf '%s' "$scan" | grep -Eq '(\.env([^a-zA-Z]|$)|secrets/|\.pem|\.key|\.kdbx)'; then
  if printf '%s' "$scan" | grep -Eq "$fw" \
    || printf '%s' "$scan" | grep -Eq ">>?[[:space:]]*${q}?(\.env|secrets/|[^[:space:]]*\.(pem|key|kdbx))" \
    || printf '%s' "$scan" | grep -Eq '(^|[[:space:]])(tee|cp|mv|truncate)[[:space:]]|sed[[:space:]]+-i'; then
    block "writing to .env / secrets / key material via shell is forbidden" "containment.md"
  fi
fi

# 4) control-plane / guardrail integrity (maintenance-gated): shell MUTATION of the rails.
#    A "mutation" is a FILE-write redirect while a rail is referenced, a redirect whose TARGET is a
#    rail, or a mutating command (tee/rm/mv/cp/truncate/install/sed -i) with a rail referenced. A bare
#    stderr redirect next to a rail token (e.g. `cat .claude/x 2>/dev/null`) is a read, not a mutation.
if [ "$maint" != 1 ]; then
  alt="$(protected_alternation)"
  if [ -n "$alt" ] && printf '%s' "$scan" | grep -Eq "($alt)"; then
    if printf '%s' "$scan" | grep -Eq "$fw" \
      || printf '%s' "$scan" | grep -Eq ">>?[[:space:]]*${q}?($alt)" \
      || printf '%s' "$scan" | grep -Eq '(^|[[:space:]])(tee|rm|mv|cp|truncate|install)[[:space:]]|sed[[:space:]]+-i'; then
      block "mutating a protected rail (config / doctrine / guard / policy) via shell is a maintenance-only action — set AGENT_LAB_MAINTENANCE=1" "meta.md"
    fi
  fi
fi

# 5) branch backstop: never commit on master/main (covers a skipped SessionStart bootstrap)
if printf '%s' "$scan" | grep -Eq '(^|[^[:alnum:]_])git[[:space:]]+commit([[:space:]]|$)'; then
  br="$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null || echo DETACHED)"
  case "$br" in
    master | main) block "refusing to commit on '$br' — create an agent/<tool>/<slug> branch first (SessionStart normally does this)" "git-workflow.md" ;;
  esac
fi

exit 0
