#!/usr/bin/env bash
set -euo pipefail

manifest_path="${1:-release-manifest.json}"
macos_metadata="${2:?macOS metadata is required}"
windows_identity="${3:?Windows identity metadata is required}"
artifacts_dir="${4:?artifacts directory is required}"
expected_version="${5:?expected Codex version is required}"
public_base_url="${6:?public base URL is required}"
release_tag="${7:?release tag is required}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
candidate_prefix="releases/$release_tag"
candidate_base_url="${public_base_url%/}/$candidate_prefix"
tmp_manifest="$(mktemp)"
tmp_dir="$(mktemp -d)"

cleanup() {
  rm -f "$tmp_manifest"
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

jq \
  --slurpfile mac "$macos_metadata" \
  --slurpfile win "$windows_identity" \
  --arg expectedVersion "$expected_version" \
  --arg releaseTag "$release_tag" \
  --arg candidatePrefix "$candidate_prefix" \
  --arg candidateBaseUrl "$candidate_base_url" '
  if .codexVersion != $expectedVersion or .derived.codexVersion != $expectedVersion then
    error("canonical Codex version does not match emergency snapshot")
  elif .derived.includeWindowsX64 != true
    or .derived.includeWindowsArm64 != true
    or .derived.includeMacosArm64 != true
    or .derived.includeMacosX64 != true then
    error("emergency Stable candidate must include all four architectures")
  elif $win[0].expectedIdentity != "OpenAI.Codex" then
    error("Windows identity gate did not verify OpenAI.Codex")
  elif $mac[0].identityGate.bundleIdentifier != "com.openai.codex"
    or $mac[0].identityGate.rejectedBundleIdentifier != "com.openai.chat"
    or $mac[0].identityGate.teamIdentifier != "2DC432GLL2" then
    error("macOS identity gate metadata is incomplete")
  else . end
  | .sources.windows.architectures.x64.packageIdentity = $win[0].architectures.x64.packageIdentity
  | .sources.windows.architectures.x64.applicationId = $win[0].architectures.x64.applicationId
  | .sources.windows.architectures.x64.applicationExecutable = $win[0].architectures.x64.applicationExecutable
  | .sources.windows.architectures.arm64.packageIdentity = $win[0].architectures.arm64.packageIdentity
  | .sources.windows.architectures.arm64.applicationId = $win[0].architectures.arm64.applicationId
  | .sources.windows.architectures.arm64.applicationExecutable = $win[0].architectures.arm64.applicationExecutable
  | .sources.macos.arm64.identity = {
      bundleIdentifier: $mac[0].macos.arm64.bundleIdentifier,
      teamIdentifier: $mac[0].macos.arm64.teamIdentifier,
      sparklePublicKey: $mac[0].macos.arm64.sparklePublicKey,
      rejectedBundleIdentifier: $mac[0].identityGate.rejectedBundleIdentifier
    }
  | .sources.macos.x64.identity = {
      bundleIdentifier: $mac[0].macos.x64.bundleIdentifier,
      teamIdentifier: $mac[0].macos.x64.teamIdentifier,
      sparklePublicKey: $mac[0].macos.x64.sparklePublicKey,
      rejectedBundleIdentifier: $mac[0].identityGate.rejectedBundleIdentifier
    }
  | .derived.prerelease = true
  | .derived.publishLatest = false
  | .derived.syncLatest = false
  | .derived.emergencyCandidate = true
  | .candidate = {
      releaseTag: $releaseTag,
      prefix: $candidatePrefix,
      baseUrl: $candidateBaseUrl,
      manifestUrl: ($candidateBaseUrl + "/latest/manifest"),
      checksumsUrl: ($candidateBaseUrl + "/latest/checksums"),
      arm64AppcastUrl: ($candidateBaseUrl + "/latest/appcast.xml"),
      x64AppcastUrl: ($candidateBaseUrl + "/latest/appcast-x64.xml"),
      sharedLatestAdvanced: false,
      contract: "issues-37-38-stable-p0"
    }
  | .emergency.sharedLatestAdvanced = false
  ' "$manifest_path" > "$tmp_manifest"
mv "$tmp_manifest" "$manifest_path"

# Build appcasts from an isolated copy whose full enclosure basename comes from
# mirrorEnclosureBasename instead of reconstructing it at the egress boundary.
cp "$script_dir/build-appcast.sh" "$tmp_dir/build-appcast.sh"
python3 - "$tmp_dir/build-appcast.sh" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
old = 'enclosure_url="$base/latest/$mirror_dir/Codex-darwin-${archive_arch}-${short_version}.zip"'
new = '''mirror_enclosure_basename="$(jq -r --arg a "$manifest_key" '.sources.macos[$a].appcast.mirrorEnclosureBasename // ""' "$manifest")"
if [[ -z "$mirror_enclosure_basename" ]]; then
  echo "Missing macOS $arch mirrorEnclosureBasename in $manifest." >&2
  exit 1
fi
enclosure_url="$base/latest/$mirror_dir/$mirror_enclosure_basename"'''
if source.count(old) != 1:
    raise SystemExit("build-appcast shape changed; refusing emergency patch")
path.write_text(source.replace(old, new), encoding="utf-8")
PY
chmod +x "$tmp_dir/build-appcast.sh"
"$tmp_dir/build-appcast.sh" arm64 "$manifest_path" "$candidate_base_url" candidate-appcast.xml >/dev/null
"$tmp_dir/build-appcast.sh" x64 "$manifest_path" "$candidate_base_url" candidate-appcast-x64.xml >/dev/null

python3 - release-notes.md "$candidate_base_url" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
base = sys.argv[2]
notes = path.read_text(encoding="utf-8")
for start, end in (
    ("<!-- latest-links-cn:start -->", "<!-- latest-links-cn:end -->"),
    ("<!-- latest-links-en:start -->", "<!-- latest-links-en:end -->"),
):
    notes = re.sub(re.escape(start) + r".*?" + re.escape(end) + r"\n?", "", notes, flags=re.S)

banner = f"""> [!IMPORTANT]
> 这是按 #37/#38 Stable P0 契约发布的临时候选版本。GitHub Release 与 R2 / secondary S3 的版本化快照已发布，但 shared `latest/*` 尚未推进；正式切换仍以 Manager 兼容验证为前置。
>
> Candidate manifest: {base}/latest/manifest

"""
path.write_text(banner + notes, encoding="utf-8")
PY

refresh_manifest_checksum() {
  local file="$1"
  local tmp
  tmp="$(mktemp)"
  awk '$2 != "release-manifest.json" { print }' "$file" > "$tmp"
  sha256sum "$manifest_path" | awk '{print tolower($1) "  release-manifest.json"}' >> "$tmp"
  mv "$tmp" "$file"
}

refresh_manifest_checksum SHA256SUMS.txt
refresh_manifest_checksum latest-SHA256SUMS.txt
sha256sum candidate-appcast.xml candidate-appcast-x64.xml |
  awk '{print tolower($1) "  " $2}' >> SHA256SUMS.txt

jq -e \
  --arg expectedVersion "$expected_version" \
  --arg candidateBaseUrl "$candidate_base_url" '
    .codexVersion == $expectedVersion
    and .derived.prerelease == true
    and .derived.publishLatest == false
    and .derived.syncLatest == false
    and .candidate.baseUrl == $candidateBaseUrl
    and .candidate.sharedLatestAdvanced == false
    and .sources.macos.arm64.identity.bundleIdentifier == "com.openai.codex"
    and .sources.macos.x64.identity.bundleIdentifier == "com.openai.codex"
    and .sources.windows.architectures.x64.packageIdentity == "OpenAI.Codex"
    and .sources.windows.architectures.arm64.packageIdentity == "OpenAI.Codex"
  ' "$manifest_path" >/dev/null

echo "Finalized immutable candidate $release_tag at $candidate_base_url"
jq '{codexVersion, derived, candidate, windowsEntrypoints: {x64: .sources.windows.architectures.x64.applicationExecutable, arm64: .sources.windows.architectures.arm64.applicationExecutable}, macosIdentity: {arm64: .sources.macos.arm64.identity, x64: .sources.macos.x64.identity}}' "$manifest_path"
