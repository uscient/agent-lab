#!/usr/bin/env bash
# agent-lab containment lint — CONTENT checks (complements scripts/dev/guard-diff path checks
# and AGENTS.md invariants). Read-only. Exit 1 on any FAIL.
set -uo pipefail
fails=0; warns=0
fail(){ echo "FAIL  $1" >&2; fails=$((fails+1)); }
warn(){ echo "WARN  $1" >&2; warns=$((warns+1)); }

mapfile -t FILES < <(
  { git ls-files 2>/dev/null || find . -type f 2>/dev/null; } \
   | grep -Ev '(^|/)(\.git|tmp|node_modules)/' \
   | grep -Ei '(compose.*\.ya?ml$|\.ya?ml$|^dns/|^gateway/|^policies/|^images/|^profiles/|^env/|(^|/)\.env)' \
   | grep -v '\.example' | sort -u
)
[ "${#FILES[@]}" -eq 0 ] && { echo "containment-lint: no compose/topology files found here"; exit 0; }

scan(){ # scan <regex> <label> <fail|warn>
  local re="$1" label="$2" lvl="$3" hit
  hit="$(grep -EnI "$re" "${FILES[@]}" 2>/dev/null || true)"
  if [ -n "$hit" ]; then
    printf '%s\n' "$hit" | sed 's/^/      /'
    [ "$lvl" = fail ] && fail "$label" || warn "$label"
  fi
}

scan 'docker\.sock'                                              "Docker socket mount"                 fail
scan '(--privileged|privileged[[:space:]]*:[[:space:]]*true)'    "privileged container"                fail
scan '(network_mode[[:space:]]*:[[:space:]]*.?host|--network[=[:space:]]host)' "host networking"        fail
scan '(AKIA[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY|ghp_[0-9A-Za-z]{30,}|xox[bp]-[0-9A-Za-z-]{10,})' "likely real secret in tracked file" fail
scan '(\$\{?HOME\}?|/root/|\.ssh|\.aws|\.config/gcloud)[^:]*:'   "possible host-home/sensitive mount"  warn
scan '^[[:space:]]*-[[:space:]]*"?[0-9]+:[0-9]+'                 "published port without 127.0.0.1 bind" warn

echo "----"
echo "containment-lint: $fails fail, $warns warn"
[ "$fails" -gt 0 ] && exit 1 || exit 0
