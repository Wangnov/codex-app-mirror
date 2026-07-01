#!/usr/bin/env bash
set -euo pipefail

# Regression test: after a partial release preserves the old Windows ARM64
# latest alias, the next probe must not republish the same x64/mac sources just
# because the live latest manifest intentionally differs from the current ARM64
# catalog-only state.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_dir/bin"

latest_tag="codex-app-1.2.3"
package="OpenAI.Codex_1.2.3.4_x64__2p2nqsd0c76g0"
current_arm64_package="OpenAI.Codex_1.2.3.4_arm64__2p2nqsd0c76g0"
preserved_arm64_package="OpenAI.Codex_1.2.2.4_arm64__2p2nqsd0c76g0"
gh_log="$tmp_dir/gh.log"
: > "$gh_log"

cat > "$tmp_dir/latest-release-manifest.json" <<JSON
{
  "schemaVersion": 4,
  "sources": {
    "windows": {
      "version": "1.2.3.4",
      "packageMoniker": "$package",
      "contentLength": 3,
      "architectures": {
        "x64": {
          "architecture": "x64",
          "status": "downloadable",
          "downloadable": true,
          "version": "1.2.3.4",
          "packageMoniker": "$package",
          "contentLength": 3,
          "catalog": {
            "packageFullName": "$package",
            "packageId": "x64-package-id",
            "contentId": "content-id",
            "packageFamilyName": "OpenAI.Codex_2p2nqsd0c76g0",
            "hashAlgorithm": "SHA256",
            "hash": "x64hash",
            "contentLength": 3
          }
        },
        "arm64": {
          "architecture": "arm64",
          "status": "downloadable",
          "downloadable": true,
          "version": "1.2.2.4",
          "packageMoniker": "$preserved_arm64_package",
          "contentLength": 3,
          "currentForCodexVersion": false,
          "currentLocalArtifact": false,
          "preservedFromLatest": true,
          "catalog": {
            "packageFullName": "$preserved_arm64_package",
            "packageId": "old-arm64-package-id",
            "contentId": "old-content-id",
            "packageFamilyName": "OpenAI.Codex_2p2nqsd0c76g0",
            "hashAlgorithm": "SHA256",
            "hash": "oldarm64hash",
            "contentLength": 3
          }
        }
      }
    },
    "macos": {
      "arm64": {
        "appcast": {
          "title": "1.2.3",
          "pubDate": "Thu, 11 Jun 2026 00:00:00 +0000",
          "version": "5",
          "shortVersionString": "1.2.3",
          "minimumSystemVersion": "12.0",
          "hardwareRequirements": "arm64",
          "enclosureUrl": "https://persistent.oaistatic.com/codex-app-prod/Codex-darwin-arm64-1.2.3.zip",
          "enclosureLength": 3,
          "enclosureSignature": "arm-signature",
          "deltas": []
        },
        "contentLength": 3,
        "lastModified": "Thu, 11 Jun 2026 00:00:00 GMT",
        "etag": "arm-etag"
      },
      "x64": {
        "appcast": {
          "title": "1.2.3",
          "pubDate": "Thu, 11 Jun 2026 00:00:00 +0000",
          "version": "5",
          "shortVersionString": "1.2.3",
          "minimumSystemVersion": "12.0",
          "hardwareRequirements": "",
          "enclosureUrl": "https://persistent.oaistatic.com/codex-app-prod/Codex-darwin-x64-1.2.3.zip",
          "enclosureLength": 3,
          "enclosureSignature": "x64-signature",
          "deltas": []
        },
        "contentLength": 3,
        "lastModified": "Thu, 11 Jun 2026 00:00:00 GMT",
        "etag": "x64-etag"
      }
    }
  },
  "derived": {
    "latestChecksums": {
      "$package.Msix": "1111111111111111111111111111111111111111111111111111111111111111",
      "$preserved_arm64_package.Msix": "2222222222222222222222222222222222222222222222222222222222222222",
      "Codex-mac-arm64.dmg": "3333333333333333333333333333333333333333333333333333333333333333",
      "Codex-mac-x64.dmg": "4444444444444444444444444444444444444444444444444444444444444444",
      "Codex-darwin-arm64-1.2.3.zip": "5555555555555555555555555555555555555555555555555555555555555555",
      "Codex-darwin-x64-1.2.3.zip": "6666666666666666666666666666666666666666666666666666666666666666"
    }
  }
}
JSON

cp "$tmp_dir/latest-release-manifest.json" "$tmp_dir/public-manifest.json"
public_manifest_sha="$(sha256sum "$tmp_dir/public-manifest.json" | awk '{print $1}')"

cat > "$tmp_dir/public-SHA256SUMS.txt" <<SUMS
1111111111111111111111111111111111111111111111111111111111111111  $package.Msix
2222222222222222222222222222222222222222222222222222222222222222  $preserved_arm64_package.Msix
3333333333333333333333333333333333333333333333333333333333333333  Codex-mac-arm64.dmg
4444444444444444444444444444444444444444444444444444444444444444  Codex-mac-x64.dmg
5555555555555555555555555555555555555555555555555555555555555555  Codex-darwin-arm64-1.2.3.zip
6666666666666666666666666666666666666666666666666666666666666666  Codex-darwin-x64-1.2.3.zip
$public_manifest_sha  release-manifest.json
SUMS

bash "$repo_root/scripts/build-appcast.sh" arm64 "$tmp_dir/public-manifest.json" "https://codexapp.agentsmirror.com" "$tmp_dir/public-appcast.xml" >/dev/null
bash "$repo_root/scripts/build-appcast.sh" x64 "$tmp_dir/public-manifest.json" "https://codexapp.agentsmirror.com" "$tmp_dir/public-appcast-x64.xml" >/dev/null

cat > "$tmp_dir/bin/dotnet" <<'DOTNET'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "run" ]]; then
  if [[ "$*" == *" arm64" ]]; then
    echo "No matching package found for 9PLM9XGG6VKS / arm64." >&2
    exit 1
  fi
  printf 'OpenAI.Codex_1.2.3.4_x64__2p2nqsd0c76g0\thttps://download.example/OpenAI.Codex_1.2.3.4_x64__2p2nqsd0c76g0.Msix\n'
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
    printf '{"tag_name":"%s","assets":[{"name":"release-manifest.json","url":"https://api.example/assets/release-manifest"}]}\n' "$TEST_LATEST_TAG"
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
  local etag="$1"
  printf 'HTTP/2 200\r\n'
  printf 'content-range: bytes 0-0/3\r\n'
  printf 'content-length: 3\r\n'
  printf 'last-modified: Thu, 11 Jun 2026 00:00:00 GMT\r\n'
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
      <title>1.2.3</title>
      <pubDate>Thu, 11 Jun 2026 00:00:00 +0000</pubDate>
      <sparkle:version>5</sparkle:version>
      <sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>${hardware}</sparkle:hardwareRequirements>
      <enclosure url="https://persistent.oaistatic.com/codex-app-prod/Codex-darwin-${arch}-1.2.3.zip" length="3" type="application/octet-stream" sparkle:edSignature="${sig}" />
    </item>
  </channel>
</rss>
XML
}

headers_for_url() {
  case "$url" in
    *OpenAI.Codex_1.2.3.4_x64__2p2nqsd0c76g0.Msix)
      emit_headers "windows-etag"
      ;;
    *Codex-1.2.3-arm64.dmg)
      emit_headers "arm-etag"
      ;;
    *Codex-1.2.3-x64.dmg)
      emit_headers "x64-etag"
      ;;
    *persistent.oaistatic.com/codex-app-prod/Codex-darwin-arm64-1.2.3.zip|\
    *persistent.oaistatic.com/codex-app-prod/Codex-darwin-x64-1.2.3.zip)
      emit_headers "source-zip-etag"
      ;;
    *codexapp.agentsmirror.com/latest/win-arm64*)
      if [[ "${TEST_MISSING_ARM64_ALIAS:-false}" == "true" ]]; then
        echo "missing preserved arm64 alias: $url" >&2
        exit 1
      fi
      emit_headers "public-etag"
      ;;
    *codexapp.agentsmirror.com/latest/win*|\
    *codexapp.agentsmirror.com/latest/mac-arm64*|\
    *codexapp.agentsmirror.com/latest/mac-intel*|\
    *codexapp.agentsmirror.com/latest/mac/arm64/Codex-darwin-arm64-1.2.3.zip*|\
    *codexapp.agentsmirror.com/latest/mac/intel/Codex-darwin-x64-1.2.3.zip*)
      emit_headers "public-etag"
      ;;
    *)
      echo "unexpected curl headers URL: $url" >&2
      exit 1
      ;;
  esac
}

if [[ -n "$headers_file" ]]; then
  headers_for_url > "$headers_file"
  exit 0
fi

if $head_request; then
  headers_for_url
  exit 0
fi

case "$url" in
  *displaycatalog.mp.microsoft.com/v7.0/products/9PLM9XGG6VKS*)
    cat <<'JSON'
{"Product":{"DisplaySkuAvailabilities":[{"Sku":{"Properties":{"Packages":[
{"PackageFamilyName":"OpenAI.Codex_2p2nqsd0c76g0","PackageFullName":"OpenAI.Codex_1.2.3.4_x64__2p2nqsd0c76g0","Architectures":["x64"],"PackageId":"x64-package-id","ContentId":"content-id","MaxDownloadSizeInBytes":3,"HashAlgorithm":"SHA256","Hash":"x64hash"},
{"PackageFamilyName":"OpenAI.Codex_2p2nqsd0c76g0","PackageFullName":"OpenAI.Codex_1.2.3.4_arm64__2p2nqsd0c76g0","Architectures":["arm64"],"PackageId":"arm64-package-id","ContentId":"content-id","MaxDownloadSizeInBytes":4,"HashAlgorithm":"SHA256","Hash":"arm64hash"}
]}}}]}}
JSON
    ;;
  *windows-store-update.json)
    printf '{"buildVersion":"1.2.3.4","storeProductId":"9PLM9XGG6VKS","packageIdentity":"OpenAI.Codex_2p2nqsd0c76g0"}\n'
    ;;
  *codexapp.agentsmirror.com/latest/appcast.xml*)
    cat "${TEST_PUBLIC_APPCAST:?TEST_PUBLIC_APPCAST must be set}"
    ;;
  *codexapp.agentsmirror.com/latest/appcast-x64.xml*)
    cat "${TEST_PUBLIC_APPCAST_X64:?TEST_PUBLIC_APPCAST_X64 must be set}"
    ;;
	  *codexapp.agentsmirror.com/latest/checksums*)
	    if [[ "${TEST_STALE_MANIFEST_CHECKSUM:-false}" == "true" ]]; then
	      awk '
	        $2 == "release-manifest.json" {
	          print "7777777777777777777777777777777777777777777777777777777777777777  release-manifest.json"
	          next
	        }
	        { print }
	      ' "${TEST_PUBLIC_CHECKSUMS:?TEST_PUBLIC_CHECKSUMS must be set}"
	    else
	      cat "${TEST_PUBLIC_CHECKSUMS:?TEST_PUBLIC_CHECKSUMS must be set}"
	    fi
	    if [[ "${TEST_EXTRA_CHECKSUM:-false}" == "true" ]]; then
	      printf '8888888888888888888888888888888888888888888888888888888888888888  stale-extra.Msix\n'
	    fi
	    ;;
  *codexapp.agentsmirror.com/latest/manifest*)
    cat "${TEST_PUBLIC_MANIFEST:?TEST_PUBLIC_MANIFEST must be set}"
    ;;
  *appcast.xml)
    emit_appcast arm64 arm-signature arm64
    ;;
  *appcast-x64.xml)
    emit_appcast x64 x64-signature ""
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
  TEST_PUBLIC_MANIFEST="$tmp_dir/public-manifest.json" \
  TEST_PUBLIC_CHECKSUMS="$tmp_dir/public-SHA256SUMS.txt" \
  TEST_PUBLIC_APPCAST="$tmp_dir/public-appcast.xml" \
  TEST_PUBLIC_APPCAST_X64="$tmp_dir/public-appcast-x64.xml" \
  STORE_LINK_MAX_ATTEMPTS=1 \
  MANIFEST_PATH="$tmp_dir/probe-manifest.json" \
    scripts/probe-release.sh > "$tmp_dir/output.txt"
)

grep -F "should_release=false" "$tmp_dir/output.txt"
grep -F "public mirror latest already matches current sources; GitHub latest remains $latest_tag until all architectures are complete" "$tmp_dir/output.txt"
test "$(jq -r '.sources.windows.architectures.arm64.status' "$tmp_dir/probe-manifest.json")" = "catalog-only"
test "$(jq -r '.sources.windows.architectures.arm64.packageMoniker' "$tmp_dir/probe-manifest.json")" = "$current_arm64_package"
test "$(jq -r '.sources.windows.architectures.arm64.downloadable' "$tmp_dir/probe-manifest.json")" = "false"

(
  cd "$repo_root"
  PATH="$tmp_dir/bin:$PATH" \
  TEST_GH_LOG="$gh_log" \
  TEST_LATEST_TAG="$latest_tag" \
  TEST_LATEST_MANIFEST="$tmp_dir/latest-release-manifest.json" \
  TEST_PUBLIC_MANIFEST="$tmp_dir/public-manifest.json" \
  TEST_PUBLIC_CHECKSUMS="$tmp_dir/public-SHA256SUMS.txt" \
  TEST_PUBLIC_APPCAST="$tmp_dir/public-appcast.xml" \
  TEST_PUBLIC_APPCAST_X64="$tmp_dir/public-appcast-x64.xml" \
  TEST_MISSING_ARM64_ALIAS=true \
  STORE_LINK_MAX_ATTEMPTS=1 \
  MANIFEST_PATH="$tmp_dir/probe-missing-arm64-manifest.json" \
    scripts/probe-release.sh > "$tmp_dir/missing-arm64-output.txt"
)

grep -F "should_release=true" "$tmp_dir/missing-arm64-output.txt"

(
  cd "$repo_root"
  PATH="$tmp_dir/bin:$PATH" \
  TEST_GH_LOG="$gh_log" \
  TEST_LATEST_TAG="$latest_tag" \
  TEST_LATEST_MANIFEST="$tmp_dir/latest-release-manifest.json" \
  TEST_PUBLIC_MANIFEST="$tmp_dir/public-manifest.json" \
  TEST_PUBLIC_CHECKSUMS="$tmp_dir/public-SHA256SUMS.txt" \
  TEST_PUBLIC_APPCAST="$tmp_dir/public-appcast.xml" \
  TEST_PUBLIC_APPCAST_X64="$tmp_dir/public-appcast-x64.xml" \
  TEST_STALE_MANIFEST_CHECKSUM=true \
  STORE_LINK_MAX_ATTEMPTS=1 \
  MANIFEST_PATH="$tmp_dir/probe-stale-manifest-checksum-manifest.json" \
    scripts/probe-release.sh > "$tmp_dir/stale-manifest-checksum-output.txt"
)

grep -F "should_release=true" "$tmp_dir/stale-manifest-checksum-output.txt"

(
  cd "$repo_root"
  PATH="$tmp_dir/bin:$PATH" \
  TEST_GH_LOG="$gh_log" \
  TEST_LATEST_TAG="$latest_tag" \
  TEST_LATEST_MANIFEST="$tmp_dir/latest-release-manifest.json" \
  TEST_PUBLIC_MANIFEST="$tmp_dir/public-manifest.json" \
  TEST_PUBLIC_CHECKSUMS="$tmp_dir/public-SHA256SUMS.txt" \
  TEST_PUBLIC_APPCAST="$tmp_dir/public-appcast.xml" \
  TEST_PUBLIC_APPCAST_X64="$tmp_dir/public-appcast-x64.xml" \
  TEST_EXTRA_CHECKSUM=true \
  STORE_LINK_MAX_ATTEMPTS=1 \
  MANIFEST_PATH="$tmp_dir/probe-extra-checksum-manifest.json" \
    scripts/probe-release.sh > "$tmp_dir/extra-checksum-output.txt"
)

grep -F "should_release=true" "$tmp_dir/extra-checksum-output.txt"

echo "probe-release preserved-arm64 fixture test PASS"
