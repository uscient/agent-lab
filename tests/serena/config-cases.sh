#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
# shellcheck source=scripts/lib/serena.sh
source "$repo_root/scripts/lib/serena.sh"
work="$(mktemp -d)"
cleanup() {
  find "$work" -xdev -depth -delete >/dev/null 2>&1 || true
}
trap cleanup EXIT
failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

require_text() {
  local file="$1" text="$2" label="$3"
  if grep -Fq -- "$text" "$repo_root/$file"; then
    pass "$label"
  else
    fail "$label"
  fi
}

require_absent() {
  local file="$1" pattern="$2" label="$3"
  if grep -Eq -- "$pattern" "$repo_root/$file"; then
    fail "$label"
  else
    pass "$label"
  fi
}

require_text .serena/project.yml 'project_name: "agent-lab-dev"' \
  "Serena project has an unambiguous logical name"
require_text .serena/project.yml 'language_servers:' \
  "Serena project uses the current language_servers schema"
require_text .serena/project.yml '- bash' \
  "Serena project selects the actual Bash language"
require_text .serena/project.yml 'language_backend: LSP' \
  "Serena project explicitly selects the LSP backend"
require_text .serena/project.yml 'ls_workspace_folders: ["."]' \
  "Serena indexes exactly the Agent Lab project root"

require_text compose.serena.yaml 'network_mode: none' \
  "Serena runtime has no network namespace"
require_text compose.serena.yaml 'read_only: true' \
  "Serena runtime root filesystem is read-only"
require_text compose.serena.yaml 'create_host_path: false' \
  "Serena project bind cannot create an unintended host path"
require_text compose.serena.yaml 'target: /workspace' \
  "Serena sees the stable container project root"
require_absent compose.serena.yaml \
  'docker\.sock|/run/agent-secrets|/home/[^:]*:|HTTP_PROXY|HTTPS_PROXY' \
  "Serena runtime has no socket, secret, home, or proxy mount"

require_text images/serena/Dockerfile \
  '6c1c9653700cbe644cb5a5b026b77db2f4071c36' \
  "Serena source is commit-pinned"
require_text images/serena/Dockerfile \
  'bash-language-server.version="5.6.0"' \
  "Bash language server version is recorded"
require_text images/serena/Dockerfile \
  'shellcheck.version="0.10.0"' \
  "ShellCheck version is recorded"
require_text images/serena/Dockerfile \
  '/opt/serena-assets/language_servers/static/BashLanguageServer/bash-lsp/shellcheck/' \
  "ShellCheck is preseeded in Serena's required managed layout"

require_text compose.serena.yaml 'SERENA_USAGE_REPORTING: "false"' \
  "Serena usage reporting is disabled"
require_text scripts/serena-mcp '--enable-web-dashboard false' \
  "Serena dashboard is disabled"
require_absent scripts/serena-mcp \
  '--project([=[:space:]]|$)|--project-from-cwd' \
  "Serena starts recoverably without a fixed project"

require_text .codex/config.toml '[mcp_servers.serena]' \
  "Codex registers Serena at project scope"
require_text .codex/config.toml \
  'args = ["-c", "root=\"$(git rev-parse --show-toplevel)\" && exec \"$root/scripts/serena-mcp\" --context=codex"]' \
  "Codex discovers the repository root before using its verified Serena context"
require_text .mcp.json \
  '"-c"' \
  "Claude invokes bash without login-shell startup files"
require_text .mcp.json \
  '"root=\"$(git rev-parse --show-toplevel)\" && exec \"$root/scripts/serena-mcp\" --context=claude-code"' \
  "Claude discovers the repository root before using its verified Serena context"
require_text .grok/config.toml '[mcp_servers.serena]' \
  "Grok registers Serena at project scope"
require_text .grok/config.toml \
  'args = ["-c", "root=\"$(git rev-parse --show-toplevel)\" && exec \"$root/scripts/serena-mcp\" --context=grok"]' \
  "Grok discovers the repository root before using its verified Serena context"

for excluded_tool in replace_in_files replace_content rename_symbol safe_delete_symbol; do
  require_text .serena/project.yml "- $excluded_tool" \
    "Serena excludes broad mutator $excluded_tool"
done
require_text .codex/hooks.json 'mcp__serena__replace_symbol_body' \
  "Codex guards Serena semantic mutators"
require_text .claude/settings.json 'mcp__serena__replace_symbol_body' \
  "Claude guards Serena semantic mutators"
require_text .grok/hooks/git-policy.json 'serena__replace_symbol_body' \
  "Grok guards Serena semantic mutators"

if agent_lab_serena_validate_identity 1002 1002 >/dev/null 2>&1 &&
   ! agent_lab_serena_validate_identity 0 1002 >/dev/null 2>&1 &&
   ! agent_lab_serena_validate_identity 1002 0 >/dev/null 2>&1 &&
   ! agent_lab_serena_validate_identity invalid 1002 >/dev/null 2>&1; then
  pass "Serena launcher accepts only canonical non-root UID/GID values"
else
  fail "Serena launcher accepts only canonical non-root UID/GID values"
fi

fixture="$work/project"
mount_state="$work/mount-state"
mkdir -p \
  "$fixture/.git" \
  "$fixture/policy" \
  "$fixture/.serena" \
  "$fixture/secrets" \
  "$fixture/cache" \
  "$fixture/proj" \
  "$fixture/src" \
  "$mount_state"
printf '%s\n' \
  'AGENTS.md' \
  'policy/' \
  '.mcp.json' \
  '.serena/project.yml' \
  > "$fixture/policy/protected.paths"
printf '%s\n' 'fixture rail' > "$fixture/AGENTS.md"
printf '%s\n' '{}' > "$fixture/.mcp.json"
printf '%s\n' 'project_name: fixture' > "$fixture/.serena/project.yml"
printf '%s\n' 'masked fixture value' > "$fixture/.env.local"
printf '%s\n' 'public example value' > "$fixture/.env.example"
printf '%s\n' '#!/usr/bin/env bash' > "$fixture/src/safe.sh"

mount_rc=0
agent_lab_serena_prepare_mounts \
  "$fixture" "$mount_state" >/dev/null 2>&1 || mount_rc=$?
if [ "$mount_rc" -eq 0 ] &&
   [ "$AGENT_LAB_SERENA_GIT_MASK_SOURCE" = "$mount_state/empty-dir" ] &&
   [ "$AGENT_LAB_SERENA_CACHE_DIR" = "$mount_state/project-cache" ] &&
   grep -Fq "target: '/workspace/.env.local'" \
     "$AGENT_LAB_SERENA_MOUNT_OVERRIDE" &&
   grep -Fq "target: '/workspace/secrets'" \
     "$AGENT_LAB_SERENA_MOUNT_OVERRIDE" &&
   grep -Fq "target: '/workspace/cache'" \
     "$AGENT_LAB_SERENA_MOUNT_OVERRIDE" &&
   grep -Fq "target: '/workspace/proj'" \
     "$AGENT_LAB_SERENA_MOUNT_OVERRIDE" &&
   grep -Fq "target: '/workspace/AGENTS.md'" \
     "$AGENT_LAB_SERENA_MOUNT_OVERRIDE" &&
   grep -Fq "target: '/workspace/policy'" \
     "$AGENT_LAB_SERENA_MOUNT_OVERRIDE" &&
   grep -Fq "target: '/workspace/.mcp.json'" \
     "$AGENT_LAB_SERENA_MOUNT_OVERRIDE" &&
   grep -Fq "target: '/workspace/.serena/project.yml'" \
     "$AGENT_LAB_SERENA_MOUNT_OVERRIDE" &&
   ! grep -Fq "target: '/workspace/.env.example'" \
     "$AGENT_LAB_SERENA_MOUNT_OVERRIDE" &&
   ! grep -Fq 'read_only: false' "$AGENT_LAB_SERENA_MOUNT_OVERRIDE"; then
  pass "Serena mount plan masks local state and overlays every existing rail read-only"
else
  fail "Serena mount plan masks local state and overlays every existing rail read-only"
fi

find "$fixture/secrets" -depth -delete
mkdir -p "$work/outside"
ln -s "$work/outside" "$fixture/secrets"
symlink_state="$work/symlink-state"
mkdir "$symlink_state"
symlink_rc=0
agent_lab_serena_prepare_mounts \
  "$fixture" "$symlink_state" >/dev/null 2>&1 || symlink_rc=$?
if [ "$symlink_rc" -eq 125 ]; then
  pass "Serena mount planning fails closed on a sensitive symlink"
else
  fail "Serena mount planning fails closed on a sensitive symlink"
fi
find "$fixture/secrets" -depth -delete

mkdir -p "$fixture/src/private"
printf '%s\n' 'synthetic fixture' > "$fixture/src/private/service.key"
nested_state="$work/nested-state"
mkdir "$nested_state"
nested_rc=0
agent_lab_serena_prepare_mounts \
  "$fixture" "$nested_state" >/dev/null 2>&1 || nested_rc=$?
if [ "$nested_rc" -eq 125 ]; then
  pass "Serena mount planning rejects nested credential and key paths"
else
  fail "Serena mount planning rejects nested credential and key paths"
fi

require_text compose.serena.yaml \
  'source: ${AGENT_LAB_SERENA_GIT_MASK_SOURCE:?set by scripts/serena-mcp}' \
  "Compose requires the generated Git metadata mask"
require_text compose.serena.yaml \
  'target: /workspace/.serena/cache' \
  "Compose gives Serena a private project-cache mount"
require_text scripts/serena-mcp \
  '-f "$AGENT_LAB_SERENA_MOUNT_OVERRIDE"' \
  "launcher always applies the generated containment override"

printf 'SUMMARY failures=%s\n' "$failures"
test "$failures" -eq 0
