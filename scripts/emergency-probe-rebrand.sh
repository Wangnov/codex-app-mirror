#!/usr/bin/env bash
set -euo pipefail

# One-shot Stable probe used by emergency-stable-release.yml while the permanent
# #37/#38 implementation is being completed. It runs the production probe from
# an isolated copy and replaces only the obsolete Codex DMG reconstruction with
# a derivation anchored to the authoritative Sparkle enclosure basename.

output_path="${1:-probe-manifest.json}"
expected_codex_version="${EXPECTED_CODEX_VERSION:?EXPECTED_CODEX_VERSION is required}"
expected_windows_package_version="${EXPECTED_WINDOWS_PACKAGE_VERSION:?EXPECTED_WINDOWS_PACKAGE_VERSION is required}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
tmp_dir="$(mktemp -d)"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

cp -R "$repo_root/scripts" "$tmp_dir/scripts"

python3 - "$tmp_dir/scripts/probe-release.sh" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
old = '''arm_url="https://persistent.oaistatic.com/codex-app-prod/Codex-${arm_appcast_version}-arm64.dmg"
x64_url="https://persistent.oaistatic.com/codex-app-prod/Codex-${x64_appcast_version}-x64.dmg"'''
new = '''dmg_url_from_appcast() {
  local enclosure_url="$1"
  local short_version="$2"
  local arch="$3"
  local basename suffix product_prefix base_url

  basename="${enclosure_url##*/}"
  suffix="-darwin-${arch}-${short_version}.zip"
  if [[ -z "$enclosure_url" || "$basename" != *"$suffix" ]]; then
    echo "Cannot derive macOS $arch DMG source from appcast enclosure: $enclosure_url" >&2
    return 1
  fi
  product_prefix="${basename%$suffix}"
  base_url="${enclosure_url%/*}"
  printf '%s/%s-%s-%s.dmg' "$base_url" "$product_prefix" "$short_version" "$arch"
}

arm_url="$(dmg_url_from_appcast "$(jq -r '.enclosureUrl' <<<"$arm_appcast_json")" "$arm_appcast_version" arm64)"
x64_url="$(dmg_url_from_appcast "$(jq -r '.enclosureUrl' <<<"$x64_appcast_json")" "$x64_appcast_version" x64)"'''

if source.count(old) != 1:
    raise SystemExit("production probe shape changed; refusing emergency patch")
path.write_text(source.replace(old, new), encoding="utf-8")
PY

mkdir -p "$(dirname "$output_path")"
GITHUB_OUTPUT= \
FORCE_RELEASE=true \
MANIFEST_PATH="$output_path" \
bash "$tmp_dir/scripts/probe-release.sh"

tmp_manifest="$(mktemp)"
jq '
  def basename: split("/") | last;
  .sources.macos.arm64.sourceUrl = .sources.macos.arm64.url
  | .sources.macos.arm64.sourceBasename = (.sources.macos.arm64.url | basename)
  | .sources.macos.arm64.mirrorBasename = "Codex-mac-arm64.dmg"
  | .sources.macos.arm64.appcast.sourceUrl = .sources.macos.arm64.appcast.enclosureUrl
  | .sources.macos.arm64.appcast.sourceBasename = (.sources.macos.arm64.appcast.enclosureUrl | basename)
  | .sources.macos.arm64.appcast.mirrorEnclosureBasename = ("Codex-darwin-arm64-" + .sources.macos.arm64.appcast.shortVersionString + ".zip")
  | .sources.macos.x64.sourceUrl = .sources.macos.x64.url
  | .sources.macos.x64.sourceBasename = (.sources.macos.x64.url | basename)
  | .sources.macos.x64.mirrorBasename = "Codex-mac-x64.dmg"
  | .sources.macos.x64.appcast.sourceUrl = .sources.macos.x64.appcast.enclosureUrl
  | .sources.macos.x64.appcast.sourceBasename = (.sources.macos.x64.appcast.enclosureUrl | basename)
  | .sources.macos.x64.appcast.mirrorEnclosureBasename = ("Codex-darwin-x64-" + .sources.macos.x64.appcast.shortVersionString + ".zip")
  | .emergency = {
      contract: "issues-37-38-stable-p0",
      channel: "stable",
      sharedLatestAdvanced: false
    }
' "$output_path" > "$tmp_manifest"
mv "$tmp_manifest" "$output_path"

jq -e \
  --arg codex "$expected_codex_version" \
  --arg windows "$expected_windows_package_version" '
    .sources.windows.updateManifest.packageIdentity == "OpenAI.Codex"
    and .sources.windows.updateManifest.buildVersion == $windows
    and .sources.windows.architectures.x64.version == $windows
    and .sources.windows.architectures.arm64.version == $windows
    and .sources.windows.architectures.x64.downloadable == true
    and .sources.windows.architectures.arm64.downloadable == true
    and (.sources.windows.architectures.x64.packageMoniker | startswith("OpenAI.Codex_"))
    and (.sources.windows.architectures.arm64.packageMoniker | startswith("OpenAI.Codex_"))
    and .sources.macos.arm64.appcast.shortVersionString == $codex
    and .sources.macos.x64.appcast.shortVersionString == $codex
    and .sources.macos.arm64.appcast.sourceBasename != ""
    and .sources.macos.x64.appcast.sourceBasename != ""
    and .sources.macos.arm64.appcast.mirrorEnclosureBasename == ("Codex-darwin-arm64-" + $codex + ".zip")
    and .sources.macos.x64.appcast.mirrorEnclosureBasename == ("Codex-darwin-x64-" + $codex + ".zip")
  ' "$output_path" >/dev/null

jq '{
  windowsPackageVersion: .sources.windows.version,
  windowsX64: .sources.windows.architectures.x64.packageMoniker,
  windowsArm64: .sources.windows.architectures.arm64.packageMoniker,
  macosArm64: {
    version: .sources.macos.arm64.appcast.shortVersionString,
    source: .sources.macos.arm64.sourceBasename,
    sparkleSource: .sources.macos.arm64.appcast.sourceBasename,
    sparkleMirror: .sources.macos.arm64.appcast.mirrorEnclosureBasename
  },
  macosX64: {
    version: .sources.macos.x64.appcast.shortVersionString,
    source: .sources.macos.x64.sourceBasename,
    sparkleSource: .sources.macos.x64.appcast.sourceBasename,
    sparkleMirror: .sources.macos.x64.appcast.mirrorEnclosureBasename
  }
}' "$output_path"
