#!/usr/bin/env bash
set -euo pipefail

probe_manifest="${1:-probe-manifest.json}"
macos_metadata="${2:-artifacts/codex-macos/macos-metadata.json}"
artifacts_dir="${3:-artifacts}"
r2_public_base_url="${4:-https://codexapp.agentsmirror.com}"
release_tag_override="${5:-}"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

major_minor() {
  awk -F. '{ if (NF >= 2) print $1 "." $2; else print $0 }' <<<"$1"
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

github_output_value() {
  local name="$1"
  local value="$2"
  local delimiter="__codex_output_${name}_$$_$(date +%s%N)__"

  printf '%s<<%s\n%s\n%s\n' "$name" "$delimiter" "$value" "$delimiter"
}

require find
require jq
require sha256sum

tmp_manifest="$(mktemp)"
cleanup() {
  rm -f "$tmp_manifest"
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

windows_package="$(jq -r '.sources.windows.packageMoniker' "$probe_manifest")"
windows_version="$(jq -r '.sources.windows.version // empty' "$probe_manifest")"
if [[ -z "$windows_version" || "$windows_version" == "null" ]]; then
  windows_version="$(sed -E 's/^OpenAI\.Codex_([^_]+)_.*/\1/' <<<"$windows_package")"
fi

mac_arm_version="$(jq -r '.macos.arm64.bundleShortVersion' "$macos_metadata")"
mac_arm_build="$(jq -r '.macos.arm64.bundleVersion' "$macos_metadata")"
mac_x64_version="$(jq -r '.macos.x64.bundleShortVersion' "$macos_metadata")"
mac_x64_build="$(jq -r '.macos.x64.bundleVersion' "$macos_metadata")"
mac_common_version="$(jq -r '.commonShortVersion // empty' "$macos_metadata")"
mac_common_build="$(jq -r '.commonBundleVersion // empty' "$macos_metadata")"
mac_arm_appcast_version="$(jq -r '.sources.macos.arm64.appcast.shortVersionString // empty' "$probe_manifest")"
mac_arm_appcast_build="$(jq -r '.sources.macos.arm64.appcast.version // empty' "$probe_manifest")"
mac_x64_appcast_version="$(jq -r '.sources.macos.x64.appcast.shortVersionString // empty' "$probe_manifest")"
mac_x64_appcast_build="$(jq -r '.sources.macos.x64.appcast.version // empty' "$probe_manifest")"

if [[ -z "$windows_version" || -z "$mac_arm_version" || -z "$mac_arm_build" || -z "$mac_x64_version" || -z "$mac_x64_build" ]]; then
  echo "Missing version metadata." >&2
  exit 1
fi

if [[ -n "$mac_arm_appcast_version" && "$mac_arm_appcast_version" != "$mac_arm_version" ]]; then
  echo "macOS arm64 DMG version does not match appcast: appcast=$mac_arm_appcast_version dmg=$mac_arm_version" >&2
  exit 1
fi

if [[ -n "$mac_arm_appcast_build" && "$mac_arm_appcast_build" != "$mac_arm_build" ]]; then
  echo "macOS arm64 DMG build does not match appcast: appcast=$mac_arm_appcast_build dmg=$mac_arm_build" >&2
  exit 1
fi

if [[ -n "$mac_x64_appcast_version" && "$mac_x64_appcast_version" != "$mac_x64_version" ]]; then
  echo "macOS Intel DMG version does not match appcast: appcast=$mac_x64_appcast_version dmg=$mac_x64_version" >&2
  exit 1
fi

if [[ -n "$mac_x64_appcast_build" && "$mac_x64_appcast_build" != "$mac_x64_build" ]]; then
  echo "macOS Intel DMG build does not match appcast: appcast=$mac_x64_appcast_build dmg=$mac_x64_build" >&2
  exit 1
fi

if [[ -n "$release_tag_override" ]]; then
  tag="$release_tag_override"
else
  windows_tag="$(sanitize_tag_part "$windows_version")"
  if [[ -n "$mac_common_version" && -n "$mac_common_build" ]]; then
    mac_tag="mac-$(sanitize_tag_part "$mac_common_version")-b$(sanitize_tag_part "$mac_common_build")"
  else
    mac_tag="mac-arm64-$(sanitize_tag_part "$mac_arm_version")-b$(sanitize_tag_part "$mac_arm_build")-x64-$(sanitize_tag_part "$mac_x64_version")-b$(sanitize_tag_part "$mac_x64_build")"
  fi
  tag="codex-app-win-${windows_tag}-${mac_tag}"
fi

validate_release_tag "$tag"

windows_major_minor="$(major_minor "$windows_version")"
mac_major_minor="$(major_minor "${mac_common_version:-$mac_arm_version}")"
if [[ -n "$windows_major_minor" && "$windows_major_minor" == "$mac_major_minor" ]]; then
  title="Codex App Mirror $windows_major_minor"
else
  title="Codex App Mirror Windows $windows_major_minor macOS $mac_major_minor"
fi

jq \
  --slurpfile mac "$macos_metadata" \
  --arg windowsVersion "$windows_version" \
  '
  .schemaVersion = 2
  | .sources.windows.version = $windowsVersion
  | .sources.macos.arm64.bundleShortVersion = $mac[0].macos.arm64.bundleShortVersion
  | .sources.macos.arm64.bundleVersion = $mac[0].macos.arm64.bundleVersion
  | .sources.macos.arm64.bundleIdentifier = $mac[0].macos.arm64.bundleIdentifier
  | .sources.macos.arm64.minimumSystemVersion = $mac[0].macos.arm64.minimumSystemVersion
  | .sources.macos.arm64.sha256 = $mac[0].macos.arm64.sha256
  | .sources.macos.x64.bundleShortVersion = $mac[0].macos.x64.bundleShortVersion
  | .sources.macos.x64.bundleVersion = $mac[0].macos.x64.bundleVersion
  | .sources.macos.x64.bundleIdentifier = $mac[0].macos.x64.bundleIdentifier
  | .sources.macos.x64.minimumSystemVersion = $mac[0].macos.x64.minimumSystemVersion
  | .sources.macos.x64.sha256 = $mac[0].macos.x64.sha256
  | .derived = {
      windowsVersion: $windowsVersion,
      macosCommonShortVersion: $mac[0].commonShortVersion,
      macosCommonBundleVersion: $mac[0].commonBundleVersion,
      macosVersionsMatch: $mac[0].versionsMatch
    }
  ' "$probe_manifest" > "$tmp_manifest"
mv "$tmp_manifest" release-manifest.json

write_checksum() {
  local file="$1"
  local name="${2:-$(basename "$file")}"
  local hash

  hash="$(sha256sum "$file" | awk '{print $1}')"
  printf '%s  %s\n' "$hash" "$name"
}

{
  while IFS= read -r -d '' file; do
    write_checksum "$file"
  done < <(find "$artifacts_dir" -type f ! -name macos-metadata.json -print0 | sort -z)
  write_checksum release-manifest.json release-manifest.json
} > SHA256SUMS.txt

windows_content_length="$(jq -r '.sources.windows.contentLength' release-manifest.json)"
windows_etag="$(jq -r '.sources.windows.etag // empty' release-manifest.json)"
mac_arm_content_length="$(jq -r '.sources.macos.arm64.contentLength' release-manifest.json)"
mac_arm_etag="$(jq -r '.sources.macos.arm64.etag // empty' release-manifest.json)"
mac_x64_content_length="$(jq -r '.sources.macos.x64.contentLength' release-manifest.json)"
mac_x64_etag="$(jq -r '.sources.macos.x64.etag // empty' release-manifest.json)"

{
  echo "<!-- release-banner:start -->"
  echo "![Codex App Mirror](https://github.com/Wangnov/codex-app-mirror/releases/latest/download/status.png)"
  echo "<!-- release-banner:end -->"
  echo
  echo "# Codex App 安装包镜像更新"
  echo
  echo "本次 Release 同步了官方 Codex 桌面端安装包，方便在 GitHub Releases 中下载当前版本对应的安装包。"
  echo
  echo "## 下载"
  echo
  echo "- Windows x64: \`${windows_package}.Msix\`"
  echo "- macOS Apple Silicon: \`Codex-mac-arm64.dmg\`"
  echo "- macOS Intel: \`Codex-mac-x64.dmg\`"
  echo
  echo "## 版本信息"
  echo
  echo "- Windows x64 MSIX: \`${windows_version}\`"
  echo "- macOS Apple Silicon: \`${mac_arm_version}\` build \`${mac_arm_build}\`"
  echo "- macOS Intel: \`${mac_x64_version}\` build \`${mac_x64_build}\`"
  echo
  echo "Windows 和 macOS 来自不同官方上游，版本号可能不完全一致；这是正常情况。"
  echo
  echo "<!-- latest-links-cn:start -->"
  echo "## 最新版快速下载"
  echo
  echo "- Windows: ${r2_public_base_url}/latest/win"
  echo "- Apple Silicon Mac: ${r2_public_base_url}/latest/mac-arm64"
  echo "- Intel Mac: ${r2_public_base_url}/latest/mac-intel"
  echo "- 校验和: ${r2_public_base_url}/latest/checksums"
  echo "- Manifest: ${r2_public_base_url}/latest/manifest"
  echo
  echo "这些链接始终指向当前最新镜像版本。如果你正在查看历史 Release，请优先使用该 Release 页面中的附件。"
  echo "<!-- latest-links-cn:end -->"
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
  echo "This release mirrors the latest official Codex desktop app installers and makes the matching packages available as assets on this GitHub Release."
  echo
  echo "## Downloads"
  echo
  echo "- Windows x64: \`${windows_package}.Msix\`"
  echo "- macOS Apple Silicon: \`Codex-mac-arm64.dmg\`"
  echo "- macOS Intel: \`Codex-mac-x64.dmg\`"
  echo
  echo "## Version details"
  echo
  echo "- Windows x64 MSIX: \`${windows_version}\`"
  echo "- macOS Apple Silicon: \`${mac_arm_version}\` build \`${mac_arm_build}\`"
  echo "- macOS Intel: \`${mac_x64_version}\` build \`${mac_x64_build}\`"
  echo
  echo "Windows and macOS are resolved from different official upstream packages, so their version numbers may not always match exactly."
  echo
  echo "<!-- latest-links-en:start -->"
  echo "## Latest quick downloads"
  echo
  echo "- Windows: ${r2_public_base_url}/latest/win"
  echo "- Apple Silicon Mac: ${r2_public_base_url}/latest/mac-arm64"
  echo "- Intel Mac: ${r2_public_base_url}/latest/mac-intel"
  echo "- Checksums: ${r2_public_base_url}/latest/checksums"
  echo "- Manifest: ${r2_public_base_url}/latest/manifest"
  echo
  echo "These links always point to the newest mirrored version. If you are viewing a historical Release, prefer the assets attached to that Release page."
  echo "<!-- latest-links-en:end -->"
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
  } >> "$GITHUB_OUTPUT"
fi

echo "tag=$tag"
echo "title=$title"
