#!/usr/bin/env bash
set -euo pipefail

manifest_path="${1:-probe-manifest.json}"
expected_version="${EXPECTED_MACOS_VERSION:?EXPECTED_MACOS_VERSION is required}"
arm_appcast_url="${BETA_ARM_APPCAST_URL:-https://persistent.oaistatic.com/codex-app-beta/appcast.xml}"
x64_appcast_url="${BETA_X64_APPCAST_URL:-https://persistent.oaistatic.com/codex-app-beta/appcast-x64.xml}"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

for command in curl jq python3; do
  require "$command"
done

[[ -f "$manifest_path" ]] || {
  echo "Probe manifest not found: $manifest_path" >&2
  exit 1
}

if [[ ! "$expected_version" =~ ^[0-9]+([.][0-9]+)+$ ]]; then
  echo "Invalid expected macOS Beta version: $expected_version" >&2
  exit 2
fi

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

curl_args=(
  --fail
  --location
  --silent
  --show-error
  --retry 5
  --retry-delay 2
  --retry-max-time 300
  --connect-timeout 20
  --max-time 180
  --retry-all-errors
)

curl "${curl_args[@]}" "$arm_appcast_url" -o "$tmp_dir/appcast-arm64.xml"
curl "${curl_args[@]}" "$x64_appcast_url" -o "$tmp_dir/appcast-x64.xml"

python3 - \
  "$tmp_dir/appcast-arm64.xml" \
  "$tmp_dir/appcast-x64.xml" \
  "$expected_version" \
  "$arm_appcast_url" \
  "$x64_appcast_url" \
  > "$tmp_dir/macos.json" <<'PY'
import json
import sys
import xml.etree.ElementTree as ET
from urllib.parse import urlsplit, urlunsplit

arm_path, x64_path, expected_version, arm_feed_url, x64_feed_url = sys.argv[1:]
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def sparkle(name):
    return f"{{{SPARKLE}}}{name}"


def safe_https_beta_url(value, extension, label):
    parts = urlsplit(value)
    if parts.scheme != "https" or parts.netloc != "persistent.oaistatic.com":
        raise SystemExit(f"{label} is not an official HTTPS asset URL: {value!r}")
    if not parts.path.startswith("/codex-app-beta/"):
        raise SystemExit(f"{label} is outside the official Beta path: {value!r}")
    basename = parts.path.rsplit("/", 1)[-1]
    if not basename or not basename.endswith(f".{extension}"):
        raise SystemExit(f"{label} has invalid .{extension} basename: {basename!r}")
    if any(part in basename for part in ("/", "\\", "..")) or any(
        ord(char) < 32 or ord(char) == 127 for char in basename
    ):
        raise SystemExit(f"{label} has unsafe basename: {basename!r}")
    return basename


def derive_dmg_url(enclosure_url, arch, version):
    parts = urlsplit(enclosure_url)
    basename = parts.path.rsplit("/", 1)[-1]
    suffix = f"-darwin-{arch}-{version}.zip"
    if not basename.endswith(suffix):
        raise SystemExit(
            f"macOS {arch} Beta enclosure {basename!r} does not end with {suffix!r}"
        )
    prefix = basename[: -len(suffix)]
    if not prefix:
        raise SystemExit(f"macOS {arch} Beta enclosure has no product prefix")
    directory = parts.path.rsplit("/", 1)[0]
    dmg_basename = f"{prefix}-{version}-{arch}.dmg"
    return urlunsplit((parts.scheme, parts.netloc, f"{directory}/{dmg_basename}", "", ""))


def parse_feed(path, feed_url, arch):
    root = ET.parse(path).getroot()
    channel = root.find("./channel")
    if channel is None:
        raise SystemExit(f"macOS {arch} Beta appcast has no channel")
    channel_title = channel.findtext("title") or ""
    if "Beta" not in channel_title:
        raise SystemExit(
            f"macOS {arch} feed is not the Public Beta channel: {channel_title!r}"
        )

    items = channel.findall("item")
    if not items:
        raise SystemExit(f"macOS {arch} Beta appcast has no current item")
    selected = items[0]
    selected_version = (
        selected.findtext(sparkle("shortVersionString"))
        or selected.findtext("title")
        or ""
    )
    if selected_version != expected_version:
        raise SystemExit(
            f"macOS {arch} current Beta version drift: "
            f"expected {expected_version}, got {selected_version or '<empty>'}"
        )

    version = selected.findtext(sparkle("shortVersionString")) or ""
    build = selected.findtext(sparkle("version")) or ""
    minimum = selected.findtext(sparkle("minimumSystemVersion")) or ""
    hardware = selected.findtext(sparkle("hardwareRequirements")) or ""
    enclosure = selected.find("enclosure")
    if enclosure is None:
        raise SystemExit(f"macOS {arch} Beta appcast item has no enclosure")
    enclosure_url = enclosure.attrib.get("url", "")
    source_basename = safe_https_beta_url(
        enclosure_url, "zip", f"macOS {arch} Beta Sparkle archive"
    )
    signature = enclosure.attrib.get(sparkle("edSignature"), "")
    length = enclosure.attrib.get("length", "")
    if not build or not signature or not length.isdigit() or int(length) <= 0:
        raise SystemExit(f"macOS {arch} Beta appcast metadata is incomplete")
    if arch == "arm64" and hardware != "arm64":
        raise SystemExit(f"macOS arm64 Beta feed has unexpected hardware requirement {hardware!r}")
    if arch == "x64" and hardware not in ("", "x86_64"):
        raise SystemExit(f"macOS x64 Beta feed has unexpected hardware requirement {hardware!r}")

    dmg_url = derive_dmg_url(enclosure_url, arch, version)
    dmg_source_basename = safe_https_beta_url(dmg_url, "dmg", f"macOS {arch} Beta DMG")
    return {
        "url": dmg_url,
        "sourceBasename": dmg_source_basename,
        "mirrorBasename": f"ChatGPT-Beta-mac-{arch}.dmg",
        "appcastUrl": feed_url,
        "appcast": {
            "channelTitle": channel_title,
            "title": selected.findtext("title") or "",
            "pubDate": selected.findtext("pubDate") or "",
            "version": build,
            "shortVersionString": version,
            "minimumSystemVersion": minimum,
            "hardwareRequirements": hardware,
            "enclosureUrl": enclosure_url,
            "sourceBasename": source_basename,
            "mirrorEnclosureBasename": f"ChatGPT-Beta-darwin-{arch}-{version}.zip",
            "enclosureLength": int(length),
            "enclosureSignature": signature,
            "deltas": [],
        },
    }


payload = {
    "arm64": parse_feed(arm_path, arm_feed_url, "arm64"),
    "x64": parse_feed(x64_path, x64_feed_url, "x64"),
}
if payload["arm64"]["appcast"]["version"] != payload["x64"]["appcast"]["version"]:
    raise SystemExit("macOS Beta arm64 and x64 appcast builds do not match")
print(json.dumps(payload, sort_keys=True))
PY

source_object_metadata() {
  local label="$1"
  local url="$2"
  local headers="$tmp_dir/headers-$(printf '%s' "$label" | tr -cs '[:alnum:]' '-').txt"
  local content_range content_length size last_modified etag

  curl "${curl_args[@]}" --range 0-0 --dump-header "$headers" --output /dev/null "$url"
  content_range="$(tr -d '\r' < "$headers" | awk 'tolower($1) == "content-range:" { value=$0 } END { print value }')"
  content_length="$(tr -d '\r' < "$headers" | awk 'tolower($1) == "content-length:" { value=$2 } END { print value }')"
  size="${content_range##*/}"
  if [[ ! "$size" =~ ^[0-9]+$ ]]; then
    size="$content_length"
  fi
  if [[ ! "$size" =~ ^[1-9][0-9]*$ ]]; then
    echo "$label did not return a valid source object size." >&2
    exit 1
  fi
  last_modified="$(tr -d '\r' < "$headers" | sed -n 's/^[Ll]ast-[Mm]odified:[[:space:]]*//p' | tail -n 1)"
  etag="$(tr -d '\r' < "$headers" | sed -n 's/^[Ee][Tt]ag:[[:space:]]*//p' | tail -n 1)"
  jq -n --argjson size "$size" --arg lastModified "$last_modified" --arg etag "$etag" \
    '{contentLength: $size, lastModified: $lastModified, etag: $etag}'
}

for arch in arm64 x64; do
  dmg_url="$(jq -r --arg arch "$arch" '.[$arch].url' "$tmp_dir/macos.json")"
  zip_url="$(jq -r --arg arch "$arch" '.[$arch].appcast.enclosureUrl' "$tmp_dir/macos.json")"
  source_object_metadata "macOS-$arch-Beta-DMG" "$dmg_url" > "$tmp_dir/$arch-dmg-metadata.json"
  source_object_metadata "macOS-$arch-Beta-ZIP" "$zip_url" > "$tmp_dir/$arch-zip-metadata.json"
  source_zip_size="$(jq -r '.contentLength' "$tmp_dir/$arch-zip-metadata.json")"
  appcast_zip_size="$(jq -r --arg arch "$arch" '.[$arch].appcast.enclosureLength' "$tmp_dir/macos.json")"
  if [[ "$source_zip_size" != "$appcast_zip_size" ]]; then
    echo "macOS $arch Beta appcast length $appcast_zip_size differs from source size $source_zip_size; using source size." >&2
  fi
  jq \
    --arg arch "$arch" \
    --slurpfile dmg "$tmp_dir/$arch-dmg-metadata.json" \
    --slurpfile zip "$tmp_dir/$arch-zip-metadata.json" '
      .[$arch] += $dmg[0]
      | .[$arch].appcast.enclosureLength = $zip[0].contentLength
      | .[$arch].appcast.sourceLastModified = $zip[0].lastModified
      | .[$arch].appcast.sourceEtag = $zip[0].etag
    ' "$tmp_dir/macos.json" > "$tmp_dir/macos.next.json"
  mv "$tmp_dir/macos.next.json" "$tmp_dir/macos.json"
done

jq \
  --arg expectedVersion "$expected_version" \
  --slurpfile macos "$tmp_dir/macos.json" '
    if .channel != "beta"
      or .beta.contract != "issue-36-beta-prerelease" then
      error("manifest is not the issue #36 Beta prerelease contract")
    elif .derived.prerelease != true
      or .derived.publishLatest != false
      or .derived.syncLatest != false then
      error("Beta publication policy is not fail-closed")
    else . end
    | .beta.expectedMacosVersion = $expectedVersion
    | .derived.includeMacosArm64 = true
    | .derived.includeMacosX64 = true
    | .sources.macos = $macos[0]
  ' "$manifest_path" > "$tmp_dir/manifest.next.json"
mv "$tmp_dir/manifest.next.json" "$manifest_path"

jq -e \
  --arg version "$expected_version" '
    .channel == "beta"
    and .publication.githubPrereleaseOnly == true
    and .publication.objectStoragePublished == false
    and .sources.macos.arm64.appcast.shortVersionString == $version
    and .sources.macos.x64.appcast.shortVersionString == $version
    and (.sources.macos.arm64.appcast.channelTitle | contains("Beta"))
    and (.sources.macos.x64.appcast.channelTitle | contains("Beta"))
    and (.sources.macos.arm64.url | startswith("https://persistent.oaistatic.com/codex-app-beta/"))
    and (.sources.macos.x64.url | startswith("https://persistent.oaistatic.com/codex-app-beta/"))
  ' "$manifest_path" >/dev/null

jq '{channel, beta, publication, derived, macos: (.sources.macos | map_values({url, mirrorBasename, contentLength, appcast}))}' "$manifest_path"
