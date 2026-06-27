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
mac_arm_appcast_version="$(jq -r '.sources.macos.arm64.appcast.shortVersionString // empty' "$probe_manifest")"
mac_arm_appcast_build="$(jq -r '.sources.macos.arm64.appcast.version // empty' "$probe_manifest")"
mac_arm_pub_date="$(jq -r '.sources.macos.arm64.appcast.pubDate // .sources.macos.arm64.lastModified // empty' "$probe_manifest")"
mac_x64_appcast_version="$(jq -r '.sources.macos.x64.appcast.shortVersionString // empty' "$probe_manifest")"
mac_x64_appcast_build="$(jq -r '.sources.macos.x64.appcast.version // empty' "$probe_manifest")"
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

if [[ "$mac_arm_version" != "$mac_x64_version" ]]; then
  echo "macOS arm64 and Intel resolve to different Codex versions; one canonical release cannot safely contain both yet: arm64=$mac_arm_version x64=$mac_x64_version" >&2
  exit 1
fi

windows_artifacts_dir="$artifacts_dir/codex-windows"
windows_x64_msix="$(find_windows_x64_msix "$windows_artifacts_dir")"
windows_arm64_msix="$(find_windows_arm64_msix "$windows_artifacts_dir")"
windows_arm64_downloadable=false
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
  elif [[ "$windows_arm64_app_version" != "$windows_app_version" ]]; then
    windows_arm64_status="skipped-version-mismatch"
    windows_arm64_missing_reason="$windows_arm64_status"
  else
    windows_arm64_downloadable=true
    windows_arm64_status="${windows_arm64_status:-downloadable}"
  fi
fi

mac_codex_version="${mac_common_version:-$mac_arm_version}"
codex_version="$(max_codex_version "$windows_app_version" "$mac_codex_version")"
if [[ "$windows_app_version" == "$codex_version" ]]; then
  include_windows=true
else
  include_windows=false
fi
if [[ "$mac_codex_version" == "$codex_version" ]]; then
  include_macos=true
else
  include_macos=false
fi

if [[ "$include_windows" != "true" && "$include_macos" != "true" ]]; then
  echo "No platform package matches selected Codex version $codex_version." >&2
  exit 1
fi

if [[ "$include_windows" == "true" && "$include_macos" == "true" ]]; then
  prerelease=false
  publish_latest=true
  platform_completeness="complete"
else
  prerelease=true
  publish_latest=false
  platform_completeness="partial"
fi

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
  --argjson prerelease "$prerelease" \
  --argjson publishLatest "$publish_latest" \
  --argjson windowsArm64Downloadable "$windows_arm64_downloadable" \
  --arg windowsArm64Status "$windows_arm64_status" \
  --arg windowsArm64AppVersion "$windows_arm64_app_version" \
  --arg platformCompleteness "$platform_completeness" \
  '
  .schemaVersion = 3
  | .codexVersion = $codexVersion
  | .publishedAt = $publishedAt
  | .sources.windows.version = $windowsPackageVersion
  | .sources.windows.appVersion = $windowsAppVersion
  | .sources.windows.architectures.x64.version = $windowsPackageVersion
  | .sources.windows.architectures.x64.appVersion = $windowsAppVersion
  | .sources.windows.architectures.x64.downloadable = true
  | .sources.windows.architectures.x64.status = (.sources.windows.architectures.x64.status // "downloadable")
  | if .sources.windows.architectures.arm64? != null then
      .sources.windows.architectures.arm64.downloadable = $windowsArm64Downloadable
      | .sources.windows.architectures.arm64.status = $windowsArm64Status
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
  | .sources.macos.arm64.minimumSystemVersion = $mac[0].macos.arm64.minimumSystemVersion
  | .sources.macos.arm64.sha256 = $mac[0].macos.arm64.sha256
  | .sources.macos.x64.bundleShortVersion = $mac[0].macos.x64.bundleShortVersion
  | .sources.macos.x64.bundleVersion = $mac[0].macos.x64.bundleVersion
  | .sources.macos.x64.bundleIdentifier = $mac[0].macos.x64.bundleIdentifier
  | .sources.macos.x64.minimumSystemVersion = $mac[0].macos.x64.minimumSystemVersion
  | .sources.macos.x64.sha256 = $mac[0].macos.x64.sha256
  | .derived = {
      codexVersion: $codexVersion,
      platformCompleteness: $platformCompleteness,
      includeWindows: $includeWindows,
      includeMacos: $includeMacos,
      prerelease: $prerelease,
      publishLatest: $publishLatest,
      windowsPackageVersion: $windowsPackageVersion,
      windowsAppVersion: $windowsAppVersion,
      windowsArm64AppVersion: $windowsArm64AppVersion,
      macosCommonShortVersion: $mac[0].commonShortVersion,
      macosCommonBundleVersion: $mac[0].commonBundleVersion,
      macosVersionsMatch: $mac[0].versionsMatch,
      missingPlatforms: ([if $includeWindows then empty else "windows" end, if $includeMacos then empty else "macos" end])
    }
  ' "$probe_manifest" > "$tmp_manifest"
mv "$tmp_manifest" release-manifest.json

windows_selected_files=()
if [[ "$include_windows" == "true" ]]; then
  windows_selected_files+=("$windows_x64_msix")
  if [[ "$windows_arm64_downloadable" == "true" && -n "$windows_arm64_msix" ]]; then
    windows_selected_files+=("$windows_arm64_msix")
  fi

  {
    for file in "${windows_selected_files[@]}"; do
      write_checksum "$file"
    done
  } > "$artifacts_dir/codex-windows/SHA256SUMS-windows.txt"
fi

{
  if [[ "$include_macos" == "true" ]]; then
    while IFS= read -r -d '' file; do
      write_checksum "$file"
    done < <(find "$artifacts_dir/codex-macos" -type f ! -name macos-metadata.json -print0 | sort -z)
  fi
  if [[ "$include_windows" == "true" ]]; then
    for file in "${windows_selected_files[@]}" "$artifacts_dir/codex-windows/SHA256SUMS-windows.txt"; do
      write_checksum "$file"
    done
  fi
  write_checksum release-manifest.json release-manifest.json
} > SHA256SUMS.txt

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
  if [[ "$include_windows" == "true" ]]; then
    echo "- Windows x64: \`${windows_package}.Msix\`"
    if [[ "$windows_arm64_downloadable" == "true" && -n "$windows_arm64_package" ]]; then
      echo "- Windows ARM64: \`${windows_arm64_package}.Msix\`"
    fi
  else
    echo "- Windows: 待官方发布 Codex \`${codex_version}\` 对应 MSIX"
  fi
  if [[ "$include_macos" == "true" ]]; then
    echo "- macOS Apple Silicon: \`Codex-mac-arm64.dmg\`"
    echo "- macOS Intel: \`Codex-mac-x64.dmg\`"
  else
    echo "- macOS: 待官方发布 Codex \`${codex_version}\` 对应 DMG"
  fi
  echo
  echo "## 版本与发布时间"
  echo
  echo "| 平台 | Codex 版本 | 平台包 / build | 官方发布时间 | 镜像发布时间 | 状态 |"
  echo "|---|---:|---:|---|---|---|"
  if [[ "$include_windows" == "true" ]]; then
    echo "| Windows x64 | \`${windows_app_version}\` | \`${windows_package_version}\` | $(table_cell "$windows_x64_last_modified") | ${published_at_label} | 已发布 |"
    if [[ -n "$windows_arm64_package" ]]; then
      if [[ "$windows_arm64_downloadable" == "true" ]]; then
        echo "| Windows ARM64 | \`${windows_app_version}\` | \`${windows_arm64_package_version:-$windows_package_version}\` | $(table_cell "$windows_arm64_last_modified") | ${published_at_label} | 已发布 |"
      elif [[ "$windows_arm64_missing_reason" == "skipped-rollout-drift" ]]; then
        echo "| Windows ARM64 | \`${windows_app_version}\` | \`${windows_arm64_package_version:-$windows_package_version}\` |  |  | 下载阶段上游版本漂移，待下次探测补齐（\`${windows_arm64_status}\`） |"
      elif [[ "$windows_arm64_missing_reason" == "skipped-version-mismatch" ]]; then
        echo "| Windows ARM64 | \`${windows_arm64_app_version}\` | \`${windows_arm64_package_version:-$windows_package_version}\` |  |  | 内部版本与 Windows x64 \`${windows_app_version}\` 不一致，待下次探测补齐（\`${windows_arm64_status}\`） |"
      elif [[ "$windows_arm64_missing_reason" == "skipped-version-unreadable" ]]; then
        echo "| Windows ARM64 |  | \`${windows_arm64_package_version:-$windows_package_version}\` |  |  | 无法读取内部版本，待下次探测补齐（\`${windows_arm64_status}\`） |"
      else
        echo "| Windows ARM64 | \`${windows_app_version}\` | \`${windows_arm64_package_version:-$windows_package_version}\` |  |  | Microsoft Store 目录已出现，下载 URL 待解析（\`${windows_arm64_status:-catalog-only}\`） |"
      fi
    fi
  else
    echo "| Windows x64 |  |  |  |  | 待官方发布对应版本 |"
    if [[ -n "$windows_arm64_package" ]]; then
      echo "| Windows ARM64 |  |  |  |  | 待官方发布对应版本 |"
    fi
  fi
  if [[ "$include_macos" == "true" ]]; then
    echo "| macOS Apple Silicon | \`${mac_arm_version}\` | build \`${mac_arm_build}\` | $(table_cell "$mac_arm_pub_date") | ${published_at_label} | 已发布 |"
    echo "| macOS Intel | \`${mac_x64_version}\` | build \`${mac_x64_build}\` | $(table_cell "$mac_x64_pub_date") | ${published_at_label} | 已发布 |"
  else
    echo "| macOS Apple Silicon |  |  |  |  | 待官方发布对应版本 |"
    echo "| macOS Intel |  |  |  |  | 待官方发布对应版本 |"
  fi
  echo
  echo "本仓库以 Codex 内部版本聚合平台安装包；Windows MSIX 的四段包版本会单独列在“平台包 / build”列。"
  echo
  if [[ "$publish_latest" == "true" ]]; then
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
    echo "这些链接始终指向当前最新完整镜像版本。如果你正在查看历史 Release，请优先使用该 Release 页面中的附件。"
    echo "<!-- latest-links-cn:end -->"
  else
    echo "此 Release 是平台补齐前的预发布，不会更新 latest 短链；缺失平台发布后将补齐同一个版本并转为正式 Release。"
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
  if [[ "$include_windows" == "true" ]]; then
    echo "- Windows x64: \`${windows_package}.Msix\`"
    if [[ "$windows_arm64_downloadable" == "true" && -n "$windows_arm64_package" ]]; then
      echo "- Windows ARM64: \`${windows_arm64_package}.Msix\`"
    fi
  else
    echo "- Windows: waiting for the official MSIX for Codex \`${codex_version}\`"
  fi
  if [[ "$include_macos" == "true" ]]; then
    echo "- macOS Apple Silicon: \`Codex-mac-arm64.dmg\`"
    echo "- macOS Intel: \`Codex-mac-x64.dmg\`"
  else
    echo "- macOS: waiting for the official DMG for Codex \`${codex_version}\`"
  fi
  echo
  echo "## Versions and publish times"
  echo
  echo "| Platform | Codex version | Platform package / build | Official publish time | Mirror publish time | Status |"
  echo "|---|---:|---:|---|---|---|"
  if [[ "$include_windows" == "true" ]]; then
    echo "| Windows x64 | \`${windows_app_version}\` | \`${windows_package_version}\` | $(table_cell "$windows_x64_last_modified") | ${published_at_label} | Published |"
    if [[ -n "$windows_arm64_package" ]]; then
      if [[ "$windows_arm64_downloadable" == "true" ]]; then
        echo "| Windows ARM64 | \`${windows_app_version}\` | \`${windows_arm64_package_version:-$windows_package_version}\` | $(table_cell "$windows_arm64_last_modified") | ${published_at_label} | Published |"
      elif [[ "$windows_arm64_missing_reason" == "skipped-rollout-drift" ]]; then
        echo "| Windows ARM64 | \`${windows_app_version}\` | \`${windows_arm64_package_version:-$windows_package_version}\` |  |  | Upstream version drifted during download; will be completed on the next probe (\`${windows_arm64_status}\`) |"
      elif [[ "$windows_arm64_missing_reason" == "skipped-version-mismatch" ]]; then
        echo "| Windows ARM64 | \`${windows_arm64_app_version}\` | \`${windows_arm64_package_version:-$windows_package_version}\` |  |  | Internal version differs from Windows x64 \`${windows_app_version}\`; will be completed on the next probe (\`${windows_arm64_status}\`) |"
      elif [[ "$windows_arm64_missing_reason" == "skipped-version-unreadable" ]]; then
        echo "| Windows ARM64 |  | \`${windows_arm64_package_version:-$windows_package_version}\` |  |  | Could not read internal version; will be completed on the next probe (\`${windows_arm64_status}\`) |"
      else
        echo "| Windows ARM64 | \`${windows_app_version}\` | \`${windows_arm64_package_version:-$windows_package_version}\` |  |  | Present in Microsoft Store catalog, download URL unresolved (\`${windows_arm64_status:-catalog-only}\`) |"
      fi
    fi
  else
    echo "| Windows x64 |  |  |  |  | Waiting for matching upstream package |"
    if [[ -n "$windows_arm64_package" ]]; then
      echo "| Windows ARM64 |  |  |  |  | Waiting for matching upstream package |"
    fi
  fi
  if [[ "$include_macos" == "true" ]]; then
    echo "| macOS Apple Silicon | \`${mac_arm_version}\` | build \`${mac_arm_build}\` | $(table_cell "$mac_arm_pub_date") | ${published_at_label} | Published |"
    echo "| macOS Intel | \`${mac_x64_version}\` | build \`${mac_x64_build}\` | $(table_cell "$mac_x64_pub_date") | ${published_at_label} | Published |"
  else
    echo "| macOS Apple Silicon |  |  |  |  | Waiting for matching upstream package |"
    echo "| macOS Intel |  |  |  |  | Waiting for matching upstream package |"
  fi
  echo
  echo "This mirror groups platform installers by the Codex app's internal version; the four-part Windows MSIX package version is listed separately in the platform package / build column."
  echo
  if [[ "$publish_latest" == "true" ]]; then
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
    echo "These links always point to the newest complete mirrored version. If you are viewing a historical Release, prefer the assets attached to that Release page."
    echo "<!-- latest-links-en:end -->"
  else
    echo "This is a prerelease while platform coverage is incomplete. It does not update latest quick links; when the missing platform ships, this same version will be completed and promoted to a regular Release."
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
    github_output_value "prerelease" "$prerelease"
    github_output_value "publish_latest" "$publish_latest"
    github_output_value "platform_completeness" "$platform_completeness"
  } >> "$GITHUB_OUTPUT"
fi

echo "tag=$tag"
echo "title=$title"
echo "codex_version=$codex_version"
echo "include_windows=$include_windows"
echo "include_macos=$include_macos"
echo "prerelease=$prerelease"
echo "publish_latest=$publish_latest"
echo "platform_completeness=$platform_completeness"
