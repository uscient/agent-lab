#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"
lock_file="$script_dir/openclaw.lock"
fetch_script="$repo_root/scripts/openclaw-fetch-source"
tag="${OPENCLAW_IMAGE_TAG:-agent-lab/openclaw:local}"

die() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

lock_value() {
  local key="$1"
  awk -F= -v wanted="$key" '
    $0 ~ /^[[:space:]]*#/ { next }
    $0 !~ /=/ { next }
    $1 == wanted {
      sub(/^[^=]*=/, "")
      print
      exit
    }
  ' "$lock_file"
}

require_lock_value() {
  local key="$1"
  local value
  value="$(lock_value "$key")"
  [ -n "$value" ] || die "missing $key in $lock_file"
  printf '%s' "$value"
}

command -v docker >/dev/null 2>&1 || die "docker CLI is required"
[ -x "$fetch_script" ] || die "fetch script is not executable: $fetch_script"

repo_url="$(require_lock_value OPENCLAW_REPO_URL)"
commit="$(require_lock_value OPENCLAW_COMMIT)"
build_base="$(require_lock_value OPENCLAW_BUILD_BASE_IMAGE)"
runtime_base="$(require_lock_value OPENCLAW_RUNTIME_BASE_IMAGE)"
runtime_digest="$(require_lock_value OPENCLAW_RUNTIME_BASE_DIGEST)"
bun_image="$(require_lock_value OPENCLAW_BUN_IMAGE)"

"$fetch_script"

source_dir="$repo_root/.cache/openclaw/source/$commit"
head_sha="$(git -C "$source_dir" rev-parse HEAD)"
[ "$head_sha" = "$commit" ] || die "source HEAD mismatch before build"

build_args=(
  --file "$script_dir/Dockerfile"
  --tag "$tag"
  --build-arg "OPENCLAW_SOURCE_REPO=$repo_url"
  --build-arg "OPENCLAW_SOURCE_COMMIT=$commit"
  --build-arg "OPENCLAW_NODE_BOOKWORM_IMAGE=$build_base"
  --build-arg "OPENCLAW_NODE_BOOKWORM_SLIM_IMAGE=$runtime_base"
  --build-arg "OPENCLAW_NODE_BOOKWORM_SLIM_DIGEST=$runtime_digest"
  --build-arg "OPENCLAW_BUN_IMAGE=$bun_image"
)

if docker buildx version >/dev/null 2>&1; then
  docker buildx build --load "${build_args[@]}" "$source_dir"
else
  docker build "${build_args[@]}" "$source_dir"
fi

image_id="$(docker image inspect --format '{{.Id}}' "$tag")"
printf 'Built image: %s\n' "$tag"
printf 'Image ID: %s\n' "$image_id"
