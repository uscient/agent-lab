#!/usr/bin/env bash
# agent-lab PreToolUse guard — DEFENSE-IN-DEPTH for an agent *developing* this repo.
#
# It makes the safe path automatic and catches mistakes + casual evasion. It is NOT the security
# boundary: a hostile agent is contained by the sandbox/network posture (SECURITY.md /
# THREAT_MODEL.md), not by these string matches.
#
# Matchers: Bash (inspect tool_input.command), host file tools, and the allowed Serena semantic
# mutators. Hook envelopes may use snake_case or camelCase keys depending on the client.
# Unconditional denials and destructive carve-outs live in policy/*.patterns; scoped workflow
# decisions live below because they require branch-aware validation.
# Exit 2 blocks and prints the reason (citing the relevant AGENTS.md section). Exit 0 defers.
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
  tool_name="$(printf '%s' "$input" | jq -r '(.tool_name // .toolName // empty)' 2>/dev/null || true)"
  cmd="$(
    printf '%s' "$input" \
      | jq -r '((.tool_input // .toolInput // {}) | (.command // empty))' 2>/dev/null \
      || true
  )"
  fpath="$(
    printf '%s' "$input" \
      | jq -r '
          ((.tool_input // .toolInput // {}) |
            (.file_path // .filePath // .path //
             .notebook_path // .notebookPath //
             .relative_path // .relativePath // empty))
        ' 2>/dev/null \
      || true
  )"
fi

block() { # block <reason> <AGENTS.md section>
  echo "BLOCKED by agent-lab policy: $1 (see AGENTS.md — $2)" >&2
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

# path_is_secret <path>: 0 for repository-local secret/key material.
path_is_secret() {
  case "/$1" in
    */.env | */.env.* | */secrets/* | *.pem | *.key | *.kdbx) return 0 ;;
    *) return 1 ;;
  esac
}

path_is_auth_material() {
  case "/$1" in
    */.gitconfig | */.config/git/* | */.config/gh/* | */.ssh/* | */.netrc) return 0 ;;
    *) return 1 ;;
  esac
}

# protected_alternation: regex OR of all protected entries, for the Bash control-plane check
protected_alternation() {
  active_patterns "$pol/protected.paths" \
    | sed -e 's/[.[\*^$()+?{}|]/\\&/g' \
    | paste -sd '|' -
}

maint="${AGENT_LAB_MAINTENANCE:-}"

# ---------------------------------------------------------------------------
# Host and Serena file-mutation path: protect secrets and maintenance-only rails.
# ---------------------------------------------------------------------------
case "$tool_name" in
  Read)
    if path_is_secret "$fpath" || path_is_auth_material "$fpath"; then
      block "reading secret, credential, authentication, or Git configuration material is forbidden" "Autonomy boundary"
    fi
    exit 0
    ;;
  Edit | Write | MultiEdit | NotebookEdit | apply_patch | str_replace_editor)
    if path_is_secret "$fpath" || path_is_auth_material "$fpath"; then
      block "editing secret, credential, authentication, or Git configuration material is forbidden" "Autonomy boundary"
    fi
    if [ "$maint" != 1 ] && path_is_protected "$fpath"; then
      block "editing a protected rail ($fpath) is a maintenance-only action — set AGENT_LAB_MAINTENANCE=1 for sanctioned maintenance" "Authority"
    fi
    exit 0
    ;;
  mcp__serena__replace_symbol_body | mcp__serena__insert_before_symbol | mcp__serena__insert_after_symbol | \
  serena__replace_symbol_body | serena__insert_before_symbol | serena__insert_after_symbol)
    if [ -z "$fpath" ]; then
      block "Serena semantic mutation is missing its project-relative path and cannot be authorized" "Autonomy boundary"
    fi
    if path_is_secret "$fpath" || path_is_auth_material "$fpath"; then
      block "editing secret, credential, authentication, or Git configuration material through Serena is forbidden" "Autonomy boundary"
    fi
    if [ "$maint" != 1 ] && path_is_protected "$fpath"; then
      block "editing a protected rail through Serena ($fpath) is a maintenance-only action — set AGENT_LAB_MAINTENANCE=1 for sanctioned maintenance" "Authority"
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

# 1) scoped remote workflow.
branch="$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null || echo DETACHED)"
is_work_branch() {
  case "$branch" in dev | master | main | DETACHED) return 1 ;; *) return 0 ;; esac
}

validate_push() {
  local words=() arg positional=()
  read -r -a words <<<"$scan"
  [ "${words[0]:-}" = git ] && [ "${words[1]:-}" = push ] || return 1
  is_work_branch || return 1
  for arg in "${words[@]:2}"; do
    case "$arg" in
      -u | --set-upstream | --porcelain | --progress | --no-progress | --no-verify) ;;
      --force-with-lease) ;;
      --force-with-lease=* | --force | -f | --mirror | --delete | -d) return 1 ;;
      -*) return 1 ;;
      *) positional+=("$arg") ;;
    esac
  done
  [ "${#positional[@]}" -eq 2 ] || return 1
  [ "${positional[0]}" = origin ] || return 1
  [ "${positional[1]}" = HEAD ] || [ "${positional[1]}" = "$branch" ] || return 1
  return 0
}

validate_gh() {
  local words=() sub arg i base="" head=""
  read -r -a words <<<"$scan"
  [ "${words[0]:-}" = gh ] && [ "${words[1]:-}" = pr ] || return 1
  sub="${words[2]:-}"
  for arg in "${words[@]:3}"; do
    case "$arg" in -R | -R?* | --repo | --repo=* | --hostname | --hostname=*) return 1 ;; esac
  done
  case "$sub" in
    list | view | status | checks | diff) return 0 ;;
    create) ;;
    *) return 1 ;;
  esac
  is_work_branch || return 1
  i=3
  while [ "$i" -lt "${#words[@]}" ]; do
    arg="${words[$i]}"
    case "$arg" in
      --base | -B) i=$((i + 1)); base="${words[$i]:-}" ;;
      --base=*) base="${arg#*=}" ;;
      --head | -H) i=$((i + 1)); head="${words[$i]:-}" ;;
      --head=*) head="${arg#*=}" ;;
    esac
    i=$((i + 1))
  done
  [ "$base" = dev ] || return 1
  [ -z "$head" ] || [ "$head" = "$branch" ] || return 1
}

git_push_re='(^|[^[:alnum:]_])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[^[:alnum:]_]+push([^[:alnum:]_]|$)'
git_remote_rebase_re='(^|[^[:alnum:]_])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[^[:alnum:]_]+rebase([^[:alnum:]_]|$).*((origin|upstream)/|refs/remotes/)'
if printf '%s' "$scan" | grep -Eq "$git_push_re"; then
  validate_push || block "push is limited to the current non-protected branch on origin; plain force, deletion, mirrors, and protected targets are forbidden" "Autonomy boundary"
fi
if printf '%s' "$scan" | grep -Eq "$git_remote_rebase_re"; then
  if ! { is_work_branch && printf '%s' "$scan" | grep -Eq '^[[:space:]]*git[[:space:]]+rebase[[:space:]]+origin/dev[[:space:]]*$'; }; then
    block "remote rebase is limited to rebasing the current work branch on origin/dev" "Autonomy boundary"
  fi
fi
if printf '%s' "$scan" | grep -Eq '(^|[^[:alnum:]_./-])gh([^[:alnum:]_./-]|$)|(^|[;&|][[:space:]]*)/[^[:space:]]*/gh([[:space:]]|$)'; then
  validate_gh || block "GitHub access is limited to direct read-only PR commands and creating the current work branch PR with explicit base dev" "Autonomy boundary"
fi

match_any "$scan" "$pol/deny.patterns" \
  && block "operation is outside the scoped remote workflow or would alter authentication, attribution, remote configuration, or integration state" "Autonomy boundary"

printf '%s' "$scan" | grep -Eq '(^|[[:space:]"'"'"'=])(~?/)?(\.gitconfig([^[:alnum:]]|$)|\.config/(git|gh)/|\.ssh/|\.netrc([^[:alnum:]]|$))' \
  && block "credential, authentication, and Git configuration file access is forbidden" "Autonomy boundary"
printf '%s' "$scan" | grep -Eq '(^|[^[:alnum:]_])(GH_TOKEN|GITHUB_TOKEN|GIT_ASKPASS|SSH_AUTH_SOCK)([^[:alnum:]_]|$)' \
  && block "credential and token environment access is forbidden" "Autonomy boundary"
printf '%s' "$scan" | grep -Eq '^[[:space:]]*(printenv|env|set)[[:space:]]*$' \
  && block "bulk environment disclosure is forbidden" "Autonomy boundary"

# 2) destructive / integrity carve-out
match_any "$scan" "$pol/carveout.patterns" \
  && block "destructive/integrity operation is forbidden under autonomy — ask the human first" "Autonomy boundary"

# 3) containment hard-stops (always on; not maintenance-gated) — kept verbatim from the substrate
printf '%s' "$scan" | grep -Eq 'docker\.sock' \
  && block "mounting the Docker socket is forbidden (host-escape surface)" "Autonomy boundary"
printf '%s' "$scan" | grep -Eq '(--privileged|privileged[[:space:]]*:[[:space:]]*true)' \
  && block "privileged containers are forbidden" "Autonomy boundary"
printf '%s' "$scan" | grep -Eq '(--network[=[:space:]]host|--net[=[:space:]]host|network_mode[[:space:]]*:[[:space:]]*.?host)' \
  && block "host networking is forbidden (breaks default-deny)" "Autonomy boundary"
# secret/key material: agents developing the repository must not read or write secret-bearing paths.
secret_path_re="(^|[[:space:]\"'=])([^[:space:]\"']*/)?(\\.env([^a-zA-Z]|$)|secrets/|[^[:space:]\"']*\\.(pem|key|kdbx)([^a-zA-Z]|$))"
if printf '%s' "$scan" | grep -Eq "$secret_path_re"; then
  block "reading or writing .env / secrets / key material is forbidden" "Autonomy boundary"
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
      block "mutating a protected rail (config / guard / policy) via shell is a maintenance-only action — set AGENT_LAB_MAINTENANCE=1" "Authority"
    fi
  fi
fi

# 5) branch backstop: never commit on dev/master/main (covers a skipped SessionStart bootstrap)
git_commit_re='(^|[^[:alnum:]_])git([[:space:]]+[^[:space:]]+)*[[:space:]]+commit([^[:alnum:]_]|$)'
if printf '%s' "$scan" | grep -Eq "$git_commit_re"; then
  br="$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null || echo DETACHED)"
  case "$br" in
    dev | master | main | DETACHED) block "refusing to commit on protected or detached branch '$br' — create a work branch from dev first (SessionStart normally does this)" "Prime directives" ;;
  esac
fi

exit 0
