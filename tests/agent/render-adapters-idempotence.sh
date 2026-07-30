#!/usr/bin/env bash
set -euo pipefail

repo_root="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

assert_same() {
  local expected="$1" actual="$2" label="$3"
  if ! cmp "$expected" "$actual"; then
    printf 'FAIL generated adapter drift: %s\n' "$label" >&2
    return 1
  fi
}

mkdir -p \
  "$work/.claude" \
  "$work/.codex/rules" \
  "$work/.grok" \
  "$work/policy" \
  "$work/tools" \
  "$work/expected"

cp "$repo_root/.claude/settings.json" "$work/.claude/settings.json"
cp "$repo_root/.codex/rules/agent-lab.rules" "$work/.codex/rules/agent-lab.rules"
cp "$repo_root/.grok/config.toml" "$work/.grok/config.toml"
cp "$repo_root/policy/allow.commands" "$work/policy/allow.commands"
cp "$repo_root/policy/protected.paths" "$work/policy/protected.paths"
cp "$repo_root/tools/render-adapters.sh" "$work/tools/render-adapters.sh"

cp "$work/.claude/settings.json" "$work/expected/claude.json"
cp "$work/.codex/rules/agent-lab.rules" "$work/expected/codex.rules"
cp "$work/.grok/config.toml" "$work/expected/grok.toml"

AGENT_LAB_MAINTENANCE=1 bash "$work/tools/render-adapters.sh" >/dev/null
assert_same "$work/expected/claude.json" "$work/.claude/settings.json" "Claude"
assert_same "$work/expected/codex.rules" "$work/.codex/rules/agent-lab.rules" "Codex"
assert_same "$work/expected/grok.toml" "$work/.grok/config.toml" "Grok"

cp "$work/.claude/settings.json" "$work/expected/claude.second.json"
cp "$work/.codex/rules/agent-lab.rules" "$work/expected/codex.second.rules"
cp "$work/.grok/config.toml" "$work/expected/grok.second.toml"

AGENT_LAB_MAINTENANCE=1 bash "$work/tools/render-adapters.sh" >/dev/null
assert_same "$work/expected/claude.second.json" "$work/.claude/settings.json" "Claude second render"
assert_same "$work/expected/codex.second.rules" "$work/.codex/rules/agent-lab.rules" "Codex second render"
assert_same "$work/expected/grok.second.toml" "$work/.grok/config.toml" "Grok second render"

printf 'PASS generated adapters match tracked files and are idempotent\n'
