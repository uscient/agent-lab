#!/usr/bin/env bash
# tests/agent/policy-verify.sh — tool-agnostic verification harness.
# Runs the guard/shim/token/generator/wiring/authority [probe] checks that don't need a live tool.
# Per-tool LIVE checks (no-prompt loop, guard-fired, trust) are in agent-policy-checklist.md.
# Missing adapters are reported as SKIP and make the strict result fail.
set -uo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
cd "$root" || exit 1
guard="tools/pretooluse-guard.sh"
policy_git_work=""
if ! policy_git_work="$(mktemp -d)"; then
  printf 'INFRA policy verification cannot create isolated work directory\n' >&2
  exit 125
fi
policy_git_repo="$policy_git_work/repo"
policy_render_out="$policy_git_work/render-adapters.out"
cleanup() { find "$policy_git_work" -depth -delete >/dev/null 2>&1 || true; }
trap cleanup EXIT
if ! mkdir -p "$policy_git_repo" ||
   ! git -C "$policy_git_repo" init -q ||
   ! git --git-dir="$policy_git_repo/.git" symbolic-ref HEAD refs/heads/agent/test/policy; then
  printf 'INFRA policy verification cannot initialize isolated Git state\n' >&2
  exit 125
fi
policy_git_dir="$policy_git_repo/.git"
set_policy_branch() {
  git --git-dir="$policy_git_dir" symbolic-ref HEAD "refs/heads/$1"
}

P=0 F=0 S=0
pass() { printf 'PASS %s\n' "$1"; P=$((P + 1)); }
fail() { printf 'FAIL %s\n' "$1"; F=$((F + 1)); }
skip() { printf 'SKIP %s\n' "$1"; S=$((S + 1)); }

# probe_cmd <block|allow> <name> <command> [maint]
probe_cmd() {
  local exp="$1" name="$2" cmd="$3" maint="${4:-}" rc=0
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$cmd" '$c')" \
    | env -u GIT_WORK_TREE -u GIT_COMMON_DIR AGENT_LAB_MAINTENANCE="$maint" \
        GIT_DIR="$policy_git_dir" "$guard" >/dev/null 2>&1 || rc=$?
  if [ "$exp" = block ]; then [ "$rc" -eq 2 ] && pass "$name" || fail "$name (want rc2, got $rc)"
  else [ "$rc" -eq 0 ] && pass "$name" || fail "$name (want rc0, got $rc)"; fi
}

echo "== token budget =="
n=$(wc -c < AGENTS.md)
[ "$n" -le 6000 ] && pass "AGENTS.md <= 6000 bytes ($n)" || fail "AGENTS.md token budget ($n/6000)"

echo "== guard-fired & adversarial stdin (string forms) =="
for c in 'git push' 'git push --force origin HEAD' 'git push origin dev' 'git -C . push' 'sh -c "git push"' 'env git push' \
         'nohup git push &' 'python3 -c "import subprocess;subprocess.run([\"git\",\"push\"])"' \
         'gh pr merge 1' 'gh api -X POST repos/o/r/pulls' 'gh auth status' 'git pull' \
         'git merge origin/main' 'git rebase origin/main' 'git reset --hard HEAD~1' \
         'git clean -fdx' 'rm -rf build'; do
  probe_cmd block "blocked: $c" "$c"
done
probe_cmd block "blocked: alternate-worktree commit" 'git -C /tmp/linked-dev commit -m bad'
probe_cmd block "blocked: alternate-git-dir merge" 'git --git-dir=/tmp/linked-flow/.git merge feature'
probe_cmd allow "control: local merge feature-x" 'git merge feature-x'
probe_cmd allow "control: local rebase main"     'git rebase main'
probe_cmd allow "control: rebase origin/dev"     'git rebase origin/dev'
probe_cmd allow "control: current-branch push"   'git push -u origin HEAD'
probe_cmd allow "control: lease push"            'git push --force-with-lease origin HEAD'
probe_cmd allow "control: PR read"               'gh pr view 1'
probe_cmd allow "control: PR create to dev"      'gh pr create --base dev --title x --body-file /tmp/body'
set_policy_branch group/g0-operator-surface
probe_cmd block "blocked: group history rewrite"   'git rebase origin/flow'
probe_cmd block "blocked: group local rewrite"     'git rebase flow'
probe_cmd block "blocked: group lease rewrite"     'git push --force-with-lease origin HEAD'
probe_cmd allow "control: group PR to flow"       'gh pr create --base flow --head group/g0-operator-surface --title x --body y'
probe_cmd block "blocked: group PR skips flow"     'gh pr create --base dev --head group/g0-operator-surface --title x --body y'
set_policy_branch slice/group/g0-operator-surface/cli
probe_cmd block "blocked: group slice history rewrite" 'git rebase origin/group/g0-operator-surface'
probe_cmd block "blocked: group slice sibling base" 'git rebase origin/group/g1-contract-growth'
set_policy_branch flow
probe_cmd allow "control: flow final PR"            'gh pr create --base dev --head flow --title x --body y'
probe_cmd block "blocked: flow push"                 'git push origin HEAD'
set_policy_branch work/demo
probe_cmd block "blocked: workstream history rewrite" 'git rebase origin/dev'
probe_cmd block "blocked: workstream helper bypass" 'git merge refs/heads/slice/demo/one'
probe_cmd block "blocked: workstream lease rewrite" 'git push --force-with-lease origin HEAD'
set_policy_branch agent/test/policy

echo "== shim adversarial (variable indirection — argv level) =="
if [ -x tools/bin/git ]; then
  shim_work="$policy_git_work/shim"
  shim_bin="$shim_work/bin"
  shim_tools="$shim_work/tools"
  if ! mkdir -p "$shim_bin" "$shim_tools"; then
    printf 'INFRA policy verification cannot create isolated shim state\n' >&2
    exit 125
  fi
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [ "${1:-}" = symbolic-ref ]; then echo "${AGENT_LAB_SHIM_BRANCH:-agent/test/guard}"; exit 0; fi' \
    'printf "REAL-GIT %s\n" "$*"' > "$shim_bin/git"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "REAL-GH %s\n" "$*"' > "$shim_bin/gh"
  chmod +x "$shim_bin/git" "$shim_bin/gh"
  sed "s#/usr/bin/git#$shim_bin/git#" tools/bin/git > "$shim_tools/git"
  sed -e "s#/usr/bin/gh#$shim_bin/gh#" -e "s#/usr/bin/git#$shim_bin/git#" \
    tools/bin/gh > "$shim_tools/gh"
  chmod +x "$shim_tools/git" "$shim_tools/gh"
  for c in 'g=push; git $g' 'm=merge; git $m origin/main'; do
    rc=0; out="$(PATH="$shim_tools:$shim_bin:/usr/bin:/bin" bash -c "$c" 2>&1)" || rc=$?
    { [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'BLOCKED by agent-lab policy'; } \
      && pass "shim blocks: $c" || fail "shim should block: $c (rc=$rc)"
  done
  out="$(PATH="$shim_tools:$shim_bin:/usr/bin:/bin" git push -u origin HEAD 2>&1 || true)"
  printf '%s' "$out" | grep -q '^REAL-GIT push -u origin HEAD$' \
    && pass "git shim allows scoped push" || fail "git shim blocked scoped push"
  out="$(PATH="$shim_tools:$shim_bin:/usr/bin:/bin" gh pr create --base dev --title x --body-file /tmp/body 2>&1 || true)"
  printf '%s' "$out" | grep -q '^REAL-GH pr create --base dev' \
    && pass "gh shim allows PR creation to dev" || fail "gh shim blocked scoped PR creation"
  out="$(PATH="$shim_tools:$shim_bin:/usr/bin:/bin" gh run view 123 --log 2>&1 || true)"
  printf '%s' "$out" | grep -q '^REAL-GH run view 123 --log$' \
    && pass "gh shim allows read-only Actions logs" || fail "gh shim blocked Actions logs"
  rc=0; PATH="$shim_tools:$shim_bin:/usr/bin:/bin" gh run rerun 123 --failed >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] && pass "gh shim blocks Actions mutation" || fail "gh shim allowed Actions mutation"
  rc=0; PATH="$shim_tools:$shim_bin:/usr/bin:/bin" gh -R uscient/agent-lab pr merge 1 >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] && pass "gh shim blocks PR mutation after global options" || fail "gh shim missed PR mutation after global options"
  rc=0; PATH="$shim_tools:$shim_bin:/usr/bin:/bin" gh -R other/repo pr create --base dev >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] && pass "gh shim blocks cross-repository PR creation" || fail "gh shim allowed cross-repository PR creation"
  rc=0; PATH="$shim_tools:$shim_bin:/usr/bin:/bin" gh auth status >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] && pass "gh shim blocks authentication access" || fail "gh shim should block auth access"
  rc=0
  AGENT_LAB_SHIM_BRANCH=group/g0-operator-surface \
    PATH="$shim_tools:$shim_bin:/usr/bin:/bin" git rebase origin/flow >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] && pass "git shim blocks group history rewrite" || fail "git shim allowed group history rewrite"
  rc=0
  AGENT_LAB_SHIM_BRANCH=slice/group/g0-operator-surface/cli \
    PATH="$shim_tools:$shim_bin:/usr/bin:/bin" git push --force-with-lease origin HEAD >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] && pass "git shim blocks program-slice force update" || fail "git shim allowed program-slice force update"
  out="$(AGENT_LAB_SHIM_BRANCH=slice/group/g0-operator-surface/cli \
    PATH="$shim_tools:$shim_bin:/usr/bin:/bin" gh pr create \
      --base group/g0-operator-surface --title x --body y 2>&1 || true)"
  printf '%s' "$out" | grep -q '^REAL-GH pr create --base group/g0-operator-surface' \
    && pass "gh shim allows matching group-slice PR" || fail "gh shim blocked matching group-slice PR"
  rc=0
  AGENT_LAB_SHIM_BRANCH=flow PATH="$shim_tools:$shim_bin:/usr/bin:/bin" \
    git push origin HEAD >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] && pass "git shim blocks protected flow push" || fail "git shim allowed protected flow push"
  rc=0
  AGENT_LAB_SHIM_BRANCH=agent/test/guard PATH="$shim_tools:$shim_bin:/usr/bin:/bin" \
    git -C /tmp/linked-dev commit -m bad >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] && pass "git shim blocks alternate-worktree mutation" || fail "git shim allowed alternate-worktree mutation"
  rc=0
  AGENT_LAB_SHIM_BRANCH=work/demo PATH="$shim_tools:$shim_bin:/usr/bin:/bin" \
    git merge refs/heads/slice/demo/one >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] && pass "git shim blocks alternate slice-ref integration" || fail "git shim allowed alternate slice-ref integration"
else
  skip "tools/bin/git shim missing"
fi

echo "== protected-path edit backstop =="
printf '{"tool_name":"Edit","tool_input":{"file_path":"policy/deny.patterns"}}' \
  | env -u AGENT_LAB_MAINTENANCE "$guard" >/dev/null 2>&1 && fail "policy edit not blocked" || pass "policy edit blocked (no maint)"
printf '{"tool_name":"Edit","tool_input":{"file_path":"policy/deny.patterns"}}' \
  | env AGENT_LAB_MAINTENANCE=1 "$guard" >/dev/null 2>&1 && pass "policy edit allowed (maint=1)" || fail "maint=1 did not allow policy edit"

echo "== Codex PermissionRequest approver =="
if [ -x tools/codex-permission-request.sh ]; then
  appr() {
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')" \
      | env -u GIT_WORK_TREE -u GIT_COMMON_DIR GIT_DIR="$policy_git_dir" \
          tools/codex-permission-request.sh 2>/dev/null
  }
  appr 'git commit -m x' | grep -q '"behavior": *"allow"' && pass "approver allows commit" || fail "approver should allow commit"
  appr 'git push -u origin HEAD' | grep -q '"behavior": *"allow"' && pass "approver allows scoped push" || fail "approver should allow scoped push"
  appr 'git push origin dev' | grep -q '"behavior": *"deny"' && pass "approver denies protected push" || fail "approver should deny protected push"
else
  skip "tools/codex-permission-request.sh not built yet"
fi

echo "== generator: idempotent + valid =="
if [ -x tools/render-adapters.sh ]; then
  jq -e . .claude/settings.json >/dev/null 2>&1 && pass "Claude settings.json valid JSON" || fail "Claude settings.json invalid JSON"
  if bash tests/agent/render-adapters-idempotence.sh >"$policy_render_out" 2>&1; then
    pass "generated adapters are idempotent"
  else
    fail "generated adapters drifted"
    sed 's/^/  /' "$policy_render_out"
  fi
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

echo "== authority: AGENTS.md is complete and singular =="
grep -q '^## Authority$' AGENTS.md \
  && pass "AGENTS.md defines authority" || fail "AGENTS.md lacks authority section"
grep -q 'sole operating-policy source' AGENTS.md \
  && pass "AGENTS.md declares one operating-policy source" || fail "AGENTS.md lacks sole-source declaration"

echo "== SessionStart: protected branches leave from dev =="
boot_work="$policy_git_work/boot"
boot_repo="$boot_work/repo"
if ! mkdir -p "$boot_repo/tools" ||
   ! cp tools/session-bootstrap.sh "$boot_repo/tools/session-bootstrap.sh" ||
   ! git -C "$boot_repo" init -q ||
   ! git -C "$boot_repo" -c user.name=test -c user.email=test@example.invalid \
       commit --allow-empty -qm base ||
   ! git -C "$boot_repo" branch -M dev ||
   ! git -C "$boot_repo" update-ref refs/remotes/origin/dev HEAD; then
  printf 'INFRA policy verification cannot initialize isolated bootstrap state\n' >&2
  exit 125
fi
if (cd "$boot_repo" && AGENT_LAB_TASK_SLUG=policy-probe bash tools/session-bootstrap.sh test >/dev/null 2>&1) \
  && [ "$(git -C "$boot_repo" branch --show-current)" = agent/test/policy-probe ] \
  && git -C "$boot_repo" merge-base --is-ancestor refs/remotes/origin/dev HEAD; then
  pass "SessionStart leaves dev on an origin/dev-based work branch"
else
  fail "SessionStart did not create the required origin/dev-based work branch"
fi
printf '\nSUMMARY pass=%s fail=%s skip=%s\n' "$P" "$F" "$S"
[ "$F" -eq 0 ] && [ "$S" -eq 0 ]
