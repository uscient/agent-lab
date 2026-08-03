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
shopt -u nocasematch

root="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)" || exit 0
pol="$root/policy"

# block <reason> <AGENTS.md section>
block() {
  echo "BLOCKED by agent-lab policy: $1 (see AGENTS.md — $2)" >&2
  exit 2
}

input="$(</dev/stdin)"
tool_name="" tool_name_lc="" cmd="" fpath=""
if command -v jq >/dev/null 2>&1; then
  if ! tool_name="$(
    printf '%s' "$input" \
      | jq -er 'if type == "object" then (.tool_name // .toolName // "") else error("invalid envelope") end' 2>/dev/null
  )"; then
    block "hook input is not a valid JSON object and cannot be classified" "Autonomy boundary"
  fi
  tool_name_lc="${tool_name,,}"
  case "$tool_name_lc" in
    read | read_file | edit | edit_file | write | write_file | create_file | create_text_file | \
    multiedit | notebookedit | apply_patch | str_replace_editor | \
    mcp__serena__replace_symbol_body | mcp__serena__insert_before_symbol | mcp__serena__insert_after_symbol | \
    serena__replace_symbol_body | serena__insert_before_symbol | serena__insert_after_symbol)
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
      ;;
    *)
      cmd="$(
        printf '%s' "$input" \
          | jq -r '((.tool_input // .toolInput // {}) | (.command // empty))' 2>/dev/null \
          || true
      )"
      ;;
  esac
else
  block "jq is unavailable and hook input cannot be classified" "Autonomy boundary"
fi
[ "$tool_name_lc" != bash ] || [ -n "$cmd" ] \
  || block "Bash hook input is missing its command and cannot be classified" "Autonomy boundary"

# matches_line <text> <extended-regex>: preserve grep's historical linewise matching semantics
# without spawning one grep process per predicate on the single-line hot path.
matches_line() {
  local text="$1" regex="$2"
  [ -n "$text" ] || return 1
  if [[ "$text" == *$'\n'* ]]; then
    printf '%s' "$text" | grep -Eq -- "$regex"
    return
  fi
  [[ "$text" =~ $regex ]]
}

# match_any <haystack> <patterns-file>: 0 if any active pattern matches
match_any() {
  local hay="$1" file="$2" pattern patterns
  [ -r "$file" ] || return 1
  if [[ "$hay" == *$'\n'* ]]; then
    patterns="$(grep -vE '^[[:space:]]*(#|$)' "$file" 2>/dev/null || true)"
    [ -n "$patterns" ] || return 1
    printf '%s' "$hay" | grep -Eq -f <(printf '%s\n' "$patterns")
    return
  fi
  while IFS= read -r pattern || [ -n "$pattern" ]; do
    [[ "$pattern" =~ ^[[:space:]]*(#|$) ]] && continue
    matches_line "$hay" "$pattern" && return 0
  done < "$file"
  return 1
}

# path_is_protected <path>: 0 if path matches any policy/protected.paths entry (at a / boundary)
path_is_protected() {
  local p="$1" entry needle hay
  [ -z "$p" ] && return 1
  hay="/${p#/}/"
  while IFS= read -r entry || [ -n "$entry" ]; do
    [[ "$entry" =~ ^[[:space:]]*(#|$) ]] && continue
    needle="/${entry%/}/"
    [[ "$hay" == *"$needle"* ]] && return 0
  done < "$pol/protected.paths"
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

# references_protected_path <text>: literal substring check matching the shell guard's historical
# protected-alternation behavior, without constructing a regex or spawning helper processes.
references_protected_path() {
  local text="$1" entry
  while IFS= read -r entry || [ -n "$entry" ]; do
    [[ "$entry" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$text" == *"$entry"* ]] && return 0
  done < "$pol/protected.paths"
  return 1
}

maint="${AGENT_LAB_MAINTENANCE:-}"

# ---------------------------------------------------------------------------
# Host and Serena file-mutation path: protect secrets and maintenance-only rails.
# ---------------------------------------------------------------------------
case "$tool_name_lc" in
  read | read_file)
    if path_is_secret "$fpath" || path_is_auth_material "$fpath"; then
      block "reading secret, credential, authentication, or Git configuration material is forbidden" "Autonomy boundary"
    fi
    exit 0
    ;;
  edit | edit_file | write | write_file | create_file | create_text_file | \
  multiedit | notebookedit | apply_patch | str_replace_editor)
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

# Strip the literal body of one simple cat heredoc whose only shell operation is writing a literal
# file target. The body is data, not shell syntax. Keep the header, delimiter, and every command
# after the delimiter in the scan; malformed, dynamic, piped, or compound forms remain unstripped.
strip_literal_cat_heredoc_data() {
  local s="$1" first rest line target="" resolved="" delimiter="" output="" found=0
  local header_re="^[[:space:]]*cat[[:space:]]+[0-9]*>>?[[:space:]]*[\"']?([A-Za-z0-9_./-]+)[\"']?[[:space:]]+<<-?[[:space:]]*[\"']?([A-Za-z_][A-Za-z0-9_]*)[\"']?[[:space:]]*$"
  scan="$s"
  [[ "$s" == *$'\n'* ]] || return
  first="${s%%$'\n'*}"
  if [[ ! "$first" =~ $header_re ]]; then
    return
  fi
  target="${BASH_REMATCH[1]}"
  delimiter="${BASH_REMATCH[2]}"
  case "$target" in
    /*) resolved="$(readlink -m -- "$target" 2>/dev/null || true)" ;;
    *) resolved="$(readlink -m -- "$root/$target" 2>/dev/null || true)" ;;
  esac
  if [ -z "$resolved" ]; then
    return
  fi
  if path_is_secret "$resolved" || path_is_auth_material "$resolved"; then
    block "literal heredoc target resolves to secret, credential, authentication, or Git configuration material" "Autonomy boundary"
  fi
  if [ "$maint" != 1 ] && path_is_protected "$resolved"; then
    block "literal heredoc target resolves to a protected rail — set AGENT_LAB_MAINTENANCE=1 for sanctioned maintenance" "Authority"
  fi
  rest="${s#*$'\n'}"
  output="$first"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$found" -eq 0 ]; then
      if [ "$line" = "$delimiter" ]; then
        found=1
        output+=$'\n'"$line"
      fi
    else
      output+=$'\n'"$line"
    fi
  done <<< "$rest"
  if [ "$found" -eq 1 ]; then
    scan="$output"
  fi
}

# Recognize a narrowly constrained Python file writer without treating its literal document body as
# shell operations. Python code is accepted only when its AST contains literal assignments plus one
# or more open(...).write(...) calls with literal targets and content. Dynamic targets, imports,
# subprocesses, extra statements, malformed heredocs, and commands after the delimiter fail closed.
classify_literal_python_writer() {
  local s="$1" targets="" rc=0 target resolved
  [[ "$s" =~ ^[[:space:]]*python3([[:space:]]|$) ]] || return 1
  [ "$(command -v python3 2>/dev/null || true)" = /usr/bin/python3 ] && [ -x /usr/bin/python3 ] \
    || block "Python file-write command does not resolve to the trusted system interpreter" "Autonomy boundary"
  targets="$(
    printf '%s' "$s" | /usr/bin/python3 -I -S -c '
import ast
import re
import sys

raw = sys.stdin.read()

def extract_code(text):
    command = re.fullmatch(r"\s*python3\s+-c\s+\x27([^\x27]*)\x27\s*", text, re.DOTALL)
    if command:
        return command.group(1), True, True

    lines = text.splitlines()
    if not lines:
        return "", False, False
    match = re.fullmatch(
        r"\s*python3(?:\s+-)?\s+<<\s*([\x27\x22])([A-Za-z_][A-Za-z0-9_]*)\1\s*",
        lines[0],
    )
    if not match:
        return "", False, False
    delimiter = match.group(2)
    for index, line in enumerate(lines[1:], 1):
        if line == delimiter:
            trailing = lines[index + 1:]
            if any(item.strip() for item in trailing):
                return "\n".join(lines[1:index]), True, False
            return "\n".join(lines[1:index]), True, True
    return "\n".join(lines[1:]), True, False

code, python_shape, complete = extract_code(raw)
if not python_shape:
    raise SystemExit(3)
if not complete:
    raise SystemExit(2)

try:
    tree = ast.parse(code)
except SyntaxError:
    raise SystemExit(2 if ".write" in code else 3)

write_like = any(
    isinstance(node, ast.Call)
    and isinstance(node.func, ast.Attribute)
    and node.func.attr in {"write", "write_text", "write_bytes"}
    for node in ast.walk(tree)
)
if not write_like:
    raise SystemExit(3)

bindings = {}
targets = []

def literal(node):
    if isinstance(node, ast.Name) and node.id in bindings:
        return bindings[node.id]
    try:
        return ast.literal_eval(node)
    except (ValueError, TypeError):
        raise SystemExit(2)

def validate_content(node):
    value = literal(node)
    if not isinstance(value, (str, bytes)):
        raise SystemExit(2)

def validate_open_write(call):
    if len(call.args) != 1 or call.keywords:
        raise SystemExit(2)
    validate_content(call.args[0])
    opener = call.func.value
    if not isinstance(opener, ast.Call) or not isinstance(opener.func, ast.Name) or opener.func.id != "open":
        raise SystemExit(2)
    if not 1 <= len(opener.args) <= 2:
        raise SystemExit(2)
    target = literal(opener.args[0])
    mode = literal(opener.args[1]) if len(opener.args) == 2 else None
    if not isinstance(target, str) or mode not in {"w", "a", "x", "wb", "ab", "xb"}:
        raise SystemExit(2)
    for keyword in opener.keywords:
        if keyword.arg not in {"encoding", "errors", "newline"}:
            raise SystemExit(2)
        literal(keyword.value)
    targets.append(target)

for statement in tree.body:
    if isinstance(statement, ast.Assign):
        if len(statement.targets) != 1 or not isinstance(statement.targets[0], ast.Name):
            raise SystemExit(2)
        value = literal(statement.value)
        if not isinstance(value, (str, bytes)):
            raise SystemExit(2)
        bindings[statement.targets[0].id] = value
        continue
    if isinstance(statement, ast.Expr) and isinstance(statement.value, ast.Constant) and isinstance(statement.value.value, str):
        continue
    if isinstance(statement, ast.Expr) and isinstance(statement.value, ast.Call):
        call = statement.value
        if isinstance(call.func, ast.Attribute) and call.func.attr == "write":
            validate_open_write(call)
            continue
    raise SystemExit(2)

if not targets:
    raise SystemExit(2)
for target in targets:
    if not target or any(char in target for char in "\x00\r\n"):
        raise SystemExit(2)
    print(target)
' 2>/dev/null
  )" || rc=$?
  case "$rc" in
    0) ;;
    3) return 1 ;;
    *) block "Python file-write command is dynamic, compound, or cannot be classified safely" "Autonomy boundary" ;;
  esac
  [ -n "$targets" ] || return 1
  while IFS= read -r target || [ -n "$target" ]; do
    case "$target" in
      /*) resolved="$(readlink -m -- "$target" 2>/dev/null || true)" ;;
      *) resolved="$(readlink -m -- "$root/$target" 2>/dev/null || true)" ;;
    esac
    [ -n "$resolved" ] \
      || block "Python file-write target cannot be resolved safely" "Autonomy boundary"
    case "$resolved" in
      */.git | */.git/*)
        block "Python file-write target resolves to Git metadata or control files" "Prime directives"
        ;;
      "$root"/*) ;;
      *) block "literal Python file writes are limited to the repository working tree" "Autonomy boundary" ;;
    esac
    if path_is_secret "$resolved" || path_is_auth_material "$resolved"; then
      block "Python file-write target resolves to secret, credential, authentication, or Git configuration material" "Autonomy boundary"
    fi
    if [ "$maint" != 1 ] && path_is_protected "$resolved"; then
      block "Python file-write target resolves to a protected rail — set AGENT_LAB_MAINTENANCE=1 for sanctioned maintenance" "Authority"
    fi
  done <<< "$targets"
  scan="python3 validated-literal-file-write"
  return 0
}

# scan = hay with safe message-flag DATA removed. The quoted literal argument of -m / --message / -F
# is message text, not an operation, so it must not be matched as one. Strip it ONLY when it is a
# plain quoted literal with no command substitution / expansion ($(  `  ${ ) — so anything that can
# execute stays fully matched. -c (e.g. `sh -c "git push"`) is NOT a message flag and is never stripped.
scan="$hay"
strip_literal_cat_heredoc_data "$hay"
classify_literal_python_writer "$hay" || true
case "$scan" in
  *-m* | *-F*)
    scan="$(printf '%s' "$scan" | sed -E "s/(--message|-m|-F)[[:space:]]*'[^'\$\`]*'/\1 /g")"
    scan="$(printf '%s' "$scan" | sed -E "s/(--message|-m|-F)[[:space:]]*\"[^\"\$\`]*\"/\1 /g")"
    ;;
esac

# Approximate shell token concatenation for executable-name classification. This copy is never
# executed or used for argument validation; removing quotes/backslashes merely exposes spellings
# such as `"g""h"` and `/usr/bin/g\h` to the default-deny forge matcher.
shell_scan="${scan//\"/}"
shell_scan="${shell_scan//\'/}"
shell_scan="${shell_scan//\\/}"
shell_scan="${shell_scan//\$/}"
case "$shell_scan" in
  *'['*']'*) shell_scan="$(printf '%s' "$shell_scan" | sed -E 's/\[([[:alnum:]_])\]/\1/g')" ;;
esac
case "$shell_scan" in
  *'+='*)
    shell_scan="$(
      printf '%s' "$shell_scan" \
        | sed -E 's/([[:alpha:]_][[:alnum:]_]*)=([^;[:space:]]+);[[:space:]]*\1\+=([^;[:space:]]+)/\2\3/g'
    )"
    ;;
esac

q="[\"']"                    # an optional quote in front of a redirect target

# 1) scoped remote workflow.
branch=""
load_branch() {
  [ -n "$branch" ] && return 0
  branch="$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null || echo DETACHED)"
}
valid_group() {
  [ "${#1}" -le 48 ] && [[ "$1" =~ ^[gb][0-9]+[a-z]?-[a-z0-9][a-z0-9-]*$ ]]
}
is_writable_branch() {
  load_branch
  case "$branch" in
    work/*) [[ "$branch" =~ ^work/[a-z0-9][a-z0-9-]{0,47}$ ]] ;;
    group/*) valid_group "${branch#group/}" ;;
    slice/group/*/*)
      [[ "$branch" =~ ^slice/group/([gb][0-9]+[a-z]?-[a-z0-9][a-z0-9-]*)/[a-z0-9][a-z0-9-]{0,47}$ ]] &&
        valid_group "${BASH_REMATCH[1]}"
      ;;
    slice/*/*)
      [[ "$branch" =~ ^slice/[a-z0-9][a-z0-9-]{0,47}/[a-z0-9][a-z0-9-]{0,47}$ ]]
      ;;
    slice/* | dev | flow | master | main | DETACHED) return 1 ;;
    *) return 0 ;;
  esac
}

expected_rebase_target() {
  load_branch
  case "$branch" in
    work/* | group/* | slice/group/*/*) return 1 ;;
    slice/*/*)
      [[ "$branch" =~ ^slice/([a-z0-9][a-z0-9-]{0,47})/[a-z0-9][a-z0-9-]{0,47}$ ]] \
        || return 1
      printf 'origin/work/%s\n' "${BASH_REMATCH[1]}"
      ;;
    slice/* | dev | flow | master | main | DETACHED) return 1 ;;
    *) printf 'origin/dev\n' ;;
  esac
}

expected_pr_base() {
  local group=""
  load_branch
  case "$branch" in
    flow) printf 'dev\n' ;;
    work/*)
      [[ "$branch" =~ ^work/[a-z0-9][a-z0-9-]{0,47}$ ]] || return 1
      printf 'dev\n'
      ;;
    group/*)
      valid_group "${branch#group/}" || return 1
      printf 'flow\n'
      ;;
    slice/group/*/*)
      [[ "$branch" =~ ^slice/group/([gb][0-9]+[a-z]?-[a-z0-9][a-z0-9-]*)/[a-z0-9][a-z0-9-]{0,47}$ ]] \
        || return 1
      group="${BASH_REMATCH[1]}"
      valid_group "$group" || return 1
      printf 'group/%s\n' "$group"
      ;;
    slice/*/*)
      [[ "$branch" =~ ^slice/([a-z0-9][a-z0-9-]{0,47})/[a-z0-9][a-z0-9-]{0,47}$ ]] \
        || return 1
      printf 'work/%s\n' "${BASH_REMATCH[1]}"
      ;;
    slice/* | dev | master | main | DETACHED) return 1 ;;
    *) printf 'dev\n' ;;
  esac
}

validate_push() {
  local words=() arg positional=() lease=0
  read -r -a words <<<"$scan"
  [ "${words[0]:-}" = git ] && [ "${words[1]:-}" = push ] || return 1
  is_writable_branch || return 1
  for arg in "${words[@]:2}"; do
    case "$arg" in
      -u | --set-upstream | --porcelain | --progress | --no-progress | --no-verify) ;;
      --force-with-lease) lease=1 ;;
      --force-with-lease=* | --force | -f | --mirror | --delete | -d) return 1 ;;
      -*) return 1 ;;
      *) positional+=("$arg") ;;
    esac
  done
  [ "${#positional[@]}" -eq 2 ] || return 1
  [ "${positional[0]}" = origin ] || return 1
  [ "${positional[1]}" = HEAD ] || [ "${positional[1]}" = "$branch" ] || return 1
  case "$branch" in
    work/* | group/* | slice/group/*/*) [ "$lease" -eq 0 ] || return 1 ;;
  esac
  return 0
}

validate_gh() {
  local words=() sub arg i base="" head="" required_base=""
  read -r -a words <<<"$scan"
  [ "${words[0]:-}" = gh ] || return 1
  if [ "${words[1]:-}" = run ]; then
    case "${words[2]:-}" in list | view | watch) ;; *) return 1 ;; esac
    for arg in "${words[@]:3}"; do
      case "$arg" in -R | -R?* | --repo | --repo=* | --hostname | --hostname=*) return 1 ;; esac
    done
    return 0
  fi
  [ "${words[1]:-}" = pr ] || return 1
  sub="${words[2]:-}"
  for arg in "${words[@]:3}"; do
    case "$arg" in -R | -R?* | --repo | --repo=* | --hostname | --hostname=*) return 1 ;; esac
  done
  case "$sub" in
    list | view | status | checks | diff) return 0 ;;
    create) ;;
    *) return 1 ;;
  esac
  load_branch
  required_base="$(expected_pr_base)" || return 1
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
  [ "$base" = "$required_base" ] || return 1
  [ -z "$head" ] || [ "$head" = "$branch" ] || return 1
}

validate_remote_rebase() {
  local words=() expected=""
  read -r -a words <<<"$scan"
  [ "${#words[@]}" -eq 3 ] || return 1
  [ "${words[0]}" = git ] && [ "${words[1]}" = rebase ] || return 1
  expected="$(expected_rebase_target)" || return 1
  [ "${words[2]}" = "$expected" ]
}

# is_nonexecuting_search_data <command>: true only for a single rg invocation whose
# arguments cannot start another command. rg's --pre option is excluded because it executes an
# external preprocessor. This lets a literal search pattern name a CLI without treating the data
# as an invocation of that CLI.
is_nonexecuting_search_data() {
  local s="$1" words=() arg
  read -r -a words <<<"$s"
  [ "${words[0]:-}" = rg ] || return 1
  case "$s" in *';'* | *'&'* | *'|'* | *'`'* | *'$'* | *'<'* | *'>'*) return 1 ;; esac
  [[ "$s" == *$'\n'* ]] && return 1
  for arg in "${words[@]:1}"; do
    case "$arg" in
      --pre | --pre=* | -*\"* | -*\'* | -*\\* | -*\** | -*\?* | -*\[* | -*\{* | -*\}*) return 1 ;;
    esac
  done
  return 0
}

# unsafe_protected_write_redirect <command>: true for every file-write redirect except literal
# /dev/null sinks and the exact demonstrated wc-to-/tmp false positive. Keeping these exemptions
# narrow preserves fail-closed handling for dynamic targets, pipelines, and extra commands.
unsafe_protected_write_redirect() {
  local s="$1" stripped target
  local wc_tmp_re="^[[:space:]]*wc([[:space:]]+-[[:alnum:]]+)*[[:space:]]+[^[:space:]\"'<>]+[[:space:]]+>[[:space:]]*[\"']?/tmp/[A-Za-z0-9._-]+[\"']?[[:space:]]*$"
  stripped="$(
    printf '%s' "$s" \
      | sed -E "s#(^|[[:space:]])[0-9]*>>?[[:space:]]*${q}?/dev/null${q}?#\\1#g; s/(^|[[:space:]])[0-9]+>\&[0-9-]+/\\1/g"
  )"
  case "$stripped" in *'>'*) ;; *) return 1 ;; esac
  case "$stripped" in *';'* | *'&'* | *'|'* | *'`'* | *'$'* | *'<'* | *'('* | *')'*) return 0 ;; esac
  [[ "$stripped" == *$'\n'* ]] && return 0
  if [[ "$stripped" =~ $wc_tmp_re ]]; then
    target="${stripped##*>}"
    target="${target#"${target%%[![:space:]]*}"}"
    target="${target%"${target##*[![:space:]]}"}"
    case "$target" in
      \"*\") target="${target#\"}"; target="${target%\"}" ;;
      \'*\') target="${target#\'}"; target="${target%\'}" ;;
    esac
    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
      return 1
    fi
  fi
  return 0
}

git_push_re='(^|[^[:alnum:]_])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[^[:alnum:]_]+push([^[:alnum:]_]|$)'
git_alt_context_mutation_re='(^|[^[:alnum:]_])git[[:space:]]+(-C([[:space:]]+[^[:space:]]+|[^[:space:]]+)|--(git-dir|work-tree)(=|[[:space:]]+)[^[:space:]]+).*[[:space:]](commit|merge|rebase|push)([^[:alnum:]_]|$)'
git_remote_rebase_re='(^|[^[:alnum:]_])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[^[:alnum:]_]+rebase([^[:alnum:]_]|$).*((origin|upstream)/|refs/remotes/)'
git_integration_re='(^|[^[:alnum:]_])git([[:space:]]+[^[:space:]]+)*[[:space:]]+(merge|rebase)([^[:alnum:]_]|$)'
git_slice_merge_re="(^|[^[:alnum:]_])git[[:space:]]+merge[[:space:]]+([^[:space:]]+[[:space:]]+)*[\"']?slice/"
gh_command_re='(^|[^[:alnum:]_./-])gh([^[:alnum:]_./-]|$)|(^|[;&|][[:space:]]*)/[^[:space:]]*/gh([[:space:]]|$)'
credential_path_re="(^|[[:space:]\"'=])(~?/)?(\\.gitconfig([^[:alnum:]]|$)|\\.config/(git|gh)/|\\.ssh/|\\.netrc([^[:alnum:]]|$))"
token_env_re='(^|[^[:alnum:]_])(GH_TOKEN|GITHUB_TOKEN|GIT_ASKPASS|SSH_AUTH_SOCK)([^[:alnum:]_]|$)'
bulk_env_re='^[[:space:]]*(printenv|env|set)[[:space:]]*$'
mutating_rail_re='(^|[[:space:]])(tee|rm|mv|cp|ln|truncate|install)[[:space:]]|sed[[:space:]]+-i'

if matches_line "$scan" "$git_alt_context_mutation_re"; then
  block "Git mutations through an alternate worktree or Git directory are forbidden" "Autonomy boundary"
fi
if matches_line "$scan" "$git_push_re"; then
  validate_push || block "push is limited to the current non-protected branch on origin; plain force, deletion, mirrors, and protected targets are forbidden" "Autonomy boundary"
fi
if matches_line "$scan" "$git_remote_rebase_re"; then
  validate_remote_rebase \
    || block "remote rebase must use the exact base derived from the current branch" "Autonomy boundary"
fi
if matches_line "$scan" "$git_integration_re"; then
  load_branch
  case "$branch" in
    dev | flow | master | main | DETACHED)
      block "merge and rebase on a protected branch or detached HEAD are forbidden" "Autonomy boundary"
      ;;
    work/* | group/* | slice/group/*/*)
      block "integration branch history is helper-managed; use scripts/dev/workstream sync or merge" "Autonomy boundary"
      ;;
  esac
fi
matches_line "$scan" "$git_slice_merge_re" \
  && block "slice integration is permitted only through the verified workstream helper" "Autonomy boundary"
if matches_line "$shell_scan" "$gh_command_re" \
  && ! is_nonexecuting_search_data "$scan"; then
  validate_gh || block "GitHub access is limited to direct read-only PR/Actions commands and the exact PR route derived from the current branch" "Autonomy boundary"
fi

match_any "$scan" "$pol/deny.patterns" \
  && block "operation is outside the scoped remote workflow or would alter authentication, attribution, remote configuration, or integration state" "Autonomy boundary"

matches_line "$scan" "$credential_path_re" \
  && block "credential, authentication, and Git configuration file access is forbidden" "Autonomy boundary"
matches_line "$scan" "$token_env_re" \
  && block "credential and token environment access is forbidden" "Autonomy boundary"
matches_line "$scan" "$bulk_env_re" \
  && block "bulk environment disclosure is forbidden" "Autonomy boundary"

# 2) destructive / integrity carve-out
match_any "$scan" "$pol/carveout.patterns" \
  && block "destructive/integrity operation is forbidden under autonomy — ask the human first" "Autonomy boundary"

# 3) containment hard-stops (always on; not maintenance-gated) — kept verbatim from the substrate
matches_line "$scan" 'docker\.sock' \
  && block "mounting the Docker socket is forbidden (host-escape surface)" "Autonomy boundary"
matches_line "$scan" '(--privileged|privileged[[:space:]]*:[[:space:]]*true)' \
  && block "privileged containers are forbidden" "Autonomy boundary"
matches_line "$scan" '(--network[=[:space:]]host|--net[=[:space:]]host|network_mode[[:space:]]*:[[:space:]]*.?host)' \
  && block "host networking is forbidden (breaks default-deny)" "Autonomy boundary"
# secret/key material: agents developing the repository must not read or write secret-bearing paths.
secret_path_re="(^|[[:space:]\"'=])([^[:space:]\"']*/)?(\\.env([^a-zA-Z]|$)|secrets/|[^[:space:]\"']*\\.(pem|key|kdbx)([^a-zA-Z]|$))"
if matches_line "$scan" "$secret_path_re"; then
  block "reading or writing .env / secrets / key material is forbidden" "Autonomy boundary"
fi

# 4) control-plane / guardrail integrity (maintenance-gated): shell MUTATION of the rails.
#    A "mutation" is a FILE-write redirect while a rail is referenced, a redirect whose TARGET is a
#    rail, or a mutating command (tee/rm/mv/cp/ln/truncate/install/sed -i) with a rail referenced. A bare
#    stderr redirect next to a rail token (e.g. `cat .claude/x 2>/dev/null`) is a read, not a mutation.
if [ "$maint" != 1 ]; then
  if references_protected_path "$shell_scan"; then
    if unsafe_protected_write_redirect "$scan" \
      || matches_line "$scan" "$mutating_rail_re"; then
      block "mutating a protected rail (config / guard / policy) via shell is a maintenance-only action — set AGENT_LAB_MAINTENANCE=1" "Authority"
    fi
  fi
fi

# 5) branch backstop: never commit on protected branches (covers a skipped SessionStart bootstrap)
git_commit_re='(^|[^[:alnum:]_])git([[:space:]]+[^[:space:]]+)*[[:space:]]+commit([^[:alnum:]_]|$)'
if matches_line "$scan" "$git_commit_re"; then
  load_branch
  br="$branch"
  is_writable_branch \
    || block "refusing to commit on protected, detached, or invalid reserved branch '$br'" "Prime directives"
fi

exit 0
