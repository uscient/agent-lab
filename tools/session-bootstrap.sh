#!/usr/bin/env bash
# agent-lab SessionStart hook: never work on master/main. Idempotent; never blocks the session.
# Usage (from each tool's SessionStart hook):  tools/session-bootstrap.sh <tool>   # claude|codex|grok
# If HEAD is master/main/detached, create agent/<tool>/<slug>; otherwise no-op.
#   slug = ${AGENT_LAB_TASK_SLUG:-<UTC timestamp>}, sanitized to a valid ref component.
set -uo pipefail

tool="${1:-agent}"
root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$root" || exit 0

branch="$(git symbolic-ref --short -q HEAD 2>/dev/null || echo DETACHED)"
case "$branch" in
  master | main | DETACHED)
    slug="${AGENT_LAB_TASK_SLUG:-$(date -u +%Y%m%d-%H%M%S)}"
    slug="$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^[-.]+//; s/[-.]+$//')"
    [ -z "$slug" ] && slug="$(date -u +%Y%m%d-%H%M%S)"
    target="agent/${tool}/${slug}"
    if git switch -c "$target" 2>/dev/null; then
      echo "agent-lab: started work branch $target" >&2
    elif git switch "$target" 2>/dev/null; then
      echo "agent-lab: switched to existing work branch $target" >&2
    else
      echo "agent-lab: WARNING could not leave $branch — create an agent/<tool>/<slug> branch before committing" >&2
    fi
    ;;
  *) : ;; # already on a working branch — leave it
esac
exit 0
