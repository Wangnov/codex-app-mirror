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

(
  cd "$out_dir"
  # Always checksum both DMGs; append any mirrored Sparkle archives. Built as a
  # positional list (not an array) so it stays safe under `set -u` on the macOS
  # runner's bash 3.2, where expanding an empty array is an error.
  set -- Codex-mac-arm64.dmg Codex-mac-x64.dmg
  if [[ -n "$arm_zip_name" && -f "$arm_zip_name" ]]; then
    set -- "$@" "$arm_zip_name"
  fi
  if [[ -n "$x64_zip_name" && -f "$x64_zip_name" ]]; then
    set -- "$@" "$x64_zip_name"
  fi
  shasum -a 256 "$@" > SHA256SUMS-macos.txt
)
