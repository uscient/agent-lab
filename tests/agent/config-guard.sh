#!/usr/bin/env bash
set -euo pipefail

# Regression for the config-authority fix (High-1): a BYOA value set ONLY in the env-file must
# be loaded, validated, and guarded by scripts/agent -- never bypassed. Docker-free: `--check`
# loads/validates/guards and builds the allowlist, but never builds images or brings up a
# stack. Run: bash tests/agent/config-guard.sh

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
cd "$repo_root"

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# These must NOT be in our shell env, so the loader is forced to read them from the env-file.
unset AGENT_LAB_PROJECT_DIR AGENT_LAB_SECRETS_DIR AGENT_LAB_ALLOWLIST_RECIPES \
      AGENT_LAB_EPHEMERAL_HOME AGENT_LAB_AGENT_IMAGE AGENT_LAB_AGENT_UID AGENT_LAB_AGENT_GID || true

run_check() { AGENT_LAB_ENV_FILE="$1" ./scripts/agent --check; }

no_bringup() { ! printf '%s\n' "$1" | grep -qE '(Creating|Created|Starting|Started|Pulling|Running)'; }

# --- Case 1: PROJECT_DIR=<your home> present ONLY in the env-file must be REFUSED ---
ef_home="$work/home.env"
printf 'AGENT_LAB_PROJECT_DIR=%s\n' "$HOME" > "$ef_home"
rc=0; out="$(run_check "$ef_home" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qi 'home directory'; then
  pass "env-file PROJECT_DIR=\$HOME is refused at preflight (rc=$rc)"
else
  fail "env-file PROJECT_DIR=\$HOME was NOT refused (rc=$rc)"
fi
if no_bringup "$out"; then pass "refused preflight performed no Docker bring-up"; else fail "preflight started Docker resources"; fi

# --- Case 2: a metacharacter-bearing env-file value is rejected (injection defense) ---
ef_meta="$work/meta.env"
printf 'AGENT_LAB_PROJECT_DIR=$HOME\n' > "$ef_meta"   # literal "$HOME" string
rc=0; out="$(run_check "$ef_meta" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qi 'metacharacter'; then
  pass "env-file value with shell metacharacters is rejected"
else
  fail "metacharacter env-file value was NOT rejected (rc=$rc)"
fi

# --- Case 3 (positive): a safe project dir passes and is exported as the effective value ---
safe="$work/proj"; mkdir -p "$safe"
ef_ok="$work/ok.env"
printf 'AGENT_LAB_PROJECT_DIR=%s\n' "$safe" > "$ef_ok"
rc=0; out="$(run_check "$ef_ok" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qx "EFFECTIVE AGENT_LAB_PROJECT_DIR=$safe"; then
  pass "safe env-file PROJECT_DIR passes --check and is the effective value"
else
  fail "safe env-file PROJECT_DIR did not pass cleanly (rc=$rc)"
fi

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
