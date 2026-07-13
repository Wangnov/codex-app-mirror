#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/fixtures"

cat > "$tmp_dir/base-manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "channel": "beta",
  "beta": {
    "contract": "issue-36-beta-prerelease",
    "expectedWindowsPackageVersion": "26.707.3351.0"
  },
  "publication": {
    "githubPrereleaseOnly": true,
    "githubLatestAdvanced": false,
    "objectStoragePublished": false,
    "sharedLatestAdvanced": false
  },
  "derived": {
    "prerelease": true,
    "publishLatest": false,
    "syncLatest": false,
    "includeMacosArm64": false,
    "includeMacosX64": false
  },
  "sources": {}
}
JSON

write_appcast() {
  local output="$1"
  local channel_title="$2"
  local arch="$3"
  local current_version="$4"
  local enclosure_base="$5"
  local historical_version="${6:-}"
  local hardware=""
  local length="202"

  if [[ "$arch" == "arm64" ]]; then
    hardware='<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>'
    length="201"
  fi

  {
    cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>$channel_title</title>
    <item>
      <title>$current_version</title>
      <pubDate>Thu, 09 Jul 2026 23:59:59 +0000</pubDate>
      <sparkle:version>5061</sparkle:version>
      <sparkle:shortVersionString>$current_version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
      $hardware
      <enclosure url="$enclosure_base/ChatGPT%20(Beta)-darwin-$arch-$current_version.zip" length="$length" type="application/octet-stream" sparkle:edSignature="fixture-$arch-signature" />
    </item>
XML
    if [[ -n "$historical_version" ]]; then
      cat <<XML
    <item>
      <title>$historical_version</title>
      <sparkle:version>5059</sparkle:version>
      <sparkle:shortVersionString>$historical_version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
      $hardware
      <enclosure url="https://persistent.oaistatic.com/codex-app-beta/ChatGPT%20(Beta)-darwin-$arch-$historical_version.zip" length="$length" type="application/octet-stream" sparkle:edSignature="fixture-history-$arch-signature" />
    </item>
XML
    fi
    cat <<'XML'
  </channel>
</rss>
XML
  } > "$output"
}

# The two titles intentionally match the live feeds: arm64 and Intel differ.
write_appcast \
  "$tmp_dir/fixtures/success-arm64.xml" \
  "Codex Updates (Public Beta)" \
  arm64 \
  26.707.31428 \
  https://persistent.oaistatic.com/codex-app-beta
write_appcast \
  "$tmp_dir/fixtures/success-x64.xml" \
  "Codex (Beta)" \
  x64 \
  26.707.31428 \
  https://persistent.oaistatic.com/codex-app-beta

# The requested version exists only as the second item. A safe probe must reject
# it because the first appcast item is the current release.
write_appcast \
  "$tmp_dir/fixtures/historical-arm64.xml" \
  "Codex Updates (Public Beta)" \
  arm64 \
  26.707.51957 \
  https://persistent.oaistatic.com/codex-app-beta \
  26.707.31428
write_appcast \
  "$tmp_dir/fixtures/historical-x64.xml" \
  "Codex (Beta)" \
  x64 \
  26.707.51957 \
  https://persistent.oaistatic.com/codex-app-beta \
  26.707.31428

write_appcast \
  "$tmp_dir/fixtures/wrong-host-arm64.xml" \
  "Codex Updates (Public Beta)" \
  arm64 \
  26.707.31428 \
  https://downloads.example.invalid/codex-app-beta
cp "$tmp_dir/fixtures/success-x64.xml" "$tmp_dir/fixtures/wrong-host-x64.xml"

cp "$tmp_dir/fixtures/success-arm64.xml" "$tmp_dir/fixtures/wrong-path-arm64.xml"
write_appcast \
  "$tmp_dir/fixtures/wrong-path-x64.xml" \
  "Codex (Beta)" \
  x64 \
  26.707.31428 \
  https://persistent.oaistatic.com/codex-app-prod

cat > "$tmp_dir/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail

output=""
headers=""
url=""
while (($#)); do
  case "$1" in
    -o|--output)
      output="$2"
      shift
      ;;
    --dump-header)
      headers="$2"
      shift
      ;;
    http://*|https://*)
      url="$1"
      ;;
  esac
  shift
done

if [[ -z "$url" ]]; then
  echo "fixture curl expected a URL" >&2
  exit 1
fi

case "$url" in
  https://persistent.oaistatic.com/codex-app-beta/appcast.xml)
    cp "${TEST_FIXTURE_DIR:?}/${TEST_SCENARIO:?}-arm64.xml" "${output:?}"
    ;;
  https://persistent.oaistatic.com/codex-app-beta/appcast-x64.xml)
    cp "${TEST_FIXTURE_DIR:?}/${TEST_SCENARIO:?}-x64.xml" "${output:?}"
    ;;
  *)
    [[ -n "$headers" ]] || {
      echo "unexpected fixture URL without range headers: $url" >&2
      exit 1
    }
    case "$url" in
      *-arm64.dmg) size=101 ;;
      *-x64.dmg) size=102 ;;
      *-darwin-arm64-*.zip) size=201 ;;
      *-darwin-x64-*.zip) size=202 ;;
      *)
        echo "unexpected fixture asset URL: $url" >&2
        exit 1
        ;;
    esac
    cat > "$headers" <<EOF
HTTP/2 206
content-length: 1
content-range: bytes 0-0/$size
last-modified: Thu, 09 Jul 2026 23:59:59 GMT
etag: fixture-$size
EOF
    ;;
esac
CURL
chmod +x "$tmp_dir/bin/curl"

run_probe() {
  local scenario="$1"
  local expected_version="$2"
  local manifest="$3"

  cp "$tmp_dir/base-manifest.json" "$manifest"
  env \
    PATH="$tmp_dir/bin:$PATH" \
    TEST_FIXTURE_DIR="$tmp_dir/fixtures" \
    TEST_SCENARIO="$scenario" \
    EXPECTED_MACOS_VERSION="$expected_version" \
    bash "$repo_root/scripts/probe-macos-beta.sh" "$manifest"
}

success_manifest="$tmp_dir/success-manifest.json"
run_probe success 26.707.31428 "$success_manifest" > "$tmp_dir/success.log"

jq -e '
  .channel == "beta"
  and .beta.expectedMacosVersion == "26.707.31428"
  and .publication.githubPrereleaseOnly == true
  and .publication.objectStoragePublished == false
  and .derived.includeMacosArm64 == true
  and .derived.includeMacosX64 == true
  and .sources.macos.arm64.appcast.channelTitle == "Codex Updates (Public Beta)"
  and .sources.macos.x64.appcast.channelTitle == "Codex (Beta)"
  and .sources.macos.arm64.url == "https://persistent.oaistatic.com/codex-app-beta/ChatGPT%20(Beta)-26.707.31428-arm64.dmg"
  and .sources.macos.x64.url == "https://persistent.oaistatic.com/codex-app-beta/ChatGPT%20(Beta)-26.707.31428-x64.dmg"
  and .sources.macos.arm64.contentLength == 101
  and .sources.macos.x64.contentLength == 102
  and .sources.macos.arm64.appcast.enclosureLength == 201
  and .sources.macos.x64.appcast.enclosureLength == 202
  and .sources.macos.arm64.appcast.deltas == []
  and .sources.macos.x64.appcast.deltas == []
' "$success_manifest" >/dev/null

assert_probe_failure() {
  local scenario="$1"
  local expected_message="$2"
  local output status

  set +e
  output="$(run_probe "$scenario" 26.707.31428 "$tmp_dir/$scenario-manifest.json" 2>&1)"
  status=$?
  set -e

  if [[ "$status" -eq 0 ]] || ! grep -Fq "$expected_message" <<<"$output"; then
    echo "Expected $scenario probe to fail with: $expected_message" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

assert_probe_failure historical "current Beta version drift: expected 26.707.31428, got 26.707.51957"
assert_probe_failure wrong-host "is not an official HTTPS asset URL"
assert_probe_failure wrong-path "is outside the official Beta path"

echo "probe-macos-beta fixture PASS"
