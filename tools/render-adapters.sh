#!/usr/bin/env bash
# tools/render-adapters.sh — generate the per-tool allow/deny rule BODIES from shared policy, so the
# three adapters are never hand-maintained. Single policy source:
#   - policy/allow.commands   -> the auto-approve allow set (translated per tool)
#   - NATIVE_DENY below       -> unconditional native belt-and-suspenders rules. Scoped push,
#                               branch-derived rebase, and PR-create decisions remain in the
#                               authoritative guard because native rules cannot express branch policy.
#
# Generated files (do not hand-edit the marked/whole regions):
#   .claude/settings.json          (whole file — strict JSON, no comments)
#   .codex/rules/agent-lab.rules   (whole file — execpolicy prefix_rule; token-based)
#   .grok/config.toml              (whole file — [permission] + project MCP)
#
# Codex notes: execpolicy is TOKEN-prefix, so branch-aware decisions cannot be expressed as rules;
# the guard enforces those while native rules cover unconditional denials.
#
# Idempotent. Run as a maintenance task:  AGENT_LAB_MAINTENANCE=1 tools/render-adapters.sh
set -euo pipefail
root="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$root"
command -v jq >/dev/null 2>&1 || { echo "render-adapters: jq is required" >&2; exit 1; }

mapfile -t ALLOW < <(grep -vE '^[[:space:]]*(#|$)' policy/allow.commands)

# Client hook names differ even though all three clients invoke the same Serena tools.
SERENA_MCP_MUTATORS='mcp__serena__replace_symbol_body|mcp__serena__insert_before_symbol|mcp__serena__insert_after_symbol'

# Unconditional native deny heads. AGENTS.md is authoritative; guard handles scoped operations.
NATIVE_DENY=(
  "git pull" "git config" "git credential" "gh auth" "gh repo" "gh issue"
  "gh release" "gh workflow" "gh secret" "gh variable" "gh project" "gh gist"
  "gh cache" "gh codespace" "gh extension" "gh alias" "gh ssh-key" "gh gpg-key" "gh label"
  "gh pr merge" "gh pr close" "gh pr edit" "gh pr ready" "gh pr reopen" "gh pr review" "gh pr comment"
  "gh release create" "gh release delete" "gh release edit" "gh release upload"
  "git remote add" "git remote set-url" "git remote remove" "git remote rename"
)

toks() { # "git commit" -> "git", "commit"
  printf '%s' "$1" | awk '{for(i=1;i<=NF;i++) printf "%s\"%s\"",(i>1?", ":""),$i}'
}

# ---------------- Claude: whole settings.json via jq (guarantees valid JSON) ----------------
emit_claude() {
  local allow=() deny=() c d
  for c in "${ALLOW[@]}"; do allow+=("Bash(${c}:*)"); done
  allow+=("Read(**)" "Edit(**)" "Write(**)")
  for d in "${NATIVE_DENY[@]}"; do
    case "$d" in
      */) deny+=("Bash(${d}*)") ;;                      # glob form for remote-ref denies
      *)  deny+=("Bash(${d}:*)" "Bash(${d})") ;;
    esac
  done
  # NOTE: protected-path Edit/Write denies are intentionally NOT emitted for Claude. Claude's native
  # permissions.deny has NO maintenance bypass, so a native Edit(rail) deny self-locks even sanctioned
  # maintenance (the §13.9 self-lock; see docs/agent-config.md). The guard's Edit|Write matcher
  # enforces rail read-only WITH the AGENT_LAB_MAINTENANCE bypass; the git/remote denies above keep
  # their native belt-and-suspenders. Common local env/key paths stay natively denied; the guard
  # covers other .env variants while permitting the tracked .env.example documentation.
  deny+=(
    "Read(**/.env)" "Read(**/.env.local)" "Read(**/.env.*.local)" "Read(**/secrets/**)" "Read(**/*.pem)" "Read(**/*.key)" "Read(**/*.kdbx)"
    "Edit(**/.env)" "Edit(**/.env.local)" "Edit(**/.env.*.local)" "Edit(**/secrets/**)" "Edit(**/*.pem)" "Edit(**/*.key)" "Edit(**/*.kdbx)"
    "Write(**/.env)" "Write(**/.env.local)" "Write(**/.env.*.local)" "Write(**/secrets/**)" "Write(**/*.pem)" "Write(**/*.key)" "Write(**/*.kdbx)"
  )

  local guard='bash "$(git rev-parse --show-toplevel)/tools/pretooluse-guard.sh"'
  local boot='bash "$(git rev-parse --show-toplevel)/tools/session-bootstrap.sh" claude'
  local file_matcher="Read|Edit|Write|MultiEdit|NotebookEdit|${SERENA_MCP_MUTATORS}"
  mkdir -p .claude
  jq -n \
    --argjson allow "$(printf '%s\n' "${allow[@]}" | jq -R . | jq -s .)" \
    --argjson deny "$(printf '%s\n' "${deny[@]}" | jq -R . | jq -s .)" \
    --arg guard "$guard" --arg boot "$boot" --arg file_matcher "$file_matcher" \
    '{
      "$schema": "https://json.schemastore.org/claude-code-settings.json",
      permissions: { defaultMode: "acceptEdits", allow: $allow, deny: $deny },
      hooks: {
        PreToolUse: [
          { matcher: "Bash", hooks: [ { type: "command", command: $guard } ] },
          { matcher: $file_matcher, hooks: [ { type: "command", command: $guard } ] }
        ],
        SessionStart: [
          { matcher: "startup|resume", hooks: [ { type: "command", command: $boot } ] }
        ]
      }
    }' > .claude/settings.json
}

# ---------------- Codex: execpolicy rules (token-based) ----------------
emit_codex() {
  local c d
  mkdir -p .codex/rules
  {
    echo "# >>> GENERATED by tools/render-adapters.sh — DO NOT EDIT (edit policy/* and re-run) >>>"
    echo "# Codex execpolicy: allow the scoped AGENTS.md workflow. The PreToolUse guard"
    echo "# (tools/pretooluse-guard.sh) is the AUTHORITATIVE denier; these are belt-and-suspenders."
    echo "# Branch-aware push/rebase/PR-create decisions are guard-enforced, not expressible here."
    echo
    echo "# -- allow: local git (clean token prefixes only; workspace-write auto-runs the rest) --"
    for c in "${ALLOW[@]}"; do
      case "$c" in
        git\ *) printf 'prefix_rule(pattern = [%s], decision = "allow", justification = "agent-lab local-git set")\n' "$(toks "$c")" ;;
        gh\ *) printf 'prefix_rule(pattern = [%s], decision = "allow", justification = "agent-lab scoped GitHub workflow")\n' "$(toks "$c")" ;;
        shellcheck) printf 'prefix_rule(pattern = ["shellcheck"], decision = "allow", justification = "agent-lab lint")\n' ;;
      esac
    done
    echo
    echo "# -- forbidden: authentication and remote mutations outside the scoped workflow --"
    for d in "${NATIVE_DENY[@]}"; do
      case "$d" in
        */) echo "# guard-enforced (remote ref, not a token prefix): $d*" ;;
        *) printf 'prefix_rule(pattern = [%s], decision = "forbidden", justification = "agent-lab: outside the AGENTS.md scoped workflow")\n' "$(toks "$d")" ;;
      esac
    done
    echo "# <<< END GENERATED <<<"
  } > .codex/rules/agent-lab.rules
}

# ---------------- Grok: whole config.toml ([permission] + project MCP) ----------------
emit_grok() {
  local c d
  mkdir -p .grok
  {
    echo "# >>> GENERATED by tools/render-adapters.sh — DO NOT EDIT (edit policy/* and re-run) >>>"
    echo "# Grok Build project config. Decision order: PreToolUse hooks -> deny>ask>allow -> fast"
    echo "# paths -> prompt. deny survives always-approve. Guard (tools/pretooluse-guard.sh) is"
    echo "# authoritative; these rules are belt-and-suspenders. Hooks are wired in .grok/hooks/."
    echo
    echo "# Autonomy posture is set by the OPERATOR at launch — NOT here. Grok treats [ui] permission_mode"
    echo "# as a global/user default that can leak across projects, and 'always-approve' is a launch FLAG,"
    echo "# not a config enum (valid config enum: default|acceptEdits|auto|dontAsk|bypassPermissions|plan)."
    echo "# Launch:  grok --always-approve   — the deny rules below + the PreToolUse hook still hold (Grok"
    echo "# runs hooks -> deny>allow -> fast-paths before any prompt-skip). See docs/agent-config.md."
    echo
    echo "[permission]"
    echo "deny = ["
    for d in "${NATIVE_DENY[@]}"; do printf '  "Bash(%s*)",\n' "$d"; done
    echo '  "Read(**/.env)", "Read(**/.env.local)", "Read(**/.env.*.local)", "Read(**/secrets/**)", "Read(**/*.pem)", "Read(**/*.key)", "Read(**/*.kdbx)",'
    echo '  "Edit(**/.env)", "Edit(**/.env.local)", "Edit(**/.env.*.local)", "Edit(**/secrets/**)", "Edit(**/*.pem)", "Edit(**/*.key)", "Edit(**/*.kdbx)",'
    echo '  "Write(**/.env)", "Write(**/.env.local)", "Write(**/.env.*.local)", "Write(**/secrets/**)", "Write(**/*.pem)", "Write(**/*.key)", "Write(**/*.kdbx)",'
    echo ']'
    echo "allow = ["
    for c in "${ALLOW[@]}"; do printf '  "Bash(%s*)",\n' "$c"; done
    echo '  "Read(**)", "Edit(**)", "Write(**)",'
    echo ']'
    echo "# <<< END GENERATED <<<"
    echo
    echo "# Serena is project-scoped and starts in a dedicated no-network container."
    echo "# Do not pass --project here: explicit activation must remain recoverable."
    echo "[mcp_servers.serena]"
    echo 'command = "env"'
    echo 'args = ["-u", "BASH_ENV", "-u", "ENV", "bash", "--noprofile", "--norc", "-c", "root=\"$(git rev-parse --show-toplevel)\" && exec \"$root/scripts/serena-mcp\" --context=grok"]'
  } > .grok/config.toml
}

emit_claude
emit_codex
emit_grok
echo "render-adapters: wrote .claude/settings.json .codex/rules/agent-lab.rules .grok/config.toml"
