#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/fixtures"
fixtures="$tmp_dir/fixtures"

write_deb_packages() {
  local architecture="$1"
  local size="$2"
  local digest="$3"
  cat > "$fixtures/Packages-$architecture" <<EOF
Package: chatgpt
Version: 26.803.81509
Architecture: $architecture
Maintainer: OpenAI <support@openai.com>
Filename: pool/main/c/chatgpt/chatgpt_26.803.81509_${architecture}.deb
Size: $size
SHA256: $digest
Homepage: https://developers.openai.com/codex/app
Description: ChatGPT by OpenAI

EOF
  gzip -c "$fixtures/Packages-$architecture" > "$fixtures/Packages-$architecture.gz"
}

write_rpm_primary() {
  local architecture="$1"
  local size="$2"
  local digest="$3"
  cat > "$fixtures/primary-$architecture.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<metadata xmlns="http://linux.duke.edu/metadata/common" packages="1">
  <package type="rpm">
    <name>chatgpt</name>
    <arch>$architecture</arch>
    <version epoch="0" ver="26.803.81509" rel="1"/>
    <checksum type="sha256" pkgid="YES">$digest</checksum>
    <size package="$size" installed="1" archive="1"/>
    <location href="chatgpt-26.803.81509-1.$architecture.rpm"/>
  </package>
</metadata>
EOF
  gzip -c "$fixtures/primary-$architecture.xml" > "$fixtures/primary-$architecture.xml.gz"
}

write_deb_packages amd64 349937362 a9bf91a368f9f7c4eea38082a9fb8fb46b8d005b719a6d7715d2e5a1982c38eb
write_deb_packages arm64 321468486 f38fcc194eca9ab0327dc10c92340681eae77c5d75164df700384ce2adaccbc1
write_rpm_primary x86_64 396388161 4d34fd4bb1122b7f2445f6a1bbc7c869cd3724c9f71aee3802795272c0b10702
write_rpm_primary aarch64 365320805 290b1f2d0f57a508df23e308a6d0d643063767b684906dfb916ce4b01ecfdac9

amd_index_sha="$(sha256sum "$fixtures/Packages-amd64.gz" | awk '{print $1}')"
arm_index_sha="$(sha256sum "$fixtures/Packages-arm64.gz" | awk '{print $1}')"
amd_index_size="$(wc -c < "$fixtures/Packages-amd64.gz" | tr -d '[:space:]')"
arm_index_size="$(wc -c < "$fixtures/Packages-arm64.gz" | tr -d '[:space:]')"
cat > "$fixtures/InRelease" <<EOF
Codename: stable
Suite: stable
SHA256:
 $amd_index_sha $amd_index_size main/binary-amd64/Packages.gz
 $arm_index_sha $arm_index_size main/binary-arm64/Packages.gz
EOF

write_repomd() {
  local architecture="$1"
  local sha size
  sha="$(sha256sum "$fixtures/primary-$architecture.xml.gz" | awk '{print $1}')"
  size="$(wc -c < "$fixtures/primary-$architecture.xml.gz" | tr -d '[:space:]')"
  cat > "$fixtures/repomd-$architecture.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<repomd xmlns="http://linux.duke.edu/metadata/repo">
  <data type="primary">
    <checksum type="sha256">$sha</checksum>
    <location href="repodata/$sha-primary.xml.gz"/>
    <size>$size</size>
  </data>
</repomd>
EOF
  printf 'fixture signature' > "$fixtures/repomd-$architecture.xml.asc"
  cp "$fixtures/primary-$architecture.xml.gz" "$fixtures/$sha-primary.xml.gz"
}

write_repomd x86_64
write_repomd aarch64

cat > "$tmp_dir/bin/gpgv" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
output=""
input=""
while (($#)); do
  case "$1" in
    --keyring)
      shift 2
      ;;
    --output)
      output="$2"
      shift 2
      ;;
    *)
      input="$1"
      shift
      ;;
  esac
done
printf 'verified\n' >> "${GPGV_MOCK_LOG:?}"
if [[ -n "$output" ]]; then
  cp "$input" "$output"
fi
SH

cat > "$tmp_dir/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
url=""
output=""
while (($#)); do
  case "$1" in
    -o|--output)
      output="$2"
      shift 2
      ;;
    --retry|--retry-delay|--retry-max-time|--connect-timeout|--max-time)
      shift 2
      ;;
    --*)
      shift
      ;;
    https://*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "$url" && -n "$output" ]] || { echo "mock curl could not parse request" >&2; exit 1; }
case "$url" in
  */deb/dists/stable/InRelease)
    source_file="$FIXTURES/InRelease"
    ;;
  */deb/dists/stable/main/binary-amd64/Packages.gz)
    source_file="$FIXTURES/Packages-amd64.gz"
    ;;
  */deb/dists/stable/main/binary-arm64/Packages.gz)
    source_file="$FIXTURES/Packages-arm64.gz"
    ;;
  */rpm/x86_64/repodata/repomd.xml)
    source_file="$FIXTURES/repomd-x86_64.xml"
    ;;
  */rpm/aarch64/repodata/repomd.xml)
    source_file="$FIXTURES/repomd-aarch64.xml"
    ;;
  */rpm/x86_64/repodata/repomd.xml.asc)
    source_file="$FIXTURES/repomd-x86_64.xml.asc"
    ;;
  */rpm/aarch64/repodata/repomd.xml.asc)
    source_file="$FIXTURES/repomd-aarch64.xml.asc"
    ;;
  */rpm/x86_64/repodata/*-primary.xml.gz|*/rpm/aarch64/repodata/*-primary.xml.gz)
    source_file="$FIXTURES/${url##*/}"
    ;;
  *)
    echo "unexpected mock curl URL: $url" >&2
    exit 1
    ;;
esac
cp "$source_file" "$output"
if [[ "${PROBE_MOCK_TAMPER:-}" == "arm-index" && "$url" == */binary-arm64/Packages.gz ]]; then
  printf 'tamper' >> "$output"
fi
SH
chmod +x "$tmp_dir/bin/gpgv" "$tmp_dir/bin/curl"

run_probe() {
  local version="$1"
  local manifest="$2"
  env \
    PATH="$tmp_dir/bin:$PATH" \
    FIXTURES="$fixtures" \
    GPGV_MOCK_LOG="$tmp_dir/gpgv.log" \
    PROBE_MOCK_TAMPER="${PROBE_MOCK_TAMPER:-}" \
    EXPECTED_LINUX_VERSION="$version" \
    bash "$repo_root/scripts/probe-linux-preview.sh" "$manifest"
}

run_probe 26.803.81509 "$tmp_dir/manifest.json" > "$tmp_dir/probe.log"
jq -e '
  .schemaVersion == 6
  and .channel == "linux-preview"
  and .preview.expectedVersion == "26.803.81509"
  and .preview.repositorySigningKey.fingerprint == "3BFA0E4AE8B8CC16A2D9BA684A3B4A566C4660E4"
  and .sources.linux.architectures.x64.deb.packageArchitecture == "amd64"
  and .sources.linux.architectures.x64.rpm.packageArchitecture == "x86_64"
  and .sources.linux.architectures.arm64.deb.packageArchitecture == "arm64"
  and .sources.linux.architectures.arm64.rpm.packageArchitecture == "aarch64"
  and ([.sources.linux.architectures[][]] | length == 4)
  and .publication.objectStoragePublished == false
  ' "$tmp_dir/manifest.json" >/dev/null
test "$(wc -l < "$tmp_dir/gpgv.log" | tr -d '[:space:]')" = 3

set +e
version_output="$(run_probe 26.803.99999 "$tmp_dir/version-drift.json" 2>&1)"
version_status=$?
set -e
if [[ "$version_status" -eq 0 ]] || ! grep -Fq 'version drift' <<< "$version_output"; then
  echo "Expected repository version drift to fail closed." >&2
  printf '%s\n' "$version_output" >&2
  exit 1
fi

set +e
PROBE_MOCK_TAMPER=arm-index run_probe 26.803.81509 "$tmp_dir/tampered.json" > "$tmp_dir/tampered.log" 2>&1
tamper_status=$?
set -e
if [[ "$tamper_status" -eq 0 ]] || ! grep -Fq 'size mismatch' "$tmp_dir/tampered.log"; then
  echo "Expected tampered Debian metadata to fail closed." >&2
  cat "$tmp_dir/tampered.log" >&2
  exit 1
fi

echo "Linux Preview signed repository probe fixture PASS"
