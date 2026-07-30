#!/usr/bin/env bash
# Sourced, not executed. Resolves BYO-agent images before Compose and rejects image
# metadata that would create writable anonymous volumes outside the documented surface.

agent_lab_validate_image_volumes() {
  local image volumes target failures
  image="$1"
  failures=0

  if ! volumes="$(
    docker image inspect \
      --format '{{range $target, $_ := .Config.Volumes}}{{println $target}}{{end}}' \
      "$image"
  )"; then
    printf 'FAIL cannot inspect resolved agent image: %s\n' "$image" >&2
    return 1
  fi

  while IFS= read -r target || [ -n "$target" ]; do
    [ -n "$target" ] || continue
    case "$target" in
      /workspace|/home/agent|/tmp|/run/agent-secrets)
        ;;
      *)
        printf 'FAIL unsupported image-declared VOLUME: %s\n' "$target" >&2
        failures=$((failures + 1))
        ;;
    esac
  done <<< "$volumes"

  if [ "$failures" -ne 0 ]; then
    printf 'FAIL agent image %s declares writable volumes outside the allowed surface\n' \
      "$image" >&2
    return 1
  fi

  printf 'PASS agent image volumes stay within the documented writable surface: %s\n' "$image"
}
