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
  out="$(PATH="$shim_tools:$shim_bin:/usr/bin:/bin" gh run list --repo uscient/agent-lab 2>&1 || true)"
  printf '%s' "$out" | grep -q '^REAL-GH run list --repo uscient/agent-lab$' \
    && pass "gh shim allows exact-repo Actions reads" || fail "gh shim blocked exact-repo Actions reads"
  out="$(PATH="$shim_tools:$shim_bin:/usr/bin:/bin" gh pr list --repo uscient/agent-lab 2>&1 || true)"
  printf '%s' "$out" | grep -q '^REAL-GH pr list --repo uscient/agent-lab$' \
    && pass "gh shim allows exact-repo PR reads" || fail "gh shim blocked exact-repo PR reads"
  out="$(PATH="$shim_tools:$shim_bin:/usr/bin:/bin" gh api --method GET repos/uscient/agent-lab/branches/flow 2>&1 || true)"
  printf '%s' "$out" | grep -q '^REAL-GH api --method GET repos/uscient/agent-lab/branches/flow$' \
    && pass "gh shim allows scoped API GET" || fail "gh shim blocked scoped API GET"
  rc=0; PATH="$shim_tools:$shim_bin:/usr/bin:/bin" gh run rerun 123 --failed >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] && pass "gh shim blocks Actions mutation" || fail "gh shim allowed Actions mutation"
  rc=0; PATH="$shim_tools:$shim_bin:/usr/bin:/bin" gh api -X POST repos/uscient/agent-lab/issues >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] && pass "gh shim blocks API mutation" || fail "gh shim allowed API mutation"
  rc=0; PATH="$shim_tools:$shim_bin:/usr/bin:/bin" gh api repos/other/repo/branches/main >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] && pass "gh shim blocks cross-repo API GET" || fail "gh shim allowed cross-repo API GET"
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
  grok_deny="$(sed -n '/^deny = \[/,/^\]/p' .grok/config.toml)"
  grok_allow="$(sed -n '/^allow = \[/,/^\]/p' .grok/config.toml)"
  for family in run api; do
    printf '%s\n' "$grok_allow" | grep -Fq "Bash(gh $family*)" \
      && ! printf '%s\n' "$grok_deny" | grep -Fq "Bash(gh $family*)" \
      && pass "Grok native rules allow guarded gh $family without an overriding deny" \
      || fail "Grok native rules contradict guarded gh $family access"
    jq -e --arg rule "Bash(gh $family:*)" \
      '(.permissions.allow | index($rule)) != null and (.permissions.deny | index($rule)) == null' \
      .claude/settings.json >/dev/null \
      && pass "Claude native rules allow guarded gh $family without an overriding deny" \
      || fail "Claude native rules contradict guarded gh $family access"
    grep -Fq "pattern = [\"gh\", \"$family\"], decision = \"allow\"" .codex/rules/agent-lab.rules \
      && ! grep -Fq "pattern = [\"gh\", \"$family\"], decision = \"forbidden\"" .codex/rules/agent-lab.rules \
      && pass "Codex native rules allow guarded gh $family without an overriding deny" \
      || fail "Codex native rules contradict guarded gh $family access"
  done
  if python3 - <<'PY'
import json
import re
import tomllib
from pathlib import Path

def bash_head(rule):
    if not rule.startswith("Bash("):
        return None
    return rule[5:-1].removesuffix(":*").removesuffix("*").strip()

def exact_conflicts(allow, deny):
    allowed = {head for rule in allow if (head := bash_head(rule))}
    denied = {head for rule in deny if (head := bash_head(rule))}
    return sorted(allowed & denied)

claude = json.loads(Path(".claude/settings.json").read_text())["permissions"]
grok = tomllib.loads(Path(".grok/config.toml").read_text())["permission"]
conflicts = {
    "Claude": exact_conflicts(claude["allow"], claude["deny"]),
    "Grok": exact_conflicts(grok["allow"], grok["deny"]),
}
rules = Path(".codex/rules/agent-lab.rules").read_text().splitlines()
codex = {"allow": set(), "forbidden": set()}
for line in rules:
    match = re.search(r'pattern = \[(.*?)\], decision = "(allow|forbidden)"', line)
    if match:
        codex[match.group(2)].add(" ".join(re.findall(r'"([^"]+)"', match.group(1))))
conflicts["Codex"] = sorted(codex["allow"] & codex["forbidden"])
for client, found in conflicts.items():
    if found:
        print(f"{client}: {', '.join(found)}")
raise SystemExit(1 if any(conflicts.values()) else 0)
PY
  then
    pass "generated adapters contain no exact allow/deny contradictions"
  else
    fail "generated adapters contain exact allow/deny contradictions"
  fi
  if python3 - <<'PY'
import copy
import json
import re
import tomllib
from pathlib import Path

claude = json.loads(Path(".claude/settings.json").read_text())["permissions"]
grok = tomllib.loads(Path(".grok/config.toml").read_text())["permission"]
codex_lines = Path(".codex/rules/agent-lab.rules").read_text().splitlines()

def cached_command_denials(claude_policy, grok_policy, codex_policy):
    found = []
    found.extend(f"Claude:{rule}" for rule in claude_policy["deny"] if rule.startswith("Bash("))
    found.extend(f"Grok:{rule}" for rule in grok_policy["deny"] if rule.startswith("Bash("))
    found.extend(
        f"Codex:{line.strip()}"
        for line in codex_policy
        if re.search(r'decision = "forbidden"', line)
    )
    return found

actual = cached_command_denials(claude, grok, codex_lines)
if actual:
    print("\n".join(actual))
    raise SystemExit(1)

# Adversarial mutation: every client's old-style cached deny must be detected.
mutated_claude = copy.deepcopy(claude)
mutated_claude["deny"].append("Bash(gh api:*)")
mutated_grok = copy.deepcopy(grok)
mutated_grok["deny"].append("Bash(gh api*)")
mutated_codex = [*codex_lines, 'prefix_rule(pattern = ["gh", "api"], decision = "forbidden")']
for name, candidate in {
    "Claude": cached_command_denials(mutated_claude, grok, codex_lines),
    "Grok": cached_command_denials(claude, mutated_grok, codex_lines),
    "Codex": cached_command_denials(claude, grok, mutated_codex),
}.items():
    if not any(item.startswith(f"{name}:") for item in candidate):
        raise SystemExit(f"mutation escaped cached-deny detection for {name}")
PY
  then
    pass "native adapters delegate command denial to the live guard and reject cached-deny mutations"
  else
    fail "native adapters cache command denials that can outlive the checkout"
  fi
else
  skip "tools/render-adapters.sh missing"
fi

echo "== wiring: PreToolUse hooks point at the one guard =="
for f in .claude/settings.json .codex/hooks.json .grok/hooks/git-policy.json; do
  if [ -f "$f" ]; then
    hook_commands="$(jq -r '.hooks.PreToolUse[].hooks[].command' "$f" 2>/dev/null || true)"
    hook_cmd="${hook_commands%%$'\n'*}"
    hook_ok=1
    [ -n "$hook_cmd" ] || hook_ok=0
    [ "$(printf '%s\n' "$hook_commands" | sort -u | wc -l)" -eq 1 ] || hook_ok=0

    rc=0
    printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git status"}}' \
      | (cd "$root" && /bin/bash -c "$hook_cmd") >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] || hook_ok=0

    rc=0
    hook_out="$(
      printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git push origin dev"}}' \
        | (cd "$root" && /bin/bash -c "$hook_cmd") 2>&1
    )" || rc=$?
    [ "$rc" -eq 2 ] && printf '%s' "$hook_out" | grep -q 'BLOCKED by agent-lab policy' || hook_ok=0

    [ "$hook_ok" -eq 1 ] \
      && pass "wiring: $f invokes one live guard for allow and block cases" \
      || fail "wiring: $f is missing, inconsistent, or does not invoke the guard"
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
