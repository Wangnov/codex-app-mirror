#!/usr/bin/env bash
set -euo pipefail

# Regression test for the win+mac release coupling fix.
#
# Scenario: the Microsoft Store advertises a newer Windows build than is actually
# downloadable yet (updateManifest.buildVersion 26.609.4994.0 vs the resolved,
# downloadable Store package 26.608.1337.0), while macOS has already advanced to
# 26.609.41114 on persistent.oaistatic.com. The previous behavior vetoed the
# whole release ("waiting for downloadable MSIX"), which also blocked the
# already-downloadable macOS update. probe-release.sh must now release (the
# combined manifest carries the current downloadable Windows 26.608 plus macOS
# 26.609) instead of holding mac hostage to the Windows Store rollout.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_dir/bin"

latest_tag="codex-app-26.608.12217"
# win (downloadable 26.608) + mac (advanced 26.609) should still release.
# The exact canonical tag is derived later after the Windows MSIX is downloaded
# and its internal Codex version can be read.
package="OpenAI.Codex_26.608.1337.0_x64__2p2nqsd0c76g0"
gh_log="$tmp_dir/gh.log"
: > "$gh_log"

# The latest release still mirrors win 26.608 + mac 26.608.12217 (build 3722).
cat > "$tmp_dir/latest-release-manifest.json" <<JSON
{
  "schemaVersion": 1,
  "sources": {
    "windows": {
      "version": "26.608.1337.0",
      "packageMoniker": "$package",
      "contentLength": 3
    },
    "macos": {
      "arm64": {
        "appcast": {
          "title": "26.608.12217",
          "pubDate": "Tue, 09 Jun 2026 21:26:49 +0000",
          "version": "3722",
          "shortVersionString": "26.608.12217",
          "minimumSystemVersion": "12.0",
          "hardwareRequirements": "arm64",
          "enclosureUrl": "https://persistent.oaistatic.com/codex-app-prod/Codex-darwin-arm64-26.608.12217.zip",
          "sourceBasename": "Codex-darwin-arm64-26.608.12217.zip",
          "mirrorEnclosureBasename": "Codex-darwin-arm64-26.608.12217.zip",
          "enclosureLength": 3,
          "enclosureSignature": "arm-signature-608",
          "deltas": []
        },
        "contentLength": 3,
        "lastModified": "Tue, 09 Jun 2026 21:51:54 GMT",
        "etag": "arm-etag-608"
      },
      "x64": {
        "appcast": {
          "title": "26.608.12217",
          "pubDate": "Tue, 09 Jun 2026 21:26:53 +0000",
          "version": "3722",
          "shortVersionString": "26.608.12217",
          "minimumSystemVersion": "12.0",
          "hardwareRequirements": "",
          "enclosureUrl": "https://persistent.oaistatic.com/codex-app-prod/Codex-darwin-x64-26.608.12217.zip",
          "sourceBasename": "Codex-darwin-x64-26.608.12217.zip",
          "mirrorEnclosureBasename": "Codex-darwin-x64-26.608.12217.zip",
          "enclosureLength": 3,
          "enclosureSignature": "x64-signature-608",
          "deltas": []
        },
        "contentLength": 3,
        "lastModified": "Tue, 09 Jun 2026 21:50:56 GMT",
        "etag": "x64-etag-608"
      }
    }
  }
}
JSON

# Store resolver: the downloadable Store package is still 26.608.1337.0.
cat > "$tmp_dir/bin/dotnet" <<'DOTNET'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "run" ]]; then
  if [[ "${!#}" != "OpenAI.Codex" ]]; then
    echo "store-link did not receive the exact Stable package identity: $*" >&2
    exit 1
  fi
  if [[ "$*" == *" arm64 OpenAI.Codex" ]]; then
    echo "No matching package found for 9PLM9XGG6VKS / OpenAI.Codex / arm64." >&2
    exit 1
  fi
  printf 'OpenAI.Codex_26.608.1337.0_x64__2p2nqsd0c76g0\thttps://download.example/OpenAI.Codex_26.608.1337.0_x64__2p2nqsd0c76g0.Msix\n'
  exit 0
fi

echo "unexpected dotnet invocation: $*" >&2
exit 1
DOTNET
chmod +x "$tmp_dir/bin/dotnet"

cat > "$tmp_dir/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${TEST_GH_LOG:?TEST_GH_LOG must be set}"

if [[ "${1:-}" != "api" ]]; then
  echo "unexpected gh invocation: $*" >&2
  exit 1
fi

shift
url="${*: -1}"

case "$url" in
  repos/\{owner\}/\{repo\}/releases/latest)
    printf '{"tag_name":"%s"}\n' "${TEST_LATEST_TAG:?TEST_LATEST_TAG must be set}"
    ;;
  repos/\{owner\}/\{repo\}/releases/tags/"${TEST_LATEST_TAG}")
    printf '{"tag_name":"%s","assets":[{"name":"release-manifest.json","url":"https://api.example/assets/release-manifest"},{"name":"SHA256SUMS.txt","url":"https://api.example/assets/checksums"}]}\n' "$TEST_LATEST_TAG"
    ;;
  https://api.example/assets/release-manifest)
    cat "${TEST_LATEST_MANIFEST:?TEST_LATEST_MANIFEST must be set}"
    ;;
  *)
    echo "unexpected gh api URL: $url" >&2
    exit 1
    ;;
esac
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
  printf 'HTTP/2 200\r\n'
  printf 'content-range: bytes 0-0/3\r\n'
  printf 'content-length: 3\r\n'
  printf 'last-modified: Fri, 12 Jun 2026 22:15:02 GMT\r\n'
  printf 'etag: %s\r\n' "$1"
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
      <title>26.609.41114</title>
      <pubDate>Fri, 12 Jun 2026 22:15:02 +0000</pubDate>
      <sparkle:version>3888</sparkle:version>
      <sparkle:shortVersionString>26.609.41114</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>${hardware}</sparkle:hardwareRequirements>
      <enclosure url="https://persistent.oaistatic.com/codex-app-prod/Codex-darwin-${arch}-26.609.41114.zip" length="999" type="application/octet-stream" sparkle:edSignature="${sig}" />
    </item>
  </channel>
</rss>
XML
}

if $head_request; then
  case "$url" in
    *OpenAI.Codex_26.608.1337.0_x64__2p2nqsd0c76g0.Msix) emit_headers "windows-etag-608" ;;
    *Codex-26.609.41114-arm64.dmg) emit_headers "arm-etag-609" ;;
    *Codex-26.609.41114-x64.dmg) emit_headers "x64-etag-609" ;;
    *Codex-darwin-arm64-26.609.41114.zip|*Codex-darwin-x64-26.609.41114.zip) emit_headers "zip-etag-609" ;;
    *) echo "unexpected curl headers URL: $url" >&2; exit 1 ;;
  esac
  exit 0
fi

if [[ -n "$headers_file" ]]; then
  case "$url" in
    *Codex-darwin-arm64-26.609.41114.zip|*Codex-darwin-x64-26.609.41114.zip) emit_headers "zip-etag-609" > "$headers_file" ;;
    *) echo "unexpected curl range URL: $url" >&2; exit 1 ;;
  esac
  exit 0
fi

case "$url" in
  *displaycatalog.mp.microsoft.com/v7.0/products/9PLM9XGG6VKS*)
    cat <<'JSON'
{"Product":{"DisplaySkuAvailabilities":[{"Sku":{"Properties":{"Packages":[
{"PackageFamilyName":"OpenAI.Codex_2p2nqsd0c76g0","PackageFullName":"OpenAI.Codex_26.608.1337.0_x64__2p2nqsd0c76g0","Architectures":["x64"],"PackageId":"x64-package-id","ContentId":"content-id","MaxDownloadSizeInBytes":3,"HashAlgorithm":"SHA256","Hash":"x64hash"},
{"PackageFamilyName":"OpenAI.Codex_2p2nqsd0c76g0","PackageFullName":"OpenAI.Codex_26.609.4994.0_arm64__2p2nqsd0c76g0","Architectures":["arm64"],"PackageId":"arm64-package-id","ContentId":"content-id","MaxDownloadSizeInBytes":4,"HashAlgorithm":"SHA256","Hash":"arm64hash"}
]}}}]}}
JSON
    ;;
  *windows-store-update.json)
    # Advertised build (26.609.4994.0) is AHEAD of the downloadable package (608).
    printf '{"buildVersion":"26.609.4994.0","storeProductId":"9PLM9XGG6VKS","packageIdentity":"OpenAI.Codex"}\n'
    ;;
  *appcast-x64.xml)
    emit_appcast x64 x64-signature-609 ""
    ;;
  *appcast.xml)
    emit_appcast arm64 arm-signature-609 arm64
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
  TEST_GH_LOG="$gh_log" \
  TEST_LATEST_TAG="$latest_tag" \
  TEST_LATEST_MANIFEST="$tmp_dir/latest-release-manifest.json" \
  STORE_LINK_MAX_ATTEMPTS=1 \
  MANIFEST_PATH="$tmp_dir/probe-manifest.json" \
    scripts/probe-release.sh > "$tmp_dir/output.txt"
)

# macOS advanced to 26.609 -> the combined release must go out even though the
# Windows Store still only serves the 26.608 MSIX.
grep -F "should_release=true" "$tmp_dir/output.txt"

if grep -F "should_release=false" "$tmp_dir/output.txt"; then
  echo "Windows Store rollout vetoed a macOS update that was already downloadable." >&2
  cat "$tmp_dir/output.txt" >&2
  exit 1
fi

# The generated manifest must carry the DOWNLOADABLE Windows version (26.608),
# never the advertised-but-undownloadable 26.609.4994.0.
manifest_windows_version="$(jq -r '.sources.windows.version' "$tmp_dir/probe-manifest.json")"
if [[ "$manifest_windows_version" != "26.608.1337.0" ]]; then
  echo "Expected manifest windows.version 26.608.1337.0, got '$manifest_windows_version'." >&2
  exit 1
fi
manifest_arm64_status="$(jq -r '.sources.windows.architectures.arm64.status' "$tmp_dir/probe-manifest.json")"
if [[ "$manifest_arm64_status" != "catalog-only" ]]; then
  echo "Expected manifest Windows arm64 status catalog-only, got '$manifest_arm64_status'." >&2
  exit 1
fi

manifest_mac_version="$(jq -r '.sources.macos.arm64.appcast.shortVersionString' "$tmp_dir/probe-manifest.json")"
if [[ "$manifest_mac_version" != "26.609.41114" ]]; then
  echo "Expected manifest macOS arm64 shortVersionString 26.609.41114, got '$manifest_mac_version'." >&2
  exit 1
fi

manifest_arm_zip_length="$(jq -r '.sources.macos.arm64.appcast.enclosureLength' "$tmp_dir/probe-manifest.json")"
manifest_x64_zip_length="$(jq -r '.sources.macos.x64.appcast.enclosureLength' "$tmp_dir/probe-manifest.json")"
if [[ "$manifest_arm_zip_length" != "3" || "$manifest_x64_zip_length" != "3" ]]; then
  echo "Expected manifest Sparkle archive lengths to use source object sizes, got arm64='$manifest_arm_zip_length' x64='$manifest_x64_zip_length'." >&2
  exit 1
fi

echo "probe-release windows-rollout test PASS"
