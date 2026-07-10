#!/usr/bin/env bash
set -euo pipefail

probe_manifest="${1:-probe-manifest.json}"
macos_metadata="${2:-artifacts/codex-macos/macos-metadata.json}"
artifacts_dir="${3:-artifacts}"
r2_public_base_url="${4:-https://codexapp.agentsmirror.com}"
release_tag_override="${5:-}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

sanitize_tag_part() {
  tr -cs 'A-Za-z0-9._-' '-' <<<"$1" | sed -E 's/^-+//; s/-+$//'
}

validate_release_tag() {
  local tag="$1"

  if [[ ! "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
    echo "Invalid release tag '$tag'. Use 1-128 ASCII letters, numbers, dots, underscores, or hyphens; the first character must be alphanumeric." >&2
    exit 1
  fi
}

validate_safe_basename() {
  local label="$1"
  local value="$2"
  local extension="$3"

  if [[ -z "$value" || "$value" == "null" ||
        "$value" == *"/"* || "$value" == *\\* || "$value" == *".."* ||
        "$value" != *".$extension" ]] ||
     LC_ALL=C printf '%s' "$value" | grep -q '[[:cntrl:]]'; then
    echo "Invalid $label basename: '$value'." >&2
    return 1
  fi
}

github_output_value() {
  local name="$1"
  local value="$2"
  local delimiter="__codex_output_${name}_$$_$(date +%s%N)__"

  printf '%s<<%s\n%s\n%s\n' "$name" "$delimiter" "$value" "$delimiter"
}

max_codex_version() {
  python3 - "$1" "$2" <<'PY'
import sys


def key(version):
    parts = []
    for raw in version.split("."):
        if raw.isdigit():
            parts.append((0, int(raw)))
        else:
            parts.append((1, raw))
    return parts


left, right = sys.argv[1], sys.argv[2]
print(max([left, right], key=key))
PY
}

max_nonempty_codex_versions() {
  local selected=""
  local version

  for version in "$@"; do
    if [[ -z "$version" || "$version" == "null" ]]; then
      continue
    fi
    if [[ -z "$selected" ]]; then
      selected="$version"
    else
      selected="$(max_codex_version "$selected" "$version")"
    fi
  done

  printf '%s' "$selected"
}

find_windows_x64_msix() {
  local dir="$1"

  find "$dir" -maxdepth 1 -type f \( -name '*_x64__*.Msix' -o -name '*_x64__*.msix' \) | sort | head -n 1
}

find_windows_arm64_msix() {
  local dir="$1"

  find "$dir" -maxdepth 1 -type f \( -name '*_arm64__*.Msix' -o -name '*_arm64__*.msix' \) | sort | head -n 1
}

write_checksum() {
  local file="$1"
  local name="${2:-$(basename "$file")}"
  local hash

  hash="$(sha256sum "$file" | awk '{print $1}')"
  printf '%s  %s\n' "$hash" "$name"
}

table_cell() {
  local value="${1:-}"
  if [[ -n "$value" && "$value" != "null" ]]; then
    printf '%s' "$value"
  else
    printf ''
  fi
}

require find
require jq
require python3
require sha256sum

tmp_manifest="$(mktemp)"
tmp_previous_manifest="$(mktemp)"
tmp_previous_checksums="$(mktemp)"
cleanup() {
  rm -f "$tmp_manifest" "$tmp_previous_manifest" "$tmp_previous_checksums"
}
trap cleanup EXIT

if [[ ! -f "$probe_manifest" ]]; then
  echo "Missing probe manifest: $probe_manifest" >&2
  exit 1
fi

if [[ ! -f "$macos_metadata" ]]; then
  echo "Missing macOS metadata: $macos_metadata" >&2
  exit 1
fi

windows_package="$(jq -r '.sources.windows.architectures.x64.packageMoniker // .sources.windows.packageMoniker // empty' "$probe_manifest")"
windows_package_version="$(jq -r '.sources.windows.version // empty' "$probe_manifest")"
if [[ -z "$windows_package_version" || "$windows_package_version" == "null" ]]; then
  windows_package_version="$(sed -E 's/^OpenAI\.Codex_([^_]+)_.*/\1/' <<<"$windows_package")"
fi
windows_x64_last_modified="$(jq -r '.sources.windows.architectures.x64.lastModified // .sources.windows.lastModified // empty' "$probe_manifest")"
windows_x64_content_length="$(jq -r '.sources.windows.architectures.x64.contentLength // .sources.windows.contentLength // 0' "$probe_manifest")"
windows_x64_etag="$(jq -r '.sources.windows.architectures.x64.etag // .sources.windows.etag // empty' "$probe_manifest")"
windows_arm64_package="$(jq -r '.sources.windows.architectures.arm64.packageMoniker // empty' "$probe_manifest")"
windows_arm64_package_version="$(jq -r '.sources.windows.architectures.arm64.version // empty' "$probe_manifest")"
windows_arm64_status="$(jq -r '.sources.windows.architectures.arm64.status // empty' "$probe_manifest")"
windows_arm64_probe_downloadable="$(jq -r '.sources.windows.architectures.arm64.downloadable // false' "$probe_manifest")"
windows_arm64_last_modified="$(jq -r '.sources.windows.architectures.arm64.lastModified // empty' "$probe_manifest")"

mac_arm_version="$(jq -r '.macos.arm64.bundleShortVersion' "$macos_metadata")"
mac_arm_build="$(jq -r '.macos.arm64.bundleVersion' "$macos_metadata")"
mac_x64_version="$(jq -r '.macos.x64.bundleShortVersion' "$macos_metadata")"
mac_x64_build="$(jq -r '.macos.x64.bundleVersion' "$macos_metadata")"
mac_common_version="$(jq -r '.commonShortVersion // empty' "$macos_metadata")"
mac_common_build="$(jq -r '.commonBundleVersion // empty' "$macos_metadata")"
mac_arm_zip_file="$(jq -r '.macos.arm64.sparkleArchiveFileName // empty' "$macos_metadata")"
mac_arm_zip_verified="$(jq -r '.macos.arm64.sparkleArchiveIdentityVerified // false' "$macos_metadata")"
mac_arm_zip_version="$(jq -r '.macos.arm64.sparkleArchiveBundleShortVersion // empty' "$macos_metadata")"
mac_arm_zip_build="$(jq -r '.macos.arm64.sparkleArchiveBundleVersion // empty' "$macos_metadata")"
mac_x64_zip_file="$(jq -r '.macos.x64.sparkleArchiveFileName // empty' "$macos_metadata")"
mac_x64_zip_verified="$(jq -r '.macos.x64.sparkleArchiveIdentityVerified // false' "$macos_metadata")"
mac_x64_zip_version="$(jq -r '.macos.x64.sparkleArchiveBundleShortVersion // empty' "$macos_metadata")"
mac_x64_zip_build="$(jq -r '.macos.x64.sparkleArchiveBundleVersion // empty' "$macos_metadata")"
mac_arm_appcast_version="$(jq -r '.sources.macos.arm64.appcast.shortVersionString // empty' "$probe_manifest")"
mac_arm_appcast_build="$(jq -r '.sources.macos.arm64.appcast.version // empty' "$probe_manifest")"
mac_arm_mirror_basename="$(jq -r '.sources.macos.arm64.appcast.mirrorEnclosureBasename // empty' "$probe_manifest")"
mac_arm_pub_date="$(jq -r '.sources.macos.arm64.appcast.pubDate // .sources.macos.arm64.lastModified // empty' "$probe_manifest")"
mac_x64_appcast_version="$(jq -r '.sources.macos.x64.appcast.shortVersionString // empty' "$probe_manifest")"
mac_x64_appcast_build="$(jq -r '.sources.macos.x64.appcast.version // empty' "$probe_manifest")"
mac_x64_mirror_basename="$(jq -r '.sources.macos.x64.appcast.mirrorEnclosureBasename // empty' "$probe_manifest")"
mac_x64_pub_date="$(jq -r '.sources.macos.x64.appcast.pubDate // .sources.macos.x64.lastModified // empty' "$probe_manifest")"

if [[ -z "$windows_package_version" || -z "$windows_package" || -z "$mac_arm_version" || -z "$mac_arm_build" || -z "$mac_x64_version" || -z "$mac_x64_build" ]]; then
  echo "Missing version metadata." >&2
  exit 1
fi

if [[ -n "$mac_arm_appcast_version" && "$mac_arm_appcast_version" != "$mac_arm_version" ]]; then
  echo "macOS arm64 DMG version does not match appcast: appcast=$mac_arm_appcast_version dmg=$mac_arm_version" >&2
  exit 1
fi

if [[ -n "$mac_arm_appcast_build" && "$mac_arm_appcast_build" != "$mac_arm_build" ]]; then
  echo "macOS arm64 DMG build differs from appcast; keeping both: appcast=$mac_arm_appcast_build dmg=$mac_arm_build" >&2
fi

if [[ -n "$mac_x64_appcast_version" && "$mac_x64_appcast_version" != "$mac_x64_version" ]]; then
  echo "macOS Intel DMG version does not match appcast: appcast=$mac_x64_appcast_version dmg=$mac_x64_version" >&2
  exit 1
fi

if [[ -n "$mac_x64_appcast_build" && "$mac_x64_appcast_build" != "$mac_x64_build" ]]; then
  echo "macOS Intel DMG build differs from appcast; keeping both: appcast=$mac_x64_appcast_build dmg=$mac_x64_build" >&2
fi

if [[ "$mac_arm_zip_verified" != "true" || "$mac_x64_zip_verified" != "true" ]]; then
  echo "Both macOS Sparkle archives must pass the Stable identity gate." >&2
  exit 1
fi
if [[ "$mac_arm_zip_file" != "$mac_arm_mirror_basename" ||
      "$mac_x64_zip_file" != "$mac_x64_mirror_basename" ]]; then
  echo "Verified macOS Sparkle archive filenames do not match mirrorEnclosureBasename." >&2
  exit 1
fi
if [[ "$mac_arm_zip_version" != "$mac_arm_appcast_version" ||
      "$mac_arm_zip_build" != "$mac_arm_appcast_build" ]]; then
  echo "macOS arm64 Sparkle archive does not match appcast: appcast=${mac_arm_appcast_version}/${mac_arm_appcast_build} archive=${mac_arm_zip_version}/${mac_arm_zip_build}" >&2
  exit 1
fi
if [[ "$mac_x64_zip_version" != "$mac_x64_appcast_version" ||
      "$mac_x64_zip_build" != "$mac_x64_appcast_build" ]]; then
  echo "macOS Intel Sparkle archive does not match appcast: appcast=${mac_x64_appcast_version}/${mac_x64_appcast_build} archive=${mac_x64_zip_version}/${mac_x64_zip_build}" >&2
  exit 1
fi

windows_artifacts_dir="$artifacts_dir/codex-windows"
windows_x64_msix="$(find_windows_x64_msix "$windows_artifacts_dir")"
windows_arm64_msix="$(find_windows_arm64_msix "$windows_artifacts_dir")"
windows_arm64_downloadable=false
windows_arm64_local_latest=false
windows_arm64_missing_reason="${windows_arm64_status:-catalog-only}"
windows_arm64_app_version=""
windows_app_version="${WINDOWS_APP_VERSION:-}"
if [[ -z "$windows_app_version" ]]; then
  windows_app_version="$(jq -r '.sources.windows.appVersion // .sources.windows.architectures.x64.appVersion // empty' "$probe_manifest")"
fi
if [[ -z "$windows_app_version" || "$windows_app_version" == "null" ]]; then
  if [[ -z "$windows_x64_msix" ]]; then
    echo "Cannot determine Windows Codex app version: no x64 MSIX was found in $windows_artifacts_dir." >&2
    exit 1
  fi
  windows_app_version="$(python3 "$script_dir/read-windows-msix-version.py" "$windows_x64_msix")"
fi

if [[ -z "$windows_app_version" || "$windows_app_version" == "null" ]]; then
  echo "Missing Windows Codex app version." >&2
  exit 1
fi

if [[ -n "$windows_arm64_msix" ]]; then
  if ! windows_arm64_app_version="$(python3 "$script_dir/read-windows-msix-version.py" "$windows_arm64_msix")"; then
    windows_arm64_app_version=""
    windows_arm64_status="skipped-version-unreadable"
    windows_arm64_missing_reason="$windows_arm64_status"
  fi
fi

if [[ "$windows_arm64_probe_downloadable" == "true" && -n "$windows_arm64_package" ]]; then
  if [[ -z "$windows_arm64_msix" ]]; then
    windows_arm64_status="skipped-rollout-drift"
    windows_arm64_missing_reason="$windows_arm64_status"
  elif [[ -z "$windows_arm64_app_version" ]]; then
    windows_arm64_status="${windows_arm64_status:-skipped-version-unreadable}"
    windows_arm64_missing_reason="$windows_arm64_status"
  else
    windows_arm64_downloadable=true
    windows_arm64_local_latest=true
    windows_arm64_status="${windows_arm64_status:-downloadable}"
    windows_arm64_missing_reason=""
  fi
fi
windows_arm64_release_app_version="$windows_arm64_app_version"

previous_latest_available=false
previous_windows_arm64_json="null"
preserved_windows_arm64_checksum_line=""
preserved_windows_arm64=false
if [[ "${INHERIT_LATEST_FROM_MIRROR:-false}" == "true" && "$windows_arm64_downloadable" != "true" ]]; then
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required when INHERIT_LATEST_FROM_MIRROR=true." >&2
    exit 1
  fi

  if curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 20 --max-time 120 \
      "$r2_public_base_url/latest/manifest?prepare=$$" > "$tmp_previous_manifest" &&
     curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 20 --max-time 120 \
      "$r2_public_base_url/latest/checksums?prepare=$$" > "$tmp_previous_checksums"; then
    previous_latest_available=true
  else
    : > "$tmp_previous_manifest"
    : > "$tmp_previous_checksums"
  fi
fi

if [[ "$previous_latest_available" == "true" &&
      "$windows_arm64_downloadable" != "true" &&
      "$(jq -r '.sources.windows.architectures.arm64.downloadable // false' "$tmp_previous_manifest")" == "true" ]]; then
  previous_windows_arm64_package="$(jq -r '.sources.windows.architectures.arm64.packageMoniker // empty' "$tmp_previous_manifest")"
  if [[ -n "$previous_windows_arm64_package" ]]; then
    preserved_windows_arm64_checksum_line="$(
      awk -v name="${previous_windows_arm64_package}.Msix" '
        $1 ~ /^[0-9a-fA-F]{64}$/ && $2 == name {
          print tolower($1) "  " $2
          exit
        }
      ' "$tmp_previous_checksums"
    )"
  fi

  if [[ -n "$preserved_windows_arm64_checksum_line" ]]; then
    previous_windows_arm64_json="$(jq -c '.sources.windows.architectures.arm64' "$tmp_previous_manifest")"
    windows_arm64_downloadable=true
    windows_arm64_package="$previous_windows_arm64_package"
    windows_arm64_package_version="$(jq -r '.sources.windows.architectures.arm64.version // empty' "$tmp_previous_manifest")"
    windows_arm64_status="$(jq -r '.sources.windows.architectures.arm64.status // "downloadable"' "$tmp_previous_manifest")"
    windows_arm64_app_version="$(jq -r '.sources.windows.architectures.arm64.appVersion // empty' "$tmp_previous_manifest")"
    windows_arm64_last_modified="$(jq -r '.sources.windows.architectures.arm64.lastModified // empty' "$tmp_previous_manifest")"
    windows_arm64_missing_reason=""
    preserved_windows_arm64=true
  fi
fi

codex_version="$(max_nonempty_codex_versions "$windows_app_version" "$windows_arm64_release_app_version" "$mac_arm_version" "$mac_x64_version")"
if [[ -z "$codex_version" ]]; then
  echo "No downloadable package versions were found." >&2
  exit 1
fi

if [[ "$windows_app_version" == "$codex_version" ]]; then
  include_windows_x64=true
else
  include_windows_x64=false
fi
if [[ "$windows_arm64_downloadable" == "true" &&
      ( "$windows_arm64_release_app_version" == "$codex_version" ||
        ( "$preserved_windows_arm64" == "true" && "$windows_arm64_app_version" == "$codex_version" ) ) ]]; then
  include_windows_arm64=true
else
  include_windows_arm64=false
fi
if [[ "$mac_arm_version" == "$codex_version" ]]; then
  include_macos_arm64=true
else
  include_macos_arm64=false
fi
if [[ "$mac_x64_version" == "$codex_version" ]]; then
  include_macos_x64=true
else
  include_macos_x64=false
fi

if [[ "$include_windows_x64" == "true" || "$include_windows_arm64" == "true" ]]; then
  include_windows=true
else
  include_windows=false
fi
if [[ "$include_macos_arm64" == "true" || "$include_macos_x64" == "true" ]]; then
  include_macos=true
else
  include_macos=false
fi

if [[ "$include_windows" != "true" && "$include_macos" != "true" ]]; then
  echo "No platform package matches selected Codex version $codex_version." >&2
  exit 1
fi

if [[ "$include_windows_x64" == "true" &&
      "$include_windows_arm64" == "true" &&
      "$include_macos_arm64" == "true" &&
      "$include_macos_x64" == "true" ]]; then
  prerelease=false
  publish_latest=true
  platform_completeness="complete"
else
  prerelease=true
  publish_latest=false
  platform_completeness="partial"
fi
sync_latest=true

canonical_tag="codex-app-$(sanitize_tag_part "$codex_version")"
if [[ -n "$release_tag_override" ]]; then
  validate_release_tag "$release_tag_override"
  if [[ "$release_tag_override" != "$canonical_tag" ]]; then
    echo "Release tag override '$release_tag_override' does not match canonical tag '$canonical_tag' for Codex $codex_version." >&2
    exit 1
  fi
  tag="$release_tag_override"
else
  tag="$canonical_tag"
fi
validate_release_tag "$tag"

title="Codex App Mirror $codex_version"
published_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
published_at_label="$(date -u +'%Y-%m-%d %H:%M UTC')"

jq \
  --slurpfile mac "$macos_metadata" \
  --arg codexVersion "$codex_version" \
  --arg publishedAt "$published_at" \
  --arg windowsPackageVersion "$windows_package_version" \
  --arg windowsAppVersion "$windows_app_version" \
  --argjson includeWindows "$include_windows" \
  --argjson includeMacos "$include_macos" \
  --argjson includeWindowsX64 "$include_windows_x64" \
  --argjson includeWindowsArm64 "$include_windows_arm64" \
  --argjson includeMacosArm64 "$include_macos_arm64" \
  --argjson includeMacosX64 "$include_macos_x64" \
  --argjson prerelease "$prerelease" \
  --argjson publishLatest "$publish_latest" \
  --argjson syncLatest "$sync_latest" \
  --argjson windowsArm64Downloadable "$windows_arm64_downloadable" \
  --argjson windowsArm64LocalLatest "$windows_arm64_local_latest" \
  --argjson previousWindowsArm64 "$previous_windows_arm64_json" \
  --arg windowsArm64Status "$windows_arm64_status" \
  --arg windowsArm64AppVersion "$windows_arm64_app_version" \
  --arg platformCompleteness "$platform_completeness" \
  '
  .schemaVersion = 5
  | .codexVersion = $codexVersion
  | .publishedAt = $publishedAt
  | .sources.windows.version = $windowsPackageVersion
  | .sources.windows.appVersion = $windowsAppVersion
  | .sources.windows.architectures.x64.version = $windowsPackageVersion
  | .sources.windows.architectures.x64.appVersion = $windowsAppVersion
  | .sources.windows.architectures.x64.downloadable = true
  | .sources.windows.architectures.x64.status = (.sources.windows.architectures.x64.status // "downloadable")
  | .sources.windows.architectures.x64.currentForCodexVersion = $includeWindowsX64
  | if $previousWindowsArm64 != null then
      .sources.windows.architectures.arm64 = ($previousWindowsArm64 + {
        currentForCodexVersion: $includeWindowsArm64,
        currentLocalArtifact: false,
        preservedFromLatest: true
      })
    elif .sources.windows.architectures.arm64? != null then
      .sources.windows.architectures.arm64.downloadable = $windowsArm64Downloadable
      | .sources.windows.architectures.arm64.status = $windowsArm64Status
      | .sources.windows.architectures.arm64.currentForCodexVersion = $includeWindowsArm64
      | .sources.windows.architectures.arm64.currentLocalArtifact = $windowsArm64LocalLatest
      | .sources.windows.architectures.arm64.preservedFromLatest = false
      | if $windowsArm64AppVersion != "" then
          .sources.windows.architectures.arm64.appVersion = $windowsArm64AppVersion
        else
          del(.sources.windows.architectures.arm64.appVersion)
        end
    else
      .
    end
  | .sources.macos.arm64.bundleShortVersion = $mac[0].macos.arm64.bundleShortVersion
  | .sources.macos.arm64.bundleVersion = $mac[0].macos.arm64.bundleVersion
  | .sources.macos.arm64.bundleIdentifier = $mac[0].macos.arm64.bundleIdentifier
  | .sources.macos.arm64.bundleName = ($mac[0].macos.arm64.bundleName // "")
  | .sources.macos.arm64.bundleExecutable = ($mac[0].macos.arm64.bundleExecutable // "")
  | .sources.macos.arm64.teamIdentifier = ($mac[0].macos.arm64.teamIdentifier // "")
  | .sources.macos.arm64.sparklePublicEdKey = ($mac[0].macos.arm64.sparklePublicEdKey // "")
  | .sources.macos.arm64.sparkleArchiveFileName = ($mac[0].macos.arm64.sparkleArchiveFileName // "")
  | .sources.macos.arm64.sparkleArchiveBundleShortVersion = ($mac[0].macos.arm64.sparkleArchiveBundleShortVersion // "")
  | .sources.macos.arm64.sparkleArchiveBundleVersion = ($mac[0].macos.arm64.sparkleArchiveBundleVersion // "")
  | .sources.macos.arm64.sparkleArchiveIdentityVerified = ($mac[0].macos.arm64.sparkleArchiveIdentityVerified // false)
  | .sources.macos.arm64.minimumSystemVersion = $mac[0].macos.arm64.minimumSystemVersion
  | .sources.macos.arm64.sha256 = $mac[0].macos.arm64.sha256
  | .sources.macos.arm64.downloadable = true
  | .sources.macos.arm64.status = "downloadable"
  | .sources.macos.arm64.currentForCodexVersion = $includeMacosArm64
  | .sources.macos.x64.bundleShortVersion = $mac[0].macos.x64.bundleShortVersion
  | .sources.macos.x64.bundleVersion = $mac[0].macos.x64.bundleVersion
  | .sources.macos.x64.bundleIdentifier = $mac[0].macos.x64.bundleIdentifier
  | .sources.macos.x64.bundleName = ($mac[0].macos.x64.bundleName // "")
  | .sources.macos.x64.bundleExecutable = ($mac[0].macos.x64.bundleExecutable // "")
  | .sources.macos.x64.teamIdentifier = ($mac[0].macos.x64.teamIdentifier // "")
  | .sources.macos.x64.sparklePublicEdKey = ($mac[0].macos.x64.sparklePublicEdKey // "")
  | .sources.macos.x64.sparkleArchiveFileName = ($mac[0].macos.x64.sparkleArchiveFileName // "")
  | .sources.macos.x64.sparkleArchiveBundleShortVersion = ($mac[0].macos.x64.sparkleArchiveBundleShortVersion // "")
  | .sources.macos.x64.sparkleArchiveBundleVersion = ($mac[0].macos.x64.sparkleArchiveBundleVersion // "")
  | .sources.macos.x64.sparkleArchiveIdentityVerified = ($mac[0].macos.x64.sparkleArchiveIdentityVerified // false)
  | .sources.macos.x64.minimumSystemVersion = $mac[0].macos.x64.minimumSystemVersion
  | .sources.macos.x64.sha256 = $mac[0].macos.x64.sha256
  | .sources.macos.x64.downloadable = true
  | .sources.macos.x64.status = "downloadable"
  | .sources.macos.x64.currentForCodexVersion = $includeMacosX64
  | .derived = {
      codexVersion: $codexVersion,
      platformCompleteness: $platformCompleteness,
      includeWindows: $includeWindows,
      includeMacos: $includeMacos,
      includeWindowsX64: $includeWindowsX64,
      includeWindowsArm64: $includeWindowsArm64,
      includeMacosArm64: $includeMacosArm64,
      includeMacosX64: $includeMacosX64,
      prerelease: $prerelease,
      publishLatest: $publishLatest,
      syncLatest: $syncLatest,
      windowsPackageVersion: $windowsPackageVersion,
      windowsAppVersion: $windowsAppVersion,
      windowsArm64AppVersion: $windowsArm64AppVersion,
      macosCommonShortVersion: $mac[0].commonShortVersion,
      macosCommonBundleVersion: $mac[0].commonBundleVersion,
      macosVersionsMatch: $mac[0].versionsMatch,
      missingPlatforms: ([if $includeWindows then empty else "windows" end, if $includeMacos then empty else "macos" end]),
      missingArchitectures: ([
        if $includeWindowsX64 then empty else "windows-x64" end,
        if $includeWindowsArm64 then empty else "windows-arm64" end,
        if $includeMacosArm64 then empty else "macos-arm64" end,
        if $includeMacosX64 then empty else "macos-x64" end
      ])
    }
  ' "$probe_manifest" > "$tmp_manifest"
mv "$tmp_manifest" release-manifest.json

for mac_arch_key in arm64 x64; do
  mac_mirror_basename="$(jq -r --arg a "$mac_arch_key" '.sources.macos[$a].appcast.mirrorEnclosureBasename // empty' release-manifest.json)"
  validate_safe_basename "macOS $mac_arch_key mirror enclosure" "$mac_mirror_basename" zip || exit 1
done

macos_arch_files() {
  local arch_key="$1"
  local dmg_path="$2"
  local basename

  printf '%s\n' "$dmg_path"

  basename="$(jq -r --arg a "$arch_key" '.sources.macos[$a].appcast.mirrorEnclosureBasename // empty' release-manifest.json)"
  printf '%s\n' "$artifacts_dir/codex-macos/$basename"

  while IFS= read -r basename; do
    [[ -n "$basename" ]] || continue
    printf '%s\n' "$artifacts_dir/codex-macos/$basename"
  done < <(jq -r --arg a "$arch_key" '.sources.macos[$a].appcast.deltas[]?.basename // empty' release-manifest.json)
}

require_selected_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "Selected release file does not exist: $file" >&2
    exit 1
  fi
}

windows_selected_files=()
if [[ "$include_windows_x64" == "true" ]]; then
  windows_selected_files+=("$windows_x64_msix")
fi
if [[ "$include_windows_arm64" == "true" ]]; then
  if [[ "$preserved_windows_arm64" != "true" ]]; then
    windows_selected_files+=("$windows_arm64_msix")
  fi
fi

if [[ "$include_windows" == "true" ]]; then
  for file in "${windows_selected_files[@]}"; do
    require_selected_file "$file"
  done

  {
    for file in "${windows_selected_files[@]}"; do
      write_checksum "$file"
    done
    if [[ "$include_windows_arm64" == "true" && "$preserved_windows_arm64" == "true" && -n "$preserved_windows_arm64_checksum_line" ]]; then
      printf '%s\n' "$preserved_windows_arm64_checksum_line"
    fi
  } > "$artifacts_dir/codex-windows/SHA256SUMS-windows.txt"
fi

macos_selected_files=()
if [[ "$include_macos_arm64" == "true" ]]; then
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    require_selected_file "$file"
    macos_selected_files+=("$file")
  done < <(macos_arch_files arm64 "$artifacts_dir/codex-macos/Codex-mac-arm64.dmg")
fi
if [[ "$include_macos_x64" == "true" ]]; then
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    require_selected_file "$file"
    macos_selected_files+=("$file")
  done < <(macos_arch_files x64 "$artifacts_dir/codex-macos/Codex-mac-x64.dmg")
fi

if [[ "$include_macos" == "true" ]]; then
  {
    for file in "${macos_selected_files[@]}"; do
      write_checksum "$file"
    done
  } > "$artifacts_dir/codex-macos/SHA256SUMS-macos.txt"
fi

latest_checksum_files=()
while IFS= read -r file; do
  [[ -n "$file" && -f "$file" ]] || continue
  latest_checksum_files+=("$file")
done < <(macos_arch_files arm64 "$artifacts_dir/codex-macos/Codex-mac-arm64.dmg" Codex-darwin-arm64)
while IFS= read -r file; do
  [[ -n "$file" && -f "$file" ]] || continue
  latest_checksum_files+=("$file")
done < <(macos_arch_files x64 "$artifacts_dir/codex-macos/Codex-mac-x64.dmg" Codex-darwin-x64)
if [[ -n "$windows_x64_msix" && -f "$windows_x64_msix" ]]; then
  latest_checksum_files+=("$windows_x64_msix")
fi
if [[ "$windows_arm64_local_latest" == "true" && -n "$windows_arm64_msix" && -f "$windows_arm64_msix" ]]; then
  latest_checksum_files+=("$windows_arm64_msix")
fi

tmp_latest_artifact_checksums="$(mktemp)"
{
  for file in "${latest_checksum_files[@]}"; do
    write_checksum "$file"
  done
  if [[ -n "$preserved_windows_arm64_checksum_line" ]]; then
    printf '%s\n' "$preserved_windows_arm64_checksum_line"
  fi
} > "$tmp_latest_artifact_checksums"

latest_checksums_json="$(
  python3 - "$tmp_latest_artifact_checksums" <<'PY'
import json
import re
import sys

checksums = {}
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    parts = line.split(None, 1)
    if len(parts) != 2:
        continue
    digest, name = parts
    if re.fullmatch(r"[0-9a-fA-F]{64}", digest):
        checksums[name] = digest.lower()
print(json.dumps(checksums, sort_keys=True, separators=(",", ":")))
PY
)"
rm -f "$tmp_latest_artifact_checksums"

jq --argjson latestChecksums "$latest_checksums_json" \
  '.derived.latestChecksums = $latestChecksums' \
  release-manifest.json > "$tmp_manifest"
mv "$tmp_manifest" release-manifest.json

{
  if [[ "$include_macos" == "true" ]]; then
    for file in "${macos_selected_files[@]}" "$artifacts_dir/codex-macos/SHA256SUMS-macos.txt"; do
      write_checksum "$file"
    done
  fi
  if [[ "$include_windows" == "true" ]]; then
    for file in "${windows_selected_files[@]}"; do
      write_checksum "$file"
    done
    if [[ "$include_windows_arm64" == "true" && "$preserved_windows_arm64" == "true" && -n "$preserved_windows_arm64_checksum_line" ]]; then
      printf '%s\n' "$preserved_windows_arm64_checksum_line"
    fi
    write_checksum "$artifacts_dir/codex-windows/SHA256SUMS-windows.txt"
  fi
  write_checksum release-manifest.json release-manifest.json
} > SHA256SUMS.txt

{
  for file in "${latest_checksum_files[@]}"; do
    write_checksum "$file"
  done
  if [[ -n "$preserved_windows_arm64_checksum_line" ]]; then
    printf '%s\n' "$preserved_windows_arm64_checksum_line"
  fi
  write_checksum release-manifest.json release-manifest.json
} > latest-SHA256SUMS.txt

{
  echo "<!-- release-banner:start -->"
  echo "![Codex App Mirror](https://github.com/Wangnov/codex-app-mirror/releases/latest/download/status.png)"
  echo "<!-- release-banner:end -->"
  echo
  echo "# Codex App 安装包镜像更新"
  echo
  if [[ "$platform_completeness" == "complete" ]]; then
    echo "本次 Release 同步了 Codex \`${codex_version}\` 的官方桌面端安装包，方便在 GitHub Releases 中下载当前版本对应的安装包。"
  else
    echo "本次 Release 先同步 Codex \`${codex_version}\` 已发布平台的官方安装包；缺失平台发布后会补齐同一个 Release。"
  fi
  echo
  echo "## 下载"
  echo
  if [[ "$include_windows_x64" == "true" ]]; then
    echo "- Windows x64: \`${windows_package}.Msix\`"
  else
    echo "- Windows x64: 待官方发布 Codex \`${codex_version}\` 对应 MSIX（当前 latest 保持 \`${windows_app_version}\`）"
  fi
  if [[ "$include_windows_arm64" == "true" && -n "$windows_arm64_package" ]]; then
    echo "- Windows ARM64: \`${windows_arm64_package}.Msix\`"
  elif [[ -n "$windows_arm64_package" ]]; then
    if [[ "$windows_arm64_downloadable" == "true" && -n "$windows_arm64_app_version" ]]; then
      echo "- Windows ARM64: 待官方发布 Codex \`${codex_version}\` 对应 MSIX（当前 latest 保持 \`${windows_arm64_app_version}\`）"
    else
      echo "- Windows ARM64: 待官方发布 Codex \`${codex_version}\` 对应可下载 MSIX（\`${windows_arm64_status:-catalog-only}\`）"
    fi
  else
    echo "- Windows ARM64: 待官方发布 Codex \`${codex_version}\` 对应 MSIX"
  fi
  if [[ "$include_macos_arm64" == "true" ]]; then
    echo "- macOS Apple Silicon: \`Codex-mac-arm64.dmg\`"
  else
    echo "- macOS Apple Silicon: 待官方发布 Codex \`${codex_version}\` 对应 DMG（当前 latest 保持 \`${mac_arm_version}\`）"
  fi
  if [[ "$include_macos_x64" == "true" ]]; then
    echo "- macOS Intel: \`Codex-mac-x64.dmg\`"
  else
    echo "- macOS Intel: 待官方发布 Codex \`${codex_version}\` 对应 DMG（当前 latest 保持 \`${mac_x64_version}\`）"
  fi
  echo
  echo "## 版本与发布时间"
  echo
  echo "| 平台 | Codex 版本 | 平台包 / build | 官方发布时间 | 镜像发布时间 | 状态 |"
  echo "|---|---:|---:|---|---|---|"
  if [[ "$include_windows_x64" == "true" ]]; then
    echo "| Windows x64 | \`${windows_app_version}\` | \`${windows_package_version}\` | $(table_cell "$windows_x64_last_modified") | ${published_at_label} | 已发布 |"
  else
    echo "| Windows x64 | \`${windows_app_version}\` | \`${windows_package_version}\` | $(table_cell "$windows_x64_last_modified") |  | 当前 latest，待目标版本 |"
  fi
  if [[ "$include_windows_arm64" == "true" ]]; then
    echo "| Windows ARM64 | \`${windows_arm64_app_version}\` | \`${windows_arm64_package_version:-$windows_package_version}\` | $(table_cell "$windows_arm64_last_modified") | ${published_at_label} | 已发布 |"
  elif [[ -n "$windows_arm64_package" ]]; then
    if [[ "$windows_arm64_downloadable" == "true" ]]; then
      echo "| Windows ARM64 | \`${windows_arm64_app_version}\` | \`${windows_arm64_package_version:-$windows_package_version}\` | $(table_cell "$windows_arm64_last_modified") |  | 当前 latest，待目标版本 |"
    elif [[ "$windows_arm64_missing_reason" == "skipped-rollout-drift" ]]; then
      echo "| Windows ARM64 |  | \`${windows_arm64_package_version:-$windows_package_version}\` |  |  | 下载阶段上游版本漂移，待下次探测补齐（\`${windows_arm64_status}\`） |"
    elif [[ "$windows_arm64_missing_reason" == "skipped-version-unreadable" ]]; then
      echo "| Windows ARM64 |  | \`${windows_arm64_package_version:-$windows_package_version}\` |  |  | 无法读取内部版本，待下次探测补齐（\`${windows_arm64_status}\`） |"
    else
      echo "| Windows ARM64 |  | \`${windows_arm64_package_version:-$windows_package_version}\` |  |  | Microsoft Store 目录已出现，下载 URL 待解析（\`${windows_arm64_status:-catalog-only}\`） |"
    fi
  else
    echo "| Windows ARM64 |  |  |  |  | 待官方发布对应版本 |"
  fi
  if [[ "$include_macos_arm64" == "true" ]]; then
    echo "| macOS Apple Silicon | \`${mac_arm_version}\` | build \`${mac_arm_build}\` | $(table_cell "$mac_arm_pub_date") | ${published_at_label} | 已发布 |"
  else
    echo "| macOS Apple Silicon | \`${mac_arm_version}\` | build \`${mac_arm_build}\` | $(table_cell "$mac_arm_pub_date") |  | 当前 latest，待目标版本 |"
  fi
  if [[ "$include_macos_x64" == "true" ]]; then
    echo "| macOS Intel | \`${mac_x64_version}\` | build \`${mac_x64_build}\` | $(table_cell "$mac_x64_pub_date") | ${published_at_label} | 已发布 |"
  else
    echo "| macOS Intel | \`${mac_x64_version}\` | build \`${mac_x64_build}\` | $(table_cell "$mac_x64_pub_date") |  | 当前 latest，待目标版本 |"
  fi
  echo
  echo "本仓库以 Codex 内部版本聚合平台安装包；Windows MSIX 的四段包版本会单独列在“平台包 / build”列。"
  echo
  if [[ "$sync_latest" == "true" ]]; then
    echo "<!-- latest-links-cn:start -->"
    echo "## 最新版快速下载"
    echo
    echo "- Windows: ${r2_public_base_url}/latest/win"
    echo "- Windows x64: ${r2_public_base_url}/latest/win-x64"
    if [[ "$windows_arm64_downloadable" == "true" && -n "$windows_arm64_package" ]]; then
      echo "- Windows ARM64: ${r2_public_base_url}/latest/win-arm64"
    fi
    echo "- Apple Silicon Mac: ${r2_public_base_url}/latest/mac-arm64"
    echo "- Intel Mac: ${r2_public_base_url}/latest/mac-intel"
    echo "- 校验和: ${r2_public_base_url}/latest/checksums"
    echo "- Manifest: ${r2_public_base_url}/latest/manifest"
    echo
    echo "这些 latest 链接按架构滚动：某个架构一旦同步到新版本，该架构用户就能收到；尚未发布该版本的架构会继续指向它自己的当前版本。"
    echo "<!-- latest-links-cn:end -->"
  fi
  echo
  echo "## 校验"
  echo
  echo "建议下载后使用随附的 \`SHA256SUMS.txt\` 校验文件完整性。"
  echo
  echo "## Windows 安装策略提示"
  echo
  echo "如果安装 \`.Msix\` 时提示“你的系统管理员已阻止此程序”，通常是当前设备策略不允许从商店外安装 MSIX / AppX 包，或应用安装器 / AppX 部署服务被禁用。请优先尝试 Microsoft Store 官方页面；公司、学校或其他受组织策略管理的设备需要联系设备管理员放行，本镜像不会绕过本机安装策略。"
  echo
  echo "## 来源说明"
  echo
  echo "本项目只镜像官方安装包，不修改、不重打包、不破解安装器。更完整的上游指纹记录在随附的 \`release-manifest.json\` 中。"
  echo
  echo "---"
  echo
  echo "# Codex App installer mirror update"
  echo
  if [[ "$platform_completeness" == "complete" ]]; then
    echo "This release mirrors the official desktop installers for Codex \`${codex_version}\` and makes the matching packages available as assets on this GitHub Release."
  else
    echo "This release mirrors the official installers currently available for Codex \`${codex_version}\`; missing platforms will be added to this same Release after upstream publishes them."
  fi
  echo
  echo "## Downloads"
  echo
  if [[ "$include_windows_x64" == "true" ]]; then
    echo "- Windows x64: \`${windows_package}.Msix\`"
  else
    echo "- Windows x64: waiting for the official MSIX for Codex \`${codex_version}\` (current latest stays on \`${windows_app_version}\`)"
  fi
  if [[ "$include_windows_arm64" == "true" && -n "$windows_arm64_package" ]]; then
    echo "- Windows ARM64: \`${windows_arm64_package}.Msix\`"
  elif [[ -n "$windows_arm64_package" ]]; then
    if [[ "$windows_arm64_downloadable" == "true" && -n "$windows_arm64_app_version" ]]; then
      echo "- Windows ARM64: waiting for the official MSIX for Codex \`${codex_version}\` (current latest stays on \`${windows_arm64_app_version}\`)"
    else
      echo "- Windows ARM64: waiting for a downloadable official MSIX for Codex \`${codex_version}\` (\`${windows_arm64_status:-catalog-only}\`)"
    fi
  else
    echo "- Windows ARM64: waiting for the official MSIX for Codex \`${codex_version}\`"
  fi
  if [[ "$include_macos_arm64" == "true" ]]; then
    echo "- macOS Apple Silicon: \`Codex-mac-arm64.dmg\`"
  else
    echo "- macOS Apple Silicon: waiting for the official DMG for Codex \`${codex_version}\` (current latest stays on \`${mac_arm_version}\`)"
  fi
  if [[ "$include_macos_x64" == "true" ]]; then
    echo "- macOS Intel: \`Codex-mac-x64.dmg\`"
  else
    echo "- macOS Intel: waiting for the official DMG for Codex \`${codex_version}\` (current latest stays on \`${mac_x64_version}\`)"
  fi
  echo
  echo "## Versions and publish times"
  echo
  echo "| Platform | Codex version | Platform package / build | Official publish time | Mirror publish time | Status |"
  echo "|---|---:|---:|---|---|---|"
  if [[ "$include_windows_x64" == "true" ]]; then
    echo "| Windows x64 | \`${windows_app_version}\` | \`${windows_package_version}\` | $(table_cell "$windows_x64_last_modified") | ${published_at_label} | Published |"
  else
    echo "| Windows x64 | \`${windows_app_version}\` | \`${windows_package_version}\` | $(table_cell "$windows_x64_last_modified") |  | Current latest, waiting for target version |"
  fi
  if [[ "$include_windows_arm64" == "true" ]]; then
    echo "| Windows ARM64 | \`${windows_arm64_app_version}\` | \`${windows_arm64_package_version:-$windows_package_version}\` | $(table_cell "$windows_arm64_last_modified") | ${published_at_label} | Published |"
  elif [[ -n "$windows_arm64_package" ]]; then
    if [[ "$windows_arm64_downloadable" == "true" ]]; then
      echo "| Windows ARM64 | \`${windows_arm64_app_version}\` | \`${windows_arm64_package_version:-$windows_package_version}\` | $(table_cell "$windows_arm64_last_modified") |  | Current latest, waiting for target version |"
    elif [[ "$windows_arm64_missing_reason" == "skipped-rollout-drift" ]]; then
      echo "| Windows ARM64 |  | \`${windows_arm64_package_version:-$windows_package_version}\` |  |  | Upstream version drifted during download; will be retried on the next probe (\`${windows_arm64_status}\`) |"
    elif [[ "$windows_arm64_missing_reason" == "skipped-version-unreadable" ]]; then
      echo "| Windows ARM64 |  | \`${windows_arm64_package_version:-$windows_package_version}\` |  |  | Could not read internal version; will be retried on the next probe (\`${windows_arm64_status}\`) |"
    else
      echo "| Windows ARM64 |  | \`${windows_arm64_package_version:-$windows_package_version}\` |  |  | Present in Microsoft Store catalog, download URL unresolved (\`${windows_arm64_status:-catalog-only}\`) |"
    fi
  else
    echo "| Windows ARM64 |  |  |  |  | Waiting for matching upstream package |"
  fi
  if [[ "$include_macos_arm64" == "true" ]]; then
    echo "| macOS Apple Silicon | \`${mac_arm_version}\` | build \`${mac_arm_build}\` | $(table_cell "$mac_arm_pub_date") | ${published_at_label} | Published |"
  else
    echo "| macOS Apple Silicon | \`${mac_arm_version}\` | build \`${mac_arm_build}\` | $(table_cell "$mac_arm_pub_date") |  | Current latest, waiting for target version |"
  fi
  if [[ "$include_macos_x64" == "true" ]]; then
    echo "| macOS Intel | \`${mac_x64_version}\` | build \`${mac_x64_build}\` | $(table_cell "$mac_x64_pub_date") | ${published_at_label} | Published |"
  else
    echo "| macOS Intel | \`${mac_x64_version}\` | build \`${mac_x64_build}\` | $(table_cell "$mac_x64_pub_date") |  | Current latest, waiting for target version |"
  fi
  echo
  echo "This mirror groups platform installers by the Codex app's internal version; the four-part Windows MSIX package version is listed separately in the platform package / build column."
  echo
  if [[ "$sync_latest" == "true" ]]; then
    echo "<!-- latest-links-en:start -->"
    echo "## Latest quick downloads"
    echo
    echo "- Windows: ${r2_public_base_url}/latest/win"
    echo "- Windows x64: ${r2_public_base_url}/latest/win-x64"
    if [[ "$windows_arm64_downloadable" == "true" && -n "$windows_arm64_package" ]]; then
      echo "- Windows ARM64: ${r2_public_base_url}/latest/win-arm64"
    fi
    echo "- Apple Silicon Mac: ${r2_public_base_url}/latest/mac-arm64"
    echo "- Intel Mac: ${r2_public_base_url}/latest/mac-intel"
    echo "- Checksums: ${r2_public_base_url}/latest/checksums"
    echo "- Manifest: ${r2_public_base_url}/latest/manifest"
    echo
    echo "These latest links roll forward per architecture: once an architecture is mirrored, users on that architecture can receive it immediately; architectures not yet published for this Codex version continue to point at their own current latest package."
    echo "<!-- latest-links-en:end -->"
  fi
  echo
  echo "## Verification"
  echo
  echo "We recommend verifying downloaded files with the attached \`SHA256SUMS.txt\`."
  echo
  echo "## Windows install policy note"
  echo
  echo "If installing the \`.Msix\` file shows \"This app has been blocked by your system administrator\", the device is usually blocking sideloaded MSIX / AppX installation, or App Installer / AppX deployment has been disabled by policy. Prefer the official Microsoft Store page first. Work, school, or otherwise managed devices need an administrator to allow the install; this mirror does not bypass local install policies."
  echo
  echo "## Source notes"
  echo
  echo "This project only mirrors official installer packages. It does not modify, repackage, or bypass installer authorization. The full upstream fingerprints are included in the attached \`release-manifest.json\`."
} > release-notes.md

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    github_output_value "tag" "$tag"
    github_output_value "title" "$title"
    github_output_value "codex_version" "$codex_version"
    github_output_value "include_windows" "$include_windows"
    github_output_value "include_macos" "$include_macos"
    github_output_value "include_windows_x64" "$include_windows_x64"
    github_output_value "include_windows_arm64" "$include_windows_arm64"
    github_output_value "include_macos_arm64" "$include_macos_arm64"
    github_output_value "include_macos_x64" "$include_macos_x64"
    github_output_value "prerelease" "$prerelease"
    github_output_value "publish_latest" "$publish_latest"
    github_output_value "sync_latest" "$sync_latest"
    github_output_value "platform_completeness" "$platform_completeness"
  } >> "$GITHUB_OUTPUT"
fi

echo "tag=$tag"
echo "title=$title"
echo "codex_version=$codex_version"
echo "include_windows=$include_windows"
echo "include_macos=$include_macos"
echo "include_windows_x64=$include_windows_x64"
echo "include_windows_arm64=$include_windows_arm64"
echo "include_macos_arm64=$include_macos_arm64"
echo "include_macos_x64=$include_macos_x64"
echo "prerelease=$prerelease"
echo "publish_latest=$publish_latest"
echo "sync_latest=$sync_latest"
echo "platform_completeness=$platform_completeness"
