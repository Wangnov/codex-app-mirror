#!/usr/bin/env bash
set -euo pipefail

manifest_path="${1:?probe manifest is required}"
artifacts_dir="${2:-dist/macos}"
output_path="${3:-$artifacts_dir/macos-metadata.json}"
expected_bundle_id="com.openai.codex"
rejected_classic_bundle_id="com.openai.chat"
expected_team_id="2DC432GLL2"
expected_sparkle_key="mNfr1v9t63BfgDtlw4C8lRvSY6uMggIXABDOCi3tS6k="
plistbuddy="/usr/libexec/PlistBuddy"
tmp_dir="$(mktemp -d)"
mounts_file="$tmp_dir/mounts"
: > "$mounts_file"

cleanup() {
  while IFS= read -r volume; do
    [[ -n "$volume" ]] || continue
    hdiutil detach "$volume" -quiet >/dev/null 2>&1 || true
  done < "$mounts_file"
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

for command in codesign ditto hdiutil jq python3 shasum; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing required command: $command" >&2
    exit 1
  fi
done
if [[ ! -x "$plistbuddy" ]]; then
  echo "Missing required command: $plistbuddy" >&2
  exit 1
fi

plist_value() {
  local plist="$1"
  local key="$2"
  "$plistbuddy" -c "Print :$key" "$plist" 2>/dev/null || true
}

single_top_level_app() {
  local root="$1"
  local candidate found="" count=0
  for candidate in "$root"/*.app; do
    [[ -d "$candidate" ]] || continue
    count=$((count + 1))
    found="$candidate"
  done
  if [[ "$count" -ne 1 ]]; then
    echo "Expected exactly one top-level .app in $root, found $count" >&2
    return 1
  fi
  printf '%s' "$found"
}

assert_stable_identity() {
  local label="$1"
  local app_path="$2"
  local expected_version="$3"
  local expected_build="$4"
  local plist signature_info

  plist="$app_path/Contents/Info.plist"
  if [[ ! -f "$plist" ]]; then
    echo "$label has no Contents/Info.plist" >&2
    exit 1
  fi

  APP_SHORT_VERSION="$(plist_value "$plist" CFBundleShortVersionString)"
  APP_BUILD_VERSION="$(plist_value "$plist" CFBundleVersion)"
  APP_BUNDLE_ID="$(plist_value "$plist" CFBundleIdentifier)"
  APP_MINIMUM_VERSION="$(plist_value "$plist" LSMinimumSystemVersion)"
  APP_SPARKLE_KEY="$(plist_value "$plist" SUPublicEDKey)"

  if [[ "$APP_BUNDLE_ID" == "$rejected_classic_bundle_id" ]]; then
    echo "$label is ChatGPT Classic ($rejected_classic_bundle_id); refusing it explicitly" >&2
    exit 1
  fi
  if [[ "$APP_BUNDLE_ID" != "$expected_bundle_id" ]]; then
    echo "$label bundle ID mismatch: expected=$expected_bundle_id actual=$APP_BUNDLE_ID" >&2
    exit 1
  fi
  if [[ "$APP_SHORT_VERSION" != "$expected_version" || "$APP_BUILD_VERSION" != "$expected_build" ]]; then
    echo "$label version mismatch: expected=$expected_version/$expected_build actual=$APP_SHORT_VERSION/$APP_BUILD_VERSION" >&2
    exit 1
  fi
  if [[ "$APP_SPARKLE_KEY" != "$expected_sparkle_key" ]]; then
    echo "$label Sparkle key mismatch" >&2
    exit 1
  fi

  codesign --verify --deep --strict --verbose=2 "$app_path"
  signature_info="$(codesign -dv --verbose=4 "$app_path" 2>&1)"
  APP_TEAM_ID="$(awk -F= '/^TeamIdentifier=/ { print $2; exit }' <<<"$signature_info")"
  if [[ "$APP_TEAM_ID" != "$expected_team_id" ]]; then
    echo "$label Team ID mismatch: expected=$expected_team_id actual=$APP_TEAM_ID" >&2
    exit 1
  fi

  echo "$label passed Stable identity gate: $APP_BUNDLE_ID / $APP_TEAM_ID / $APP_SHORT_VERSION ($APP_BUILD_VERSION)" >&2
}

mount_dmg() {
  local dmg="$1"
  local attach_plist volume
  attach_plist="$(hdiutil attach -plist -nobrowse -readonly "$dmg")"
  volume="$(python3 -c '
import plistlib
import sys
data = plistlib.loads(sys.stdin.buffer.read())
mounts = [
    item.get("mount-point", "")
    for item in data.get("system-entities", [])
    if item.get("mount-point", "").startswith("/Volumes/")
]
print(mounts[-1] if mounts else "")
' <<<"$attach_plist")"
  if [[ -z "$volume" ]]; then
    echo "Could not find mounted volume for $dmg" >&2
    exit 1
  fi
  printf '%s\n' "$volume" >> "$mounts_file"
  printf '%s' "$volume"
}

inspect_arch() {
  local arch="$1"
  local expected_version expected_build dmg_name zip_name dmg_path zip_path
  local volume dmg_app extract_dir zip_app dmg_sha zip_sha
  local zip_json dmg_json

  expected_version="$(jq -r --arg a "$arch" '.sources.macos[$a].appcast.shortVersionString' "$manifest_path")"
  expected_build="$(jq -r --arg a "$arch" '.sources.macos[$a].appcast.version' "$manifest_path")"
  dmg_name="$(jq -r --arg a "$arch" '.sources.macos[$a].mirrorBasename' "$manifest_path")"
  zip_name="$(jq -r --arg a "$arch" '.sources.macos[$a].appcast.mirrorEnclosureBasename' "$manifest_path")"
  dmg_path="$artifacts_dir/$dmg_name"
  zip_path="$artifacts_dir/$zip_name"

  [[ -f "$dmg_path" ]] || { echo "Missing $dmg_path" >&2; exit 1; }
  [[ -f "$zip_path" ]] || { echo "Missing $zip_path" >&2; exit 1; }

  volume="$(mount_dmg "$dmg_path")"
  dmg_app="$(single_top_level_app "$volume")"
  assert_stable_identity "macOS $arch DMG" "$dmg_app" "$expected_version" "$expected_build"
  dmg_sha="$(shasum -a 256 "$dmg_path" | awk '{print $1}')"
  dmg_json="$tmp_dir/$arch-dmg.json"
  jq -n \
    --arg architecture "$arch" \
    --arg fileName "$dmg_name" \
    --arg sha256 "$dmg_sha" \
    --arg shortVersion "$APP_SHORT_VERSION" \
    --arg bundleVersion "$APP_BUILD_VERSION" \
    --arg bundleId "$APP_BUNDLE_ID" \
    --arg minimumVersion "$APP_MINIMUM_VERSION" \
    --arg teamId "$APP_TEAM_ID" \
    --arg sparkleKey "$APP_SPARKLE_KEY" \
    '{
      architecture: $architecture,
      fileName: $fileName,
      sha256: $sha256,
      bundleShortVersion: $shortVersion,
      bundleVersion: $bundleVersion,
      bundleIdentifier: $bundleId,
      minimumSystemVersion: $minimumVersion,
      teamIdentifier: $teamId,
      sparklePublicKey: $sparkleKey
    }' > "$dmg_json"
  hdiutil detach "$volume" -quiet

  extract_dir="$tmp_dir/$arch-zip"
  mkdir -p "$extract_dir"
  ditto -x -k "$zip_path" "$extract_dir"
  zip_app="$(single_top_level_app "$extract_dir")"
  assert_stable_identity "macOS $arch Sparkle ZIP" "$zip_app" "$expected_version" "$expected_build"
  zip_sha="$(shasum -a 256 "$zip_path" | awk '{print $1}')"
  zip_json="$tmp_dir/$arch-zip.json"
  jq -n \
    --arg fileName "$zip_name" \
    --arg sha256 "$zip_sha" \
    --arg sourceBasename "$(jq -r --arg a "$arch" '.sources.macos[$a].appcast.sourceBasename' "$manifest_path")" \
    --arg shortVersion "$APP_SHORT_VERSION" \
    --arg bundleVersion "$APP_BUILD_VERSION" \
    --arg bundleId "$APP_BUNDLE_ID" \
    --arg teamId "$APP_TEAM_ID" \
    --arg sparkleKey "$APP_SPARKLE_KEY" \
    '{
      fileName: $fileName,
      sourceBasename: $sourceBasename,
      sha256: $sha256,
      bundleShortVersion: $shortVersion,
      bundleVersion: $bundleVersion,
      bundleIdentifier: $bundleId,
      teamIdentifier: $teamId,
      sparklePublicKey: $sparkleKey
    }' > "$zip_json"

  jq --slurpfile sparkle "$zip_json" '. + {sparkleArchive: $sparkle[0]}' "$dmg_json" > "$tmp_dir/$arch.json"
  rm -rf "$extract_dir"
}

inspect_arch arm64
inspect_arch x64
mkdir -p "$(dirname "$output_path")"
jq -n \
  --slurpfile arm "$tmp_dir/arm64.json" \
  --slurpfile x64 "$tmp_dir/x64.json" '
  {
    schemaVersion: 2,
    macos: {arm64: $arm[0], x64: $x64[0]},
    commonShortVersion: $arm[0].bundleShortVersion,
    commonBundleVersion: $arm[0].bundleVersion,
    versionsMatch: (
      $arm[0].bundleShortVersion == $x64[0].bundleShortVersion
      and $arm[0].bundleVersion == $x64[0].bundleVersion
    ),
    identityGate: {
      bundleIdentifier: "com.openai.codex",
      rejectedBundleIdentifier: "com.openai.chat",
      teamIdentifier: "2DC432GLL2",
      sparklePublicKey: "mNfr1v9t63BfgDtlw4C8lRvSY6uMggIXABDOCi3tS6k="
    }
  }' > "$output_path"

jq -e '.versionsMatch == true' "$output_path" >/dev/null
cat "$output_path"
