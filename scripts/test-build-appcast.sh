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

# Delta enclosure fixtures (real upstream shape: each has its own edSignature and
# the deltaFromSparkle* attributes Sparkle publishes). arm64 ships two deltas to
# exercise the delta path; x64 ships none to exercise the full-update-only path.
arm_delta1_sig="46z2mpw1xOZWuQ0rpQn+tZ5yRQL/GmJN2UJ7qpS7IC7NILk9xxHALGnGa8gRZvKK3lV9ni11AnXCCPbRQMKXDg=="
arm_delta2_sig="uIgT0RouyKTkFMQ/MNFhITkvxyNhEfnsXgvKCKVWxv8FedrmWvLYWzwAFcz86UEx2JaszL2QfMIM5u3yOIrIBg=="

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
          "enclosureUrl": "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-darwin-arm64-26.602.40724.zip",
          "sourceBasename": "ChatGPT-darwin-arm64-26.602.40724.zip",
          "mirrorEnclosureBasename": "Codex-darwin-arm64-26.602.40724.zip",
          "enclosureLength": 406585586,
          "enclosureSignature": "$arm_sig",
          "deltas": [
            {
              "basename": "Codex3593-3575-arm64.delta",
              "url": "https://persistent.oaistatic.com/codex-app-prod/Codex3593-3575-arm64.delta",
              "length": 195130,
              "deltaFrom": "3575",
              "version": "",
              "os": "",
              "type": "application/octet-stream",
              "edSignature": "$arm_delta1_sig",
              "attributes": {
                "url": "https://persistent.oaistatic.com/codex-app-prod/Codex3593-3575-arm64.delta",
                "length": "195130",
                "type": "application/octet-stream",
                "sparkle:deltaFrom": "3575",
                "sparkle:deltaFromSparkleExecutableSize": "979952",
                "sparkle:deltaFromSparkleLocales": "de,ar,el,ja,fa,uk,zh_CN",
                "sparkle:edSignature": "$arm_delta1_sig"
              }
            },
            {
              "basename": "Codex3593-3511-arm64.delta",
              "url": "https://persistent.oaistatic.com/codex-app-prod/Codex3593-3511-arm64.delta",
              "length": 18255214,
              "deltaFrom": "3511",
              "version": "",
              "os": "",
              "type": "application/octet-stream",
              "edSignature": "$arm_delta2_sig",
              "attributes": {
                "url": "https://persistent.oaistatic.com/codex-app-prod/Codex3593-3511-arm64.delta",
                "length": "18255214",
                "type": "application/octet-stream",
                "sparkle:deltaFrom": "3511",
                "sparkle:deltaFromSparkleExecutableSize": "979952",
                "sparkle:deltaFromSparkleLocales": "de,ar,el,ja,fa,uk,zh_CN",
                "sparkle:edSignature": "$arm_delta2_sig"
              }
            }
          ]
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
          "enclosureUrl": "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-darwin-x64-26.602.40724.zip",
          "sourceBasename": "ChatGPT-darwin-x64-26.602.40724.zip",
          "mirrorEnclosureBasename": "Codex-darwin-x64-26.602.40724.zip",
          "enclosureLength": 397428010,
          "enclosureSignature": "$x64_sig",
          "deltas": []
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

# arm64 deltas: a <sparkle:deltas> block whose enclosures point at the mirror,
# preserve the official basename, and reuse each delta's edSignature/length/
# deltaFrom verbatim. The extra deltaFromSparkle* attributes are kept too.
assert_contains "$tmp_dir/appcast.xml" '<sparkle:deltas>'
assert_contains "$tmp_dir/appcast.xml" 'url="https://codexapp.agentsmirror.com/latest/mac/arm64/Codex3593-3575-arm64.delta"'
assert_contains "$tmp_dir/appcast.xml" 'url="https://codexapp.agentsmirror.com/latest/mac/arm64/Codex3593-3511-arm64.delta"'
assert_contains "$tmp_dir/appcast.xml" 'sparkle:deltaFrom="3575"'
assert_contains "$tmp_dir/appcast.xml" 'sparkle:deltaFrom="3511"'
assert_contains "$tmp_dir/appcast.xml" "sparkle:edSignature=\"$arm_delta1_sig\""
assert_contains "$tmp_dir/appcast.xml" "sparkle:edSignature=\"$arm_delta2_sig\""
assert_contains "$tmp_dir/appcast.xml" 'length="195130"'
assert_contains "$tmp_dir/appcast.xml" 'sparkle:deltaFromSparkleExecutableSize="979952"'
assert_contains "$tmp_dir/appcast.xml" 'sparkle:deltaFromSparkleLocales="de,ar,el,ja,fa,uk,zh_CN"'
# Never leak the upstream enclosure host into the mirror feed (full or delta).
assert_absent "$tmp_dir/appcast.xml" 'persistent.oaistatic.com'

# x64: own enclosure name + signature, and no hardwareRequirements element.
assert_contains "$tmp_dir/appcast-x64.xml" 'url="https://codexapp.agentsmirror.com/latest/mac/intel/Codex-darwin-x64-26.602.40724.zip"'
assert_contains "$tmp_dir/appcast-x64.xml" "sparkle:edSignature=\"$x64_sig\""
assert_contains "$tmp_dir/appcast-x64.xml" 'length="397428010"'
assert_absent "$tmp_dir/appcast-x64.xml" 'hardwareRequirements'
assert_absent "$tmp_dir/appcast-x64.xml" 'persistent.oaistatic.com'
# x64 has no upstream deltas: the feed must stay full-update-only (no empty
# <sparkle:deltas> element, no .delta enclosures).
assert_absent "$tmp_dir/appcast-x64.xml" '<sparkle:deltas>'
assert_absent "$tmp_dir/appcast-x64.xml" '.delta"'

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

# Structural delta checks: arm64 has exactly the two upstream deltas (each a
# mirror URL with its own verbatim edSignature); x64 has no <sparkle:deltas>.
python3 - "$tmp_dir/appcast.xml" "$arm_delta1_sig" "$arm_delta2_sig" <<'PY'
import sys
import xml.etree.ElementTree as ET

SP = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
feed, sig1, sig2 = sys.argv[1:]
item = ET.parse(feed).getroot().find("./channel/item")
deltas = item.find(SP + "deltas")
assert deltas is not None, "arm64 feed must have <sparkle:deltas>"
encs = deltas.findall("enclosure")
assert len(encs) == 2, f"expected 2 deltas, got {len(encs)}"
by_from = {e.attrib.get(SP + "deltaFrom"): e for e in encs}
assert set(by_from) == {"3575", "3511"}, sorted(by_from)
for e in encs:
    url = e.attrib["url"]
    assert url.startswith(
        "https://codexapp.agentsmirror.com/latest/mac/arm64/"
    ), url
    assert url.endswith(".delta"), url
    assert e.attrib.get(SP + "edSignature"), "delta missing edSignature"
    assert e.attrib.get("length"), "delta missing length"
assert by_from["3575"].attrib[SP + "edSignature"] == sig1
assert by_from["3511"].attrib[SP + "edSignature"] == sig2
PY

python3 - "$tmp_dir/appcast-x64.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

SP = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
item = ET.parse(sys.argv[1]).getroot().find("./channel/item")
assert item.find(SP + "deltas") is None, "x64 feed must not have <sparkle:deltas>"
PY

# Missing appcast metadata must fail loudly (the guard against shipping a broken feed).
cat > "$tmp_dir/empty-manifest.json" <<'JSON'
{ "schemaVersion": 2, "sources": { "macos": { "arm64": {}, "x64": {} } } }
JSON
if bash "$repo_root/scripts/build-appcast.sh" arm64 "$tmp_dir/empty-manifest.json" "$base" "$tmp_dir/should-not-exist.xml" >/dev/null 2>&1; then
  echo "build-appcast.sh should fail when appcast metadata is missing." >&2
  exit 1
fi

# Unsafe mirror basenames must never become object keys or enclosure URLs.
jq '.sources.macos.arm64.appcast.mirrorEnclosureBasename = "../escape.zip"' \
  "$tmp_dir/release-manifest.json" > "$tmp_dir/unsafe-manifest.json"
if bash "$repo_root/scripts/build-appcast.sh" arm64 "$tmp_dir/unsafe-manifest.json" "$base" "$tmp_dir/unsafe.xml" >/dev/null 2>&1; then
  echo "build-appcast.sh should reject an unsafe mirror enclosure basename." >&2
  exit 1
fi

echo "build-appcast fixture test PASS"
