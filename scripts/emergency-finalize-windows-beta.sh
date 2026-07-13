#!/usr/bin/env bash
set -euo pipefail

manifest_path="${1:-probe-manifest.json}"
windows_identity="${2:?Windows identity metadata is required}"
macos_identity="${3:?macOS identity metadata is required}"
artifacts_dir="${4:?artifacts directory is required}"
expected_windows_version="${5:?expected Windows package version is required}"
expected_macos_version="${6:?expected macOS version is required}"
release_tag="${7:?release tag is required}"
expected_release_tag="codex-app-beta-win-${expected_windows_version}-mac-${expected_macos_version}"
windows_dir="$artifacts_dir/codex-windows"
macos_dir="$artifacts_dir/codex-macos"
tmp_manifest="$(mktemp)"

if [[ "$release_tag" != "$expected_release_tag" ]]; then
  echo "Beta release tag/version mismatch: expected $expected_release_tag, got $release_tag" >&2
  exit 1
fi

cleanup() {
  rm -f "$tmp_manifest"
}
trap cleanup EXIT

mac_arm_dmg="$(jq -r '.sources.macos.arm64.mirrorBasename // empty' "$manifest_path")"
mac_x64_dmg="$(jq -r '.sources.macos.x64.mirrorBasename // empty' "$manifest_path")"
mac_arm_zip="$(jq -r '.sources.macos.arm64.appcast.mirrorEnclosureBasename // empty' "$manifest_path")"
mac_x64_zip="$(jq -r '.sources.macos.x64.appcast.mirrorEnclosureBasename // empty' "$manifest_path")"

for file_name in "$mac_arm_dmg" "$mac_x64_dmg" "$mac_arm_zip" "$mac_x64_zip"; do
  if [[ -z "$file_name" || "$file_name" == *"/"* || "$file_name" == *"\\"* || "$file_name" == *".."* ]]; then
    echo "Unsafe or missing macOS Beta asset basename: $file_name" >&2
    exit 1
  fi
  [[ -f "$macos_dir/$file_name" ]] || {
    echo "Missing macOS Beta asset: $macos_dir/$file_name" >&2
    exit 1
  }
done

mac_arm_zip_sha="$(sha256sum "$macos_dir/$mac_arm_zip" | awk '{print tolower($1)}')"
mac_x64_zip_sha="$(sha256sum "$macos_dir/$mac_x64_zip" | awk '{print tolower($1)}')"

jq \
  --slurpfile win "$windows_identity" \
  --slurpfile mac "$macos_identity" \
  --arg expectedWindowsVersion "$expected_windows_version" \
  --arg expectedMacosVersion "$expected_macos_version" \
  --arg releaseTag "$release_tag" \
  --arg macArmZipSha "$mac_arm_zip_sha" \
  --arg macX64ZipSha "$mac_x64_zip_sha" '
  if .channel != "beta"
    or .beta.contract != "issue-36-beta-prerelease" then
    error("manifest is not the issue #36 Beta prerelease contract")
  elif .publication.githubPrereleaseOnly != true
    or .publication.objectStoragePublished != false
    or .publication.githubLatestAdvanced != false
    or .publication.sharedLatestAdvanced != false then
    error("Beta publication policy is not GitHub-prerelease-only")
  elif .sources.windows.productId != "9N8CJ4W95TBZ"
    or .sources.windows.packageIdentity != "OpenAI.CodexBeta" then
    error("Windows Beta Store identity contract mismatch")
  elif .sources.windows.version != $expectedWindowsVersion then
    error("Windows Beta package version does not match the frozen input")
  elif $win[0].channel != "beta"
    or $win[0].expectedIdentity != "OpenAI.CodexBeta"
    or $win[0].expectedExecutable != "app/ChatGPT (Beta).exe" then
    error("Windows Beta identity gate metadata is incomplete")
  elif $win[0].architectures.x64.packageVersion != $expectedWindowsVersion
    or $win[0].architectures.arm64.packageVersion != $expectedWindowsVersion then
    error("verified MSIX package version drift")
  elif $win[0].architectures.x64.applicationArchivePath != "app/ChatGPT%20%28Beta%29.exe"
    or $win[0].architectures.arm64.applicationArchivePath != "app/ChatGPT%20%28Beta%29.exe" then
    error("verified MSIX archive entrypoint drift")
  elif $mac[0].versionsMatch != true
    or $mac[0].commonShortVersion != $expectedMacosVersion then
    error("verified macOS Beta package version drift")
  elif $mac[0].macos.arm64.bundleIdentifier != "com.openai.codex.beta"
    or $mac[0].macos.x64.bundleIdentifier != "com.openai.codex.beta"
    or $mac[0].macos.arm64.sparkleArchiveBundleIdentifier != "com.openai.codex.beta"
    or $mac[0].macos.x64.sparkleArchiveBundleIdentifier != "com.openai.codex.beta" then
    error("macOS Beta bundle identity contract mismatch")
  elif $mac[0].macos.arm64.teamIdentifier != "2DC432GLL2"
    or $mac[0].macos.x64.teamIdentifier != "2DC432GLL2"
    or $mac[0].macos.arm64.sparkleArchiveTeamIdentifier != "2DC432GLL2"
    or $mac[0].macos.x64.sparkleArchiveTeamIdentifier != "2DC432GLL2" then
    error("macOS Beta signing team contract mismatch")
  elif $mac[0].macos.arm64.sparklePublicEdKey != "mNfr1v9t63BfgDtlw4C8lRvSY6uMggIXABDOCi3tS6k="
    or $mac[0].macos.x64.sparklePublicEdKey != "mNfr1v9t63BfgDtlw4C8lRvSY6uMggIXABDOCi3tS6k="
    or $mac[0].macos.arm64.sparkleArchivePublicEdKey != "mNfr1v9t63BfgDtlw4C8lRvSY6uMggIXABDOCi3tS6k="
    or $mac[0].macos.x64.sparkleArchivePublicEdKey != "mNfr1v9t63BfgDtlw4C8lRvSY6uMggIXABDOCi3tS6k=" then
    error("macOS Beta Sparkle public key contract mismatch")
  elif $mac[0].macos.arm64.sparkleArchiveIdentityVerified != true
    or $mac[0].macos.x64.sparkleArchiveIdentityVerified != true
    or $mac[0].macos.arm64.sparkleArchiveBundleShortVersion != $expectedMacosVersion
    or $mac[0].macos.x64.sparkleArchiveBundleShortVersion != $expectedMacosVersion then
    error("macOS Beta Sparkle archive version or identity gate is incomplete")
  elif $mac[0].macos.arm64.fileName != .sources.macos.arm64.mirrorBasename
    or $mac[0].macos.x64.fileName != .sources.macos.x64.mirrorBasename
    or $mac[0].macos.arm64.sparkleArchiveFileName != .sources.macos.arm64.appcast.mirrorEnclosureBasename
    or $mac[0].macos.x64.sparkleArchiveFileName != .sources.macos.x64.appcast.mirrorEnclosureBasename then
    error("macOS Beta verified filenames do not match the frozen manifest")
  elif $mac[0].macos.arm64.sparkleArchiveBundleVersion != .sources.macos.arm64.appcast.version
    or $mac[0].macos.x64.sparkleArchiveBundleVersion != .sources.macos.x64.appcast.version then
    error("macOS Beta Sparkle archive build does not match the appcast")
  else . end
  | .sources.windows.architectures.x64 += {
      fileName: $win[0].architectures.x64.fileName,
      sha256: $win[0].architectures.x64.sha256,
      packageIdentity: $win[0].architectures.x64.packageIdentity,
      packageFamilyName: $win[0].architectures.x64.packageFamilyName,
      applicationId: $win[0].architectures.x64.applicationId,
      applicationExecutable: $win[0].architectures.x64.applicationExecutable,
      applicationArchivePath: $win[0].architectures.x64.applicationArchivePath
    }
  | .sources.windows.architectures.arm64 += {
      fileName: $win[0].architectures.arm64.fileName,
      sha256: $win[0].architectures.arm64.sha256,
      packageIdentity: $win[0].architectures.arm64.packageIdentity,
      packageFamilyName: $win[0].architectures.arm64.packageFamilyName,
      applicationId: $win[0].architectures.arm64.applicationId,
      applicationExecutable: $win[0].architectures.arm64.applicationExecutable,
      applicationArchivePath: $win[0].architectures.arm64.applicationArchivePath
    }
  | .sources.macos.arm64 += {
      sha256: $mac[0].macos.arm64.sha256,
      bundleShortVersion: $mac[0].macos.arm64.bundleShortVersion,
      bundleVersion: $mac[0].macos.arm64.bundleVersion,
      bundleIdentifier: $mac[0].macos.arm64.bundleIdentifier,
      bundleName: $mac[0].macos.arm64.bundleName,
      bundleExecutable: $mac[0].macos.arm64.bundleExecutable,
      minimumSystemVersion: $mac[0].macos.arm64.minimumSystemVersion,
      teamIdentifier: $mac[0].macos.arm64.teamIdentifier,
      sparklePublicEdKey: $mac[0].macos.arm64.sparklePublicEdKey
    }
  | .sources.macos.x64 += {
      sha256: $mac[0].macos.x64.sha256,
      bundleShortVersion: $mac[0].macos.x64.bundleShortVersion,
      bundleVersion: $mac[0].macos.x64.bundleVersion,
      bundleIdentifier: $mac[0].macos.x64.bundleIdentifier,
      bundleName: $mac[0].macos.x64.bundleName,
      bundleExecutable: $mac[0].macos.x64.bundleExecutable,
      minimumSystemVersion: $mac[0].macos.x64.minimumSystemVersion,
      teamIdentifier: $mac[0].macos.x64.teamIdentifier,
      sparklePublicEdKey: $mac[0].macos.x64.sparklePublicEdKey
    }
  | .sources.macos.arm64.appcast += {
      sha256: $macArmZipSha,
      identityVerified: $mac[0].macos.arm64.sparkleArchiveIdentityVerified,
      bundleIdentifier: $mac[0].macos.arm64.sparkleArchiveBundleIdentifier,
      teamIdentifier: $mac[0].macos.arm64.sparkleArchiveTeamIdentifier,
      sparklePublicEdKey: $mac[0].macos.arm64.sparkleArchivePublicEdKey
    }
  | .sources.macos.x64.appcast += {
      sha256: $macX64ZipSha,
      identityVerified: $mac[0].macos.x64.sparkleArchiveIdentityVerified,
      bundleIdentifier: $mac[0].macos.x64.sparkleArchiveBundleIdentifier,
      teamIdentifier: $mac[0].macos.x64.sparkleArchiveTeamIdentifier,
      sparklePublicEdKey: $mac[0].macos.x64.sparkleArchivePublicEdKey
    }
  | .derived.prerelease = true
  | .derived.publishLatest = false
  | .derived.syncLatest = false
  | .release = {
      tag: $releaseTag,
      destination: "github-prerelease",
      immutableAssets: true
    }
  ' "$manifest_path" > "$tmp_manifest"
mv "$tmp_manifest" "$manifest_path"

windows_sums="$windows_dir/SHA256SUMS-windows.txt"
macos_sums="$macos_dir/SHA256SUMS-macos.txt"
[[ -f "$windows_sums" ]] || { echo "Missing Windows checksums: $windows_sums" >&2; exit 1; }
[[ -f "$macos_sums" ]] || { echo "Missing macOS checksums: $macos_sums" >&2; exit 1; }

tr -d '\r' < "$windows_sums" > SHA256SUMS.txt
cat "$macos_sums" >> SHA256SUMS.txt

while IFS=$'\t' read -r digest file_name; do
  grep -Fqx "$digest  $file_name" SHA256SUMS.txt || {
    echo "Windows checksum metadata mismatch for $file_name" >&2
    exit 1
  }
done < <(jq -r '.architectures.x64, .architectures.arm64 | [.sha256, .fileName] | @tsv' "$windows_identity")

while IFS=$'\t' read -r digest file_name; do
  grep -Fqx "$digest  $file_name" SHA256SUMS.txt || {
    echo "macOS checksum metadata mismatch for $file_name" >&2
    exit 1
  }
done < <(jq -r '
  (.sources.macos.arm64 | [.sha256, .mirrorBasename] | @tsv),
  (.sources.macos.x64 | [.sha256, .mirrorBasename] | @tsv),
  (.sources.macos.arm64.appcast | [.sha256, .mirrorEnclosureBasename] | @tsv),
  (.sources.macos.x64.appcast | [.sha256, .mirrorEnclosureBasename] | @tsv)
' "$manifest_path")

sha256sum "$windows_identity" | awk '{print tolower($1) "  windows-identity.json"}' >> SHA256SUMS.txt
sha256sum "$macos_identity" | awk '{print tolower($1) "  macos-identity.json"}' >> SHA256SUMS.txt
sha256sum "$manifest_path" | awk '{print tolower($1) "  release-manifest.json"}' >> SHA256SUMS.txt

cat > release-notes.md <<EOF
> [!IMPORTANT]
> 这是按 #36 发布的按需 Beta 快照。所有安装资产均保留官方原始字节，只进入 GitHub prerelease；不会上传到 Cloudflare R2 或 secondary S3，也不会推进 GitHub Latest 或任何 shared \`latest/*\`。

- Windows Microsoft Store ProductId: \`9N8CJ4W95TBZ\`
- Windows package identity: \`OpenAI.CodexBeta\`
- Windows package version: \`$expected_windows_version\`
- Windows entrypoint: \`app/ChatGPT (Beta).exe\`
- macOS bundle identifier: \`com.openai.codex.beta\`
- macOS app version: \`$expected_macos_version\`
- macOS source: official \`codex-app-beta\` Sparkle feeds

This on-demand Beta snapshot is published only as a GitHub prerelease. It does not replace the Stable channel, publish to object storage, or advance any latest route.
EOF

jq -e \
  --arg windowsVersion "$expected_windows_version" \
  --arg macosVersion "$expected_macos_version" \
  --arg releaseTag "$release_tag" '
    .channel == "beta"
    and .sources.windows.version == $windowsVersion
    and .sources.windows.productId == "9N8CJ4W95TBZ"
    and .sources.windows.packageIdentity == "OpenAI.CodexBeta"
    and .sources.windows.architectures.x64.packageIdentity == "OpenAI.CodexBeta"
    and .sources.windows.architectures.arm64.packageIdentity == "OpenAI.CodexBeta"
    and .sources.windows.architectures.x64.applicationExecutable == "app/ChatGPT (Beta).exe"
    and .sources.windows.architectures.arm64.applicationExecutable == "app/ChatGPT (Beta).exe"
    and .sources.macos.arm64.bundleShortVersion == $macosVersion
    and .sources.macos.x64.bundleShortVersion == $macosVersion
    and .sources.macos.arm64.bundleIdentifier == "com.openai.codex.beta"
    and .sources.macos.x64.bundleIdentifier == "com.openai.codex.beta"
    and .derived.prerelease == true
    and .derived.publishLatest == false
    and .derived.syncLatest == false
    and .publication.githubPrereleaseOnly == true
    and .publication.githubLatestAdvanced == false
    and .publication.objectStoragePublished == false
    and .publication.sharedLatestAdvanced == false
    and .release.tag == $releaseTag
    and .release.destination == "github-prerelease"
  ' "$manifest_path" >/dev/null

echo "Finalized GitHub-only Beta prerelease $release_tag"
jq '{channel, beta, publication, derived, release, windows: .sources.windows, macos: .sources.macos}' "$manifest_path"
