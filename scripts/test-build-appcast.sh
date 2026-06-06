#!/usr/bin/env bash
set -euo pipefail

# Fixture test for build-appcast.sh: render arm64 + x64 appcasts from a synthetic
# release manifest and assert the output is a valid Sparkle feed whose enclosure
# points at the mirror while every upstream field (notably the EdDSA signature)
# is preserved verbatim. Runs without secrets or a real release event.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

arm_sig="fQ7rDmk/lQGGg8JReeCvN+ct0Db3z6MFvV8FqgI9ZzpYNKpjWalf2vfLi8TqSCVBF+jXs20U3FGwTeaWocDYBg=="
x64_sig="6OM9z2K/DXc05QidSyspEl9LXe1s5E8HesofMpw9vQ/nBNK39pSarOqGt6u1jA+VyDy4pbsphk4WAUH8D3eKDg=="

cat > "$tmp_dir/release-manifest.json" <<JSON
{
  "schemaVersion": 2,
  "sources": {
    "macos": {
      "arm64": {
        "appcast": {
          "title": "26.602.40724",
          "pubDate": "Fri, 05 Jun 2026 17:00:22 +0000",
          "version": "3593",
          "shortVersionString": "26.602.40724",
          "minimumSystemVersion": "12.0",
          "hardwareRequirements": "arm64",
          "enclosureUrl": "https://persistent.oaistatic.com/codex-app-prod/Codex-darwin-arm64-26.602.40724.zip",
          "enclosureLength": 406585586,
          "enclosureSignature": "$arm_sig"
        }
      },
      "x64": {
        "appcast": {
          "title": "26.602.40724",
          "pubDate": "Fri, 05 Jun 2026 17:00:20 +0000",
          "version": "3593",
          "shortVersionString": "26.602.40724",
          "minimumSystemVersion": "12.0",
          "hardwareRequirements": "",
          "enclosureUrl": "https://persistent.oaistatic.com/codex-app-prod/Codex-darwin-x64-26.602.40724.zip",
          "enclosureLength": 397428010,
          "enclosureSignature": "$x64_sig"
        }
      }
    }
  }
}
JSON

base="https://codexapp.agentsmirror.com"

bash "$repo_root/scripts/build-appcast.sh" arm64 "$tmp_dir/release-manifest.json" "$base" "$tmp_dir/appcast.xml" >/dev/null
bash "$repo_root/scripts/build-appcast.sh" x64 "$tmp_dir/release-manifest.json" "$base" "$tmp_dir/appcast-x64.xml" >/dev/null

assert_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq "$needle" "$file"; then
    echo "Expected to find in $file: $needle" >&2
    echo "--- actual ---" >&2
    cat "$file" >&2
    exit 1
  fi
}

assert_absent() {
  local file="$1"
  local needle="$2"
  if grep -Fq "$needle" "$file"; then
    echo "Did not expect to find in $file: $needle" >&2
    exit 1
  fi
}

# arm64: enclosure rewritten to the mirror, signature/length/version preserved.
assert_contains "$tmp_dir/appcast.xml" 'url="https://codexapp.agentsmirror.com/latest/mac/arm64/Codex-darwin-arm64-26.602.40724.zip"'
assert_contains "$tmp_dir/appcast.xml" "sparkle:edSignature=\"$arm_sig\""
assert_contains "$tmp_dir/appcast.xml" 'length="406585586"'
assert_contains "$tmp_dir/appcast.xml" '<sparkle:version>3593</sparkle:version>'
assert_contains "$tmp_dir/appcast.xml" '<sparkle:shortVersionString>26.602.40724</sparkle:shortVersionString>'
assert_contains "$tmp_dir/appcast.xml" '<sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>'
assert_contains "$tmp_dir/appcast.xml" '<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>'
assert_contains "$tmp_dir/appcast.xml" 'type="application/octet-stream"'
# Never leak the upstream enclosure host into the mirror feed.
assert_absent "$tmp_dir/appcast.xml" 'persistent.oaistatic.com'

# x64: own enclosure name + signature, and no hardwareRequirements element.
assert_contains "$tmp_dir/appcast-x64.xml" 'url="https://codexapp.agentsmirror.com/latest/mac/intel/Codex-darwin-x64-26.602.40724.zip"'
assert_contains "$tmp_dir/appcast-x64.xml" "sparkle:edSignature=\"$x64_sig\""
assert_contains "$tmp_dir/appcast-x64.xml" 'length="397428010"'
assert_absent "$tmp_dir/appcast-x64.xml" 'hardwareRequirements'
assert_absent "$tmp_dir/appcast-x64.xml" 'persistent.oaistatic.com'

# Both feeds must be well-formed XML with exactly one <item>.
for feed in "$tmp_dir/appcast.xml" "$tmp_dir/appcast-x64.xml"; do
  python3 - "$feed" <<'PY'
import sys
import xml.etree.ElementTree as ET

ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
root = ET.parse(sys.argv[1]).getroot()
items = root.findall("./channel/item")
assert len(items) == 1, f"expected exactly one item, got {len(items)}"
item = items[0]
enclosure = item.find("enclosure")
assert enclosure is not None, "missing enclosure"
sig = enclosure.attrib.get(
    "{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature", ""
)
assert sig, "missing edSignature"
assert item.findtext("sparkle:version", namespaces=ns), "missing sparkle:version"
assert item.findtext(
    "sparkle:shortVersionString", namespaces=ns
), "missing sparkle:shortVersionString"
PY
done

# Missing appcast metadata must fail loudly (the guard against shipping a broken feed).
cat > "$tmp_dir/empty-manifest.json" <<'JSON'
{ "schemaVersion": 2, "sources": { "macos": { "arm64": {}, "x64": {} } } }
JSON
if bash "$repo_root/scripts/build-appcast.sh" arm64 "$tmp_dir/empty-manifest.json" "$base" "$tmp_dir/should-not-exist.xml" >/dev/null 2>&1; then
  echo "build-appcast.sh should fail when appcast metadata is missing." >&2
  exit 1
fi

echo "build-appcast fixture test PASS"
