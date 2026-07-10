#!/usr/bin/env bash
set -euo pipefail

manifest_path="${1:-probe-manifest.json}"
windows_identity="${2:?Windows identity metadata is required}"
artifacts_dir="${3:?artifacts directory is required}"
expected_version="${4:?expected Windows package version is required}"
public_base_url="${5:?public base URL is required}"
release_tag="${6:?release tag is required}"
candidate_prefix="releases/$release_tag"
candidate_base_url="${public_base_url%/}/$candidate_prefix"
windows_dir="$artifacts_dir/codex-windows"
tmp_manifest="$(mktemp)"

if [[ "$release_tag" != "codex-app-beta-$expected_version" ]]; then
  echo "Windows Beta release tag/version mismatch: $release_tag / $expected_version" >&2
  exit 1
fi

cleanup() {
  rm -f "$tmp_manifest"
}
trap cleanup EXIT

jq \
  --slurpfile win "$windows_identity" \
  --arg expectedVersion "$expected_version" \
  --arg releaseTag "$release_tag" \
  --arg candidatePrefix "$candidate_prefix" \
  --arg candidateBaseUrl "$candidate_base_url" '
  if .emergency.contract != "issue-36-windows-beta"
    or .emergency.channel != "beta" then
    error("manifest is not the issue #36 Windows Beta emergency contract")
  elif .sources.windows.productId != "9N8CJ4W95TBZ"
    or .sources.windows.packageIdentity != "OpenAI.CodexBeta" then
    error("Windows Beta Store identity contract mismatch")
  elif .sources.windows.version != $expectedVersion then
    error("Windows Beta package version does not match the frozen input")
  elif $win[0].channel != "beta"
    or $win[0].expectedIdentity != "OpenAI.CodexBeta"
    or $win[0].expectedExecutable != "app/ChatGPT (Beta).exe" then
    error("Windows Beta identity gate metadata is incomplete")
  elif $win[0].architectures.x64.packageVersion != $expectedVersion
    or $win[0].architectures.arm64.packageVersion != $expectedVersion then
    error("verified MSIX package version drift")
  elif $win[0].architectures.x64.applicationArchivePath != "app/ChatGPT%20%28Beta%29.exe"
    or $win[0].architectures.arm64.applicationArchivePath != "app/ChatGPT%20%28Beta%29.exe" then
    error("verified MSIX archive entrypoint drift")
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
      windowsIdentityUrl: ($candidateBaseUrl + "/latest/windows-identity.json"),
      windowsUrl: ($candidateBaseUrl + "/latest/win"),
      windowsX64Url: ($candidateBaseUrl + "/latest/win-x64"),
      windowsArm64Url: ($candidateBaseUrl + "/latest/win-arm64"),
      sharedLatestAdvanced: false,
      contract: "issue-36-windows-beta"
    }
  | .emergency.sharedLatestAdvanced = false
  ' "$manifest_path" > "$tmp_manifest"
mv "$tmp_manifest" "$manifest_path"

windows_sums="$windows_dir/SHA256SUMS-windows.txt"
[[ -f "$windows_sums" ]] || { echo "Missing Windows checksums: $windows_sums" >&2; exit 1; }
tr -d '\r' < "$windows_sums" > SHA256SUMS.txt
while IFS=$'\t' read -r digest file_name; do
  grep -Fqx "$digest  $file_name" SHA256SUMS.txt || {
    echo "Windows checksum metadata mismatch for $file_name" >&2
    exit 1
  }
done < <(jq -r '.architectures.x64, .architectures.arm64 | [.sha256, .fileName] | @tsv' "$windows_identity")
sha256sum "$windows_identity" | awk '{print tolower($1) "  windows-identity.json"}' >> SHA256SUMS.txt
sha256sum "$manifest_path" | awk '{print tolower($1) "  release-manifest.json"}' >> SHA256SUMS.txt

cat > release-notes.md <<EOF
> [!IMPORTANT]
> 这是按 #36 发布的临时 Windows Beta 候选版本。仅镜像 Microsoft Store 的官方 MSIX 原始字节；GitHub Release、R2 和 secondary S3 使用独立 Beta 版本化路径，Stable 与 shared \`latest/*\` 均未推进。

- Microsoft Store ProductId: \`9N8CJ4W95TBZ\`
- Package identity: \`OpenAI.CodexBeta\`
- Package version: \`$expected_version\`
- Entrypoint: \`app/ChatGPT (Beta).exe\`
- Candidate manifest: $candidate_base_url/latest/manifest
- Windows x64: $candidate_base_url/latest/win-x64
- Windows ARM64: $candidate_base_url/latest/win-arm64

This emergency prerelease mirrors the official Windows Beta MSIX packages for issue #36. It does not replace the Stable channel or advance shared \`latest/*\`.
EOF

jq -e \
  --arg expectedVersion "$expected_version" \
  --arg releaseTag "$release_tag" \
  --arg candidateBaseUrl "$candidate_base_url" '
    .sources.windows.version == $expectedVersion
    and .sources.windows.productId == "9N8CJ4W95TBZ"
    and .sources.windows.packageIdentity == "OpenAI.CodexBeta"
    and .sources.windows.architectures.x64.packageIdentity == "OpenAI.CodexBeta"
    and .sources.windows.architectures.arm64.packageIdentity == "OpenAI.CodexBeta"
    and .sources.windows.architectures.x64.applicationExecutable == "app/ChatGPT (Beta).exe"
    and .sources.windows.architectures.arm64.applicationExecutable == "app/ChatGPT (Beta).exe"
    and .sources.windows.architectures.x64.applicationArchivePath == "app/ChatGPT%20%28Beta%29.exe"
    and .sources.windows.architectures.arm64.applicationArchivePath == "app/ChatGPT%20%28Beta%29.exe"
    and .derived.prerelease == true
    and .derived.publishLatest == false
    and .derived.syncLatest == false
    and .candidate.releaseTag == $releaseTag
    and .candidate.baseUrl == $candidateBaseUrl
    and .candidate.sharedLatestAdvanced == false
  ' "$manifest_path" >/dev/null

echo "Finalized immutable Windows Beta candidate $release_tag at $candidate_base_url"
jq '{version: .sources.windows.version, emergency, derived, candidate, architectures: (.sources.windows.architectures | map_values({fileName, contentLength, sha256, packageIdentity, applicationId, applicationExecutable, applicationArchivePath}))}' "$manifest_path"
