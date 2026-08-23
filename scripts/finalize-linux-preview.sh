#!/usr/bin/env bash
set -euo pipefail

manifest_path="${1:-probe-manifest.json}"
identity_path="${2:?Linux identity metadata is required}"
artifacts_dir="${3:?Linux artifacts directory is required}"
expected_version="${4:?Expected Linux Preview version is required}"
release_tag="${5:?Linux Preview release tag is required}"
expected_release_tag="codex-app-linux-preview-$expected_version"

if [[ "$release_tag" != "$expected_release_tag" ]]; then
  echo "Linux Preview release tag/version mismatch: expected $expected_release_tag, got $release_tag" >&2
  exit 1
fi

for command in jq sha256sum; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Missing required command: $command" >&2
    exit 1
  }
done

[[ -f "$manifest_path" ]] || { echo "Missing Linux Preview manifest: $manifest_path" >&2; exit 1; }
[[ -f "$identity_path" ]] || { echo "Missing Linux Preview identity metadata: $identity_path" >&2; exit 1; }
[[ -d "$artifacts_dir" ]] || { echo "Missing Linux Preview artifacts directory: $artifacts_dir" >&2; exit 1; }

tmp_manifest="$(mktemp)"
tmp_expected_sums="$(mktemp)"
cleanup() {
  rm -f "$tmp_manifest" "$tmp_expected_sums"
}
trap cleanup EXIT

jq \
  --slurpfile identity "$identity_path" \
  --arg expectedVersion "$expected_version" \
  --arg releaseTag "$release_tag" '
  if .schemaVersion != 6
    or .channel != "linux-preview"
    or .preview.contract != "linux-preview-v1"
    or .preview.expectedVersion != $expectedVersion then
    error("manifest is not the requested Linux Preview contract")
  elif .publication.githubPrereleaseOnly != true
    or .publication.objectStoragePublished != false
    or .publication.githubLatestAdvanced != false
    or .publication.sharedLatestAdvanced != false then
    error("Linux Preview publication policy is not GitHub-prerelease-only")
  elif $identity[0].channel != "linux-preview"
    or $identity[0].expectedPackageName != "chatgpt"
    or $identity[0].expectedVersion != $expectedVersion
    or $identity[0].versionsMatch != true
    or $identity[0].repositorySigningKeyFingerprint != .preview.repositorySigningKey.fingerprint then
    error("Linux Preview identity gate metadata is incomplete")
  elif ([$identity[0].packages[][]] | length) != 4 then
    error("Linux Preview identity gate did not verify four packages")
  else . end
  | reduce (["x64", "arm64"][] as $architecture
      | ["deb", "rpm"][] as $format
      | {architecture: $architecture, format: $format}) as $item (.;
      ($identity[0].packages[$item.architecture][$item.format]) as $verified
      | (.sources.linux.architectures[$item.architecture][$item.format]) as $source
      | if $verified.fileName != $source.mirrorBasename
          or $verified.sha256 != $source.sha256
          or $verified.packageName != "chatgpt"
          or $verified.version != $expectedVersion
          or $verified.packageArchitecture != $source.packageArchitecture
          or $verified.repositoryMetadataSignatureVerified != true
          or $verified.packageChecksumVerified != true
          or $verified.embeddedRepositoryKeyVerified != true
          or ($item.format == "rpm" and $verified.packageSignatureVerified != true)
        then error("Linux Preview verified package identity differs from frozen source metadata")
        else
          .sources.linux.architectures[$item.architecture][$item.format] += {
            verified: true,
            repositoryMetadataSignatureVerified: $verified.repositoryMetadataSignatureVerified,
            packageChecksumVerified: $verified.packageChecksumVerified,
            embeddedRepositoryKeyVerified: $verified.embeddedRepositoryKeyVerified,
            packageSignatureVerified: $verified.packageSignatureVerified,
            repositorySigningKeyFingerprint: $verified.repositorySigningKeyFingerprint
          }
        end
    )
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

while IFS=$'\t' read -r expected_sha file_name; do
  file="$artifacts_dir/$file_name"
  [[ -f "$file" ]] || { echo "Missing Linux Preview release asset: $file" >&2; exit 1; }
  actual_sha="$(sha256sum "$file" | awk '{print tolower($1)}')"
  [[ "$actual_sha" == "$expected_sha" ]] || {
    echo "Linux Preview release asset checksum drift for $file_name" >&2
    exit 1
  }
  printf '%s  %s\n' "$actual_sha" "$file_name" >> "$tmp_expected_sums"
done < <(
  jq -r '
    .sources.linux.architectures[][]
    | [.sha256, .mirrorBasename]
    | @tsv
    ' "$manifest_path"
)
sort -k2 "$tmp_expected_sums" -o "$tmp_expected_sums"

linux_sums="$artifacts_dir/SHA256SUMS-linux.txt"
[[ -f "$linux_sums" ]] || { echo "Missing Linux checksums: $linux_sums" >&2; exit 1; }
if ! cmp "$tmp_expected_sums" "$linux_sums" >/dev/null 2>&1; then
  echo "Linux package checksums do not match the frozen manifest." >&2
  diff -u "$tmp_expected_sums" "$linux_sums" >&2 || true
  exit 1
fi

cp "$linux_sums" SHA256SUMS.txt
{
  sha256sum "$identity_path" | awk '{print tolower($1) "  linux-identity.json"}'
  sha256sum "$manifest_path" | awk '{print tolower($1) "  release-manifest.json"}'
  sha256sum "$linux_sums" | awk '{print tolower($1) "  SHA256SUMS-linux.txt"}'
} >> SHA256SUMS.txt

cat > release-notes.md <<EOF
# ChatGPT desktop app for Linux Preview $expected_version

> 这是 OpenAI 官方 Linux Preview 的按需、原字节快照。它只发布为 GitHub prerelease，不会上传到 Cloudflare R2 或 secondary S3，也不会推进 GitHub Latest 或任何共享的 \`latest/*\` 路径。

## 支持范围

- Ubuntu 24.04 LTS / 26.04 LTS、Debian 13：x64 与 ARM64 \`.deb\`
- Fedora 43 / 44：x64 与 ARM64 \`.rpm\`
- 应用身份：\`chatgpt\` ${expected_version}（统一桌面应用，包含 ChatGPT、ChatGPT Work 与 Codex）

## 完整性与来源验证

- APT \`InRelease\` 与 RPM \`repomd.xml\` 均使用固定指纹 \`3BFA0E4AE8B8CC16A2D9BA684A3B4A566C4660E4\` 验签。
- 四个包的版本、架构、包名、仓库 SHA-256 与文件清单均已校验。
- 两个 RPM 还通过固定公钥完成包签名验证；DEB 没有独立包签名，依赖已签名的 APT 元数据和固定 SHA-256。
- 安装包按 OpenAI 官方仓库原字节发布，没有重打包或修改。

注意：官方安装包会配置 OpenAI 自己的 APT/RPM 更新仓库；后续自动更新默认直接从 OpenAI 获取，不经过本镜像。

Official announcement: https://x.com/OpenAI/status/2087248033906094175

Official Linux Preview snapshot. GitHub prerelease only; no object-storage publication and no latest-channel promotion.
EOF

jq -e --arg version "$expected_version" --arg tag "$release_tag" '
  .schemaVersion == 6
  and .channel == "linux-preview"
  and .preview.expectedVersion == $version
  and .publication.githubPrereleaseOnly == true
  and .publication.objectStoragePublished == false
  and .publication.githubLatestAdvanced == false
  and .publication.sharedLatestAdvanced == false
  and .derived.prerelease == true
  and .derived.publishLatest == false
  and .derived.syncLatest == false
  and .release.tag == $tag
  and .release.destination == "github-prerelease"
  and .release.immutableAssets == true
  and ([.sources.linux.architectures[][] | .verified == true] | all)
  ' "$manifest_path" >/dev/null

echo "Finalized GitHub-only Linux Preview prerelease $release_tag"
jq '{channel, preview, publication, derived, release, linux: .sources.linux}' "$manifest_path"
