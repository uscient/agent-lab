#!/usr/bin/env bash
# Create a NEW revision doc in tmp/ (never overwrite). Lineage-named.
# usage: new-revision.sh <base-name> [descriptive-suffix]
set -euo pipefail
base="${1:?usage: new-revision.sh <base-name> [suffix]}"
suffix="${2:-}"
mkdir -p tmp
n=1
shopt -s nullglob
for f in tmp/"$base"*; do
  r="$(printf '%s' "$f" | sed -nE 's/.*-rev([0-9]+).*/\1/p')"
  if [ -n "$r" ] && [ "$r" -ge "$n" ]; then n=$((r+1)); fi
done
name="tmp/${base}-rev${n}"; [ -n "$suffix" ] && name="${name}-${suffix}"; name="${name}.md"
date="$(date -u +%Y-%m-%dT%H:%MZ)"
if [ "$n" -gt 1 ]; then sup="${base}-rev$((n-1))"; else sup="none"; fi
cat > "$name" <<DOC
---
doc: ${base}
revision: ${n}
created: ${date}
supersedes: ${sup}
status: draft
---

# ${base} — rev ${n}${suffix:+ (${suffix})}

> New revision. Do not edit prior revisions.

## Objective

## Current state

## Design

## Security boundary impact

## Phased tasks

## Validation (docker compose config / containment-lint / egress-test)

## Open questions
DOC
echo "$name"
