#!/usr/bin/env bash
set -euo pipefail

output_path="${1:-dist/macos/macos-metadata.json}"
arm64_dmg="${2:-dist/macos/Codex-mac-arm64.dmg}"
x64_dmg="${3:-dist/macos/Codex-mac-x64.dmg}"
arm64_zip="${4:-}"
x64_zip="${5:-}"
x64_backend_input_dir="${6:-}"
channel="${7:-stable}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require hdiutil
require python3
require shasum
require codesign

if [[ -n "$arm64_zip" || -n "$x64_zip" ]]; then
  if [[ -z "$arm64_zip" || -z "$x64_zip" ]]; then
    echo "Both arm64 and x64 Sparkle archives must be provided together." >&2
    exit 1
  fi
  require ditto
fi

case "$channel" in
  stable)
    readonly EXPECTED_BUNDLE_IDENTIFIER="com.openai.codex"
    ;;
  beta)
    readonly EXPECTED_BUNDLE_IDENTIFIER="com.openai.codex.beta"
    ;;
  *)
    echo "Unsupported macOS channel: $channel (expected stable or beta)" >&2
    exit 2
    ;;
esac
readonly EXPECTED_TEAM_IDENTIFIER="2DC432GLL2"
readonly EXPECTED_SPARKLE_PUBLIC_ED_KEY="mNfr1v9t63BfgDtlw4C8lRvSY6uMggIXABDOCi3tS6k="
readonly METADATA_TEST_MODE="${READ_MACOS_METADATA_TEST_MODE:-0}"

if [[ "$METADATA_TEST_MODE" != "0" && "$METADATA_TEST_MODE" != "1" ]]; then
  echo "READ_MACOS_METADATA_TEST_MODE must be 0 or 1" >&2
  exit 1
fi

plistbuddy="/usr/libexec/PlistBuddy"
if [[ ! -x "$plistbuddy" ]]; then
  echo "Missing required command: $plistbuddy" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
mounted_volumes=()
mounted_dmg_volume=""
found_app_path=""
identity_short_version=""
identity_bundle_version=""
identity_bundle_id=""
identity_bundle_name=""
identity_bundle_executable=""
identity_minimum_system_version=""
identity_sparkle_public_ed_key=""
identity_team_identifier=""

cleanup() {
  local volume
  for volume in "${mounted_volumes[@]:-}"; do
    hdiutil detach "$volume" -quiet >/dev/null 2>&1 || true
  done
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mount_dmg() {
  local dmg="$1"
  local attach_plist
  local volume

  if [[ ! -f "$dmg" ]]; then
    echo "Missing DMG: $dmg" >&2
    exit 1
  fi

  attach_plist="$(hdiutil attach -plist -nobrowse -readonly "$dmg")"
  volume="$(python3 -c '
import os
import plistlib
import sys

data = plistlib.loads(sys.stdin.buffer.read())
allow_nonstandard_mount = sys.argv[1] == "1"
mounts = [
    item.get("mount-point", "")
    for item in data.get("system-entities", [])
    if item.get("mount-point", "").startswith("/Volumes/")
    or (
        allow_nonstandard_mount
        and os.path.isabs(item.get("mount-point", ""))
    )
]
print(mounts[-1] if mounts else "")
' "$METADATA_TEST_MODE" <<<"$attach_plist")"

  if [[ -z "$volume" || ! -d "$volume" ]]; then
    echo "Could not find mounted volume for $dmg" >&2
    exit 1
  fi

  mounted_volumes+=("$volume")
  mounted_dmg_volume="$volume"
}

plist_value() {
  local plist="$1"
  local key="$2"
  "$plistbuddy" -c "Print :$key" "$plist" 2>/dev/null || true
}

find_single_top_level_app() {
  local root="$1"
  local media="$2"
  local app_candidate
  local app_candidates=()

  while IFS= read -r -d '' app_candidate; do
    app_candidates+=("$app_candidate")
  done < <(find "$root" -mindepth 1 -maxdepth 1 -name '*.app' -print0)

  if [[ "${#app_candidates[@]}" -ne 1 ]]; then
    echo "Expected exactly one top-level .app in $media, found ${#app_candidates[@]}" >&2
    exit 1
  fi

  found_app_path="${app_candidates[0]}"
  if [[ ! -d "$found_app_path" || -L "$found_app_path" ]]; then
    echo "Top-level .app is not an application directory in $media" >&2
    exit 1
  fi
}

inspect_app_identity() {
  local media="$1"
  local app_path="$2"
  local plist="$app_path/Contents/Info.plist"
  local codesign_verify_output
  local codesign_metadata

  if [[ ! -f "$plist" ]]; then
    echo "Missing Info.plist in $(basename "$app_path") from $media" >&2
    exit 1
  fi

  identity_short_version="$(plist_value "$plist" CFBundleShortVersionString)"
  identity_bundle_version="$(plist_value "$plist" CFBundleVersion)"
  identity_bundle_id="$(plist_value "$plist" CFBundleIdentifier)"
  identity_bundle_name="$(plist_value "$plist" CFBundleName)"
  identity_bundle_executable="$(plist_value "$plist" CFBundleExecutable)"
  identity_minimum_system_version="$(plist_value "$plist" LSMinimumSystemVersion)"
  identity_sparkle_public_ed_key="$(plist_value "$plist" SUPublicEDKey)"

  if [[ -z "$identity_short_version" || -z "$identity_bundle_version" ]]; then
    echo "Missing bundle version metadata in $media" >&2
    exit 1
  fi
  if [[ -z "$identity_bundle_name" || -z "$identity_bundle_executable" ]]; then
    echo "Missing bundle name or executable metadata in $media" >&2
    exit 1
  fi
  if [[ "$identity_bundle_id" != "$EXPECTED_BUNDLE_IDENTIFIER" ]]; then
    echo "Unexpected bundle identifier in $media: expected $EXPECTED_BUNDLE_IDENTIFIER, got ${identity_bundle_id:-<empty>}" >&2
    exit 1
  fi
  if [[ "$identity_sparkle_public_ed_key" != "$EXPECTED_SPARKLE_PUBLIC_ED_KEY" ]]; then
    echo "Unexpected Sparkle public key in $media" >&2
    exit 1
  fi

  if ! codesign_verify_output="$(codesign --verify --deep --strict --verbose=2 "$app_path" 2>&1)"; then
    echo "Code signature verification failed for $(basename "$app_path") in $media" >&2
    if [[ -n "$codesign_verify_output" ]]; then
      printf '%s\n' "$codesign_verify_output" >&2
    fi
    exit 1
  fi

  if ! codesign_metadata="$(codesign -d --verbose=4 "$app_path" 2>&1)"; then
    echo "Could not read code signature metadata for $(basename "$app_path") in $media" >&2
    if [[ -n "$codesign_metadata" ]]; then
      printf '%s\n' "$codesign_metadata" >&2
    fi
    exit 1
  fi

  identity_team_identifier="$(printf '%s\n' "$codesign_metadata" | sed -n 's/^TeamIdentifier=//p' | tail -n 1)"
  if [[ "$identity_team_identifier" != "$EXPECTED_TEAM_IDENTIFIER" ]]; then
    echo "Unexpected signing team in $media: expected $EXPECTED_TEAM_IDENTIFIER, got ${identity_team_identifier:-<empty>}" >&2
    exit 1
  fi
}

inspect_dmg() {
  local arch="$1"
  local dmg="$2"
  local json_path="$3"
  local backend_input_dir="${4:-}"
  local volume
  local backend_version
  local sha256

  mount_dmg "$dmg"
  volume="$mounted_dmg_volume"

  find_single_top_level_app "$volume" "$dmg"
  inspect_app_identity "$dmg" "$found_app_path"
  sha256="$(shasum -a 256 "$dmg" | awk '{print $1}')"
  backend_version="$(python3 "$script_dir/read-codex-backend-version.py" "$found_app_path" 2>/dev/null || true)"

  if [[ -n "$backend_input_dir" ]]; then
    mkdir -p "$backend_input_dir"
    if ! python3 "$script_dir/read-codex-backend-version.py" \
      --prepare-input-dir "$backend_input_dir" \
      --source-package "$dmg" \
      --source-package-sha256 "$sha256" \
      --platform macos \
      --architecture "$arch" \
      "$found_app_path" > "$tmp_dir/backend-input-$arch.log"; then
      echo "Could not prepare macOS $arch backend input; metadata will remain unavailable." >&2
      rm -f \
        "$backend_input_dir/codex" \
        "$backend_input_dir/codex.exe" \
        "$backend_input_dir/backend-input.json"
      printf '%s\n' \
        "{\"architecture\":\"$arch\",\"platform\":\"macos\",\"schemaVersion\":1,\"status\":\"unavailable\"}" \
        > "$backend_input_dir/backend-input.json"
    fi
  fi

  python3 - "$json_path" "$arch" "$dmg" "$sha256" "$identity_short_version" "$identity_bundle_version" "$identity_bundle_id" "$identity_bundle_name" "$identity_bundle_executable" "$identity_minimum_system_version" "$identity_team_identifier" "$identity_sparkle_public_ed_key" "$backend_version" <<'PY'
import json
import os
import sys

(
    out,
    arch,
    dmg,
    sha256,
    short,
    build,
    bundle_id,
    bundle_name,
    bundle_executable,
    minimum,
    team_identifier,
    sparkle_public_ed_key,
    backend,
) = sys.argv[1:]
payload = {
    "architecture": arch,
    "fileName": os.path.basename(dmg),
    "sha256": sha256,
    "bundleShortVersion": short,
    "bundleVersion": build,
    "bundleIdentifier": bundle_id,
    "bundleName": bundle_name,
    "bundleExecutable": bundle_executable,
    "minimumSystemVersion": minimum,
    "teamIdentifier": team_identifier,
    "sparklePublicEdKey": sparkle_public_ed_key,
}
if backend:
    payload["backendVersion"] = backend
with open(out, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

verify_sparkle_archive() {
  local arch="$1"
  local archive="$2"
  local json_path="$3"
  local extract_dir="$tmp_dir/sparkle-$arch"

  if [[ ! -f "$archive" ]]; then
    echo "Missing Sparkle archive: $archive" >&2
    exit 1
  fi

  mkdir -p "$extract_dir"
  if ! ditto -x -k "$archive" "$extract_dir"; then
    echo "Could not extract Sparkle archive: $archive" >&2
    exit 1
  fi

  find_single_top_level_app "$extract_dir" "$archive"
  inspect_app_identity "$archive" "$found_app_path"

  python3 - "$json_path" "$archive" "$identity_short_version" "$identity_bundle_version" "$identity_bundle_id" "$identity_bundle_name" "$identity_bundle_executable" "$identity_team_identifier" "$identity_sparkle_public_ed_key" <<'PY'
import json
import os
import sys

(
    path,
    archive,
    short_version,
    bundle_version,
    bundle_identifier,
    bundle_name,
    bundle_executable,
    team_identifier,
    sparkle_public_ed_key,
) = sys.argv[1:]
with open(path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)
payload["sparkleArchiveFileName"] = os.path.basename(archive)
payload["sparkleArchiveIdentityVerified"] = True
payload["sparkleArchiveBundleShortVersion"] = short_version
payload["sparkleArchiveBundleVersion"] = bundle_version
payload["sparkleArchiveBundleIdentifier"] = bundle_identifier
payload["sparkleArchiveBundleName"] = bundle_name
payload["sparkleArchiveBundleExecutable"] = bundle_executable
payload["sparkleArchiveTeamIdentifier"] = team_identifier
payload["sparkleArchivePublicEdKey"] = sparkle_public_ed_key
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

mkdir -p "$(dirname "$output_path")"

inspect_dmg arm64 "$arm64_dmg" "$tmp_dir/arm64.json"
inspect_dmg x64 "$x64_dmg" "$tmp_dir/x64.json" "$x64_backend_input_dir"

if [[ -n "$arm64_zip" ]]; then
  verify_sparkle_archive arm64 "$arm64_zip" "$tmp_dir/arm64.json"
  verify_sparkle_archive x64 "$x64_zip" "$tmp_dir/x64.json"
fi

python3 - "$output_path" "$tmp_dir/arm64.json" "$tmp_dir/x64.json" <<'PY'
import datetime as dt
import json
import sys

out, arm_path, x64_path = sys.argv[1:]
with open(arm_path, "r", encoding="utf-8") as handle:
    arm64 = json.load(handle)
with open(x64_path, "r", encoding="utf-8") as handle:
    x64 = json.load(handle)

versions_match = (
    arm64["bundleShortVersion"] == x64["bundleShortVersion"]
    and arm64["bundleVersion"] == x64["bundleVersion"]
)

payload = {
    "schemaVersion": 1,
    "generatedAt": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "macos": {
        "arm64": arm64,
        "x64": x64,
    },
    "commonShortVersion": arm64["bundleShortVersion"] if versions_match else "",
    "commonBundleVersion": arm64["bundleVersion"] if versions_match else "",
    "versionsMatch": versions_match,
}

with open(out, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

cat "$output_path"
