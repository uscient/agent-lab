#!/usr/bin/env bash
# Unit tests for tools/pretooluse-guard.sh (the PreToolUse guard) — pure shell, no Docker.
# This is SEPARATE from tests/guard/cases.sh, which tests scripts/lib/guard.sh (project/secrets
# vetting). Run: bash tests/guard/pretooluse-cases.sh
set -uo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
# GUARD_OVERRIDE lets maintenance verify a candidate guard (e.g. tmp/guard-new.sh) before swap-in.
guard="${GUARD_OVERRIDE:-$repo_root/tools/pretooluse-guard.sh}"

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
    | env -u AGENT_LAB_MAINTENANCE "$guard" >/dev/null 2>&1 || rc=$?
  _check "$exp" "$name" "$rc"
}
# expect_edit <block|allow> <name> <file_path> [maint]
expect_edit() {
  local exp="$1" name="$2" fp="$3" maint="${4:-}" rc=0
  printf '{"tool_name":"Edit","tool_input":{"file_path":%s}}' "$(jq -Rn --arg c "$fp" '$c')" \
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
expect_cmd allow "git branch -d (safe)"       'git branch -d old'
expect_cmd allow "run tests"                  './scripts/dev/test quick'
expect_cmd allow "lint"                       './scripts/dev/lint-scripts'
expect_cmd allow "read a protected file"      'cat AGENTS.md'
expect_cmd allow "grep doctrine"              'grep -r TLDR doctrine/'

echo "== deny: remote integrity =="
expect_cmd block "push"                       'git push'
expect_cmd block "push origin HEAD"           'git push origin HEAD'
expect_cmd block "push --force"               'git push --force'
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
expect_cmd block "merge refs/remotes"         'git merge refs/remotes/origin/main'
expect_cmd block "git -C . merge origin"      'git -C . merge origin/main'
expect_cmd block "gh pr create"               'gh pr create'
expect_cmd block "gh api pulls"               'gh api -X POST repos/o/r/pulls'
expect_cmd block "git remote set-url"         'git remote set-url origin https://x'

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
expect_edit block "edit doctrine (no maint)"         'doctrine/git-workflow.md'
expect_edit block "edit guard (no maint)"            'tools/pretooluse-guard.sh'
expect_edit block "edit policy (no maint)"           'policy/deny.patterns'
expect_edit block "edit .codex (no maint)"           '.codex/config.toml'
expect_edit block "edit abs-path doctrine (no maint)" "$repo_root/doctrine/meta.md"
expect_edit allow "edit AGENTS.md (maint=1)"         'AGENTS.md' 1
expect_edit allow "edit .grok (maint=1)"             '.grok/config.toml' 1
expect_edit allow "edit normal file"                 'scripts/dev/test'
expect_edit allow "edit README"                      'README.md'

echo "== shell mutation of rails (maintenance-gated) =="
expect_cmd block "append to AGENTS.md"        'echo x >> AGENTS.md'
expect_cmd block "tee into policy"            'echo x | tee policy/deny.patterns'
expect_cmd allow "read AGENTS.md (cat)"       'cat AGENTS.md'

echo "== false-positive fixes: now ALLOWED (data / non-write redirects) =="
expect_cmd allow "ls rail, stderr->null"       'ls ~/.codex 2>/dev/null'
expect_cmd allow "cat rail, stderr->null"      'cat .claude/settings.json 2>/dev/null'
expect_cmd allow "git status 2>&1"             'git status 2>&1'
expect_cmd allow "cat .env, stderr->null"      'cat .env 2>/dev/null'
expect_cmd allow "msg mentions rail+verb"      'git commit -m "update doctrine/ and the guard"'
expect_cmd allow "msg mentions git push"       'git commit -m "block git push in the guard"'
expect_cmd allow "msg mentions pull"           'git commit -m "fix pull handling"'
expect_cmd allow "msg single-quoted rail"      "git commit -m 'tidy doctrine/ and the guard'"
expect_cmd allow "--message long form"         'git commit --message "discuss tee and rm in policy/"'

echo "== false-positive fixes: MUST STILL DENY (executable / substitution / real writes) =="
expect_cmd block "sh -c push (not a msg flag)" 'sh -c "git push"'
expect_cmd block "bash -c push"                "bash -c 'git push'"
expect_cmd block "eval push"                   'eval "git push"'
expect_cmd block "cmd-subst push in -m"        'git commit -m "$(git push)"'
expect_cmd block "backtick push in -m"         'git commit -m "`git push`"'
expect_cmd block "cmd-subst rail-write in -m"  'git commit -m "$(echo x > doctrine/y)"'
expect_cmd block "real rail redirect write"    'echo x > doctrine/foo.md'
expect_cmd block "real rail append write"      'echo x >> AGENTS.md'
expect_cmd block "tee rail (piped)"            'echo x | tee .claude/settings.json'
expect_cmd block "sed -i rail"                 'sed -i s/a/b/ policy/deny.patterns'
expect_cmd block "stderr redirected INTO rail" 'run 2> doctrine/err.log'
expect_cmd block "real rm after stripped msg"  'git commit -m "tidy"; rm doctrine/x'

printf '\nSUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
