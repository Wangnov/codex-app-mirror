#!/usr/bin/env bash
set -euo pipefail

out_dir="${1:-dist}"
manifest_path="${2:-}"
mkdir -p "$out_dir"

arm_url="https://persistent.oaistatic.com/codex-app-prod/Codex.dmg"
x64_url="https://persistent.oaistatic.com/codex-app-prod/Codex-latest-x64.dmg"
arm_expected_size=""
x64_expected_size=""

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
fi

curl -fL --retry 3 --retry-delay 2 \
  -o "$out_dir/Codex-mac-arm64.dmg" \
  "$arm_url"
validate_size "$out_dir/Codex-mac-arm64.dmg" "$arm_expected_size"

curl -fL --retry 3 --retry-delay 2 \
  -o "$out_dir/Codex-mac-x64.dmg" \
  "$x64_url"
validate_size "$out_dir/Codex-mac-x64.dmg" "$x64_expected_size"

shasum -a 256 "$out_dir/Codex-mac-arm64.dmg" "$out_dir/Codex-mac-x64.dmg" \
  > "$out_dir/SHA256SUMS-macos.txt"
