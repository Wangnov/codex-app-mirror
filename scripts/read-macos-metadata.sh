#!/usr/bin/env bash
set -euo pipefail

output_path="${1:-dist/macos/macos-metadata.json}"
arm64_dmg="${2:-dist/macos/Codex-mac-arm64.dmg}"
x64_dmg="${3:-dist/macos/Codex-mac-x64.dmg}"
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

plistbuddy="/usr/libexec/PlistBuddy"
if [[ ! -x "$plistbuddy" ]]; then
  echo "Missing required command: $plistbuddy" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
mounted_volumes=()
mounted_dmg_volume=""

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

  mounted_volumes+=("$volume")
  mounted_dmg_volume="$volume"
}

plist_value() {
  local plist="$1"
  local key="$2"
  "$plistbuddy" -c "Print :$key" "$plist" 2>/dev/null || true
}

inspect_dmg() {
  local arch="$1"
  local dmg="$2"
  local json_path="$3"
  local volume
  local plist
  local short_version
  local bundle_version
  local bundle_id
  local minimum_system_version
  local backend_version
  local sha256

  mount_dmg "$dmg"
  volume="$mounted_dmg_volume"
  plist="$volume/Codex.app/Contents/Info.plist"

  if [[ ! -f "$plist" ]]; then
    echo "Missing Codex.app Info.plist in $dmg" >&2
    exit 1
  fi

  short_version="$(plist_value "$plist" CFBundleShortVersionString)"
  bundle_version="$(plist_value "$plist" CFBundleVersion)"
  bundle_id="$(plist_value "$plist" CFBundleIdentifier)"
  minimum_system_version="$(plist_value "$plist" LSMinimumSystemVersion)"
  backend_version="$(python3 "$script_dir/read-codex-backend-version.py" "$volume/Codex.app" 2>/dev/null || true)"
  sha256="$(shasum -a 256 "$dmg" | awk '{print $1}')"

  if [[ -z "$short_version" || -z "$bundle_version" ]]; then
    echo "Missing bundle version metadata in $dmg" >&2
    exit 1
  fi

  python3 - "$json_path" "$arch" "$dmg" "$sha256" "$short_version" "$bundle_version" "$bundle_id" "$minimum_system_version" "$backend_version" <<'PY'
import json
import os
import sys

out, arch, dmg, sha256, short, build, bundle_id, minimum, backend = sys.argv[1:]
payload = {
    "architecture": arch,
    "fileName": os.path.basename(dmg),
    "sha256": sha256,
    "bundleShortVersion": short,
    "bundleVersion": build,
    "bundleIdentifier": bundle_id,
    "minimumSystemVersion": minimum,
}
if backend:
    payload["backendVersion"] = backend
with open(out, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

mkdir -p "$(dirname "$output_path")"

inspect_dmg arm64 "$arm64_dmg" "$tmp_dir/arm64.json"
inspect_dmg x64 "$x64_dmg" "$tmp_dir/x64.json"

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
