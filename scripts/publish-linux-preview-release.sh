#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/github-api.sh"

tag="${1:?release tag is required}"
title="${2:?release title is required}"
notes_file="${3:?release notes file is required}"
manifest_path="${4:?release manifest is required}"
checksums_path="${5:?release checksums are required}"
artifacts_dir="${6:?Linux artifacts directory is required}"

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GH_REPO:?GH_REPO is required}"

for command in cmp gh jq sha256sum stat; do
  command -v "$command" >/dev/null 2>&1 || { echo "Missing required command: $command" >&2; exit 1; }
done

if ! jq -e --arg tag "$tag" '
  .schemaVersion == 6
  and .channel == "linux-preview"
  and .preview.contract == "linux-preview-v1"
  and .publication.githubPrereleaseOnly == true
  and .publication.githubLatestAdvanced == false
  and .publication.objectStoragePublished == false
  and .publication.sharedLatestAdvanced == false
  and .derived.prerelease == true
  and .derived.publishLatest == false
  and .derived.syncLatest == false
  and .release.tag == $tag
  and .release.destination == "github-prerelease"
  and .release.immutableAssets == true
  and ([.sources.linux.architectures[][]] | length == 4)
  ' "$manifest_path" >/dev/null; then
  echo "Refusing to publish outside the GitHub-only Linux Preview contract." >&2
  exit 1
fi

assets=(
  "$manifest_path"
  "$checksums_path"
  "$artifacts_dir/SHA256SUMS-linux.txt"
  "$artifacts_dir/linux-identity.json"
)
while IFS= read -r file_name; do
  [[ -n "$file_name" ]] || continue
  assets+=("$artifacts_dir/$file_name")
done < <(jq -r '.sources.linux.architectures[][].mirrorBasename' "$manifest_path" | sort)

seen_names_file="$(mktemp)"
cleanup() {
  rm -f "$seen_names_file"
}
trap cleanup EXIT
: > "$seen_names_file"
for asset in "${assets[@]}"; do
  [[ -f "$asset" ]] || { echo "Missing Linux Preview release asset: $asset" >&2; exit 1; }
  name="$(basename "$asset")"
  if grep -Fxq "$name" "$seen_names_file"; then
    echo "Duplicate Linux Preview release asset basename: $name" >&2
    exit 1
  fi
  printf '%s\n' "$name" >> "$seen_names_file"
done
sort -o "$seen_names_file" "$seen_names_file"

[[ "$(wc -l < "$seen_names_file" | tr -d '[:space:]')" == "8" ]] || {
  echo "Linux Preview release contract must contain exactly eight assets." >&2
  exit 1
}

is_replaceable_metadata() {
  case "$1" in
    release-manifest.json|SHA256SUMS.txt|SHA256SUMS-linux.txt|linux-identity.json)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

file_size() {
  local file="$1"
  if stat -c '%s' "$file" >/dev/null 2>&1; then
    stat -c '%s' "$file"
  else
    stat -f '%z' "$file"
  fi
}

lowercase() {
  tr '[:upper:]' '[:lower:]' <<< "$1"
}

release_lookup_status=0
if existing_assets="$(github_release_assets_json_allow_404 "$tag")"; then
  existing_names_file="$(mktemp)"
  jq -r '.[].name' <<< "$existing_assets" | sort > "$existing_names_file"
  unexpected_existing_assets="$(comm -13 "$seen_names_file" "$existing_names_file")"
  rm -f "$existing_names_file"
  if [[ -n "$unexpected_existing_assets" ]]; then
    echo "Refusing to mutate Linux Preview release with assets outside the exact contract:" >&2
    printf '%s\n' "$unexpected_existing_assets" >&2
    exit 1
  fi

  for asset in "${assets[@]}"; do
    name="$(basename "$asset")"
    is_replaceable_metadata "$name" && continue
    existing_size="$(jq -r --arg name "$name" '.[] | select(.name == $name) | .size' <<< "$existing_assets" | head -n 1)"
    [[ -n "$existing_size" ]] || continue
    local_size="$(file_size "$asset")"
    local_sha="$(sha256sum "$asset" | awk '{print tolower($1)}')"
    existing_digest="$(jq -r --arg name "$name" '.[] | select(.name == $name) | .digest // ""' <<< "$existing_assets" | head -n 1)"
    existing_sha="${existing_digest#sha256:}"
    if [[ "$existing_size" != "$local_size" || -z "$existing_sha" || "$(lowercase "$existing_sha")" != "$local_sha" ]]; then
      echo "Refusing to mutate release with mismatched immutable Linux package $name (release=$existing_size/${existing_sha:-no-sha256}, local=$local_size/$local_sha)" >&2
      exit 1
    fi
  done

  gh release edit "$tag" \
    --title "$title" \
    --notes-file "$notes_file" \
    --prerelease \
    --latest=false

  for asset in "${assets[@]}"; do
    name="$(basename "$asset")"
    local_size="$(file_size "$asset")"
    local_sha="$(sha256sum "$asset" | awk '{print tolower($1)}')"
    existing_size="$(jq -r --arg name "$name" '.[] | select(.name == $name) | .size' <<< "$existing_assets" | head -n 1)"
    existing_digest="$(jq -r --arg name "$name" '.[] | select(.name == $name) | .digest // ""' <<< "$existing_assets" | head -n 1)"
    existing_sha="${existing_digest#sha256:}"

    if [[ -z "$existing_size" ]]; then
      gh release upload "$tag" "$asset"
      continue
    fi
    if [[ "$existing_size" == "$local_size" && -n "$existing_sha" && "$(lowercase "$existing_sha")" == "$local_sha" ]]; then
      echo "Release asset already matches: $name"
      continue
    fi
    if ! is_replaceable_metadata "$name"; then
      echo "Refusing to overwrite immutable Linux package $name" >&2
      exit 1
    fi
    gh release delete-asset "$tag" "$name" --yes
    gh release upload "$tag" "$asset"
  done
else
  release_lookup_status=$?
  if [[ "$release_lookup_status" -ne "$GITHUB_API_NOT_FOUND_STATUS" ]]; then
    echo "Unable to determine whether Linux Preview prerelease $tag exists; refusing to create it." >&2
    exit "$release_lookup_status"
  fi
  gh release create "$tag" \
    --target "${GITHUB_SHA:-main}" \
    --title "$title" \
    --notes-file "$notes_file" \
    --prerelease \
    --latest=false \
    "${assets[@]}"
fi

published_release="$(gh release view "$tag" --json tagName,name,isDraft,isPrerelease,publishedAt,assets)"
jq -e --arg tag "$tag" '
  .tagName == $tag
  and .isDraft == false
  and .isPrerelease == true
  ' <<< "$published_release" >/dev/null

remote_names_file="$(mktemp)"
jq -r '.assets[].name' <<< "$published_release" | sort > "$remote_names_file"
if ! cmp "$seen_names_file" "$remote_names_file" >/dev/null 2>&1; then
  echo "Published GitHub asset set differs from the exact Linux Preview contract." >&2
  diff -u "$seen_names_file" "$remote_names_file" >&2 || true
  rm -f "$remote_names_file"
  exit 1
fi
rm -f "$remote_names_file"

for asset in "${assets[@]}"; do
  name="$(basename "$asset")"
  local_size="$(file_size "$asset")"
  local_sha="$(sha256sum "$asset" | awk '{print tolower($1)}')"
  remote_size="$(jq -r --arg name "$name" '.assets[] | select(.name == $name) | .size' <<< "$published_release" | head -n 1)"
  remote_digest="$(jq -r --arg name "$name" '.assets[] | select(.name == $name) | .digest // ""' <<< "$published_release" | head -n 1)"
  remote_sha="${remote_digest#sha256:}"
  if [[ "$remote_size" != "$local_size" || -z "$remote_sha" || "$(lowercase "$remote_sha")" != "$local_sha" ]]; then
    echo "Published GitHub asset verification failed for $name" >&2
    exit 1
  fi
done

jq '{tagName,name,isDraft,isPrerelease,publishedAt,assetCount:(.assets|length),assets:[.assets[]|{name,size,digest}]}' <<< "$published_release"
