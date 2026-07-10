#!/usr/bin/env bash
set -euo pipefail

# Regression test for Microsoft Store rollback snapshots.
#
# Scenario: DisplayCatalog and the OpenAI update manifest both advertise the new
# Windows x64 package, but FE3 still returns an older downloadable package. The
# probe must not treat that older FE3 link as a releasable source, because a later
# download step would either fail the package-moniker guard or, worse, publish a
# rollback snapshot if the guard were relaxed.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_dir/bin"

old_package="OpenAI.Codex_26.623.13972.0_x64__2p2nqsd0c76g0"
new_x64_package="OpenAI.Codex_26.623.19656.0_x64__2p2nqsd0c76g0"
new_arm64_package="OpenAI.Codex_26.623.19656.0_arm64__2p2nqsd0c76g0"
ahead_x64_package="OpenAI.Codex_26.624.100.0_x64__2p2nqsd0c76g0"

cat > "$tmp_dir/bin/dotnet" <<'DOTNET'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "run" ]]; then
  if [[ "${!#}" != "OpenAI.Codex" ]]; then
    echo "store-link did not receive the exact Stable package identity: $*" >&2
    exit 1
  fi
  case "$*" in
    *" arm64 OpenAI.Codex")
      printf '%s\thttps://download.example/%s.Msix\n' \
        "${TEST_NEW_ARM64_PACKAGE:?TEST_NEW_ARM64_PACKAGE must be set}" \
        "$TEST_NEW_ARM64_PACKAGE"
      ;;
    *)
      package="${TEST_OLD_PACKAGE:?TEST_OLD_PACKAGE must be set}"
      if [[ -n "${TEST_X64_COUNTER:-}" ]]; then
        count="$(cat "$TEST_X64_COUNTER")"
        count=$((count + 1))
        printf '%s' "$count" > "$TEST_X64_COUNTER"
        if ((count >= ${TEST_X64_NEW_ON_ATTEMPT:?TEST_X64_NEW_ON_ATTEMPT must be set})); then
          package="${TEST_NEW_X64_PACKAGE:?TEST_NEW_X64_PACKAGE must be set}"
        fi
      fi
      printf '%s\thttps://download.example/%s.Msix\n' "$package" "$package"
      ;;
  esac
  exit 0
fi

echo "unexpected dotnet invocation: $*" >&2
exit 1
DOTNET
chmod +x "$tmp_dir/bin/dotnet"

cat > "$tmp_dir/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail

echo "gh should not be called when the Windows x64 FE3 snapshot is stale: $*" >&2
exit 1
GH
chmod +x "$tmp_dir/bin/gh"

cat > "$tmp_dir/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail

head_request=false
headers_file=""
url=""
while (($#)); do
  case "$1" in
    -D)
      headers_file="$2"
      shift
      ;;
    -o)
      shift
      ;;
    --range)
      shift
      ;;
    -I|-*I*)
      head_request=true
      ;;
    http://*|https://*)
      url="$1"
      ;;
  esac
  shift
done

emit_headers() {
  local etag="$1"
  local size="$2"

  printf 'HTTP/2 200\r\n'
  printf 'content-range: bytes 0-0/%s\r\n' "$size"
  printf 'content-length: %s\r\n' "$size"
  printf 'last-modified: Tue, 07 Jul 2026 00:35:59 GMT\r\n'
  printf 'etag: %s\r\n' "$etag"
  printf '\r\n'
}

emit_appcast() {
  local arch="$1"
  local sig="$2"
  local hardware="$3"

  cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <item>
      <title>26.623.141536</title>
      <pubDate>Tue, 07 Jul 2026 00:35:59 +0000</pubDate>
      <sparkle:version>4753</sparkle:version>
      <sparkle:shortVersionString>26.623.141536</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>${hardware}</sparkle:hardwareRequirements>
      <enclosure url="https://persistent.oaistatic.com/codex-app-prod/Codex-darwin-${arch}-26.623.141536.zip" length="9" type="application/octet-stream" sparkle:edSignature="${sig}" />
    </item>
  </channel>
</rss>
XML
}

if $head_request; then
  case "$url" in
    *OpenAI.Codex_26.623.13972.0_x64__2p2nqsd0c76g0.Msix) emit_headers "old-windows-etag" 3 ;;
    *OpenAI.Codex_26.623.19656.0_x64__2p2nqsd0c76g0.Msix) emit_headers "new-windows-etag" 4 ;;
    *OpenAI.Codex_26.624.100.0_x64__2p2nqsd0c76g0.Msix) emit_headers "ahead-windows-etag" 10 ;;
    *OpenAI.Codex_26.623.19656.0_arm64__2p2nqsd0c76g0.Msix) emit_headers "new-arm64-etag" 4 ;;
    *Codex-26.623.141536-arm64.dmg) emit_headers "arm-dmg-etag" 5 ;;
    *Codex-26.623.141536-x64.dmg) emit_headers "x64-dmg-etag" 6 ;;
    *) echo "unexpected curl headers URL: $url" >&2; exit 1 ;;
  esac
  exit 0
fi

if [[ -n "$headers_file" ]]; then
  case "$url" in
    *Codex-darwin-arm64-26.623.141536.zip) emit_headers "arm-zip-etag" 7 > "$headers_file" ;;
    *Codex-darwin-x64-26.623.141536.zip) emit_headers "x64-zip-etag" 8 > "$headers_file" ;;
    *) echo "unexpected curl range URL: $url" >&2; exit 1 ;;
  esac
  exit 0
fi

case "$url" in
  *displaycatalog.mp.microsoft.com/v7.0/products/9PLM9XGG6VKS*)
    cat <<JSON
{"Product":{"DisplaySkuAvailabilities":[{"Sku":{"Properties":{"Packages":[
{"PackageFamilyName":"OpenAI.Codex_2p2nqsd0c76g0","PackageFullName":"${TEST_NEW_X64_PACKAGE:?TEST_NEW_X64_PACKAGE must be set}","Architectures":["x64"],"PackageId":"x64-package-id","ContentId":"content-id","MaxDownloadSizeInBytes":671019430,"HashAlgorithm":"SHA256","Hash":"x64hash"},
{"PackageFamilyName":"OpenAI.Codex_2p2nqsd0c76g0","PackageFullName":"${TEST_NEW_ARM64_PACKAGE:?TEST_NEW_ARM64_PACKAGE must be set}","Architectures":["arm64"],"PackageId":"arm64-package-id","ContentId":"content-id","MaxDownloadSizeInBytes":670125154,"HashAlgorithm":"SHA256","Hash":"arm64hash"}
]}}}]}}
JSON
    ;;
  *windows-store-update.json)
    printf '{"buildVersion":"26.623.19656.0","storeProductId":"9PLM9XGG6VKS","packageIdentity":"OpenAI.Codex"}\n'
    ;;
  *appcast-x64.xml)
    emit_appcast x64 x64-signature ""
    ;;
  *appcast.xml)
    emit_appcast arm64 arm-signature arm64
    ;;
  *)
    echo "unexpected curl URL: $url" >&2
    exit 1
    ;;
esac
CURL
chmod +x "$tmp_dir/bin/curl"

(
  cd "$repo_root"
  PATH="$tmp_dir/bin:$PATH" \
  TEST_OLD_PACKAGE="$old_package" \
  TEST_NEW_X64_PACKAGE="$new_x64_package" \
  TEST_NEW_ARM64_PACKAGE="$new_arm64_package" \
  STORE_LINK_MAX_ATTEMPTS=1 \
  STORE_LINK_STABILITY_MAX_ATTEMPTS=1 \
  STORE_LINK_STABILITY_RETRY_DELAY_SECONDS=0 \
  MANIFEST_PATH="$tmp_dir/probe-manifest.json" \
    scripts/probe-release.sh > "$tmp_dir/output.txt"
)

grep -F "should_release=false" "$tmp_dir/output.txt"
grep -F "Windows x64 DisplayCatalog/update manifest advertise $new_x64_package, but FE3 returned $old_package. Waiting for a consistent downloadable MSIX." "$tmp_dir/output.txt"

manifest_windows_package="$(jq -r '.sources.windows.architectures.x64.packageMoniker' "$tmp_dir/probe-manifest.json")"
if [[ "$manifest_windows_package" != "$old_package" ]]; then
  echo "Expected manifest to preserve observed FE3 package for diagnostics, got '$manifest_windows_package'." >&2
  exit 1
fi

counter_path="$tmp_dir/x64-counter"
printf '0' > "$counter_path"
(
  cd "$repo_root"
  PATH="$tmp_dir/bin:$PATH" \
  TEST_OLD_PACKAGE="$old_package" \
  TEST_NEW_X64_PACKAGE="$new_x64_package" \
  TEST_NEW_ARM64_PACKAGE="$new_arm64_package" \
  TEST_X64_COUNTER="$counter_path" \
  TEST_X64_NEW_ON_ATTEMPT=2 \
  STORE_LINK_MAX_ATTEMPTS=1 \
  STORE_LINK_STABILITY_MAX_ATTEMPTS=2 \
  STORE_LINK_STABILITY_RETRY_DELAY_SECONDS=0 \
  FORCE_RELEASE=true \
  MANIFEST_PATH="$tmp_dir/probe-manifest-retry.json" \
    scripts/probe-release.sh > "$tmp_dir/output-retry.txt"
)

grep -F "should_release=true" "$tmp_dir/output-retry.txt"
retry_manifest_windows_package="$(jq -r '.sources.windows.architectures.x64.packageMoniker' "$tmp_dir/probe-manifest-retry.json")"
if [[ "$retry_manifest_windows_package" != "$new_x64_package" ]]; then
  echo "Expected re-probe to converge on $new_x64_package, got '$retry_manifest_windows_package'." >&2
  exit 1
fi
if [[ "$(cat "$counter_path")" != "2" ]]; then
  echo "Expected x64 store link to be resolved twice, got '$(cat "$counter_path")'." >&2
  exit 1
fi

(
  cd "$repo_root"
  PATH="$tmp_dir/bin:$PATH" \
  TEST_OLD_PACKAGE="$ahead_x64_package" \
  TEST_NEW_X64_PACKAGE="$new_x64_package" \
  TEST_NEW_ARM64_PACKAGE="$new_arm64_package" \
  STORE_LINK_MAX_ATTEMPTS=1 \
  STORE_LINK_STABILITY_MAX_ATTEMPTS=1 \
  STORE_LINK_STABILITY_RETRY_DELAY_SECONDS=0 \
  FORCE_RELEASE=true \
  MANIFEST_PATH="$tmp_dir/probe-manifest-ahead.json" \
    scripts/probe-release.sh > "$tmp_dir/output-ahead.txt"
)

grep -F "should_release=true" "$tmp_dir/output-ahead.txt"
if grep -F "Waiting for a consistent downloadable MSIX." "$tmp_dir/output-ahead.txt"; then
  echo "FE3 returned a newer package than DisplayCatalog/update manifest, but probe treated it as stale." >&2
  cat "$tmp_dir/output-ahead.txt" >&2
  exit 1
fi
ahead_manifest_windows_package="$(jq -r '.sources.windows.architectures.x64.packageMoniker' "$tmp_dir/probe-manifest-ahead.json")"
if [[ "$ahead_manifest_windows_package" != "$ahead_x64_package" ]]; then
  echo "Expected FE3-ahead manifest to keep $ahead_x64_package, got '$ahead_manifest_windows_package'." >&2
  exit 1
fi

echo "probe-release stale-FE3 fixture test PASS"
