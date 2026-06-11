#!/usr/bin/env bash
set -euo pipefail

# Fixture test for probe-release.sh: when the latest release already matches the
# current upstream sources but the public mirror checksum alias is stale,
# probe-release.sh must republish that exact latest tag. A version-derived tag
# may also exist, but it must not override the latest-tag fallback selected for
# mirror repair.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_dir/bin"

latest_tag="codex-app-force-20260611-010101"
predicted_tag="codex-app-win-1.2.3.4-mac-1.2.3-b5"
package="OpenAI.Codex_1.2.3.4_x64__2p2nqsd0c76g0"
gh_log="$tmp_dir/gh.log"
: > "$gh_log"

cat > "$tmp_dir/latest-release-manifest.json" <<JSON
{
  "schemaVersion": 1,
  "sources": {
    "windows": {
      "version": "1.2.3.4",
      "packageMoniker": "$package",
      "contentLength": 3
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
  }
}
JSON

cat > "$tmp_dir/public-manifest.json" <<JSON
{
  "schemaVersion": 1,
  "sources": {
    "windows": {
      "version": "1.2.3.4",
      "packageMoniker": "$package",
      "contentLength": 3
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
  }
}
JSON

cat > "$tmp_dir/latest-SHA256SUMS.txt" <<'SUMS'
current-checksum  release-manifest.json
SUMS

bash "$repo_root/scripts/build-appcast.sh" arm64 "$tmp_dir/latest-release-manifest.json" "https://codexapp.agentsmirror.com" "$tmp_dir/public-appcast.xml" >/dev/null
bash "$repo_root/scripts/build-appcast.sh" x64 "$tmp_dir/latest-release-manifest.json" "https://codexapp.agentsmirror.com" "$tmp_dir/public-appcast-x64.xml" >/dev/null

cat > "$tmp_dir/bin/dotnet" <<'DOTNET'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "run" ]]; then
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
    printf '{"tag_name":"%s","assets":[{"name":"release-manifest.json","url":"https://api.example/assets/release-manifest"},{"name":"SHA256SUMS.txt","url":"https://api.example/assets/checksums"}]}\n' "$TEST_LATEST_TAG"
    ;;
  repos/\{owner\}/\{repo\}/releases/tags/"${TEST_PREDICTED_TAG}")
    printf '{"tag_name":"%s","assets":[]}\n' "$TEST_PREDICTED_TAG"
    ;;
  https://api.example/assets/release-manifest)
    cat "${TEST_LATEST_MANIFEST:?TEST_LATEST_MANIFEST must be set}"
    ;;
  https://api.example/assets/checksums)
    cat "${TEST_LATEST_CHECKSUMS:?TEST_LATEST_CHECKSUMS must be set}"
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
    printf 'stale-checksum  release-manifest.json\n'
    ;;
  *appcast.xml)
    emit_appcast arm64 arm-signature arm64
    ;;
  *appcast-x64.xml)
    emit_appcast x64 x64-signature ""
    ;;
  *codexapp.agentsmirror.com/latest/manifest*)
    cat "${TEST_PUBLIC_MANIFEST:?TEST_PUBLIC_MANIFEST must be set}"
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
  TEST_PREDICTED_TAG="$predicted_tag" \
  TEST_LATEST_MANIFEST="$tmp_dir/latest-release-manifest.json" \
  TEST_LATEST_CHECKSUMS="$tmp_dir/latest-SHA256SUMS.txt" \
  TEST_PUBLIC_MANIFEST="$tmp_dir/public-manifest.json" \
  TEST_PUBLIC_APPCAST="$tmp_dir/public-appcast.xml" \
  TEST_PUBLIC_APPCAST_X64="$tmp_dir/public-appcast-x64.xml" \
  STORE_LINK_MAX_ATTEMPTS=1 \
  MANIFEST_PATH="$tmp_dir/probe-manifest.json" \
    scripts/probe-release.sh > "$tmp_dir/output.txt"
)

grep -F "should_release=true" "$tmp_dir/output.txt"
grep -F "release_tag=$latest_tag" "$tmp_dir/output.txt"
grep -F "latest_tag=$latest_tag" "$tmp_dir/output.txt"
grep -F "latest release $latest_tag matches current sources, but public mirror aliases or appcasts are stale; republishing" "$tmp_dir/output.txt"

if grep -F "release_tag=$predicted_tag" "$tmp_dir/output.txt"; then
  echo "probe-release.sh overwrote the latest-tag fallback with the predicted tag." >&2
  exit 1
fi

if grep -F "releases/tags/$predicted_tag" "$gh_log"; then
  echo "probe-release.sh should not query the predicted tag after selecting a latest-tag fallback." >&2
  cat "$gh_log" >&2
  exit 1
fi

echo "probe-release fixture test PASS"
