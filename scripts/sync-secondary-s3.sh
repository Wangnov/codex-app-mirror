#!/usr/bin/env bash
set -euo pipefail

: "${SECONDARY_S3_ENDPOINT:?SECONDARY_S3_ENDPOINT must be set, for example https://s3.example.com}"
: "${SECONDARY_S3_BUCKET:?SECONDARY_S3_BUCKET must be set}"
: "${SECONDARY_S3_ACCESS_KEY_ID:?SECONDARY_S3_ACCESS_KEY_ID must be set}"
: "${SECONDARY_S3_SECRET_ACCESS_KEY:?SECONDARY_S3_SECRET_ACCESS_KEY must be set}"

if [[ $# -ne 9 ]]; then
  echo "Usage: sync-secondary-s3.sh <mac-arm64-dmg> <mac-intel-dmg> <windows-msix> <checksums> <manifest> <mac-arm64-zip> <mac-intel-zip> <appcast-arm64> <appcast-x64>" >&2
  exit 2
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI is required for S3-compatible uploads." >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
prefix="${SECONDARY_S3_PREFIX:-latest}"
prefix="${prefix#/}"
prefix="${prefix%/}"
region="${SECONDARY_S3_REGION:-auto}"
cache_control="${SECONDARY_S3_CACHE_CONTROL:-public, max-age=600, s-maxage=86400}"
addressing_style="${SECONDARY_S3_ADDRESSING_STYLE:-path}"

if [[ -z "$prefix" ]]; then
  echo "SECONDARY_S3_PREFIX must not resolve to an empty prefix." >&2
  exit 2
fi

tmp_config="$(mktemp)"
cleanup() {
  rm -f "$tmp_config"
}
trap cleanup EXIT

cat > "$tmp_config" <<EOF
[default]
region = $region
s3 =
    addressing_style = $addressing_style
EOF

export AWS_ACCESS_KEY_ID="$SECONDARY_S3_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$SECONDARY_S3_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="$region"
export AWS_EC2_METADATA_DISABLED=true
export AWS_CONFIG_FILE="$tmp_config"
export R2_S3_ENDPOINT="$SECONDARY_S3_ENDPOINT"
export R2_CACHE_CONTROL="$cache_control"

mac_arm64="$1"
mac_intel="$2"
win_msix="$3"
checksums="$4"
manifest="$5"
mac_arm64_zip="$6"
mac_intel_zip="$7"
appcast_arm64="$8"
appcast_x64="$9"

mac_arm64_zip_name="$(basename "$mac_arm64_zip")"
mac_intel_zip_name="$(basename "$mac_intel_zip")"

# Extract the .delta enclosure basenames an appcast references. The mirror keeps
# the official basenames verbatim, so the basename is enough to locate the file
# (downloaded alongside the full .zip) and to build the object key.
delta_basenames_from_appcast() {
  local appcast="$1"
  python3 - "$appcast" <<'PY'
import sys
import xml.etree.ElementTree as ET

SP = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
item = ET.parse(sys.argv[1]).getroot().find("./channel/item")
if item is None:
    sys.exit(0)
deltas = item.find(SP + "deltas")
if deltas is None:
    sys.exit(0)
for enc in deltas.findall("enclosure"):
    url = enc.attrib.get("url", "")
    if url:
        print(url.rsplit("/", 1)[-1])
PY
}

# Upload every .delta the given appcast references, from the same directory as
# its full .zip, into <prefix>/mac/<dir>/<basename>. Done before the appcasts are
# published so the feed never advertises a delta that is not yet downloadable.
upload_deltas_for_appcast() {
  local appcast="$1"
  local zip_path="$2"
  local mac_dir="$3"
  local src_dir
  local bn

  src_dir="$(dirname "$zip_path")"
  while IFS= read -r bn; do
    [[ -z "$bn" ]] && continue
    if [[ ! -f "$src_dir/$bn" ]]; then
      echo "Missing delta archive $src_dir/$bn referenced by $appcast." >&2
      exit 1
    fi
    bash "$repo_root/scripts/sync-r2.sh" --object "$SECONDARY_S3_BUCKET" "$prefix/mac/$mac_dir/$bn" "$src_dir/$bn" "$bn"
  done < <(delta_basenames_from_appcast "$appcast")
}

bash "$repo_root/scripts/sync-r2.sh" --object "$SECONDARY_S3_BUCKET" "$prefix/mac-arm64" "$mac_arm64" Codex-mac-arm64.dmg
bash "$repo_root/scripts/sync-r2.sh" --object "$SECONDARY_S3_BUCKET" "$prefix/mac-intel" "$mac_intel" Codex-mac-intel.dmg
bash "$repo_root/scripts/sync-r2.sh" --object "$SECONDARY_S3_BUCKET" "$prefix/win" "$win_msix" Codex-Windows-x64.msix
bash "$repo_root/scripts/sync-r2.sh" --object "$SECONDARY_S3_BUCKET" "$prefix/checksums" "$checksums" SHA256SUMS.txt
bash "$repo_root/scripts/sync-r2.sh" --object "$SECONDARY_S3_BUCKET" "$prefix/manifest" "$manifest" release-manifest.json

# Sparkle update archives, keyed to match the appcast enclosure URLs. Upload the
# archives (full .zip + every .delta) before the appcasts so the feed never
# advertises a missing enclosure.
bash "$repo_root/scripts/sync-r2.sh" --object "$SECONDARY_S3_BUCKET" "$prefix/mac/arm64/$mac_arm64_zip_name" "$mac_arm64_zip" "$mac_arm64_zip_name"
bash "$repo_root/scripts/sync-r2.sh" --object "$SECONDARY_S3_BUCKET" "$prefix/mac/intel/$mac_intel_zip_name" "$mac_intel_zip" "$mac_intel_zip_name"
upload_deltas_for_appcast "$appcast_arm64" "$mac_arm64_zip" arm64
upload_deltas_for_appcast "$appcast_x64" "$mac_intel_zip" intel

# appcast feeds change every release; keep their CDN cache short.
R2_CACHE_CONTROL="public, max-age=600" \
  bash "$repo_root/scripts/sync-r2.sh" --object "$SECONDARY_S3_BUCKET" "$prefix/appcast.xml" "$appcast_arm64" appcast.xml
R2_CACHE_CONTROL="public, max-age=600" \
  bash "$repo_root/scripts/sync-r2.sh" --object "$SECONDARY_S3_BUCKET" "$prefix/appcast-x64.xml" "$appcast_x64" appcast-x64.xml
