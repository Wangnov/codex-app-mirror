#!/usr/bin/env bash
set -euo pipefail

# Render a Sparkle appcast (arm64 or x64) from release-manifest.json.
#
# The downstream macOS client (Codex App Manager) fetches the mirror appcast,
# downloads the enclosure `.zip`, and verifies it against a *pinned* OpenAI
# EdDSA key. EdDSA signs the archive bytes, so as long as we mirror the official
# archive byte-for-byte, the original `sparkle:edSignature` stays valid even
# though the enclosure URL points at the mirror.
#
# This script therefore copies every upstream appcast field verbatim
# (shortVersionString, version, minimumSystemVersion, pubDate, title,
# hardwareRequirements, enclosureLength, enclosureSignature) and only rewrites
# the enclosure URL to the mirrored archive location. It intentionally emits a
# full-update-only appcast: the probe does not capture upstream deltas, and the
# client gracefully falls back to the full archive when no delta matches.
#
# Usage:
#   build-appcast.sh <arch> <manifest> <public-base-url> <output-path>
#     arch             arm64 | x64
#     manifest         path to release-manifest.json (schemaVersion 2)
#     public-base-url  e.g. https://codexapp.agentsmirror.com (no trailing /latest)
#     output-path      where to write the appcast XML

arch="${1:?arch (arm64|x64) is required}"
manifest="${2:?manifest path is required}"
public_base_url="${3:?public base URL is required}"
output_path="${4:?output path is required}"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require jq
require python3

case "$arch" in
  arm64)
    manifest_key="arm64"
    archive_arch="arm64"
    mirror_dir="mac/arm64"
    ;;
  x64)
    manifest_key="x64"
    archive_arch="x64"
    mirror_dir="mac/intel"
    ;;
  *)
    echo "Unknown arch '$arch' (expected arm64 or x64)." >&2
    exit 2
    ;;
esac

if [[ ! -f "$manifest" ]]; then
  echo "Missing manifest: $manifest" >&2
  exit 1
fi

# Strip any trailing slash (and an accidental trailing /latest) so we can build
# a single canonical "<base>/latest/<dir>/<file>" enclosure URL.
base="${public_base_url%/}"
base="${base%/latest}"

short_version="$(jq -r --arg a "$manifest_key" '.sources.macos[$a].appcast.shortVersionString // ""' "$manifest")"
build_version="$(jq -r --arg a "$manifest_key" '.sources.macos[$a].appcast.version // ""' "$manifest")"
enclosure_length="$(jq -r --arg a "$manifest_key" '.sources.macos[$a].appcast.enclosureLength // 0' "$manifest")"
enclosure_signature="$(jq -r --arg a "$manifest_key" '.sources.macos[$a].appcast.enclosureSignature // ""' "$manifest")"
minimum_system_version="$(jq -r --arg a "$manifest_key" '.sources.macos[$a].appcast.minimumSystemVersion // ""' "$manifest")"
hardware_requirements="$(jq -r --arg a "$manifest_key" '.sources.macos[$a].appcast.hardwareRequirements // ""' "$manifest")"
pub_date="$(jq -r --arg a "$manifest_key" '.sources.macos[$a].appcast.pubDate // ""' "$manifest")"
title="$(jq -r --arg a "$manifest_key" '.sources.macos[$a].appcast.title // ""' "$manifest")"

# These four are the bare minimum a valid, verifiable appcast item needs. Fail
# loudly if upstream metadata is missing so a broken feed never ships silently.
if [[ -z "$short_version" || -z "$build_version" || -z "$enclosure_signature" ]]; then
  echo "Missing macOS $arch appcast metadata in $manifest (shortVersionString/version/enclosureSignature)." >&2
  exit 1
fi
if [[ ! "$enclosure_length" =~ ^[0-9]+$ ]] || [[ "$enclosure_length" -le 0 ]]; then
  echo "Invalid macOS $arch enclosure length in $manifest: '$enclosure_length'." >&2
  exit 1
fi

# Title defaults to the short version (matches upstream behaviour).
if [[ -z "$title" ]]; then
  title="$short_version"
fi

enclosure_url="$base/latest/$mirror_dir/Codex-darwin-${archive_arch}-${short_version}.zip"

python3 - \
  "$output_path" \
  "$title" \
  "$pub_date" \
  "$build_version" \
  "$short_version" \
  "$minimum_system_version" \
  "$hardware_requirements" \
  "$enclosure_url" \
  "$enclosure_length" \
  "$enclosure_signature" <<'PY'
import sys
from xml.sax.saxutils import escape, quoteattr

(
    out_path,
    title,
    pub_date,
    build_version,
    short_version,
    minimum_system_version,
    hardware_requirements,
    enclosure_url,
    enclosure_length,
    enclosure_signature,
) = sys.argv[1:]

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"

lines = []
lines.append("<?xml version='1.0' encoding='utf-8'?>")
lines.append(f'<rss xmlns:sparkle="{SPARKLE_NS}" version="2.0">')
lines.append("    <channel>")
lines.append("        <title>Codex</title>")
lines.append("        <item>")
lines.append(f"            <title>{escape(title)}</title>")
if pub_date:
    lines.append(f"            <pubDate>{escape(pub_date)}</pubDate>")
lines.append(f"            <sparkle:version>{escape(build_version)}</sparkle:version>")
lines.append(
    f"            <sparkle:shortVersionString>{escape(short_version)}</sparkle:shortVersionString>"
)
if minimum_system_version:
    lines.append(
        f"            <sparkle:minimumSystemVersion>{escape(minimum_system_version)}</sparkle:minimumSystemVersion>"
    )
if hardware_requirements:
    lines.append(
        f"            <sparkle:hardwareRequirements>{escape(hardware_requirements)}</sparkle:hardwareRequirements>"
    )
enclosure_attrs = " ".join(
    [
        f"url={quoteattr(enclosure_url)}",
        f"length={quoteattr(str(enclosure_length))}",
        'type="application/octet-stream"',
        f"sparkle:edSignature={quoteattr(enclosure_signature)}",
    ]
)
lines.append(f"            <enclosure {enclosure_attrs} />")
lines.append("        </item>")
lines.append("    </channel>")
lines.append("</rss>")

with open(out_path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines))
    handle.write("\n")
PY

echo "Wrote $arch appcast to $output_path (enclosure: $enclosure_url)" >&2
cat "$output_path"
