#!/usr/bin/env bash
# Unit tests for tools/pretooluse-guard.sh (the PreToolUse guard) — pure shell, no Docker.
# This is SEPARATE from tests/guard/cases.sh, which tests scripts/lib/guard.sh (project/secrets
# vetting). Run: bash tests/guard/pretooluse-cases.sh
set -uo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
# GUARD_OVERRIDE lets maintenance verify a candidate guard (e.g. tmp/guard-new.sh) before swap-in.
guard="${GUARD_OVERRIDE:-$repo_root/tools/pretooluse-guard.sh}"

# The commit backstop reads the current branch from Git. Give it an isolated branch context so
# allow-cases do not depend on whether this suite runs from a working branch, dev, or master.
infra() { printf 'INFRA %s\n' "$1" >&2; exit 125; }
guard_git_work="$(mktemp -d)" || infra "could not create guard Git fixture"
guard_git_repo="$guard_git_work/repo"
guard_tmp_link="/tmp/agent-lab-guard-link-$$"
cleanup() {
  find "$guard_git_work" -depth -delete >/dev/null 2>&1 || true
  find "$guard_tmp_link" -maxdepth 0 -delete >/dev/null 2>&1 || true
}
trap cleanup EXIT
env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git init -q "$guard_git_repo" \
  || infra "could not initialize guard Git fixture"
guard_git_dir="$guard_git_repo/.git"
set_guard_branch() {
  git --git-dir="$guard_git_dir" symbolic-ref HEAD "refs/heads/$1" \
    || infra "could not select guard test branch $1"
}
set_guard_branch agent/test/guard

probe_bin="$guard_git_work/process-probe-bin"
probe_log="$guard_git_work/process-probe.log"
mkdir -p "$probe_bin"
cat > "$probe_bin/probe" <<'EOF'
#!/usr/bin/env bash
name="${0##*/}"
printf '%s\n' "$name" >> "$AGENT_LAB_PROCESS_PROBE_LOG"
case "$name" in
  git) exec "$AGENT_LAB_REAL_GIT" "$@" ;;
  grep) exec "$AGENT_LAB_REAL_GREP" "$@" ;;
  sed) exec "$AGENT_LAB_REAL_SED" "$@" ;;
  *) exit 127 ;;
esac
EOF
chmod +x "$probe_bin/probe"
ln -s probe "$probe_bin/git"
ln -s probe "$probe_bin/grep"
ln -s probe "$probe_bin/sed"
ln -s probe "$probe_bin/python3"
real_git="$(command -v git)"
real_grep="$(command -v grep)"
real_sed="$(command -v sed)"

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }
_check() {
  local exp="$1" name="$2" rc="$3"
  if [ "$exp" = block ]; then
    [ "$rc" -eq 2 ] && pass "$name" || fail "$name (expected BLOCK rc=2, got $rc)"
  else
    [ "$rc" -eq 0 ] && pass "$name" || fail "$name (expected ALLOW rc=0, got $rc)"
  fi
}
# expect_cmd <block|allow> <name> <command>   (AGENT_LAB_MAINTENANCE explicitly unset)
expect_cmd() {
  local exp="$1" name="$2" cmd="$3" rc=0
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$cmd" '$c')" \
    | env -u AGENT_LAB_MAINTENANCE -u GIT_WORK_TREE -u GIT_COMMON_DIR \
        GIT_DIR="$guard_git_dir" "$guard" >/dev/null 2>&1 || rc=$?
  _check "$exp" "$name" "$rc"
}
expect_cmd_env() {
  local exp="$1" name="$2" key="$3" value="$4" cmd="$5" rc=0
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$cmd" '$c')" \
    | env -u AGENT_LAB_MAINTENANCE -u GIT_WORK_TREE -u GIT_COMMON_DIR \
        "$key=$value" GIT_DIR="$guard_git_dir" "$guard" >/dev/null 2>&1 || rc=$?
  _check "$exp" "$name" "$rc"
}
# expect_edit <block|allow> <name> <file_path> [maint]
expect_edit() {
  local exp="$1" name="$2" fp="$3" maint="${4:-}" rc=0
  printf '{"tool_name":"Edit","tool_input":{"file_path":%s}}' "$(jq -Rn --arg c "$fp" '$c')" \
    | env AGENT_LAB_MAINTENANCE="$maint" "$guard" >/dev/null 2>&1 || rc=$?
  _check "$exp" "$name" "$rc"
}
expect_read() {
  local exp="$1" name="$2" fp="$3" rc=0
  printf '{"tool_name":"Read","tool_input":{"file_path":%s}}' "$(jq -Rn --arg c "$fp" '$c')" \
    | env -u AGENT_LAB_MAINTENANCE "$guard" >/dev/null 2>&1 || rc=$?
  _check "$exp" "$name" "$rc"
}
expect_payload() {
  local exp="$1" name="$2" payload="$3" maint="${4:-}" rc=0
  printf '%s' "$payload" \
    | env AGENT_LAB_MAINTENANCE="$maint" "$guard" >/dev/null 2>&1 || rc=$?
  _check "$exp" "$name" "$rc"
}
expect_socket_payload() {
  local exp="$1" name="$2" payload="$3" rc=0
  /usr/bin/python3 -I -S - "$guard" "$payload" "$guard_git_dir" <<'PY' || rc=$?
import os
import socket
import subprocess
import sys

guard, payload, git_dir = sys.argv[1:]
left, right = socket.socketpair()
env = os.environ.copy()
env.pop("AGENT_LAB_MAINTENANCE", None)
env.pop("GIT_WORK_TREE", None)
env.pop("GIT_COMMON_DIR", None)
env["GIT_DIR"] = git_dir
process = subprocess.Popen(
    [guard],
    stdin=right,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    env=env,
)
right.close()
left.sendall(payload.encode())
left.shutdown(socket.SHUT_WR)
left.close()
raise SystemExit(process.wait())
PY
  _check "$exp" "$name" "$rc"
}
expect_file_content() {
  local exp="$1" name="$2" tool="$3" fp="$4" body="$5" payload
  payload="$(
    jq -cn --arg tool "$tool" --arg fp "$fp" --arg body "$body" \
      '{toolName:$tool,toolInput:{filePath:$fp,content:$body}}'
  )" || infra "could not construct file-tool payload"
  expect_payload "$exp" "$name" "$payload"
}
expect_large_file_content() {
  local exp="$1" name="$2" fp="$3" body="$4" rc=0
  jq -cn --arg fp "$fp" --arg body "$body" \
    '{toolName:"Write",toolInput:{filePath:$fp,content:($body + ("x" * 131072))}}' \
    | env -u AGENT_LAB_MAINTENANCE "$guard" >/dev/null 2>&1 || rc=$?
  _check "$exp" "$name" "$rc"
}
expect_no_eager_helpers() {
  local name="$1" payload="$2" rc=0
  : > "$probe_log"
  printf '%s' "$payload" \
    | env -u AGENT_LAB_MAINTENANCE -u GIT_WORK_TREE -u GIT_COMMON_DIR \
        PATH="$probe_bin:$PATH" GIT_DIR="$guard_git_dir" \
        AGENT_LAB_PROCESS_PROBE_LOG="$probe_log" \
        AGENT_LAB_REAL_GIT="$real_git" AGENT_LAB_REAL_GREP="$real_grep" \
        AGENT_LAB_REAL_SED="$real_sed" "$guard" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$probe_log" ]; then
    pass "$name"
  else
    fail "$name (rc=$rc eager=$(tr '\n' ',' < "$probe_log"))"
  fi
}
expect_inherited_nocasematch_allow() {
  local name="$1" cmd="$2" rc=0
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$cmd" '$c')" \
    | env BASHOPTS=nocasematch GIT_DIR="$guard_git_dir" \
        bash "$guard" >/dev/null 2>&1 || rc=$?
  _check allow "$name" "$rc"
}
expect_hostile_python_block() {
  local name="$1" cmd="$2" rc=0 seen=""
  : > "$probe_log"
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$cmd" '$c')" \
    | env -u AGENT_LAB_MAINTENANCE -u GIT_WORK_TREE -u GIT_COMMON_DIR \
        PATH="$probe_bin:$PATH" GIT_DIR="$guard_git_dir" \
        AGENT_LAB_PROCESS_PROBE_LOG="$probe_log" \
        AGENT_LAB_REAL_GIT="$real_git" AGENT_LAB_REAL_GREP="$real_grep" \
        AGENT_LAB_REAL_SED="$real_sed" "$guard" >/dev/null 2>&1 || rc=$?
  seen="$(tr '\n' ',' < "$probe_log")"
  if [ "$rc" -eq 2 ] && [[ "$seen" != *python3* ]]; then
    pass "$name"
  else
    fail "$name (rc=$rc invoked=$seen)"
  fi
}

echo "== allow: local work + git (commit inversion fixed; local merge/rebase preserved) =="
expect_cmd allow "git commit"                 'git commit -m "wip"'
expect_cmd allow "git add -A"                 'git add -A'
expect_cmd allow "git fetch"                  'git fetch origin'
expect_cmd allow "git switch -c"              'git switch -c agent/claude/x'
expect_cmd allow "local merge (branch)"       'git merge feature-x'
expect_cmd allow "local rebase (branch)"      'git rebase main'
expect_cmd allow "rebase on origin/dev"        'git rebase origin/dev'
expect_cmd allow "push current branch"         'git push -u origin HEAD'
expect_cmd allow "lease push current branch"   'git push --force-with-lease origin agent/test/guard'
expect_cmd allow "PR list"                     'gh pr list --state open'
expect_cmd allow "PR view"                     'gh pr view 10'
expect_cmd allow "PR checks"                   'gh pr checks 10'
expect_cmd allow "Actions run list"             'gh run list --branch slice/demo/one'
expect_cmd allow "Actions run view"             'gh run view 123 --log'
expect_cmd allow "Actions run watch"            'gh run watch 123 --exit-status'
expect_cmd allow "PR read with exact repo"       'gh pr list --repo uscient/agent-lab --state open'
expect_cmd allow "PR read with exact global repo" 'gh --repo uscient/agent-lab pr view 10'
expect_cmd allow "Actions read with exact repo"  'gh run list --repo uscient/agent-lab --limit 10'
expect_cmd allow "API implicit GET for repo"     'gh api repos/uscient/agent-lab/branches/flow'
expect_cmd allow "API explicit GET for repo"     'gh api --method GET repos/uscient/agent-lab/actions/runs --jq .total_count'
expect_cmd allow "API GET with quoted jq expression" \
  'gh api --method GET repos/uscient/agent-lab/pulls/52 --jq '\''.state + " " + .base.ref'\'''
expect_cmd allow "variable-driven repository PR read" \
  'pr=52; gh pr view $pr'
expect_cmd allow "PR create to dev"            'gh pr create --base dev --head agent/test/guard --title x --body-file /tmp/body'
expect_cmd allow "git branch -d (safe)"       'git branch -d old'
expect_cmd allow "run tests"                  './scripts/dev/test quick'
expect_cmd allow "lint"                       './scripts/dev/lint-scripts'
expect_cmd allow "verified Group PR readiness" './scripts/dev/workstream ready 55'
expect_cmd allow "verified intermediate merge" './scripts/dev/workstream merge 55'
expect_cmd allow "read a protected file"      'cat AGENTS.md'
expect_cmd allow "grep policy"                 'grep -r AGENTS.md policy/'
expect_cmd allow "read tracked environment example" 'cat .env.example'
expect_cmd block "read example-suffixed environment" 'cat .env.example.local'
expect_cmd block "read secrets environment example" 'cat secrets/.env.example'

echo "== allow: branch-derived flow/group/slice routes =="
set_guard_branch group/g0-operator-surface
expect_cmd allow "group PR targets flow"        'gh pr create --base flow --head group/g0-operator-surface --title x --body y'
expect_cmd block "group same-branch push"       'git push origin HEAD'
expect_cmd block "group direct commit"          'git commit -m "bypass slice PR"'
expect_cmd allow "group-sync helper route"      './scripts/dev/workstream group-sync'
set_guard_branch slice/group/g0-operator-surface/cli
expect_cmd allow "group slice PR matches parent" \
  'gh pr create --base group/g0-operator-surface --head slice/group/g0-operator-surface/cli --title x --body y'
set_guard_branch slice/demo/one
expect_cmd allow "legacy slice rebase matches parent" 'git rebase origin/work/demo'
expect_cmd allow "legacy slice PR matches parent" \
  'gh pr create --base work/demo --head slice/demo/one --title x --body y'
set_guard_branch flow
expect_cmd allow "flow final PR targets dev" \
  'gh pr create --base dev --head flow --title x --body y'
expect_cmd allow "read-only merge-base on flow" 'git merge-base origin/dev HEAD'
set_guard_branch agent/test/guard

echo "== deny: commit on protected branches (branch backstop) =="
for protected in dev flow master main; do
  set_guard_branch "$protected"
  expect_cmd block "git commit on $protected" 'git commit -m "wip"'
  expect_cmd block "git -C commit on $protected" 'git -C . commit -m "wip"'
  expect_cmd block "git global-option commit on $protected" 'git --no-pager commit -m "wip"'
done
printf '%040d\n' 0 > "$guard_git_dir/HEAD"
expect_cmd block "git commit on detached HEAD" 'git commit -m "wip"'
set_guard_branch agent/test/guard

echo "== deny: remote operations outside the scoped workflow =="
expect_cmd block "implicit push"               'git push'
expect_cmd block "push --force"               'git push --force'
expect_cmd block "push wrong remote"           'git push upstream HEAD'
expect_cmd block "push protected branch"       'git push origin dev'
expect_cmd block "push mismatched branch"      'git push origin another-branch'
expect_cmd block "push delete"                 'git push --delete origin old'
expect_cmd block "git -C . push"              'git -C . push'
expect_cmd block "git -C /tmp/x push"         'git -C /tmp/x push'
expect_cmd block "sh -c git push"             'sh -c "git push"'
expect_cmd block "bash -c spaced push"        'bash -c "git   push"'
expect_cmd block "env git push"               'env git push'
expect_cmd block "nohup git push"             'nohup git push &'
expect_cmd block "subprocess push"            'python3 -c "import subprocess;subprocess.run([\"git\",\"push\"])"'
expect_cmd block "pull"                        'git pull'
expect_cmd block "merge origin/main"          'git merge origin/main'
expect_cmd block "rebase origin/main"         'git rebase origin/main'
expect_cmd block "rebase upstream/dev"         'git rebase upstream/dev'
expect_cmd block "merge refs/remotes"         'git merge refs/remotes/origin/main'
expect_cmd block "git -C . merge origin"      'git -C . merge origin/main'
expect_cmd block "alternate-worktree commit"   'git -C /tmp/linked-dev commit -m bad'
expect_cmd block "alternate-git-dir merge"     'git --git-dir=/tmp/linked-flow/.git merge feature'
expect_cmd block "direct slice merge"           'git merge slice/demo/one'
expect_cmd block "PR create without base"       'gh pr create --title x --body y'
expect_cmd block "PR create wrong base"         'gh pr create --base main --title x --body y'
expect_cmd block "PR create wrong head"         'gh pr create --base dev --head other --title x --body y'
expect_cmd block "PR create for another repo"    'gh pr create -R other/repo --base dev --title x --body y'
expect_cmd block "PR create attached other repo" 'gh pr create -Rother/repo --base dev --title x --body y'
expect_cmd block "PR read from another repo"      'gh pr list --repo other/repo'
expect_cmd block "Actions read from another repo" 'gh run list --repo other/repo'
expect_cmd block "PR merge"                     'gh pr merge 10'
expect_cmd block "Actions run rerun"             'gh run rerun 123 --failed'
expect_cmd block "Actions run cancel"            'gh run cancel 123'
expect_cmd block "Actions workflow mutation"     'gh workflow run ci.yml'
expect_cmd block "PR edit"                      'gh pr edit 10 --title x'
expect_cmd block "gh api write"                 'gh api -X POST repos/o/r/pulls'
expect_cmd block "gh api implicit POST"         'gh api repos/o/r/issues -f title=x'
expect_cmd block "gh api repo write"            'gh api repos/uscient/agent-lab/issues -f title=x'
expect_cmd block "gh api repo delete"           'gh api --method DELETE repos/uscient/agent-lab/actions/runs/1'
expect_cmd block "gh api cross-repo GET"        'gh api repos/other/repo/branches/main'
expect_cmd block "gh api GraphQL"               'gh api graphql --method GET'
expect_cmd block "GitHub repo delete"           'gh repo delete uscient/agent-lab --yes'
expect_cmd block "absolute GitHub repo delete"  '/usr/bin/gh repo delete uscient/agent-lab --yes'
expect_cmd block "GitHub issue close"           'gh issue close 1'
expect_cmd block "GitHub global-option PR merge" 'gh --repo uscient/agent-lab pr merge 10'

echo "== deny: wrong flow/group/slice routes and invalid reserved names =="
set_guard_branch work/demo
expect_cmd block "workstream remote rebase cannot erase accepted merges" 'git rebase origin/dev'
expect_cmd block "workstream local rebase cannot erase accepted merges" 'git rebase dev'
expect_cmd block "workstream alternate slice ref cannot bypass helper" \
  'git merge refs/heads/slice/demo/one'
expect_cmd block "workstream commit-id merge cannot bypass helper" \
  'git merge 0123456789abcdef0123456789abcdef01234567'
expect_cmd block "workstream lease push cannot rewrite history" \
  'git push --force-with-lease origin HEAD'
set_guard_branch group/g0-operator-surface
expect_cmd block "group alternate slice ref cannot bypass helper" \
  'git merge refs/heads/slice/group/g0-operator-surface/cli'
expect_cmd block "group remote rebase cannot rewrite history" 'git rebase origin/flow'
expect_cmd block "group local rebase cannot rewrite history" 'git rebase flow'
expect_cmd block "group lease push cannot rewrite history" 'git push --force-with-lease origin HEAD'
expect_cmd block "group cannot rebase on dev"    'git rebase origin/dev'
expect_cmd block "group cannot PR to dev"         'gh pr create --base dev --head group/g0-operator-surface --title x --body y'
set_guard_branch slice/group/g0-operator-surface/cli
expect_cmd block "group slice remote rebase cannot rewrite history" \
  'git rebase origin/group/g0-operator-surface'
expect_cmd block "group slice local rebase cannot rewrite history" \
  'git rebase group/g0-operator-surface'
expect_cmd block "group slice lease push cannot rewrite history" \
  'git push --force-with-lease origin HEAD'
expect_cmd block "group slice cannot rebase on flow" 'git rebase origin/flow'
expect_cmd block "group slice cannot rebase sibling" 'git rebase origin/group/g1-contract-growth'
expect_cmd block "group slice cannot PR to flow" \
  'gh pr create --base flow --head slice/group/g0-operator-surface/cli --title x --body y'
set_guard_branch slice/demo/one
expect_cmd block "legacy slice cannot rebase on dev" 'git rebase origin/dev'
expect_cmd block "legacy slice cannot PR to dev" \
  'gh pr create --base dev --head slice/demo/one --title x --body y'
set_guard_branch flow
expect_cmd block "merge on protected flow"        'git merge group/g0-operator-surface'
expect_cmd block "rebase on protected flow"       'git rebase dev'
expect_cmd block "push from protected flow"        'git push origin HEAD'
set_guard_branch group/not-valid
expect_cmd block "invalid reserved group cannot push" 'git push origin HEAD'
expect_cmd block "invalid reserved group cannot create PR" \
  'gh pr create --base dev --head group/not-valid --title x --body y'
set_guard_branch group/g0-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
expect_cmd block "overlong reserved group cannot push" 'git push origin HEAD'
set_guard_branch agent/test/guard
expect_cmd block "GitHub hostname auth"          'gh --hostname github.com auth token'
expect_cmd block "GitHub auth access"           'gh auth status'
expect_cmd block "Git identity access"          'git config --get user.email'
expect_cmd block "Git config list"               'git config --list'
expect_cmd block "Git global-option config list" 'git --no-pager config --list'
expect_cmd block "Git remote config mutation"    'git config remote.origin.url https://example.invalid/repo'
expect_cmd block "Git credential access"         'git credential fill'
expect_cmd block "Git identity override"        'git -c user.email=other@example.test commit -m x'
expect_cmd block "compact Git identity override" 'git -cuser.email=other@example.test commit -m x'
expect_cmd block "Git config-env identity override" 'git --config-env=user.email=OTHER_EMAIL commit -m x'
expect_cmd block "Git author override"          'git commit --author "Other <other@example.test>" -m x'
expect_cmd block "Git author environment"       'GIT_AUTHOR_EMAIL=other@example.test git commit -m x'
expect_cmd block "git remote set-url"         'git remote set-url origin https://x'
expect_cmd block "git -C remote set-url"      'git -C . remote set-url origin https://x'
expect_cmd block "git remote set-branches"    'git remote set-branches origin dev'
expect_cmd block "GitHub credential file read" 'cat ~/.config/gh/hosts.yml'
expect_cmd block "Git config file read"         'cat ~/.gitconfig'
expect_cmd block "GitHub token environment read" 'printenv GH_TOKEN'

echo "== deny: destructive/integrity carve-out =="
expect_cmd block "reset --hard"               'git reset --hard HEAD~1'
expect_cmd block "git clean -fdx"             'git clean -fdx'
expect_cmd block "rm -rf"                      'rm -rf build'
expect_cmd block "rm -fr"                      'rm -fr build'
expect_cmd block "chmod -R 777"               'chmod -R 777 .'
expect_cmd block "chown -R"                    'chown -R root .'
expect_cmd block "sudo"                        'sudo apt-get install x'
expect_cmd block "sed -i"                      'sed -i s/a/b/ file'
expect_cmd block "rebase -i"                   'git rebase -i HEAD~3'
expect_cmd block "branch -D"                   'git branch -D feature'
expect_cmd block "filter-branch"               'git filter-branch --tree-filter x HEAD'

echo "== deny: containment hard-stops =="
expect_cmd block "docker.sock"                'docker run -v /var/run/docker.sock:/s img'
expect_cmd block "privileged"                 'docker run --privileged img'
expect_cmd block "host networking"            'docker run --network host img'
expect_cmd block "secret write"               'echo k >> secrets/key'
expect_cmd block ".env write"                 'echo x > .env'

echo "== protected-path edits (Edit/Write matcher) =="
expect_edit block "edit AGENTS.md (no maint)"        'AGENTS.md'
expect_edit block "edit guard (no maint)"            'tools/pretooluse-guard.sh'
expect_edit block "edit policy (no maint)"           'policy/deny.patterns'
expect_edit block "edit CI workflow (no maint)"      '.github/workflows/ci.yml'
expect_edit block "edit PR evidence template"        '.github/PULL_REQUEST_TEMPLATE.md'
expect_edit block "edit gate reducer (no maint)"     'scripts/dev/required-gates'
expect_edit block "edit gate oracle (no maint)"      'tests/dev/required-gates-cases.sh'
expect_edit block "edit fast manifest (no maint)"    'tests/security/fast.manifest'
expect_edit block "edit fast inventory (no maint)"   'tests/dev/security-gate-cases.sh'
expect_edit block "edit Docker manifest (no maint)"  'tests/security/docker.manifest'
expect_edit block "edit Docker inventory (no maint)" 'tests/dev/docker-harness-cases.sh'
expect_edit block "edit CI manifest (no maint)"      'tests/security/ci.manifest'
expect_edit block "edit CI inventory (no maint)"     'tests/dev/required-gates-cases.sh'
expect_edit block "edit .codex (no maint)"           '.codex/config.toml'
expect_edit block "edit Claude MCP registration"     '.mcp.json'
expect_edit block "edit Serena project config"       '.serena/project.yml'
expect_edit block "edit Serena Compose config"       'compose.serena.yaml'
expect_edit block "edit Serena image source"         'images/serena/Dockerfile'
expect_edit block "edit Serena launcher"             'scripts/serena-mcp'
expect_edit block "edit Serena pin constants"        'scripts/lib/serena.sh'
expect_edit block "edit Serena image entrypoint"     'tools/serena-entrypoint.sh'
expect_edit block "edit abs-path policy (no maint)"   "$repo_root/policy/deny.patterns"
expect_edit block "edit secret file"                  'secrets/token'
expect_edit block "edit environment file"             '.env'
expect_read block "read nested environment file"      'fixtures/app/.env.local'
expect_read allow "read tracked environment example"   '.env.example'
expect_read block "read example-suffixed environment"  '.env.example.local'
expect_read block "read example under secrets"         'secrets/.env.example'
expect_read block "read nested private key"           'fixtures/app/client.key'
expect_read block "read GitHub credential file"       '/home/agent/.config/gh/hosts.yml'
expect_read allow "read normal source file"           'tools/validate.sh'
expect_edit allow "edit AGENTS.md (maint=1)"         'AGENTS.md' 1
expect_edit allow "edit Docker inventory (maint=1)"  'tests/dev/docker-harness-cases.sh' 1
expect_edit allow "edit PR evidence template (maint=1)" '.github/PULL_REQUEST_TEMPLATE.md' 1
expect_edit allow "edit .grok (maint=1)"             '.grok/config.toml' 1
expect_edit block "edit repo .grok hooks (no maint)" '.grok/hooks/pretooluse.sh'
expect_edit block "edit abs repo .grok (no maint)"   "$repo_root/.grok/hooks/pretooluse.sh"
expect_edit allow "host .grok session path is not a rail" \
  "${HOME:-/home/work}/.grok/sessions/agent-lab-guard-fixture/plan.md"
expect_file_content allow "Write host .grok session path is not a rail" \
  Write "${HOME:-/home/work}/.grok/sessions/agent-lab-guard-fixture/plan.md" \
  $'session plan notes\nnot a repository rail\n'
expect_edit allow "edit normal file"                 'scripts/dev/brief'
expect_edit allow "edit README"                      'README.md'

echo "== Serena vendor hook envelopes and semantic mutators =="
expect_payload allow "Codex snake-case Serena source edit" \
  '{"tool_name":"mcp__serena__replace_symbol_body","tool_input":{"relative_path":"scripts/lib/config.sh"}}'
expect_payload block "Codex snake-case Serena rail edit" \
  '{"tool_name":"mcp__serena__insert_before_symbol","tool_input":{"relative_path":"AGENTS.md"}}'
expect_payload allow "Codex snake-case Serena maintenance edit" \
  '{"tool_name":"mcp__serena__insert_after_symbol","tool_input":{"relative_path":"AGENTS.md"}}' 1
expect_payload block "Claude camel-case Serena rail edit" \
  '{"toolName":"mcp__serena__replace_symbol_body","toolInput":{"relativePath":".codex/config.toml"}}'
expect_payload allow "Claude camel-case Serena source edit" \
  '{"toolName":"mcp__serena__insert_after_symbol","toolInput":{"relativePath":"scripts/lib/config.sh"}}'
expect_payload block "Grok camel-case Serena rail edit" \
  '{"toolName":"serena__insert_before_symbol","toolInput":{"relativePath":"compose.serena.yaml"}}'
expect_payload allow "Grok snake-case Serena source edit" \
  '{"tool_name":"serena__replace_symbol_body","tool_input":{"relative_path":"scripts/lib/config.sh"}}'
expect_payload block "Serena secret edit remains forbidden in maintenance" \
  '{"toolName":"serena__insert_after_symbol","toolInput":{"relativePath":"secrets/token"}}' 1
expect_payload block "Serena mutator without path fails closed" \
  '{"tool_name":"mcp__serena__replace_symbol_body","tool_input":{"name_path":"x"}}'

echo "== shell mutation of rails (maintenance-gated) =="
expect_cmd block "append to AGENTS.md"        'echo x >> AGENTS.md'
expect_cmd block "tee into policy"            'echo x | tee policy/deny.patterns'
expect_cmd allow "read AGENTS.md (cat)"       'cat AGENTS.md'

echo "== false-positive fixes: data / non-write redirects (secret access remains blocked) =="
expect_cmd allow "ls rail, stderr->null"       'ls ~/.codex 2>/dev/null'
expect_cmd allow "cat rail, stderr->null"      'cat .claude/settings.json 2>/dev/null'
expect_cmd allow "execute Serena rail, stdout->null" './scripts/dev/serena-smoke >/dev/null'
expect_cmd allow "git status 2>&1"             'git status 2>&1'
expect_cmd block "cat .env, stderr->null"      'cat .env 2>/dev/null'
expect_cmd allow "msg mentions rail+verb"      'git commit -m "update policy/ and the guard"'
expect_cmd allow "msg mentions git push"       'git commit -m "block git push in the guard"'
expect_cmd allow "msg mentions pull"           'git commit -m "fix pull handling"'
expect_cmd allow "msg single-quoted rail"      "git commit -m 'tidy policy/ and the guard'"
expect_cmd allow "--message long form"         'git commit --message "discuss tee and rm in policy/"'
expect_cmd allow "search data names forge CLI" 'rg -n "gh" README.md'
expect_cmd allow "search alternation is data" 'rg -n "gh pr|gh run|gh api" README.md'
expect_cmd allow "compound read-only audit keeps search terms as data" \
  'git diff --check && git diff --stat && git status --short --branch && rg -n "git pull|gh api|gh auth|gh pr merge" tools/ tests/ || true'
expect_cmd allow "Git log plus policy search stays read-only" \
  'git log -1 --oneline && rg -n "gh api" tools/'
expect_cmd allow "Git diff can feed a policy search" \
  'git diff | rg "gh api"'
expect_cmd allow "tracked file list can feed a policy search" \
  'git ls-files | rg "gh api"'
expect_cmd allow "ripgrep file list can feed grep policy search" \
  'rg --files | grep "gh auth"'
expect_cmd allow "Git log data does not become an operation" \
  'git log --grep="git pull" && rg -n needle README.md'
expect_cmd allow "Git log data is safe without a second search" \
  'git log --grep="gh api" -5 --oneline'
expect_cmd allow "Git diff pickaxe data does not become an operation" \
  'git diff -G"git pull" -- .'
expect_cmd allow "newline-separated read audit stays usable" \
  $'git status --short\nrg -n "TODO" README.md || true'
expect_cmd allow "search pipeline may end with true" \
  'git ls-files | rg "secrets/" || true'
expect_cmd allow "grep pipeline may end with true" \
  'git diff | grep "gh api" || true'
expect_cmd allow "local read may precede a policy search" \
  $'ls\nrg -n "gh api" tools/ || true'
expect_cmd allow "assignment and local read may precede a policy search" \
  $'git status --short\ntarget=README.md; wc -l "$target"\nrg -n "gh api" tools/ || true'
expect_cmd allow "dynamic pattern is data after option terminator" \
  'pattern="gh api"; rg -n -- "$pattern" tools/ || true'
expect_cmd allow "search stdout may be discarded" \
  'rg -n "gh api|git pull" tools/ >/dev/null || true'
expect_cmd allow "search stderr may be discarded" \
  'rg -n "gh api|git pull" tools/ 2>/dev/null || true'
expect_cmd allow "multiple searches may each tolerate no matches" \
  $'grep -rnE "gh api|git pull" tools/ || true\nrg -n -g "*.sh" "gh api|git pull" tools/ || true'
expect_cmd allow "search output may feed a safe jq filter" \
  'rg -n "gh api" tools/ | jq -R .'
expect_cmd allow "Git no-pager read keeps log search data" \
  'git --no-pager log --grep="gh api" --oneline'
expect_cmd allow "security terms remain search data" \
  'rg -n "GITHUB_TOKEN|docker.sock|--privileged" tools/ tests/'
expect_cmd allow "environment filename remains search data" 'rg -n "\.env" tools/ tests/'
expect_cmd allow "secret directory name remains search data" 'rg -n "secrets/" tools/ tests/'
expect_cmd allow "quoted regex anchors remain search data" 'rg -n '\''GITHUB_TOKEN$'\'' tools/'
expect_cmd allow "unquoted trailing regex anchor remains search data" 'rg GITHUB_TOKEN$ tools/'
expect_cmd allow "trailing regex anchor works before true" 'rg -n "TODO$" README.md || true'
expect_cmd allow "option-shaped positional pattern remains data" 'rg -- --pre README.md'
expect_cmd allow "explicit option-shaped pattern remains data" 'rg -e --pre README.md'
expect_cmd allow "negative glob selector does not read the excluded file" 'rg -g "!.env" needle .'
expect_cmd allow "grep exclusion does not read the excluded file" 'grep --exclude=.env -R needle .'
expect_cmd allow "environment substring is an ordinary path" 'rg needle docs/.environment.md'
expect_cmd allow "env-like infix is an ordinary path" 'rg needle docs/my.env.notes'
expect_cmd allow "jq JSON property is not environment disclosure" 'jq -n '\''.env'\'''
expect_cmd allow "GitHub jq JSON property is not environment disclosure" \
  'gh api repos/uscient/agent-lab --jq .env'
expect_cmd allow "quoted regex quantifiers remain search data" 'rg -n '\''docker[.]sock{1}'\'' tools/'
expect_cmd allow "search data through read filter" 'rg -n "gh pr|gh run" README.md | head -n 20'
expect_cmd allow "grep search is data" 'grep -n "gh run" README.md'
expect_cmd allow "git grep search is data" 'git grep -n "gh api" -- README.md'
expect_cmd allow "rail read output to tmp"      'wc -l AGENTS.md > /tmp/agent-lab-rail-count'

hostile_note=$'AGENTS.md is authority\nNever run git pull\nA human may git merge a branch\nDo not invoke gh pr merge\n> quoted policy text'
expect_file_content allow "Write content is data, not a command" \
  Write "$guard_git_work/write-note.md" "$hostile_note"
expect_large_file_content allow "large Write content is data, not a command" \
  'proj/flow/_guard-large-write.md' "$hostile_note"
expect_file_content allow "lowercase write content is data, not a command" \
  write "$guard_git_work/write-note-lower.md" "$hostile_note"
expect_file_content block "lowercase write still protects rails" \
  write 'AGENTS.md' "$hostile_note"
expect_cmd allow "literal heredoc content is data, not a command" \
  $'cat > tmp/workbench-note.md <<\'NOTE\'\nAGENTS.md is authority\nNever run git pull\nA human may git merge a branch\nDo not invoke gh pr merge\n> quoted policy text\nNOTE'
expect_cmd allow "literal heredoc supports delimiter-first writes" \
  $'cat <<\'NOTE\' > proj/flow/_guard-large-write.md\nAGENTS.md is authority\nNever run git pull\nA human may git merge a branch\nDo not invoke gh pr merge\n> quoted policy text\nNOTE'
expect_cmd allow "literal Python writer content is data, not a command" \
  $'python3 -c \'doc = """AGENTS.md is authority\nNever run git pull\nA human may git merge a branch\nDo not invoke gh pr merge\n> quoted policy text"""\nopen("proj/flow/_guard-python-note.md", "w").write(doc)\''
expect_cmd allow "literal Python heredoc writer content is data, not a command" \
  $'python3 <<\'PY\'\ndoc = """AGENTS.md is authority\nNever run git pull\nA human may git merge a branch\nDo not invoke gh pr merge\n> quoted policy text"""\nopen("proj/flow/_guard-python-heredoc.md", "w").write(doc)\nPY'
expect_cmd allow "literal pathlib writer content is data, not a command" \
  $'python3 <<\'PY\'\nfrom pathlib import Path\ndoc = """AGENTS.md is authority\nNever run git pull\nA human may git merge a branch\nDo not invoke gh pr merge\n> quoted policy text"""\nPath("proj/flow/_guard-pathlib-note.md").write_text(doc, encoding="utf-8")\nPY'
expect_cmd allow "agent-realistic pathlib multi-section builder under proj" \
  $'mkdir -p proj && python3 <<\'PY\'\nfrom pathlib import Path\nsections = ["# Title", "", "## One", "body one", "## Two", "body two"]\nPath("proj/flow/_guard-multi-section.md").write_text("\\n".join(sections) + "\\n", encoding="utf-8")\nprint(Path("proj/flow/_guard-multi-section.md").stat().st_size)\nPY'
expect_cmd allow "unrelated variable name does not trigger search parsing" \
  'target=README.md; wc -l "$target"'
expect_cmd allow "safe jq variables are not environment disclosure" \
  'value=x; jq -n --arg value "$value" '\''$value'\'''
expect_cmd allow "local Git variable does not trigger search parsing" \
  'branch=feature; git merge "$branch"'
expect_cmd allow "search diagnostic may inspect its resolved executable" \
  'command -v rg; ls -l "$(command -v rg)"'
# Heredoc strip ends at the first line equal to the delimiter. Prefer Write/Edit for docs that
# embed delimiter tokens; collision remains fail-closed rather than weakening the strip.
expect_cmd block "heredoc delimiter collision remains fail-closed" \
  $'cat > proj/flow/_guard-collision.md <<\'NOTE\'\n# Example block\nNOTE\n# remaining body after early delimiter\ngh pr merge 1\nNOTE'

echo "== hot-path helpers are lazy =="
expect_no_eager_helpers "allowed command avoids git/grep/sed" \
  '{"tool_name":"Bash","tool_input":{"command":"git status"}}'
expect_no_eager_helpers "normal edit avoids git/grep/sed" \
  '{"tool_name":"Edit","tool_input":{"file_path":"README.md"}}'

echo "== command regexes remain linewise =="
expect_cmd block "second-line bulk environment" $'echo ok\nprintenv'
expect_cmd allow "newline does not join git push" $'git\npush'
expect_cmd allow "newline does not join destructive rm" $'rm\n-rf build'
expect_inherited_nocasematch_allow "inherited nocasematch stays case-sensitive" 'PRINTENV'

echo "== false-positive fixes: MUST STILL DENY (executable / substitution / real writes) =="
expect_cmd block "actual forge command"         'gh pr merge 1'
expect_cmd block "quoted absolute forge command" '"/usr/bin/gh" pr merge 1'
expect_cmd block "constructed forge command"    '"g""h" pr merge 1'
expect_cmd block "ANSI-constructed forge command" 'g$'\''h'\'' pr merge 1'
expect_cmd block "glob-constructed forge command" '/usr/bin/g[h] pr merge 1'
expect_cmd block "search then forge command"    'rg -n "gh" README.md; gh pr merge 1'
expect_cmd block "search preprocessor command"  'rg --pre "gh pr merge 1" needle README.md'
expect_cmd block "search hostname helper command" 'rg --hostname-bin=/usr/bin/true needle README.md'
expect_cmd block "git grep pager execution"     'git grep --open-files-in-pager=sh "gh pr merge"'
expect_cmd block "brace search preprocessor"    'rg --p{re,re}=gh needle README.md'
expect_cmd block "ANSI-constructed search preprocessor" 'rg --p$'\''re'\''=gh needle README.md'
expect_cmd block "brace search hostname helper" 'rg --host{name,name}-bin=/usr/bin/true needle README.md'
expect_cmd block "constructed preprocessor payload" 'rg --pre "g""h auth status" needle README.md'
expect_cmd block "constructed search preprocessor" 'rg --p"re" "gh auth status" needle README.md'
expect_cmd block "grouped pipe cannot hide a forge command" 'rg needle README.md |& gh pr merge 1'
expect_cmd block "grouped redirect cannot hide a rail write" 'rg needle README.md &> AGENTS.md'
expect_cmd block "short git-grep pager execution" 'git grep -Osh needle'
expect_cmd block "clustered git-grep pager execution" 'git grep -nOsh needle'
expect_cmd block "git-grep textconv execution" 'git grep --textconv needle'
expect_cmd block "abbreviated git-grep pager execution" 'git grep --open-files-in-p=sh needle'
expect_cmd block "abbreviated git-grep textconv execution" 'git grep --textc needle'
expect_cmd block "abbreviated git-grep external engine" 'git grep --ext-g=sh needle'
expect_cmd block "grep flag does not consume its pattern" 'grep -E needle .env'
expect_cmd block "ripgrep glob selector retains secret target" 'rg -uuu -g .env needle .'
expect_cmd block "grep include selector retains secret target" 'grep -R --include=.env needle .'
expect_cmd block "grep clustered regexp retains secret input" 'grep -nefoo .env'
expect_cmd block "grep clustered pattern file remains protected" 'grep -Ef.env README.md'
expect_cmd block "ripgrep clustered glob retains secret target" 'rg -ug.env needle .'
expect_cmd block "inspection chain cannot read environment files" 'rg -n needle .env && git status'
expect_cmd block "inspection chain cannot read secret directories" 'rg -n needle secrets/ | head'
expect_cmd block "inspection chain cannot read normalized secret directories" 'rg -n needle ./secrets'
expect_cmd block "inspection chain cannot read SSH directories" 'rg -n needle ~/.ssh'
expect_cmd block "file listing cannot inspect SSH directories" 'rg --files ~/.ssh'
expect_cmd block "file listing cannot inspect normalized secret directories" 'rg --files ./secrets'
expect_cmd block "file listing terminator retains SSH operand" 'rg --files -- ~/.ssh'
expect_cmd block "file listing terminator retains secret operand" 'rg --files -- ./secrets'
expect_cmd block "inspection cannot read parent-relative SSH path" 'rg needle ../.ssh'
expect_cmd block "inspection cannot read nested absolute SSH path" 'rg needle /tmp/audit-user/.ssh'
expect_cmd block "inspection cannot read HOME SSH path" 'rg needle $HOME/.ssh'
expect_cmd block "inspection cannot read nested netrc" 'rg needle /tmp/audit-user/.netrc'
expect_cmd block "inspection cannot read nested GitHub config" 'rg needle /tmp/audit-user/.config/gh'
expect_cmd block "ordinary read cannot inspect nested SSH material" 'cat /tmp/audit-user/.ssh/id_rsa'
expect_cmd block "ordinary read cannot inspect HOME SSH material" 'cat $HOME/.ssh/id_rsa'
expect_cmd block "Git object syntax cannot hide an environment file" 'git show HEAD:.env'
expect_cmd block "inspection chain cannot read a netrc" 'rg -n needle .netrc'
expect_cmd block "inspection chain cannot use an environment ignore file" 'rg --ignore-file=.env needle tools/'
expect_cmd block "inspection chain cannot use an environment pattern file" 'grep --file=.env needle tools/'
expect_cmd block "inspection filter cannot use an environment file list" 'rg needle README.md | wc --files0-from=.env'
expect_cmd block "inspection filter cannot consume an indirect file list" 'rg --files -0 ~/.ssh | sort --files0-from=-'
expect_cmd block "search filter cannot execute a compressor" 'rg -n needle README.md | sort --compress-program=sh'
expect_cmd block "search filter cannot write an output file" 'rg -n needle README.md | sort --output AGENTS.md'
expect_cmd block "search filter cannot write protected temporary files" 'rg -n needle README.md | sort -T policy/'
expect_cmd block "search filter cannot hide clustered output" 'rg -n needle README.md | sort -uoAGENTS.md'
expect_cmd block "search filter cannot hide clustered temporary path" 'rg -n needle README.md | sort -uTpolicy/'
expect_cmd block "constructed sort compressor is executable" 'rg needle README.md | sort --compress-pro{gram,gram}=sh'
expect_cmd block "search filter cannot use a positional output file" 'rg -n needle README.md | uniq README.md AGENTS.md'
expect_cmd block "standalone jq cannot disclose the environment" 'rg needle README.md; jq -n env'
expect_cmd block "quoted jq filter cannot disclose the environment" 'jq -n '\''env'\'''
expect_cmd block "jq ENV builtin cannot disclose the environment" 'jq -n '\''$ENV'\'''
expect_cmd block "jq options cannot hide environment disclosure" 'jq -n --arg x y env'
expect_cmd block "pipeline jq cannot disclose the environment" 'rg needle README.md | jq -n '\''env'\'''
expect_cmd block "API jq cannot disclose the environment" \
  'gh api repos/uscient/agent-lab --jq env'
expect_cmd block "PR jq cannot disclose the environment" \
  'gh pr list --repo uscient/agent-lab --json number --jq env'
expect_cmd block "command-local ripgrep config is rejected" \
  'RIPGREP_CONFIG_PATH=/tmp/rg.conf rg -n needle tools/'
expect_cmd block "env-wrapped ripgrep config is rejected" \
  'env RIPGREP_CONFIG_PATH=/tmp/rg.conf rg -n needle tools/'
expect_cmd block "Git external diff cannot hide in an inspection chain" \
  'GIT_EXTERNAL_DIFF=/usr/bin/true git diff && rg needle README.md'
expect_cmd block "abbreviated Git external diff cannot hide" \
  'git diff --ext-di && rg needle README.md'
expect_cmd block "abbreviated Git output cannot hide" \
  'git log --out=AGENTS.md && rg needle README.md'
expect_cmd block "environment split wrapper cannot inject a command" \
  'env -S "gh pr merge 1" rg needle README.md'
expect_cmd block "environment chdir wrapper cannot redirect inspection" \
  'env -C /tmp/audit-user/.ssh rg needle .'
expect_cmd block "jq interpolation cannot disclose environment" \
  'jq -n '\''"\(env.HOME)"'\'''
expect_cmd block "GitHub jq interpolation cannot disclose environment" \
  'gh api repos/uscient/agent-lab --jq '\''"\($ENV.HOME)"'\'''
expect_cmd block "piped environment listing remains bulk disclosure" 'env | head'
expect_cmd_env block "ambient ripgrep preprocessing is rejected" \
  RIPGREP_CONFIG_PATH "$guard_git_work/rg.conf" 'rg -n "gh api" tools/'
expect_cmd_env allow "explicit no-config defeats ambient ripgrep preprocessing" \
  RIPGREP_CONFIG_PATH "$guard_git_work/rg.conf" 'rg --no-config -n "gh api" tools/'
mkdir -p "$guard_git_work/pythonpath"
printf '%s\n' 'raise SystemExit(99)' > "$guard_git_work/pythonpath/sitecustomize.py"
expect_cmd_env allow "inspection parser ignores hostile Python customization" \
  PYTHONPATH "$guard_git_work/pythonpath" 'rg -n "gh api" tools/'
expect_cmd block "sh -c push (not a msg flag)" 'sh -c "git push"'
expect_cmd block "bash -c push"                "bash -c 'git push'"
expect_cmd block "eval push"                   'eval "git push"'
expect_cmd block "cmd-subst push in -m"        'git commit -m "$(git push)"'
expect_cmd block "backtick push in -m"         'git commit -m "`git push`"'
expect_cmd block "cmd-subst rail-write in -m"  'git commit -m "$(echo x > policy/y)"'
expect_cmd block "real rail redirect write"    'echo x > policy/foo'
expect_cmd block "real rail append write"      'echo x >> AGENTS.md'
expect_cmd block "tee rail (piped)"            'echo x | tee .claude/settings.json'
expect_cmd block "sed -i rail"                 'sed -i s/a/b/ policy/deny.patterns'
expect_cmd block "stderr redirected INTO rail" 'run 2> policy/err.log'
expect_cmd block "variable redirect into rail"  'target=AGENTS.md; echo x > "$target"'
expect_cmd block "variable fd redirect into rail" 'target=AGENTS.md; echo x 3> "$target"'
expect_cmd block "variable all-output redirect into rail" 'target=AGENTS.md; echo x &> "$target"'
expect_cmd block "literal fd redirect into rail" ': 3> ./AGENTS.md'
expect_cmd block "prefixed variable fd redirect" 'target=AGENTS.md; : 3> "./$target"'
expect_cmd block "nested fd redirect into rail"  'sh -c '\'' : 3> "$1"'\'' _ AGENTS.md'
expect_cmd block "substituted fd redirect into rail" ': 3> "$(printf ./AGENTS.md)"'
expect_cmd block "glob fd redirect into rail"    ': 3> ./*AGENTS.md'
expect_cmd block "absolute fd redirect into rail" ": 3> \"$repo_root/AGENTS.md\""
expect_cmd block "quoted rail target construction" 'echo x > AGENTS"."md'
expect_cmd block "ANSI rail target construction" 'echo x > AGENTS$'\''.md'\'''
expect_cmd block "appended rail target construction" 'target=AGENTS; target+=.md; echo x > "$target"'
expect_cmd block "symlink setup names rail"      'ln -sf AGENTS.md /tmp/agent-lab-rail-link'
ln -s "$repo_root/AGENTS.md" "$guard_tmp_link" || infra "could not create rail-link fixture"
expect_cmd block "wc tmp symlink into rail"      "wc -l AGENTS.md > $guard_tmp_link"
expect_cmd block "literal heredoc symlink into rail" \
  $'cat > '"$guard_tmp_link"$' <<\'NOTE\'\npolicy prose only\nNOTE'
expect_cmd block "dynamic heredoc rail target is not treated as data" \
  $'target=AGENTS.md; cat > "$target" <<\'NOTE\'\npolicy prose only\nNOTE'
expect_cmd block "literal Python writer still protects rails" \
  'python3 -c '\''open("AGENTS.md", "w").write("policy prose only")'\'''
expect_cmd block "literal Python writer cannot mutate Git metadata" \
  'python3 -c '\''open(".git/config", "w").write("policy prose only")'\'''
expect_cmd block "literal Python writer cannot mutate nested Git metadata" \
  'python3 -c '\''open("proj/flow/.git/config", "w").write("git push")'\'''
expect_cmd block "literal Python writer cannot leave repository" \
  'python3 -c '\''open("../outside.md", "w").write("policy prose only")'\'''
expect_cmd block "literal Python writer symlink still protects rails" \
  "python3 -c 'open(\"$guard_tmp_link\", \"w\").write(\"policy prose only\")'"
expect_cmd block "dynamic Python writer target fails closed" \
  'python3 -c '\''open(input(), "w").write("policy prose only")'\'''
expect_cmd block "lookalike Python executable is not trusted" \
  './python3 -c '\''open("proj/flow/note.md", "w").write("git push")'\'''
expect_cmd block "double-quoted Python source can expand shell commands" \
  $'python3 -c "open(\'proj/flow/note.md\', \'w\').write(\'$(git push)\')"'
expect_cmd block "unquoted Python heredoc can expand shell commands" \
  $'python3 <<PY\nopen("proj/flow/note.md", "w").write("$(git push)")\nPY'
expect_cmd block "unquoted cat heredoc can expand shell commands" \
  $'cat > proj/flow/note.md <<NOTE\n$(git push)\nNOTE'
expect_hostile_python_block "hostile PATH Python is neither trusted nor invoked" \
  'python3 -c '\''open("proj/flow/note.md", "w").write("safe")'\'''
expect_cmd block "Python writer cannot hide a second operation" \
  'python3 -c '\''import subprocess; open("tmp/workbench-note.md", "w").write("safe"); subprocess.run(["git", "push"])'\'''
expect_cmd block "real rm after stripped msg"  'git commit -m "tidy"; rm policy/x'
expect_cmd block "command after literal heredoc remains executable" \
  $'cat > tmp/workbench-note.md <<\'NOTE\'\nsafe note\nNOTE\ngh pr merge 1'
expect_cmd block "command after Python heredoc remains executable" \
  $'python3 <<\'PY\'\nopen("tmp/workbench-note.md", "w").write("safe")\nPY\ngh pr merge 1'

echo "== malformed hook envelopes fail closed =="
expect_socket_payload allow "socket-backed hook input is readable" \
  '{"tool_name":"Bash","tool_input":{"command":"git status"}}'
expect_socket_payload block "socket-backed hook input still blocks" \
  '{"tool_name":"Bash","tool_input":{"command":"git push origin dev"}}'
missing_policy_guard="$guard_git_work/missing-policy/tools/pretooluse-guard.sh"
mkdir -p "${missing_policy_guard%/*}"
cp "$guard" "$missing_policy_guard"
rc=0
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git status"}}' \
  | "$missing_policy_guard" >/dev/null 2>&1 || rc=$?
_check block "missing policy inputs fail closed" "$rc"
expect_payload block "malformed JSON" '{'
expect_payload block "Bash missing command" '{"tool_name":"Bash","tool_input":{}}'

printf '\nSUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
