#!/usr/bin/env bash
# agent-lab SessionStart hook: never write protected branches. Idempotent; never blocks the session.
# Usage (from each tool's SessionStart hook):  tools/session-bootstrap.sh <tool>   # claude|codex|grok
# If HEAD is dev/master/main/detached, create agent/<tool>/<slug> from origin/dev (or local dev).
# A flow checkout remains read-only so the final PR can be inspected or opened deliberately.
#   slug = ${AGENT_LAB_TASK_SLUG:-<UTC timestamp>}, sanitized to a valid ref component.
set -uo pipefail

tool="${1:-agent}"
root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$root" || exit 0

branch="$(git symbolic-ref --short -q HEAD 2>/dev/null || echo DETACHED)"
case "$branch" in
  flow)
    echo "agent-lab: flow is protected and remains read-only; use a group/slice branch for changes" >&2
    ;;
  dev | master | main | DETACHED)
    slug="${AGENT_LAB_TASK_SLUG:-$(date -u +%Y%m%d-%H%M%S)}"
    slug="$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^[-.]+//; s/[-.]+$//')"
    [ -z "$slug" ] && slug="$(date -u +%Y%m%d-%H%M%S)"
    target="agent/${tool}/${slug}"
    base=""
    if git show-ref --verify --quiet refs/remotes/origin/dev; then
      base="origin/dev"
    elif git show-ref --verify --quiet refs/heads/dev; then
      base="dev"
    else
      echo "agent-lab: WARNING no origin/dev or local dev ref — cannot create a correctly based work branch" >&2
      exit 0
    fi
    if git switch -c "$target" "$base" 2>/dev/null; then
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
