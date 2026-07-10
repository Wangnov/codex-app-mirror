#!/usr/bin/env bash
set -euo pipefail

manifest_path="${1:?probe manifest is required}"
out_dir="${2:-dist/macos}"
mkdir -p "$out_dir"

for command in curl jq shasum; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing required command: $command" >&2
    exit 1
  fi
done

names_file="$(mktemp)"
cleanup() {
  rm -f "$names_file"
}
trap cleanup EXIT
: > "$names_file"

file_size() {
  local file="$1"
  if stat -f '%z' "$file" >/dev/null 2>&1; then
    stat -f '%z' "$file"
  else
    stat -c '%s' "$file"
  fi
}

download_object() {
  local label="$1"
  local url="$2"
  local output_name="$3"
  local expected_size="$4"
  local expected_source_basename="$5"
  local actual_size

  if [[ -z "$url" || "$url" == "null" || -z "$output_name" || "$output_name" == "null" ]]; then
    echo "Missing URL or mirror filename for $label" >&2
    exit 1
  fi
  if [[ "${url##*/}" != "$expected_source_basename" ]]; then
    echo "$label source basename drifted: URL=${url##*/} manifest=$expected_source_basename" >&2
    exit 1
  fi

  echo "Downloading $label from $expected_source_basename as $output_name" >&2
  curl -fL \
    --retry 5 \
    --retry-delay 2 \
    --retry-max-time 1200 \
    --retry-all-errors \
    --connect-timeout 20 \
    -o "$out_dir/$output_name" \
    "$url"

  actual_size="$(file_size "$out_dir/$output_name")"
  if [[ ! "$expected_size" =~ ^[0-9]+$ || "$expected_size" == "0" || "$actual_size" != "$expected_size" ]]; then
    echo "$label size mismatch: expected=$expected_size actual=$actual_size" >&2
    exit 1
  fi
  printf '%s\n' "$output_name" >> "$names_file"
}

download_arch() {
  local arch_key="$1"
  local dmg_url dmg_source dmg_mirror dmg_size
  local zip_url zip_source zip_mirror zip_size
  local delta_count index delta_url delta_name delta_size

  dmg_url="$(jq -r --arg a "$arch_key" '.sources.macos[$a].sourceUrl' "$manifest_path")"
  dmg_source="$(jq -r --arg a "$arch_key" '.sources.macos[$a].sourceBasename' "$manifest_path")"
  dmg_mirror="$(jq -r --arg a "$arch_key" '.sources.macos[$a].mirrorBasename' "$manifest_path")"
  dmg_size="$(jq -r --arg a "$arch_key" '.sources.macos[$a].contentLength' "$manifest_path")"
  download_object "macOS $arch_key DMG" "$dmg_url" "$dmg_mirror" "$dmg_size" "$dmg_source"

  zip_url="$(jq -r --arg a "$arch_key" '.sources.macos[$a].appcast.sourceUrl' "$manifest_path")"
  zip_source="$(jq -r --arg a "$arch_key" '.sources.macos[$a].appcast.sourceBasename' "$manifest_path")"
  zip_mirror="$(jq -r --arg a "$arch_key" '.sources.macos[$a].appcast.mirrorEnclosureBasename' "$manifest_path")"
  zip_size="$(jq -r --arg a "$arch_key" '.sources.macos[$a].appcast.enclosureLength' "$manifest_path")"
  download_object "macOS $arch_key Sparkle archive" "$zip_url" "$zip_mirror" "$zip_size" "$zip_source"

  delta_count="$(jq -r --arg a "$arch_key" '.sources.macos[$a].appcast.deltas | length' "$manifest_path")"
  for ((index = 0; index < delta_count; index++)); do
    delta_url="$(jq -r --arg a "$arch_key" --argjson i "$index" '.sources.macos[$a].appcast.deltas[$i].url' "$manifest_path")"
    delta_name="$(jq -r --arg a "$arch_key" --argjson i "$index" '.sources.macos[$a].appcast.deltas[$i].basename' "$manifest_path")"
    delta_size="$(jq -r --arg a "$arch_key" --argjson i "$index" '.sources.macos[$a].appcast.deltas[$i].length' "$manifest_path")"
    download_object "macOS $arch_key Sparkle delta[$index]" "$delta_url" "$delta_name" "$delta_size" "$delta_name"
  done
}

download_arch arm64
download_arch x64

LC_ALL=C sort -u "$names_file" | while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  (
    cd "$out_dir"
    shasum -a 256 "$name"
  )
done > "$out_dir/SHA256SUMS-macos.txt"

cat "$out_dir/SHA256SUMS-macos.txt"
