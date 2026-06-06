#!/usr/bin/env bash
set -euo pipefail

out_dir="${1:-dist}"
manifest_path="${2:-}"
mkdir -p "$out_dir"

arm_url=""
x64_url=""
arm_expected_size=""
x64_expected_size=""
arm_zip_url=""
x64_zip_url=""
arm_zip_expected_size=""
x64_zip_expected_size=""
arm_zip_name=""
x64_zip_name=""
curl_retry_args=(
  --retry 5
  --retry-delay 2
  --retry-max-time 900
  --connect-timeout 20
  --retry-all-errors
)

file_size() {
  local file="$1"
  if stat -f '%z' "$file" >/dev/null 2>&1; then
    stat -f '%z' "$file"
  else
    stat -c '%s' "$file"
  fi
}

validate_size() {
  local file="$1"
  local expected="$2"
  local actual

  if [[ -z "$expected" || "$expected" == "null" || "$expected" == "0" ]]; then
    return 0
  fi

  actual="$(file_size "$file")"
  if [[ "$actual" != "$expected" ]]; then
    echo "Downloaded size mismatch for $file: expected $expected bytes, got $actual bytes." >&2
    exit 1
  fi
}

download_file() {
  local label="$1"
  local url="$2"
  local output="$3"

  echo "Downloading $label: $url" >&2
  curl -fL "${curl_retry_args[@]}" \
    -o "$output" \
    "$url"
}

if [[ -n "$manifest_path" ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required when a probe manifest is provided." >&2
    exit 1
  fi

  if [[ ! -f "$manifest_path" ]]; then
    echo "Probe manifest not found: $manifest_path" >&2
    exit 1
  fi

  arm_url="$(jq -r '.sources.macos.arm64.url' "$manifest_path")"
  x64_url="$(jq -r '.sources.macos.x64.url' "$manifest_path")"
  arm_expected_size="$(jq -r '.sources.macos.arm64.contentLength' "$manifest_path")"
  x64_expected_size="$(jq -r '.sources.macos.x64.contentLength' "$manifest_path")"

  # Sparkle update archives (.zip) referenced by the official appcast. These are
  # what the macOS auto-updater (and the downstream Codex App Manager client)
  # actually download, so the mirror must host them too. We name them by their
  # official basename (Codex-darwin-<arch>-<shortVersion>.zip) so the generated
  # appcast enclosure URL stays stable and predictable.
  arm_zip_url="$(jq -r '.sources.macos.arm64.appcast.enclosureUrl // ""' "$manifest_path")"
  x64_zip_url="$(jq -r '.sources.macos.x64.appcast.enclosureUrl // ""' "$manifest_path")"
  arm_zip_expected_size="$(jq -r '.sources.macos.arm64.appcast.enclosureLength // 0' "$manifest_path")"
  x64_zip_expected_size="$(jq -r '.sources.macos.x64.appcast.enclosureLength // 0' "$manifest_path")"
  arm_zip_short_version="$(jq -r '.sources.macos.arm64.appcast.shortVersionString // ""' "$manifest_path")"
  x64_zip_short_version="$(jq -r '.sources.macos.x64.appcast.shortVersionString // ""' "$manifest_path")"
  if [[ -n "$arm_zip_short_version" ]]; then
    arm_zip_name="Codex-darwin-arm64-${arm_zip_short_version}.zip"
  fi
  if [[ -n "$x64_zip_short_version" ]]; then
    x64_zip_name="Codex-darwin-x64-${x64_zip_short_version}.zip"
  fi
else
  arm_url="https://persistent.oaistatic.com/codex-app-prod/Codex.dmg"
  x64_url="https://persistent.oaistatic.com/codex-app-prod/Codex-latest-x64.dmg"
fi

download_file "macOS arm64 DMG" "$arm_url" "$out_dir/Codex-mac-arm64.dmg"
validate_size "$out_dir/Codex-mac-arm64.dmg" "$arm_expected_size"

download_file "macOS x64 DMG" "$x64_url" "$out_dir/Codex-mac-x64.dmg"
validate_size "$out_dir/Codex-mac-x64.dmg" "$x64_expected_size"

# Mirror the Sparkle update archives (.zip) so the appcast enclosure URLs are
# downloadable from the mirror. The archive bytes are copied verbatim, which is
# what keeps the official EdDSA signature valid. When a manifest provides an
# enclosure URL the archive is mandatory; a missing one means a broken appcast,
# so fail loudly rather than ship a feed that points at nothing.
download_zip() {
  local label="$1"
  local url="$2"
  local name="$3"
  local expected_size="$4"

  if [[ -z "$url" || "$url" == "null" ]]; then
    if [[ -n "$manifest_path" ]]; then
      echo "Missing $label enclosure URL in manifest; cannot mirror Sparkle archive." >&2
      exit 1
    fi
    return 0
  fi
  if [[ -z "$name" ]]; then
    echo "Missing $label archive name (no shortVersionString in manifest)." >&2
    exit 1
  fi

  download_file "$label" "$url" "$out_dir/$name"
  validate_size "$out_dir/$name" "$expected_size"
}

download_zip "macOS arm64 Sparkle archive" "$arm_zip_url" "$arm_zip_name" "$arm_zip_expected_size"
download_zip "macOS x64 Sparkle archive" "$x64_zip_url" "$x64_zip_name" "$x64_zip_expected_size"

# Mirror the Sparkle delta archives (.delta) the official appcast advertises
# under <sparkle:deltas>. Like the full .zip archives, the bytes are copied
# verbatim so the official EdDSA signature stays valid; we NEVER run BinaryDelta
# and NEVER touch the edSignature. The official basename is preserved exactly
# (the enclosure URL the mirror publishes is resolved by basename), and the byte
# length is checked against the appcast `length` as an integrity guard. Deltas
# land alongside the full zips in $out_dir, the same staging layout the zips use.
#
# The downloaded delta basenames are recorded (one per line) so they can be
# appended to SHA256SUMS-macos.txt without relying on bash arrays (the macOS
# runner's bash 3.2 errors on expanding an empty array under `set -u`).
mac_delta_names_file="$(mktemp)"
trap 'rm -f "$mac_delta_names_file"' EXIT
: > "$mac_delta_names_file"

download_deltas() {
  local arch_key="$1"
  local count i
  local url basename expected_size

  if [[ -z "$manifest_path" ]]; then
    return 0
  fi

  count="$(jq -r --arg a "$arch_key" '.sources.macos[$a].appcast.deltas | length // 0' "$manifest_path")"
  if [[ -z "$count" || "$count" == "null" || "$count" -eq 0 ]]; then
    return 0
  fi

  for ((i = 0; i < count; i++)); do
    url="$(jq -r --arg a "$arch_key" --argjson i "$i" '.sources.macos[$a].appcast.deltas[$i].url // ""' "$manifest_path")"
    basename="$(jq -r --arg a "$arch_key" --argjson i "$i" '.sources.macos[$a].appcast.deltas[$i].basename // ""' "$manifest_path")"
    expected_size="$(jq -r --arg a "$arch_key" --argjson i "$i" '.sources.macos[$a].appcast.deltas[$i].length // 0' "$manifest_path")"

    if [[ -z "$url" || "$url" == "null" ]]; then
      echo "Missing macOS $arch_key delta[$i] URL in manifest; cannot mirror Sparkle delta." >&2
      exit 1
    fi
    if [[ -z "$basename" || "$basename" == "null" ]]; then
      # Preserve the official filename: fall back to the URL basename if the
      # probe did not record one explicitly.
      basename="${url##*/}"
    fi
    if [[ -z "$basename" ]]; then
      echo "Could not determine macOS $arch_key delta[$i] basename." >&2
      exit 1
    fi

    download_file "macOS $arch_key Sparkle delta ($basename)" "$url" "$out_dir/$basename"
    validate_size "$out_dir/$basename" "$expected_size"
    printf '%s\n' "$basename" >> "$mac_delta_names_file"
  done
}

download_deltas arm64
download_deltas x64

(
  cd "$out_dir"
  # Always checksum both DMGs; append any mirrored Sparkle archives + deltas.
  # Built as a positional list (not an array) so it stays safe under `set -u` on
  # the macOS runner's bash 3.2, where expanding an empty array is an error.
  set -- Codex-mac-arm64.dmg Codex-mac-x64.dmg
  if [[ -n "$arm_zip_name" && -f "$arm_zip_name" ]]; then
    set -- "$@" "$arm_zip_name"
  fi
  if [[ -n "$x64_zip_name" && -f "$x64_zip_name" ]]; then
    set -- "$@" "$x64_zip_name"
  fi
  while IFS= read -r delta_name; do
    [[ -z "$delta_name" ]] && continue
    if [[ -f "$delta_name" ]]; then
      set -- "$@" "$delta_name"
    fi
  done < "$mac_delta_names_file"
  shasum -a 256 "$@" > SHA256SUMS-macos.txt
)
