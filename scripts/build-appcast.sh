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
# This script therefore copies upstream appcast metadata and only rewrites the
# enclosure URL to the mirrored archive location. Length fields come from the
# probe manifest's verified source object sizes, because upstream appcast lengths
# can lag the actual object headers while the EdDSA signature still matches the
# copied archive bytes.
#
# When the probe captured upstream <sparkle:deltas>, this script re-emits them
# too: one delta <enclosure> per entry with the URL host swapped to the mirror
# and every other attribute (notably each delta's own sparkle:edSignature) kept
# byte-for-byte. The mirror never runs BinaryDelta and never recomputes a
# signature; it copies the official delta bytes + signatures verbatim. The full
# <enclosure> is always present, so a client with no matching delta still falls
# back to the full archive.
#
# Usage:
#   build-appcast.sh <arch> <manifest> <public-base-url> <output-path>
#     arch             arm64 | x64
#     manifest         path to release-manifest.json (schemaVersion 2+)
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

validate_safe_basename() {
  local label="$1"
  local value="$2"
  local extension="$3"

  if [[ -z "$value" || "$value" == "null" ||
        "$value" == *"/"* || "$value" == *\\* || "$value" == *".."* ||
        "$value" != *".$extension" ]] ||
     LC_ALL=C printf '%s' "$value" | grep -q '[[:cntrl:]]'; then
    echo "Invalid $label basename: '$value'." >&2
    return 1
  fi
}

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
enclosure_basename="$(jq -r --arg a "$manifest_key" '.sources.macos[$a].appcast.mirrorEnclosureBasename // ""' "$manifest")"
enclosure_length="$(jq -r --arg a "$manifest_key" '.sources.macos[$a].appcast.enclosureLength // 0' "$manifest")"
enclosure_signature="$(jq -r --arg a "$manifest_key" '.sources.macos[$a].appcast.enclosureSignature // ""' "$manifest")"
minimum_system_version="$(jq -r --arg a "$manifest_key" '.sources.macos[$a].appcast.minimumSystemVersion // ""' "$manifest")"
hardware_requirements="$(jq -r --arg a "$manifest_key" '.sources.macos[$a].appcast.hardwareRequirements // ""' "$manifest")"
pub_date="$(jq -r --arg a "$manifest_key" '.sources.macos[$a].appcast.pubDate // ""' "$manifest")"
title="$(jq -r --arg a "$manifest_key" '.sources.macos[$a].appcast.title // ""' "$manifest")"

# These four are the bare minimum a valid, verifiable appcast item needs. Fail
# loudly if upstream metadata is missing so a broken feed never ships silently.
if [[ -z "$short_version" || -z "$build_version" || -z "$enclosure_signature" || -z "$enclosure_basename" ]]; then
  echo "Missing macOS $arch appcast metadata in $manifest (shortVersionString/version/enclosureSignature/mirrorEnclosureBasename)." >&2
  exit 1
fi
validate_safe_basename "macOS $arch mirror enclosure" "$enclosure_basename" zip || exit 1
if [[ ! "$enclosure_length" =~ ^[0-9]+$ ]] || [[ "$enclosure_length" -le 0 ]]; then
  echo "Invalid macOS $arch enclosure length in $manifest: '$enclosure_length'." >&2
  exit 1
fi

# Title defaults to the short version (matches upstream behaviour).
if [[ -z "$title" ]]; then
  title="$short_version"
fi

enclosure_url="$base/latest/$mirror_dir/$enclosure_basename"

# Delta enclosures the official appcast advertises under <sparkle:deltas>. The
# probe captured each one verbatim (every attribute, including the official
# edSignature). We re-emit them unchanged except for swapping the enclosure URL
# host to the mirror; the bytes (and therefore the signature) are untouched and
# we never run BinaryDelta. Empty/missing array => a full-update-only feed, which
# is exactly today's behaviour, so existing releases stay byte-identical.
deltas_json="$(jq -c --arg a "$manifest_key" '.sources.macos[$a].appcast.deltas // []' "$manifest")"

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
  "$enclosure_signature" \
  "$base" \
  "$mirror_dir" \
  "$deltas_json" <<'PY'
import json
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
    mirror_base,
    mirror_dir,
    deltas_json,
) = sys.argv[1:]

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"

deltas = json.loads(deltas_json) if deltas_json else []


def delta_enclosure_line(delta):
    # Resolve the mirror URL from the official basename so URL resolution through
    # the Worker stays stable. Preserve the basename exactly as published.
    basename = delta.get("basename") or (delta.get("url", "").rsplit("/", 1)[-1])
    if not basename:
        raise SystemExit("delta enclosure missing basename/url")
    mirror_url = f"{mirror_base}/latest/{mirror_dir}/{basename}"

    # Start from every attribute the probe captured (verbatim, sparkle: prefixes
    # preserved) so we faithfully reproduce OpenAI's enclosure, then override the
    # URL with the mirror location. Fall back to the explicit prompt-named fields
    # if an older manifest predates the full "attributes" map.
    attrs = dict(delta.get("attributes") or {})
    if not attrs:
        attrs = {
            "url": delta.get("url", ""),
            "sparkle:deltaFrom": delta.get("deltaFrom", ""),
            "length": str(delta.get("length", "")),
            "type": delta.get("type", "") or "application/octet-stream",
            "sparkle:edSignature": delta.get("edSignature", ""),
        }
        if delta.get("version"):
            attrs["sparkle:version"] = delta["version"]
        if delta.get("os"):
            attrs["sparkle:os"] = delta["os"]
        attrs = {k: v for k, v in attrs.items() if v != ""}
    attrs["url"] = mirror_url

    # Emit a stable, readable attribute order: url first, then the Sparkle
    # delta-identifying / signature attributes, then any remaining official
    # attributes (sorted) so nothing OpenAI published is dropped.
    preferred = [
        "url",
        "sparkle:deltaFrom",
        "sparkle:version",
        "sparkle:os",
        "length",
        "type",
        "sparkle:edSignature",
    ]
    ordered = [k for k in preferred if k in attrs]
    ordered += [k for k in sorted(attrs) if k not in preferred]
    rendered = " ".join(f"{k}={quoteattr(str(attrs[k]))}" for k in ordered)
    return f"                <enclosure {rendered} />"

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
# Delta enclosures (incremental updates). Emitted only when upstream advertised
# them; the full <enclosure> above is always present so clients without a
# matching delta still fall back to the full archive.
if deltas:
    lines.append("            <sparkle:deltas>")
    for delta in deltas:
        lines.append(delta_enclosure_line(delta))
    lines.append("            </sparkle:deltas>")
lines.append("        </item>")
lines.append("    </channel>")
lines.append("</rss>")

with open(out_path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines))
    handle.write("\n")
PY

echo "Wrote $arch appcast to $output_path (enclosure: $enclosure_url)" >&2
cat "$output_path"
