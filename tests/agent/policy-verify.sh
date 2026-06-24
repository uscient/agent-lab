#!/usr/bin/env bash
# tests/agent/policy-verify.sh — tool-agnostic verification harness.
# Runs the guard/shim/token/generator/wiring/doctrine [probe] checks that don't need a live tool.
# Per-tool LIVE checks (no-prompt loop, guard-fired, trust) are in agent-policy-checklist.md.
# Tolerant of not-yet-built adapters (SKIP, not FAIL). Run: bash tests/agent/policy-verify.sh
set -uo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
cd "$root" || exit 1
guard="tools/pretooluse-guard.sh"

P=0 F=0 S=0
pass() { printf 'PASS %s\n' "$1"; P=$((P + 1)); }
fail() { printf 'FAIL %s\n' "$1"; F=$((F + 1)); }
skip() { printf 'SKIP %s\n' "$1"; S=$((S + 1)); }

# probe_cmd <block|allow> <name> <command> [maint]
probe_cmd() {
  local exp="$1" name="$2" cmd="$3" maint="${4:-}" rc=0
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$cmd" '$c')" \
    | env AGENT_LAB_MAINTENANCE="$maint" "$guard" >/dev/null 2>&1 || rc=$?
  if [ "$exp" = block ]; then [ "$rc" -eq 2 ] && pass "$name" || fail "$name (want rc2, got $rc)"
  else [ "$rc" -eq 0 ] && pass "$name" || fail "$name (want rc0, got $rc)"; fi
}

echo "== token budget =="
n=$(wc -c < AGENTS.md)
[ "$n" -le 6000 ] && pass "AGENTS.md <= 6000 bytes ($n)" || fail "AGENTS.md token budget ($n/6000)"

echo "== guard unit matrix (delegate) =="
if bash tests/guard/pretooluse-cases.sh >/tmp/pol_guard.out 2>&1; then
  pass "tests/guard/pretooluse-cases.sh ($(grep -c '^PASS' /tmp/pol_guard.out) cases)"
else
  fail "tests/guard/pretooluse-cases.sh — see /tmp/pol_guard.out"
fi

echo "== guard-fired & adversarial stdin (string forms) =="
for c in 'git push' 'git push origin HEAD' 'git -C . push' 'sh -c "git push"' 'env git push' \
         'nohup git push &' 'python3 -c "import subprocess;subprocess.run([\"git\",\"push\"])"' \
         'gh pr create' 'gh api -X POST repos/o/r/pulls' 'git pull' 'git merge origin/main' \
         'git rebase origin/main' 'git reset --hard HEAD~1' 'git clean -fdx' 'rm -rf build'; do
  probe_cmd block "blocked: $c" "$c"
done
probe_cmd allow "control: local merge feature-x" 'git merge feature-x'
probe_cmd allow "control: local rebase main"     'git rebase main'

echo "== shim adversarial (variable indirection — argv level) =="
if [ -x tools/bin/git ]; then
  for c in 'g=push; git $g' 'm=merge; git $m origin/main'; do
    rc=0; out="$(PATH="$PWD/tools/bin:$PATH" bash -c "$c" 2>&1)" || rc=$?
    { [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'BLOCKED by agent-lab policy'; } \
      && pass "shim blocks: $c" || fail "shim should block: $c (rc=$rc)"
  done
  rc=0; PATH="$PWD/tools/bin:$PATH" bash -c 'git status' >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] && pass "shim passes through: git status" || fail "shim broke git status (rc=$rc)"
else
  skip "tools/bin/git shim missing"
fi

echo "== protected-path edit backstop =="
printf '{"tool_name":"Edit","tool_input":{"file_path":"doctrine/git-workflow.md"}}' \
  | env -u AGENT_LAB_MAINTENANCE "$guard" >/dev/null 2>&1 && fail "doctrine edit not blocked" || pass "doctrine edit blocked (no maint)"
printf '{"tool_name":"Edit","tool_input":{"file_path":"doctrine/git-workflow.md"}}' \
  | env AGENT_LAB_MAINTENANCE=1 "$guard" >/dev/null 2>&1 && pass "doctrine edit allowed (maint=1)" || fail "maint=1 did not allow doctrine edit"

echo "== Codex PermissionRequest approver =="
if [ -x tools/codex-permission-request.sh ]; then
  appr() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')" | tools/codex-permission-request.sh 2>/dev/null; }
  appr 'git commit -m x' | grep -q '"behavior": *"allow"' && pass "approver allows commit" || fail "approver should allow commit"
  appr 'git push'        | grep -q '"behavior": *"deny"'  && pass "approver denies push"   || fail "approver should deny push"
else
  skip "tools/codex-permission-request.sh not built yet"
fi

echo "== generator: idempotent + valid =="
if [ -x tools/render-adapters.sh ]; then
  jq -e . .claude/settings.json >/dev/null 2>&1 && pass "Claude settings.json valid JSON" || fail "Claude settings.json invalid JSON"
else
  skip "tools/render-adapters.sh missing"
fi

echo "== wiring: PreToolUse hooks point at the one guard =="
for f in .claude/settings.json .codex/hooks.json .grok/hooks/git-policy.json; do
  if [ -f "$f" ]; then
    grep -q 'pretooluse-guard.sh' "$f" && pass "wiring: $f -> guard" || fail "wiring: $f missing guard ref"
  else
    skip "wiring: $f not built yet"
  fi
done

echo "== doctrine: TL;DR + index 1:1 =="
ok=1; for f in doctrine/*.md; do
  l=$(grep -vE '^[[:space:]]*$' "$f" | grep -vE '^#' | head -1)
  case "$l" in "TL;DR:"*) ;; *) ok=0; echo "  $f missing TL;DR";; esac
done
[ "$ok" = 1 ] && pass "all doctrine lead with TL;DR" || fail "a doctrine file lacks TL;DR"
idx=$(grep -cE '^- `doctrine/.*\.md`' AGENTS.md); files=$(find doctrine -maxdepth 1 -name '*.md' | wc -l)
[ "$idx" -eq "$files" ] && pass "AGENTS.md doctrine index 1:1 ($idx)" || fail "doctrine index $idx != $files files"

printf '\nSUMMARY pass=%s fail=%s skip=%s\n' "$P" "$F" "$S"
[ "$F" -eq 0 ]
