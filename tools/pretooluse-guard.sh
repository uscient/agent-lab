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

for required_policy in deny.patterns carveout.patterns protected.paths; do
  [ -r "$pol/$required_policy" ] \
    || block "required policy input is missing or unreadable ($required_policy)" "Authority"
done

input="$(/bin/cat)"
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

# path_is_protected <path>: 0 if path is inside this repository worktree and matches any
# policy/protected.paths entry (at a / boundary on the repo-relative form). Host paths outside
# $root never match — e.g. ~/.grok/sessions/... is not a rail even though .grok/ is protected
# inside the repo.
path_is_protected() {
  local p="$1" entry needle hay resolved="" rel=""
  [ -z "$p" ] && return 1
  case "$p" in
    /*) resolved="$(readlink -m -- "$p" 2>/dev/null || true)" ;;
    *) resolved="$(readlink -m -- "$root/$p" 2>/dev/null || true)" ;;
  esac
  [ -n "$resolved" ] || return 1
  case "$resolved" in
    "$root"|"$root"/*) ;;
    *) return 1 ;;
  esac
  if [ "$resolved" = "$root" ]; then
    rel=""
  else
    rel="${resolved#"$root"/}"
  fi
  hay="/${rel}/"
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
    */secrets | */secrets/*) return 0 ;;
    */.env.example) return 1 ;;
  esac
  case "/$1" in
    */.env | */.env.* | */secrets | */secrets/* | *.pem | *.key | *.kdbx) return 0 ;;
    *) return 1 ;;
  esac
}

path_is_auth_material() {
  case "/$1" in
    */.gitconfig | */.config/git | */.config/git/* | */.config/gh | */.config/gh/* | */.ssh | */.ssh/* | */.netrc) return 0 ;;
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
  local target_first_re="^[[:space:]]*cat[[:space:]]+[0-9]*>>?[[:space:]]*[\"']?([A-Za-z0-9_./-]+)[\"']?[[:space:]]+<<[[:space:]]*[\"']([A-Za-z_][A-Za-z0-9_]*)[\"'][[:space:]]*$"
  local delimiter_first_re="^[[:space:]]*cat[[:space:]]+<<[[:space:]]*[\"']([A-Za-z_][A-Za-z0-9_]*)[\"'][[:space:]]+[0-9]*>>?[[:space:]]*[\"']?([A-Za-z0-9_./-]+)[\"']?[[:space:]]*$"
  scan="$s"
  [[ "$s" == *$'\n'* ]] || return
  first="${s%%$'\n'*}"
  if [[ "$first" =~ $target_first_re ]]; then
    target="${BASH_REMATCH[1]}"
    delimiter="${BASH_REMATCH[2]}"
  elif [[ "$first" =~ $delimiter_first_re ]]; then
    delimiter="${BASH_REMATCH[1]}"
    target="${BASH_REMATCH[2]}"
  else
    return
  fi
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

# Recognize a constrained Python document generator without treating its strings as shell
# operations. Only non-expanding shell forms, pure computation, pathlib, and repository-local file
# operations are accepted. Dynamic targets, unsafe imports/calls, malformed heredocs, and commands
# after the delimiter fail closed.
classify_literal_python_writer() {
  local s="$1" targets="" rc=0 target resolved
  [[ "$s" =~ ^[[:space:]]*(mkdir[[:space:]]+-p[[:space:]]+proj[[:space:]]+\&\&[[:space:]]+)?python3([[:space:]]|$) ]] \
    || return 1
  [ "$(command -v python3 2>/dev/null || true)" = /usr/bin/python3 ] && [ -x /usr/bin/python3 ] \
    || block "Python file-write command does not resolve to the trusted system interpreter" "Autonomy boundary"
  targets="$(
    printf '%s' "$s" | /usr/bin/python3 -I -S -c '
import ast
import re
import shlex
import sys

raw = sys.stdin.read()

def extract_code(text):
    prefix = r"(?:mkdir\s+-p\s+proj\s*&&\s*)?"
    command = re.fullmatch(r"\s*" + prefix + r"python3\s+-c\s+\x27([^\x27]*)\x27\s*", text, re.DOTALL)
    if command:
        return command.group(1), True, True, ""

    lines = text.splitlines()
    if not lines:
        return "", False, False, ""
    match = re.fullmatch(
        r"\s*" + prefix + r"python3(?:\s+-)?\s+<<\s*([\x27\x22])([A-Za-z_][A-Za-z0-9_]*)\1\s*",
        lines[0],
    )
    if not match:
        return "", False, False, ""
    delimiter = match.group(2)
    for index, line in enumerate(lines[1:], 1):
        if line == delimiter:
            trailing = lines[index + 1:]
            return "\n".join(lines[1:index]), True, True, "\n".join(trailing)
    return "\n".join(lines[1:]), True, False, ""

code, python_shape, complete, trailing = extract_code(raw)
if not python_shape:
    raise SystemExit(3)
if not complete:
    raise SystemExit(2)

def validate_trailing_verification(text):
    if not text.strip():
        return
    if any(marker in text for marker in ("$(", chr(96), "<(", ">(", "$" "{")):
        raise SystemExit(2)
    allowed_commands = {
        "[", "[[", "echo", "false", "grep", "head", "ls", "printf", "tail",
        "test", "true", "wc",
    }
    separators = {";", "&&", "||", "|", "&"}
    controls = {"if", "then", "elif", "else", "do", "!", "time"}
    endings = {"fi", "done"}
    for_mode = False
    for raw_line in text.splitlines():
        try:
            lexer = shlex.shlex(raw_line, posix=True, punctuation_chars=";&|<>")
            lexer.whitespace_split = True
            lexer.commenters = "#"
            tokens = list(lexer)
        except ValueError:
            raise SystemExit(2)
        if not tokens:
            continue
        if any(token in {"<", ">", "<<", ">>", "<>", ">|", "&>"} for token in tokens):
            raise SystemExit(2)
        expect_command = not for_mode
        for token in tokens:
            lowered = token.lower()
            if (
                token.startswith("/")
                and token != "/dev/null"
                or token == ".."
                or token.startswith("../")
                or "/.git" in token
                or ".gitconfig" in lowered
                or "/.ssh" in lowered
                or "/.config/gh" in lowered
                or "/secrets/" in lowered
                or lowered.startswith("secrets/")
                or "/.env" in lowered
                or lowered.startswith(".env")
            ):
                raise SystemExit(2)
            if for_mode:
                if token == "do":
                    for_mode = False
                    expect_command = True
                continue
            if token in separators:
                expect_command = True
                continue
            if not expect_command:
                continue
            if token == "for":
                for_mode = True
                expect_command = False
                continue
            if token in controls:
                expect_command = True
                continue
            if token in endings:
                expect_command = False
                continue
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", token):
                continue
            command = token.rsplit("/", 1)[-1]
            if command not in allowed_commands:
                raise SystemExit(2)
            expect_command = False
    if for_mode:
        raise SystemExit(2)

validate_trailing_verification(trailing)

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

string_bindings = {}
path_bindings = {}
file_bindings = {}
targets = []

def literal_value(node):
    if isinstance(node, ast.Name) and node.id in string_bindings:
        return string_bindings[node.id]
    try:
        return ast.literal_eval(node)
    except (ValueError, TypeError):
        raise SystemExit(2)

def path_target(node):
    if isinstance(node, ast.Name) and node.id in path_bindings:
        return path_bindings[node.id]
    if (
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Name)
        and node.func.id == "Path"
        and len(node.args) == 1
        and not node.keywords
    ):
        target = literal_value(node.args[0])
        if isinstance(target, str):
            return target
    raise SystemExit(2)

for statement in tree.body:
    if isinstance(statement, ast.Assign):
        if len(statement.targets) != 1 or not isinstance(statement.targets[0], ast.Name):
            continue
        name = statement.targets[0].id
        if (
            isinstance(statement.value, ast.Call)
            and isinstance(statement.value.func, ast.Name)
            and statement.value.func.id == "Path"
        ):
            path_bindings[name] = path_target(statement.value)
            continue
        try:
            value = ast.literal_eval(statement.value)
        except (ValueError, TypeError):
            continue
        if isinstance(value, (str, bytes)):
            string_bindings[name] = value
    if isinstance(statement, ast.With):
        for item in statement.items:
            opener = item.context_expr
            if (
                isinstance(opener, ast.Call)
                and isinstance(opener.func, ast.Name)
                and opener.func.id == "open"
                and isinstance(item.optional_vars, ast.Name)
                and opener.args
            ):
                target = literal_value(opener.args[0])
                if not isinstance(target, str):
                    raise SystemExit(2)
                file_bindings[item.optional_vars.id] = target

safe_builtin_calls = {
    "all", "any", "bool", "bytes", "dict", "enumerate", "float", "int", "len",
    "chr", "list", "max", "min", "print", "range", "reversed", "set", "sorted", "str",
    "sum", "tuple", "zip",
}
safe_method_calls = {
    "add", "append", "count", "decode", "encode", "endswith", "extend", "format",
    "get", "items", "join", "keys", "lower", "lstrip", "replace", "rstrip", "split",
    "splitlines", "startswith", "strip", "upper", "update", "values",
}

class Validator(ast.NodeVisitor):
    def visit_Import(self, node):
        if not (
            len(node.names) == 1
            and node.names[0].name == "os"
            and node.names[0].asname in {None, "os"}
        ):
            raise SystemExit(2)

    def visit_ImportFrom(self, node):
        if not (
            node.module == "pathlib"
            and node.level == 0
            and len(node.names) == 1
            and node.names[0].name == "Path"
            and node.names[0].asname in {None, "Path"}
        ):
            raise SystemExit(2)

    def visit_FunctionDef(self, node):
        raise SystemExit(2)

    visit_AsyncFunctionDef = visit_FunctionDef
    visit_ClassDef = visit_FunctionDef
    visit_Lambda = visit_FunctionDef

    def visit_Name(self, node):
        if node.id.startswith("_"):
            raise SystemExit(2)

    def visit_Attribute(self, node):
        if node.attr.startswith("_"):
            raise SystemExit(2)
        chain = []
        current = node
        while isinstance(current, ast.Attribute):
            chain.append(current.attr)
            current = current.value
        if isinstance(current, ast.Name) and current.id == "os":
            full = ["os"] + list(reversed(chain))
            if full not in (["os", "path"], ["os", "path", "getsize"]):
                raise SystemExit(2)
        self.generic_visit(node)

    def visit_Call(self, node):
        func = node.func
        if isinstance(func, ast.Name):
            if func.id == "Path":
                targets.append(path_target(node))
            elif func.id == "open":
                if not 1 <= len(node.args) <= 2:
                    raise SystemExit(2)
                target = literal_value(node.args[0])
                mode = literal_value(node.args[1]) if len(node.args) == 2 else "r"
                if not isinstance(target, str) or mode not in {
                    "r", "rb", "w", "a", "x", "wb", "ab", "xb",
                }:
                    raise SystemExit(2)
                if any(keyword.arg not in {"encoding", "errors", "newline"} for keyword in node.keywords):
                    raise SystemExit(2)
                targets.append(target)
            elif func.id not in safe_builtin_calls:
                raise SystemExit(2)
            self.generic_visit(node)
            return

        if not isinstance(func, ast.Attribute):
            raise SystemExit(2)
        method = func.attr
        chain = []
        current = func
        while isinstance(current, ast.Attribute):
            chain.append(current.attr)
            current = current.value
        full = [current.id] + list(reversed(chain)) if isinstance(current, ast.Name) else []
        if full == ["os", "path", "getsize"]:
            if len(node.args) != 1 or node.keywords:
                raise SystemExit(2)
            target = literal_value(node.args[0])
            if not isinstance(target, str):
                raise SystemExit(2)
            targets.append(target)
        elif method in {"write_text", "write_bytes"}:
            if len(node.args) != 1:
                raise SystemExit(2)
            allowed = {"encoding", "errors", "newline"} if method == "write_text" else set()
            if any(keyword.arg not in allowed for keyword in node.keywords):
                raise SystemExit(2)
            targets.append(path_target(func.value))
        elif method in {"read_text", "read_bytes", "resolve", "stat"}:
            if method in {"read_text", "read_bytes"}:
                allowed = {"encoding", "errors"} if method == "read_text" else set()
                if node.args or any(keyword.arg not in allowed for keyword in node.keywords):
                    raise SystemExit(2)
            elif node.args or node.keywords:
                raise SystemExit(2)
            targets.append(path_target(func.value))
        elif method == "write":
            opener = func.value
            direct_open = (
                isinstance(opener, ast.Call)
                and isinstance(opener.func, ast.Name)
                and opener.func.id == "open"
            )
            bound_open = isinstance(opener, ast.Name) and opener.id in file_bindings
            if not ((direct_open or bound_open) and len(node.args) == 1 and not node.keywords):
                raise SystemExit(2)
            if bound_open:
                targets.append(file_bindings[opener.id])
        elif method not in safe_method_calls:
            raise SystemExit(2)
        self.generic_visit(node)

Validator().visit(tree)

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

# split_shell_words <command>: emit one shell-decoded argument per line without expansion. Quoted
# spaces stay within one argument; substitutions, globbing, and command execution never occur.
split_shell_words() {
  /usr/bin/python3 -I -S - "$1" <<'PY'
import shlex
import sys

try:
    words = shlex.split(sys.argv[1], comments=False, posix=True)
except ValueError:
    raise SystemExit(1)
for word in words:
    if "\n" in word or "\r" in word or "\0" in word:
        raise SystemExit(1)
    print(word)
PY
}

validate_push() {
  local words=() arg positional=() lease=0 parsed=""
  parsed="$(split_shell_words "$scan")" || return 1
  while IFS= read -r arg; do words+=("$arg"); done <<<"$parsed"
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
  local words=() sub arg i base="" head="" required_base="" family_i=1
  local repo="" endpoint="" method="GET" parsed=""
  parsed="$(split_shell_words "$scan")" || return 1
  while IFS= read -r arg; do words+=("$arg"); done <<<"$parsed"
  [ "${words[0]:-}" = gh ] || return 1

  # Explicit current-repository selectors are equivalent to running in this checkout. Agents use
  # them routinely to make audit commands unambiguous; only cross-repository selectors are denied.
  case "${words[1]:-}" in
    -R | --repo)
      repo="${words[2]:-}"
      [ "$repo" = uscient/agent-lab ] || return 1
      family_i=3
      ;;
    -R?*)
      repo="${words[1]#-R}"
      [ "$repo" = uscient/agent-lab ] || return 1
      family_i=2
      ;;
    --repo=*)
      repo="${words[1]#*=}"
      [ "$repo" = uscient/agent-lab ] || return 1
      family_i=2
      ;;
    --hostname | --hostname=*) return 1 ;;
  esac

  if [ "${words[$family_i]:-}" = api ]; then
    i=$((family_i + 1))
    while [ "$i" -lt "${#words[@]}" ]; do
      arg="${words[$i]}"
      case "$arg" in
        -X | --method)
          i=$((i + 1)); method="${words[$i]:-}" ;;
        -X?*) method="${arg#-X}" ;;
        --method=*) method="${arg#*=}" ;;
        -f | -F | --field | --raw-field | --input | -H | --header | --hostname)
          return 1 ;;
        -f?* | -F?* | --field=* | --raw-field=* | --input=* | -H?* | --header=* | --hostname=*)
          return 1 ;;
        --paginate | --slurp | --include | --silent) ;;
        --cache | --jq | --template)
          i=$((i + 1)); [ "$i" -lt "${#words[@]}" ] || return 1 ;;
        --cache=* | --jq=* | --template=*) ;;
        -*) return 1 ;;
        *)
          [ -z "$endpoint" ] || return 1
          endpoint="${arg#/}"
          ;;
      esac
      i=$((i + 1))
    done
    [ "${method^^}" = GET ] || return 1
    case "$endpoint" in
      repos/uscient/agent-lab | repos/uscient/agent-lab/* | repos/uscient/agent-lab\?*) return 0 ;;
      *) return 1 ;;
    esac
  fi

  if [ "${words[$family_i]:-}" = run ]; then
    case "${words[$((family_i + 1))]:-}" in list | view | watch) ;; *) return 1 ;; esac
    i=$((family_i + 2))
    while [ "$i" -lt "${#words[@]}" ]; do
      arg="${words[$i]}"
      case "$arg" in
        -R | --repo)
          i=$((i + 1)); [ "${words[$i]:-}" = uscient/agent-lab ] || return 1 ;;
        -R?*) [ "${arg#-R}" = uscient/agent-lab ] || return 1 ;;
        --repo=*) [ "${arg#*=}" = uscient/agent-lab ] || return 1 ;;
        --hostname | --hostname=*) return 1 ;;
      esac
      i=$((i + 1))
    done
    return 0
  fi
  [ "${words[$family_i]:-}" = pr ] || return 1
  sub="${words[$((family_i + 1))]:-}"
  i=$((family_i + 2))
  while [ "$i" -lt "${#words[@]}" ]; do
    arg="${words[$i]}"
    case "$arg" in
      -R | --repo)
        i=$((i + 1)); [ "${words[$i]:-}" = uscient/agent-lab ] || return 1 ;;
      -R?*) [ "${arg#-R}" = uscient/agent-lab ] || return 1 ;;
      --repo=*) [ "${arg#*=}" = uscient/agent-lab ] || return 1 ;;
      --hostname | --hostname=*) return 1 ;;
    esac
    i=$((i + 1))
  done
  case "$sub" in
    list | view | status | checks | diff) return 0 ;;
    create) ;;
    *) return 1 ;;
  esac
  load_branch
  required_base="$(expected_pr_base)" || return 1
  i=$((family_i + 2))
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
  local words=() expected="" arg parsed=""
  parsed="$(split_shell_words "$scan")" || return 1
  while IFS= read -r arg; do words+=("$arg"); done <<<"$parsed"
  [ "${#words[@]}" -eq 3 ] || return 1
  [ "${words[0]}" = git ] && [ "${words[1]}" = rebase ] || return 1
  expected="$(expected_rebase_target)" || return 1
  [ "${words[2]}" = "$expected" ]
}

# sanitize_nonexecuting_inspection_chain <command>: for a shell-aware chain made entirely of
# read-only Git inspection, searches, and pipe-only output filters, emit a canonical scan with
# search expressions removed but file operands retained. The canonical command still passes through
# every policy check below; this function never authorizes or exits early. Recognized dynamic or
# executable forms block; commands outside this grammar continue through the original policy scan.
sanitize_nonexecuting_inspection_chain() {
  /usr/bin/python3 -I -S - "$1" <<'PY'
import os
import posixpath
import re
import shlex
import sys

text = sys.argv[1]

def normalize_shell_source(source):
    output = []
    state = "plain"
    escaped = False
    for index, char in enumerate(source):
        if escaped:
            output.append(char)
            escaped = False
            continue
        if state == "single":
            output.append(char)
            if char == "'":
                state = "plain"
            continue
        if char == "\\":
            output.append(char)
            escaped = True
            continue
        if state == "double":
            output.append(char)
            if char == '"':
                state = "plain"
            continue
        if char == "'":
            state = "single"
            output.append(char)
        elif char == '"':
            state = "double"
            output.append(char)
        elif char == "\n":
            output.extend((" ", ";", " "))
        else:
            output.append(char)
    return "".join(output)

try:
    lexer = shlex.shlex(normalize_shell_source(text), posix=True, punctuation_chars=";&|<>()")
    lexer.whitespace_split = True
    lexer.commenters = ""
    tokens = list(lexer)
except ValueError:
    raise SystemExit(1)
if not tokens:
    raise SystemExit(1)

def strip_safe_null_redirections(items):
    stripped = []
    index = 0
    while index < len(items):
        if items[index] in {">", ">>", "&>"} and index + 1 < len(items) and items[index + 1] == "/dev/null":
            index += 2
            continue
        if (
            items[index].isdigit()
            and index + 2 < len(items)
            and items[index + 1] in {">", ">>"}
            and items[index + 2] == "/dev/null"
        ):
            index += 3
            continue
        if (
            items[index].isdigit()
            and index + 2 < len(items)
            and items[index + 1] in {">&", "<&"}
            and (items[index + 2].isdigit() or items[index + 2] == "-")
        ):
            index += 3
            continue
        stripped.append(items[index])
        index += 1
    return stripped

tokens = strip_safe_null_redirections(tokens)

separators = {";", "&&", "||", "|"}
segments = []
operators = []
current = []
for token in tokens:
    if token and all(char in ";&|<>()" for char in token):
        if token not in separators:
            raise SystemExit(1)
        if not current:
            raise SystemExit(1)
        segments.append(current)
        operators.append(token)
        current = []
    else:
        current.append(token)
if not current:
    raise SystemExit(1)
segments.append(current)

assignment_re = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

def unwrap_segment(segment):
    assignments = []
    index = 0
    while index < len(segment) and assignment_re.match(segment[index]):
        assignments.append(segment[index])
        index += 1
    if index < len(segment) and posixpath.basename(segment[index]) == "env":
        index += 1
        while index < len(segment):
            arg = segment[index]
            if assignment_re.match(arg):
                assignments.append(arg)
                index += 1
                continue
            if arg in {"-i", "--ignore-environment", "-0", "--null"}:
                index += 1
                continue
            if arg == "--":
                index += 1
                break
            if arg in {"-S", "--split-string"}:
                assignments.append("AGENT_LAB_UNSAFE_ENV_SPLIT=1")
                index += 2
                continue
            if arg.startswith("--split-string="):
                assignments.append("AGENT_LAB_UNSAFE_ENV_SPLIT=1")
                index += 1
                continue
            if arg in {"-C", "--chdir"}:
                assignments.append("AGENT_LAB_UNSAFE_ENV_CHDIR=1")
                index += 2
                continue
            if arg.startswith("--chdir="):
                assignments.append("AGENT_LAB_UNSAFE_ENV_CHDIR=1")
                index += 1
                continue
            if arg in {"-u", "--unset"}:
                if index + 1 >= len(segment):
                    return None, assignments
                index += 2
                continue
            if arg.startswith("--unset=") or (arg.startswith("-u") and arg != "-u"):
                index += 1
                continue
            break
    if index >= len(segment):
        return [], assignments
    actual = segment[index:]
    if actual[0] == "command":
        command_index = 1
        while command_index < len(actual) and actual[command_index] in {"-p", "--"}:
            command_index += 1
        if command_index >= len(actual) or actual[command_index] in {"-v", "-V"}:
            return actual, assignments
        actual = actual[command_index:]
    if actual[0] in {"git", "/usr/bin/git"} and actual[1:2] == ["--no-pager"]:
        actual = [actual[0], *actual[2:]]
    return actual, assignments

unwrapped = []
has_inspection_head = False
for segment in segments:
    actual, assignments = unwrap_segment(segment)
    unwrapped.append((actual, assignments))
    if actual:
        command = actual[0]
        args = actual[1:]
        if command in {"rg", "/usr/bin/rg", "grep", "/usr/bin/grep", "/bin/grep"}:
            has_inspection_head = True
        elif posixpath.basename(command) == "jq":
            has_inspection_head = True
        elif posixpath.basename(command) == "gh" and any(
            arg in {"--jq", "-q"} or arg.startswith(("--jq=", "-q")) for arg in args
        ):
            has_inspection_head = True
        elif posixpath.basename(command) == "gh":
            has_inspection_head = True
        elif command in {"git", "/usr/bin/git"} and args[:1] in (["grep"], ["diff"], ["log"], ["show"]):
            has_inspection_head = True
if not has_inspection_head:
    raise SystemExit(1)

def option_value(args, index, attached=None):
    if attached is not None:
        return attached, index + 1
    if index + 1 >= len(args):
        raise ValueError
    return args[index + 1], index + 2

def sensitive_path(value):
    if value in {"", "-", "."}:
        return False
    candidate = value.replace("${HOME}", "HOME").replace("$HOME", "HOME")
    if candidate.startswith("~"):
        candidate = "HOME" + candidate[1:]
    if ":" in candidate and "://" not in candidate:
        candidate = candidate.rsplit(":", 1)[1]
    candidate = posixpath.normpath(candidate)
    components = [part for part in candidate.split("/") if part not in {"", ".", ".."}]
    for index, component in enumerate(components):
        probe = component.lstrip("!")
        env_match = re.search(r"(^|[*?\\]])\\.env([^A-Za-z]|$)", probe)
        if env_match and probe != ".env.example":
            return True
        if probe.strip("*?[]") == "secrets":
            return True
        if probe.strip("*?[]") in {".ssh", ".gitconfig", ".netrc"}:
            return True
        if probe.endswith((".pem", ".key", ".kdbx")):
            return True
        if probe == ".config" and index + 1 < len(components):
            if components[index + 1].strip("*?[]") in {"git", "gh"}:
                return True
    return False

def retain_path(paths, value):
    if sensitive_path(value):
        raise SystemExit(2)
    paths.append(value)

def dynamic_shell_word(value):
    if "`" in value or re.search(r"\$[A-Za-z_({\"'`?!*#@-]", value):
        return True
    for match in re.finditer(r"\{([^{}]*)\}", value):
        if "," in match.group(1) or ".." in match.group(1):
            return True
    return False

def abbreviates_option(name, full):
    return name.startswith("--") and len(name) >= 5 and full.startswith(name)

def consume_short_option(arg, args, index, flavor, paths, state):
    cluster = arg[1:]
    if not cluster:
        return index + 1
    if flavor == "rg":
        value_actions = {
            "A": "data", "B": "data", "C": "data", "d": "data", "E": "data",
            "e": "pattern", "f": "path_pattern", "g": "selector", "j": "data",
            "M": "data", "m": "data", "r": "data", "T": "data", "t": "data",
        }
        flags = set("0abcFHIilNnopPqSsUuvwxy")
        dangers = {"L", "z"}
    elif flavor == "grep":
        value_actions = {
            "A": "data", "B": "data", "C": "data", "D": "data", "d": "data",
            "e": "pattern", "f": "path_pattern", "m": "data",
        }
        flags = set("aEFGPIRHhioqsTVvwxZzbnrlLcuU")
        dangers = set()
    else:
        value_actions = {
            "A": "data", "B": "data", "C": "data", "e": "pattern",
            "f": "path_pattern", "m": "data",
        }
        flags = set("aEFGPHhIiLlnoqrsvwxzpcW")
        dangers = {"O"}
    position = 0
    while position < len(cluster):
        char = cluster[position]
        if char in dangers:
            raise SystemExit(2)
        if char in value_actions:
            attached = cluster[position + 1:]
            try:
                value, next_index = option_value(args, index, attached if attached else None)
            except ValueError:
                raise SystemExit(2)
            action = value_actions[char]
            if action == "pattern":
                state["explicit_pattern"] = True
            elif action == "path_pattern":
                retain_path(paths, value)
                state["explicit_pattern"] = True
            elif action == "selector":
                if not value.startswith("!"):
                    retain_path(paths, value)
            return next_index
        if char.isdigit() or char in flags:
            position += 1
            continue
        return None
    return index + 1

def sanitize_search(segment, assignments):
    command = segment[0]
    args = segment[1:]
    git_grep = command in {"git", "/usr/bin/git"} and args[:1] == ["grep"]
    if git_grep:
        prefix = [command, "grep"]
        args = args[1:]
    elif command in {"rg", "/usr/bin/rg", "grep", "/usr/bin/grep", "/bin/grep"}:
        prefix = [command]
    else:
        return None

    is_rg = command == "rg" or command.endswith("/rg")
    flavor = "git_grep" if git_grep else ("rg" if is_rg else "grep")
    local_names = {assignment.split("=", 1)[0] for assignment in assignments}
    state = {"explicit_pattern": False, "positional_pattern": False, "no_pattern_mode": False, "no_config": False}
    paths = []
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == "--":
            remainder = args[index + 1:]
            if state["no_pattern_mode"]:
                for value in remainder:
                    retain_path(paths, value)
                break
            if not state["explicit_pattern"] and not state["positional_pattern"]:
                if not remainder:
                    return None
                state["positional_pattern"] = True
                remainder = remainder[1:]
            for value in remainder:
                retain_path(paths, value)
            break
        if arg.startswith("--"):
            if dynamic_shell_word(arg):
                raise SystemExit(2)
            name, separator, attached = arg.partition("=")
            if is_rg and any(
                name == full or abbreviates_option(name, full)
                for full in {"--pre", "--hostname-bin", "--search-zip", "--follow"}
            ):
                raise SystemExit(2)
            if git_grep and any(
                name == full or abbreviates_option(name, full)
                for full in {"--open-files-in-pager", "--textconv", "--ext-grep"}
            ):
                raise SystemExit(2)
            pattern_names = {"--regexp"}
            path_pattern_names = {"--file"}
            path_names = {"--ignore-file", "--exclude-from", "--files0-from"}
            include_names = {"--glob", "--iglob", "--include", "--pre-glob"}
            exclude_names = {"--exclude", "--exclude-dir"}
            data_names = {
                "--after-context", "--before-context", "--binary-files", "--colors",
                "--context", "--context-separator", "--devices", "--directories",
                "--dfa-size-limit", "--encoding", "--engine", "--field-context-separator",
                "--field-match-separator", "--group-separator", "--hyperlink-format",
                "--label", "--max-columns", "--max-count", "--max-depth", "--max-filesize",
                "--path-separator", "--regex-size-limit", "--replace", "--sort",
                "--sortr", "--threads", "--type", "--type-add", "--type-clear",
                "--type-not",
            }
            optional_data_names = {"--color", "--hyperlink"}
            flag_names = {
                "--binary", "--block-buffered", "--byte-offset", "--case-sensitive",
                "--column", "--count", "--count-matches", "--crlf", "--debug",
                "--files", "--files-with-matches",
                "--files-without-match", "--fixed-strings", "--heading", "--hidden",
                "--ignore-case", "--invert-match", "--json", "--line-buffered",
                "--line-number", "--messages", "--mmap", "--multiline",
                "--multiline-dotall", "--no-config", "--no-filename", "--no-heading",
                "--no-ignore", "--no-ignore-dot", "--no-ignore-exclude",
                "--no-ignore-files", "--no-ignore-global", "--no-ignore-messages",
                "--no-ignore-parent", "--no-ignore-vcs", "--no-line-number",
                "--no-messages", "--no-pcre2-unicode", "--no-require-git",
                "--no-unicode", "--null", "--null-data", "--one-file-system",
                "--only-matching", "--passthru", "--pcre2", "--pcre2-unicode",
                "--pretty", "--quiet", "--require-git", "--smart-case", "--stats",
                "--stop-on-nonmatch", "--text", "--trace", "--trim", "--unrestricted",
                "--vimgrep", "--with-filename", "--word-regexp", "--line-regexp",
                "--recursive", "--dereference-recursive", "--extended-regexp",
                "--fixed-regexp", "--basic-regexp", "--perl-regexp", "--regexp-extended",
                "--glob-case-insensitive", "--no-follow", "--no-search-zip", "--no-pre",
            }
            if git_grep:
                flag_names |= {
                    "--cached", "--no-index", "--untracked", "--exclude-standard",
                    "--recurse-submodules", "--no-textconv", "--full-name", "--break",
                    "--show-function", "--function-context", "--all-match",
                    "--no-open-files-in-pager",
                }
            if name in pattern_names:
                try:
                    _, index = option_value(args, index, attached if separator else None)
                except ValueError:
                    raise SystemExit(2)
                state["explicit_pattern"] = True
                continue
            if name in path_pattern_names | path_names | include_names | exclude_names | data_names:
                try:
                    value, index = option_value(args, index, attached if separator else None)
                except ValueError:
                    raise SystemExit(2)
                if name in path_pattern_names:
                    retain_path(paths, value)
                    state["explicit_pattern"] = True
                elif name in path_names:
                    retain_path(paths, value)
                elif name in include_names:
                    if not value.startswith("!"):
                        retain_path(paths, value)
                continue
            if name in optional_data_names:
                index += 1
                continue
            if name in flag_names:
                if separator:
                    return None
                if name == "--files":
                    state["no_pattern_mode"] = True
                if name == "--no-config":
                    state["no_config"] = True
                index += 1
                continue
            return None
        if arg.startswith("-") and arg != "-":
            if dynamic_shell_word(arg):
                raise SystemExit(2)
            next_index = consume_short_option(arg, args, index, flavor, paths, state)
            if next_index is None:
                return None
            index = next_index
            continue
        if state["no_pattern_mode"]:
            retain_path(paths, arg)
        elif not state["explicit_pattern"] and not state["positional_pattern"]:
            if dynamic_shell_word(arg):
                raise SystemExit(2)
            state["positional_pattern"] = True
        else:
            retain_path(paths, arg)
        index += 1
    if is_rg and (os.environ.get("RIPGREP_CONFIG_PATH") or "RIPGREP_CONFIG_PATH" in local_names) and not state["no_config"]:
        raise SystemExit(2)
    if not state["no_pattern_mode"] and not state["explicit_pattern"] and not state["positional_pattern"]:
        return None
    return prefix + paths

def sanitize_git_read(segment, assignments):
    if segment[0] not in {"git", "/usr/bin/git"} or len(segment) < 2:
        return None
    subcommand = segment[1]
    args = segment[2:]
    allowed = {"branch", "describe", "diff", "log", "ls-files", "merge-base", "name-rev", "rev-parse", "show", "status"}
    if subcommand not in allowed:
        return None
    if any(assignment.startswith("GIT_EXTERNAL_DIFF=") for assignment in assignments):
        raise SystemExit(2)
    if subcommand in {"diff", "log", "show"}:
        for arg in args:
            name = arg.partition("=")[0]
            if any(
                name == full or abbreviates_option(name, full)
                for full in {"--ext-diff", "--textconv", "--no-index", "--output"}
            ):
                raise SystemExit(2)
    if subcommand == "branch" and any(
        arg in {"-d", "-D", "-m", "-M", "-c", "-C", "--delete", "--move", "--copy",
                "--edit-description", "--set-upstream-to", "--unset-upstream", "--create-reflog"}
        or arg.startswith("--set-upstream-to=")
        for arg in args
    ):
        return None
    data_options = {
        "--author", "--committer", "--date", "--decorate-refs", "--format", "--grep", "--pretty",
        "--since", "--until", "--after", "--before", "--word-diff-regex", "--anchored",
    }
    sanitized = [segment[0], subcommand]
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == "--":
            sanitized.append(arg)
            for value in args[index + 1:]:
                if sensitive_path(value):
                    raise SystemExit(2)
                sanitized.append(value)
            break
        if arg in data_options or arg in {"-G", "-S", "-L"}:
            if index + 1 >= len(args):
                raise SystemExit(2)
            index += 2
            continue
        if any(arg.startswith(option + "=") for option in data_options):
            index += 1
            continue
        if (arg.startswith("-G") or arg.startswith("-S") or arg.startswith("-L")) and len(arg) > 2:
            index += 1
            continue
        if sensitive_path(arg):
            raise SystemExit(2)
        sanitized.append(arg)
        index += 1
    return sanitized

def sanitize_filter(segment):
    command = segment[0]
    args = segment[1:]
    if command not in {"head", "tail", "wc", "sort", "uniq"}:
        return None
    if any(arg.startswith("-") and dynamic_shell_word(arg) for arg in args):
        raise SystemExit(2)
    if command in {"wc", "sort"} and any(
        arg == "--files0-from" or arg.startswith("--files0-from=")
        for arg in args
    ):
        raise SystemExit(2)
    if command == "sort":
        for arg in args:
            name = arg.partition("=")[0]
            if (
                arg in {"-o", "-T"}
                or (arg.startswith("-o") and arg != "-o")
                or (arg.startswith("-T") and arg != "-T")
                or any(
                    name == full or abbreviates_option(name, full)
                    for full in {
                        "--output", "--compress-program", "--temporary-directory",
                        "--files0-from", "--random-source",
                    }
                )
            ):
                raise SystemExit(2)
    if command == "sort":
        index = 0
        while index < len(args):
            arg = args[index]
            if arg.startswith("-") and not arg.startswith("--") and arg != "-":
                cluster = arg[1:]
                position = 0
                while position < len(cluster):
                    char = cluster[position]
                    if char in {"o", "T"}:
                        raise SystemExit(2)
                    if char in {"k", "S", "t"}:
                        if position + 1 == len(cluster):
                            index += 1
                        break
                    position += 1
            index += 1
    if command == "uniq":
        positional = []
        index = 0
        value_options = {"-f", "--skip-fields", "-s", "--skip-chars", "-w", "--check-chars"}
        while index < len(args):
            arg = args[index]
            if arg == "--":
                positional.extend(args[index + 1:])
                break
            if arg in value_options:
                index += 2
                continue
            if arg.startswith(("--skip-fields=", "--skip-chars=", "--check-chars=")):
                index += 1
                continue
            if arg.startswith("-"):
                index += 1
                continue
            positional.append(arg)
            index += 1
        if len(positional) > 1:
            raise SystemExit(2)
    return segment

def sanitize_local_read(segment):
    if not segment:
        return None
    if segment[0] in {"ls", "pwd", "wc", "head", "tail", "stat", "file"}:
        return segment
    return None

def sanitize_jq_filter(segment):
    if not segment or posixpath.basename(segment[0]) != "jq":
        return None
    args = segment[1:]
    paths = []
    filter_seen = False
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == "--":
            remainder = args[index + 1:]
            if not filter_seen:
                if not remainder:
                    return None
                filter_seen = True
                remainder = remainder[1:]
            for value in remainder:
                retain_path(paths, value)
            break
        if arg in {"-f", "--from-file", "-L", "--library-path"} or arg.startswith(("--from-file=", "--library-path=")):
            raise SystemExit(2)
        if arg in {"--arg", "--argjson"}:
            if index + 2 >= len(args):
                raise SystemExit(2)
            index += 3
            continue
        if arg in {"--slurpfile", "--rawfile", "--argfile"}:
            if index + 2 >= len(args):
                raise SystemExit(2)
            retain_path(paths, args[index + 2])
            index += 3
            continue
        if arg.startswith("-") and arg != "-":
            index += 1
            continue
        if not filter_seen:
            filter_seen = True
        else:
            retain_path(paths, arg)
        index += 1
    if not filter_seen:
        return None
    return [segment[0], *paths]

def sanitize_gh_command(segment):
    if not segment or posixpath.basename(segment[0]) != "gh":
        return None
    sanitized = [segment[0]]
    index = 1
    while index < len(segment):
        arg = segment[index]
        if arg in {"--jq", "-q"}:
            if index + 1 >= len(segment):
                return None
            sanitized.extend((arg, "."))
            index += 2
            continue
        if arg.startswith("--jq="):
            sanitized.append("--jq=.")
            index += 1
            continue
        if arg.startswith("-q") and arg != "-q":
            sanitized.append("-q.")
            index += 1
            continue
        sanitized.append(arg)
        index += 1
    return sanitized

saw_search = False
saw_jq_data = False
saw_gh = False
sanitized = []
kinds = []
for index, (segment, assignments) in enumerate(unwrapped):
    operator_before = operators[index - 1] if index else None
    assignment_names = {assignment.split("=", 1)[0] for assignment in assignments}
    if assignment_names & {
        "GH_TOKEN", "GITHUB_TOKEN", "GIT_ASKPASS", "SSH_AUTH_SOCK", "BASH_ENV", "ENV",
        "AGENT_LAB_UNSAFE_ENV_SPLIT", "AGENT_LAB_UNSAFE_ENV_CHDIR",
    }:
        raise SystemExit(2)
    if not segment and assignments:
        candidate = ["true"]
        kind = "assignment"
    else:
        candidate = sanitize_search(segment, assignments)
        kind = None
    if candidate is not None:
        if kind is None:
            saw_search = True
            kind = "search"
    else:
        candidate = sanitize_git_read(segment, assignments)
        kind = "git" if candidate is not None else None
    if candidate is None and operator_before != "|":
        candidate = sanitize_local_read(segment)
        kind = "local" if candidate is not None else None
    if candidate is None:
        candidate = sanitize_jq_filter(segment)
        kind = "filter" if candidate is not None and operator_before == "|" else ("jq" if candidate is not None else None)
        if candidate is not None:
            saw_jq_data = True
    if candidate is None and operator_before != "|":
        candidate = sanitize_gh_command(segment)
        kind = "gh" if candidate is not None else None
        if candidate is not None:
            saw_gh = True
    if candidate is None and operator_before == "|":
        candidate = sanitize_filter(segment)
        kind = "filter" if candidate is not None else None
    if candidate is None and operator_before == "||" and segment == ["true"]:
        candidate = segment
        kind = "true"
    if candidate is None:
        raise SystemExit(1)
    if operator_before == "|" and kind not in {"search", "filter"}:
        raise SystemExit(1)
    if kind == "filter" and operator_before != "|":
        raise SystemExit(1)
    if kind == "true" and operator_before != "||":
        raise SystemExit(1)
    if kind == "assignment" and operator_before == "|":
        raise SystemExit(1)
    sanitized.append(candidate)
    kinds.append(kind)

if not saw_search and not saw_jq_data and not saw_gh and not any(segment and segment[1:2] in (["diff"], ["log"], ["show"]) for segment, _ in unwrapped):
    raise SystemExit(1)
if saw_gh and kinds.count("gh") == 1 and all(kind in {"assignment", "gh"} for kind in kinds):
    print(shlex.join(sanitized[kinds.index("gh")]))
    raise SystemExit(0)
parts = []
for index, segment in enumerate(sanitized):
    if index:
        parts.append(operators[index - 1])
    parts.append(shlex.join(segment))
print(" ".join(parts))
PY
}

# requests_environment_disclosure <command>: true only when an actual jq filter (standalone or
# passed through gh --jq) invokes jq's environment builtins. Search text and --arg data stay data.
requests_environment_disclosure() {
  /usr/bin/python3 -I -S - "$1" <<'PY'
import os
import re
import shlex
import sys

def normalize_newlines(source):
    output = []
    state = "plain"
    escaped = False
    for char in source:
        if escaped:
            output.append(char)
            escaped = False
            continue
        if state == "single":
            output.append(char)
            if char == "'":
                state = "plain"
            continue
        if char == "\\":
            output.append(char)
            escaped = True
            continue
        if state == "double":
            output.append(char)
            if char == '"':
                state = "plain"
            continue
        if char == "'":
            state = "single"
            output.append(char)
        elif char == '"':
            state = "double"
            output.append(char)
        elif char == "\n":
            output.extend((" ", ";", " "))
        else:
            output.append(char)
    return "".join(output)

try:
    lexer = shlex.shlex(normalize_newlines(sys.argv[1]), posix=True, punctuation_chars=";&|<>()")
    lexer.whitespace_split = True
    lexer.commenters = ""
    tokens = list(lexer)
except ValueError:
    raise SystemExit(1)

segments = []
current = []
for token in tokens:
    if token and all(char in ";&|<>()" for char in token):
        if current:
            segments.append(current)
            current = []
    else:
        current.append(token)
if current:
    segments.append(current)

assignment_re = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

def actual_command(segment):
    index = 0
    while index < len(segment) and assignment_re.match(segment[index]):
        index += 1
    if index < len(segment) and os.path.basename(segment[index]) == "env":
        index += 1
        while index < len(segment):
            arg = segment[index]
            if assignment_re.match(arg):
                index += 1
                continue
            if arg in {"-i", "--ignore-environment", "-0", "--null"}:
                index += 1
                continue
            if arg in {"-u", "--unset", "-C", "--chdir"}:
                index += 2
                continue
            if arg.startswith(("--unset=", "--chdir=")):
                index += 1
                continue
            break
    return segment[index:] if index < len(segment) else []

def jq_filter_reads_environment(program):
    interpolation = re.search(
        r"\\\([^)]*((?<![A-Za-z0-9_.$])env(?![A-Za-z0-9_])|\$ENV(?![A-Za-z0-9_]))",
        program,
    )
    if interpolation:
        return True
    visible = []
    in_string = False
    escaped = False
    comment = False
    for char in program:
        if comment:
            if char == "\n":
                comment = False
                visible.append(char)
            continue
        if escaped:
            escaped = False
            continue
        if in_string:
            if char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char == "#":
            comment = True
        else:
            visible.append(char)
    code = "".join(visible)
    return bool(
        re.search(r"(?<![A-Za-z0-9_.$])env(?![A-Za-z0-9_])", code)
        or re.search(r"\$ENV(?![A-Za-z0-9_])", code)
    )

def jq_filter(args):
    index = 0
    two_value_options = {"--arg", "--argjson", "--slurpfile", "--rawfile", "--argfile"}
    one_value_options = {"-L", "--library-path", "-f", "--from-file"}
    while index < len(args):
        arg = args[index]
        if arg == "--":
            return args[index + 1] if index + 1 < len(args) else None
        if arg in two_value_options:
            index += 3
            continue
        if arg in one_value_options:
            index += 2
            continue
        if any(arg.startswith(option + "=") for option in two_value_options | one_value_options):
            index += 1
            continue
        if arg.startswith("-") and arg != "-":
            index += 1
            continue
        return arg
    return None

for segment in segments:
    argv = actual_command(segment)
    if not argv:
        continue
    command = os.path.basename(argv[0])
    if command == "jq":
        program = jq_filter(argv[1:])
        if program is not None and jq_filter_reads_environment(program):
            raise SystemExit(0)
    if command == "gh":
        args = argv[1:]
        index = 0
        while index < len(args):
            arg = args[index]
            program = None
            if arg in {"--jq", "-q"}:
                if index + 1 < len(args):
                    program = args[index + 1]
                index += 2
            elif arg.startswith("--jq="):
                program = arg.split("=", 1)[1]
                index += 1
            elif arg.startswith("-q") and arg != "-q":
                program = arg[2:]
                index += 1
            else:
                index += 1
            if program is not None and jq_filter_reads_environment(program):
                raise SystemExit(0)
raise SystemExit(1)
PY
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
git_integration_re='(^|[^[:alnum:]_])git([[:space:]]+[^[:space:]]+)*[[:space:]]+(merge|rebase)([[:space:]]|$)'
git_slice_merge_re="(^|[^[:alnum:]_])git[[:space:]]+merge[[:space:]]+([^[:space:]]+[[:space:]]+)*[\"']?slice/"
gh_command_re='(^|[^[:alnum:]_./-])gh([^[:alnum:]_./-]|$)|(^|[;&|][[:space:]]*)/[^[:space:]]*/gh([[:space:]]|$)'
credential_path_re="(^|[[:space:]\"'=:])([^[:space:]\"']*/)?(\\.gitconfig([^[:alnum:]]|$)|\\.config/(git|gh)(/|[^[:alnum:]]|$)|\\.ssh(/|[^[:alnum:]]|$)|\\.netrc([^[:alnum:]]|$))"
token_env_re='(^|[^[:alnum:]_])(GH_TOKEN|GITHUB_TOKEN|GIT_ASKPASS|SSH_AUTH_SOCK)([^[:alnum:]_]|$)'
bulk_env_re='(^|[;&|][[:space:]]*)(printenv|env|set)[[:space:]]*([;&|]|$)'
mutating_rail_re='(^|[[:space:]])(tee|rm|mv|cp|ln|truncate|install)[[:space:]]|sed[[:space:]]+-i'

# Check actual jq programs before search expressions are redacted. Mentions inside rg/grep patterns
# never appear as jq command heads, so policy audits remain usable.
case "$scan" in
  *jq* | *'\$ENV'*)
    requests_environment_disclosure "$scan" \
      && block "bulk environment disclosure through jq is forbidden" "Autonomy boundary"
    ;;
esac

# Search expressions in a fully classified inspection chain are data. Replace only those expressions
# with a canonical scan, then continue through every normal policy check with file operands intact.
case "$scan" in
  *rg* | *grep* | *jq* | *gh* | *'git diff'* | *'git log'* | *'git show'*)
    inspection_rc=0
    inspection_scan="$(sanitize_nonexecuting_inspection_chain "$scan")" || inspection_rc=$?
    [ "$inspection_rc" -ne 2 ] \
      || block "inspection command requests execution, output files, dynamic paths, or ambient preprocessing" "Autonomy boundary"
    if [ -n "$inspection_scan" ]; then
      scan="$inspection_scan"
      shell_scan="${scan//\"/}"
      shell_scan="${shell_scan//\'/}"
      shell_scan="${shell_scan//\\/}"
      shell_scan="${shell_scan//\$/}"
    fi
    ;;
esac

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
if matches_line "$shell_scan" "$gh_command_re"; then
  validate_gh || block "GitHub access is limited to repository-scoped PR/Actions reads, GET-only API reads, and the exact PR route derived from the current branch" "Autonomy boundary"
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
secret_path_re="(^|[[:space:]\"'=:])([^[:space:]\"']*/)?(\\.env([^a-zA-Z]|$)|secrets(/|[^[:alnum:]_-]|$)|[^[:space:]\"']*\\.(pem|key|kdbx)([^a-zA-Z]|$))"
# The tracked sample is documentation, not secret state. Preserve any directory prefix so an
# example under secrets/ remains blocked, and require a token boundary so suffixes stay secret.
secret_scan="$scan"
if [[ "$secret_scan" == *'.env.example'* ]]; then
  secret_scan="$(
    printf '%s' "$scan" \
      | sed -E "s#(^|[[:space:]\"'=])([^[:space:]\"']*/)?\\.env\\.example([[:space:]\"'<>;&|)]|$)#\\1\\2ENV_EXAMPLE\\3#g"
  )"
fi
if matches_line "$secret_scan" "$secret_path_re"; then
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
