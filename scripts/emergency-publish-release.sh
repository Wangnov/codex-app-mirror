#!/usr/bin/env bash
set -euo pipefail

tag="${1:?release tag is required}"
title="${2:?release title is required}"
notes_file="${3:?release notes file is required}"
manifest_path="${4:?release manifest is required}"
checksums_path="${5:?release checksums are required}"
arm_appcast="${6:?candidate arm64 appcast is required}"
x64_appcast="${7:?candidate x64 appcast is required}"
artifacts_dir="${8:?artifacts directory is required}"

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GH_REPO:?GH_REPO is required}"

for command in gh jq sha256sum stat; do
  command -v "$command" >/dev/null 2>&1 || { echo "Missing required command: $command" >&2; exit 1; }
done

mac_dir="$artifacts_dir/codex-macos"
windows_dir="$artifacts_dir/codex-windows"
assets=(
  assets/status.png
  "$manifest_path"
  "$checksums_path"
  "$arm_appcast"
  "$x64_appcast"
  "$mac_dir/SHA256SUMS-macos.txt"
  "$windows_dir/SHA256SUMS-windows.txt"
  "$mac_dir/$(jq -r '.sources.macos.arm64.mirrorBasename' "$manifest_path")"
  "$mac_dir/$(jq -r '.sources.macos.x64.mirrorBasename' "$manifest_path")"
  "$mac_dir/$(jq -r '.sources.macos.arm64.appcast.mirrorEnclosureBasename' "$manifest_path")"
  "$mac_dir/$(jq -r '.sources.macos.x64.appcast.mirrorEnclosureBasename' "$manifest_path")"
)

while IFS= read -r basename; do
  [[ -n "$basename" ]] || continue
  assets+=("$mac_dir/$basename")
done < <(jq -r '.sources.macos.arm64.appcast.deltas[]?.basename // empty, .sources.macos.x64.appcast.deltas[]?.basename // empty' "$manifest_path")

while IFS= read -r msix; do
  [[ -n "$msix" ]] || continue
  assets+=("$msix")
done < <(find "$windows_dir" -maxdepth 1 -type f \( -name '*.Msix' -o -name '*.msix' \) | sort)

seen_names_file="$(mktemp)"
cleanup() {
  rm -f "$seen_names_file"
}
trap cleanup EXIT
: > "$seen_names_file"
for asset in "${assets[@]}"; do
  [[ -f "$asset" ]] || { echo "Missing release asset: $asset" >&2; exit 1; }
  name="$(basename "$asset")"
  if grep -Fxq "$name" "$seen_names_file"; then
    echo "Duplicate release asset basename: $name" >&2
    exit 1
  fi
  printf '%s\n' "$name" >> "$seen_names_file"
done

is_replaceable_metadata() {
  case "$1" in
    release-manifest.json|SHA256SUMS.txt|SHA256SUMS-macos.txt|SHA256SUMS-windows.txt|candidate-appcast.xml|candidate-appcast-x64.xml|status.png)
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
  tr '[:upper:]' '[:lower:]' <<<"$1"
}

if existing_assets="$(gh release view "$tag" --json assets --jq '.assets' 2>/dev/null)"; then
  gh release edit "$tag" \
    --title "$title" \
    --notes-file "$notes_file" \
    --prerelease \
    --latest=false

  for asset in "${assets[@]}"; do
    name="$(basename "$asset")"
    local_size="$(file_size "$asset")"
    local_sha="$(sha256sum "$asset" | awk '{print tolower($1)}')"
    existing_size="$(jq -r --arg name "$name" '.[] | select(.name == $name) | .size' <<<"$existing_assets" | head -n 1)"
    existing_digest="$(jq -r --arg name "$name" '.[] | select(.name == $name) | .digest // ""' <<<"$existing_assets" | head -n 1)"
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
      echo "Refusing to overwrite immutable GitHub Release asset $name (release=$existing_size/${existing_sha:-no-sha256}, local=$local_size/$local_sha)" >&2
      exit 1
    fi

    gh release delete-asset "$tag" "$name" --yes
    gh release upload "$tag" "$asset"
  done
else
  gh release create "$tag" \
    --target "${GITHUB_SHA:-main}" \
    --title "$title" \
    --notes-file "$notes_file" \
    --prerelease \
    --latest=false \
    "${assets[@]}"
fi

gh release view "$tag" --json tagName,name,isDraft,isPrerelease,publishedAt,assets \
  --jq '{tagName,name,isDraft,isPrerelease,publishedAt,assetCount:(.assets|length),assets:[.assets[]|{name,size,digest}]}'
