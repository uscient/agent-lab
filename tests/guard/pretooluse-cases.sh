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
expect_cmd allow "PR create to dev"            'gh pr create --base dev --head agent/test/guard --title x --body-file /tmp/body'
expect_cmd allow "git branch -d (safe)"       'git branch -d old'
expect_cmd allow "run tests"                  './scripts/dev/test quick'
expect_cmd allow "lint"                       './scripts/dev/lint-scripts'
expect_cmd allow "read a protected file"      'cat AGENTS.md'
expect_cmd allow "grep policy"                 'grep -r AGENTS.md policy/'

echo "== deny: commit on protected branches (branch backstop) =="
for protected in dev master main; do
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
expect_cmd block "PR create without base"       'gh pr create --title x --body y'
expect_cmd block "PR create wrong base"         'gh pr create --base main --title x --body y'
expect_cmd block "PR create wrong head"         'gh pr create --base dev --head other --title x --body y'
expect_cmd block "PR create for another repo"    'gh pr create -R other/repo --base dev --title x --body y'
expect_cmd block "PR create attached other repo" 'gh pr create -Rother/repo --base dev --title x --body y'
expect_cmd block "PR merge"                     'gh pr merge 10'
expect_cmd block "PR edit"                      'gh pr edit 10 --title x'
expect_cmd block "gh api write"                 'gh api -X POST repos/o/r/pulls'
expect_cmd block "gh api implicit POST"         'gh api repos/o/r/issues -f title=x'
expect_cmd block "GitHub repo delete"           'gh repo delete uscient/agent-lab --yes'
expect_cmd block "absolute GitHub repo delete"  '/usr/bin/gh repo delete uscient/agent-lab --yes'
expect_cmd block "GitHub issue close"           'gh issue close 1'
expect_cmd block "GitHub global-option PR merge" 'gh --repo uscient/agent-lab pr merge 10'
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
expect_read block "read nested private key"           'fixtures/app/client.key'
expect_read block "read GitHub credential file"       '/home/agent/.config/gh/hosts.yml'
expect_read allow "read normal source file"           'tools/validate.sh'
expect_edit allow "edit AGENTS.md (maint=1)"         'AGENTS.md' 1
expect_edit allow "edit .grok (maint=1)"             '.grok/config.toml' 1
expect_edit allow "edit normal file"                 'scripts/dev/test'
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
expect_cmd allow "git status 2>&1"             'git status 2>&1'
expect_cmd block "cat .env, stderr->null"      'cat .env 2>/dev/null'
expect_cmd allow "msg mentions rail+verb"      'git commit -m "update policy/ and the guard"'
expect_cmd allow "msg mentions git push"       'git commit -m "block git push in the guard"'
expect_cmd allow "msg mentions pull"           'git commit -m "fix pull handling"'
expect_cmd allow "msg single-quoted rail"      "git commit -m 'tidy policy/ and the guard'"
expect_cmd allow "--message long form"         'git commit --message "discuss tee and rm in policy/"'
expect_cmd allow "search data names forge CLI" 'rg -n "gh" README.md'
expect_cmd allow "rail read output to tmp"      'wc -l AGENTS.md > /tmp/agent-lab-rail-count'

echo "== false-positive fixes: MUST STILL DENY (executable / substitution / real writes) =="
expect_cmd block "actual forge command"         'gh pr merge 1'
expect_cmd block "quoted absolute forge command" '"/usr/bin/gh" pr merge 1'
expect_cmd block "constructed forge command"    '"g""h" pr merge 1'
expect_cmd block "ANSI-constructed forge command" 'g$'\''h'\'' pr merge 1'
expect_cmd block "glob-constructed forge command" '/usr/bin/g[h] pr merge 1'
expect_cmd block "search then forge command"    'rg -n "gh" README.md; gh pr merge 1'
expect_cmd block "search preprocessor command"  'rg --pre "gh pr merge 1" needle README.md'
expect_cmd block "brace search preprocessor"    'rg --p{re,re}=gh needle README.md'
expect_cmd block "constructed preprocessor payload" 'rg --pre "g""h auth status" needle README.md'
expect_cmd block "constructed search preprocessor" 'rg --p"re" "gh auth status" needle README.md'
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
expect_cmd block "absolute fd redirect into rail" ': 3> "/home/work/projects/uscient/agent-lab/AGENTS.md"'
expect_cmd block "quoted rail target construction" 'echo x > AGENTS"."md'
expect_cmd block "ANSI rail target construction" 'echo x > AGENTS$'\''.md'\'''
expect_cmd block "appended rail target construction" 'target=AGENTS; target+=.md; echo x > "$target"'
expect_cmd block "symlink setup names rail"      'ln -sf AGENTS.md /tmp/agent-lab-rail-link'
ln -s "$repo_root/AGENTS.md" "$guard_tmp_link" || infra "could not create rail-link fixture"
expect_cmd block "wc tmp symlink into rail"      "wc -l AGENTS.md > $guard_tmp_link"
expect_cmd block "real rm after stripped msg"  'git commit -m "tidy"; rm policy/x'

echo "== malformed hook envelopes fail closed =="
expect_payload block "malformed JSON" '{'
expect_payload block "Bash missing command" '{"tool_name":"Bash","tool_input":{}}'

printf '\nSUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
