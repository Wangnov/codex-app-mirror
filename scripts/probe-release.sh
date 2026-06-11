#!/usr/bin/env bash
set -euo pipefail

product_id="9PLM9XGG6VKS"
architecture="x64"
arm_appcast_url="https://persistent.oaistatic.com/codex-app-prod/appcast.xml"
x64_appcast_url="https://persistent.oaistatic.com/codex-app-prod/appcast-x64.xml"
windows_update_manifest_url="https://persistent.oaistatic.com/codex-app-prod/windows-store-update.json"
r2_public_base_url="${R2_PUBLIC_BASE_URL:-https://codexapp.agentsmirror.com}"
force_release="${FORCE_RELEASE:-false}"
release_tag_input="${RELEASE_TAG:-}"
manifest_path="${MANIFEST_PATH:-release-manifest.json}"
curl_retry_args=(
  --retry 5
  --retry-delay 2
  --retry-max-time 300
  --connect-timeout 20
  --max-time 120
  --retry-all-errors
)

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

redact_url() {
  sed -E 's/[?].*/?<redacted>/' <<<"$1"
}

curl_get() {
  local label="$1"
  local url="$2"

  echo "Fetching $label: $(redact_url "$url")" >&2
  curl -fsSL "${curl_retry_args[@]}" "$url"
}

curl_head() {
  local label="$1"
  local url="$2"

  echo "Fetching $label headers: $(redact_url "$url")" >&2
  curl -fsSI -L "${curl_retry_args[@]}" "$url"
}

curl_range_headers() {
  local label="$1"
  local url="$2"
  local headers_file

  headers_file="$(mktemp)"
  echo "Fetching $label range headers: $(redact_url "$url")" >&2
  if curl -fsSL -L "${curl_retry_args[@]}" \
    --range 0-0 \
    -D "$headers_file" \
    -o /dev/null \
    "$url"; then
    cat "$headers_file"
    rm -f "$headers_file"
    return 0
  fi

  rm -f "$headers_file"
  return 1
}

header_value() {
  local headers="$1"
  local name="$2"

  tr -d '\r' <<<"$headers" |
    awk -v wanted="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" '
      BEGIN { value = "" }
      {
        line = $0
        lower = tolower(line)
        if (index(lower, wanted ":") == 1) {
          sub("^[^:]+:[[:space:]]*", "", line)
          value = line
        }
      }
      END { print value }
    '
}

json_number() {
  local value="$1"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s' "$value"
  else
    printf '0'
  fi
}

object_size_from_range_headers() {
  local headers="$1"
  local content_range
  local content_length

  content_range="$(header_value "$headers" "content-range")"
  if [[ "$content_range" =~ /([0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi

  content_length="$(header_value "$headers" "content-length")"
  if [[ "$content_length" =~ ^[0-9]+$ ]]; then
    printf '%s' "$content_length"
    return 0
  fi

  return 1
}

version_gt() {
  python3 - "$1" "$2" <<'PY'
import sys


def parse(version):
    parts = []
    for part in version.split("."):
        try:
            parts.append(int(part))
        except ValueError:
            parts.append(part)
    return parts


left = parse(sys.argv[1])
right = parse(sys.argv[2])
length = max(len(left), len(right))
left.extend([0] * (length - len(left)))
right.extend([0] * (length - len(right)))
raise SystemExit(0 if left > right else 1)
PY
}

appcast_latest() {
  local label="$1"
  local url="$2"
  curl_get "$label" "$url" |
    python3 -c '
import json
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ns = {"sparkle": SPARKLE}


def sparkle_attr(name):
    return "{%s}%s" % (SPARKLE, name)


def attr_key(raw):
    # Render the official attribute name back into appcast form, mapping the
    # ElementTree "{ns}local" spelling onto the "sparkle:local" prefix used in
    # the feed so the build step can re-emit it verbatim.
    if raw.startswith("{%s}" % SPARKLE):
        return "sparkle:" + raw[len("{%s}" % SPARKLE):]
    return raw


root = ET.parse(sys.stdin).getroot()
item = root.find("./channel/item")
if item is None:
    raise SystemExit("appcast has no item")
enclosure = item.find("enclosure")
if enclosure is None:
    raise SystemExit("appcast item has no enclosure")
sparkle_sig_key = sparkle_attr("edSignature")

# Capture every <sparkle:deltas>/<enclosure> verbatim. The mirror reuses the
# official bytes and the official edSignature untouched; it never runs
# BinaryDelta and never recomputes a signature. We record the prompt-named
# fields explicitly *and* a full "attributes" map (every attribute on the
# enclosure, with sparkle: prefixes preserved) so the build step can re-emit
# each delta exactly as OpenAI published it, swapping only the URL host.
deltas = []
deltas_el = item.find("sparkle:deltas", namespaces=ns)
if deltas_el is not None:
    for delta in deltas_el.findall("enclosure"):
        url = delta.attrib.get("url", "")
        basename = url.rsplit("/", 1)[-1] if url else ""
        attributes = {attr_key(k): v for k, v in delta.attrib.items()}
        deltas.append(
            {
                "basename": basename,
                "url": url,
                "length": int(delta.attrib.get("length", "0") or "0"),
                "deltaFrom": delta.attrib.get(sparkle_attr("deltaFrom"), ""),
                "version": delta.attrib.get(sparkle_attr("version"), ""),
                "os": delta.attrib.get(sparkle_attr("os"), ""),
                "type": delta.attrib.get("type", ""),
                "edSignature": delta.attrib.get(sparkle_sig_key, ""),
                "attributes": attributes,
            }
        )

payload = {
    "title": item.findtext("title") or "",
    "pubDate": item.findtext("pubDate") or "",
    "version": item.findtext("sparkle:version", namespaces=ns) or "",
    "shortVersionString": item.findtext("sparkle:shortVersionString", namespaces=ns) or "",
    "minimumSystemVersion": item.findtext("sparkle:minimumSystemVersion", namespaces=ns) or "",
    "hardwareRequirements": item.findtext("sparkle:hardwareRequirements", namespaces=ns) or "",
    "enclosureUrl": enclosure.attrib.get("url", ""),
    "enclosureLength": int(enclosure.attrib.get("length", "0") or "0"),
    "enclosureSignature": enclosure.attrib.get(sparkle_sig_key, ""),
    "deltas": deltas,
}
print(json.dumps(payload, sort_keys=True))
'
}

asset_size() {
  local assets_json="$1"
  local asset_name="$2"
  jq -r --arg name "$asset_name" '.[] | select(.name == $name) | .size' <<<"$assets_json" | head -n 1
}

github_api_json_allow_404() {
  local err_file
  local output
  local status

  err_file="$(mktemp)"
  if output="$(gh api "$@" 2>"$err_file")"; then
    rm -f "$err_file"
    printf '%s\n' "$output"
    return 0
  fi

  status=$?
  if grep -q 'HTTP 404' "$err_file"; then
    rm -f "$err_file"
    return 1
  fi

  cat "$err_file" >&2
  rm -f "$err_file"
  return "$status"
}

latest_release_tag() {
  local release_json
  local status

  if release_json="$(github_api_json_allow_404 'repos/{owner}/{repo}/releases/latest')"; then
    jq -r '.tag_name // ""' <<<"$release_json"
    return 0
  fi

  status=$?
  if [[ "$status" -eq 1 ]]; then
    printf ''
    return 0
  fi

  return "$status"
}

github_release_json() {
  local tag="$1"
  gh api "repos/{owner}/{repo}/releases/tags/$tag"
}

release_assets_json() {
  local tag="$1"
  github_release_json "$tag" | jq -c '.assets // []'
}

download_release_asset() {
  local tag="$1"
  local asset_name="$2"
  local dest_dir="$3"
  local release_json
  local asset_api_url

  release_json="$(github_release_json "$tag")"
  asset_api_url="$(jq -r --arg name "$asset_name" '.assets[]? | select(.name == $name) | .url' <<<"$release_json" | head -n 1)"
  if [[ -z "$asset_api_url" || "$asset_api_url" == "null" ]]; then
    return 1
  fi

  mkdir -p "$dest_dir"
  gh api -H "Accept: application/octet-stream" "$asset_api_url" > "$dest_dir/$asset_name"
}

release_exists() {
  local status

  if github_api_json_allow_404 "repos/{owner}/{repo}/releases/tags/$1" >/dev/null; then
    return 0
  fi

  status=$?
  if [[ "$status" -eq 1 ]]; then
    return 1
  fi

  exit "$status"
}

sanitize_tag_part() {
  tr -cs 'A-Za-z0-9._-' '-' <<<"$1" | sed -E 's/^-+//; s/-+$//'
}

validate_release_tag() {
  local tag="$1"

  if [[ ! "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
    echo "Invalid release tag '$tag'. Use 1-128 ASCII letters, numbers, dots, underscores, or hyphens; the first character must be alphanumeric." >&2
    exit 1
  fi
}

predicted_release_tag() {
  local windows_version="$1"
  local arm_version="$2"
  local arm_build="$3"
  local x64_version="$4"
  local x64_build="$5"
  local windows_tag
  local mac_tag

  windows_tag="$(sanitize_tag_part "$windows_version")"
  if [[ "$arm_version" == "$x64_version" && "$arm_build" == "$x64_build" ]]; then
    mac_tag="mac-$(sanitize_tag_part "$arm_version")-b$(sanitize_tag_part "$arm_build")"
  else
    mac_tag="mac-arm64-$(sanitize_tag_part "$arm_version")-b$(sanitize_tag_part "$arm_build")-x64-$(sanitize_tag_part "$x64_version")-b$(sanitize_tag_part "$x64_build")"
  fi

  printf 'codex-app-win-%s-%s\n' "$windows_tag" "$mac_tag"
}

windows_update_wait_notice() {
  jq -r '
    .sources.windows as $w
    | ($w.version // "") as $package
    | ($w.updateManifest.buildVersion // "") as $advertised
    | if $advertised != "" and $package != "" and $advertised != $package then
        "Windows update manifest advertises \($advertised), but Store package is still \($package); waiting for downloadable MSIX."
      else
        ""
      end
  ' "$1"
}

manifest_key() {
  jq -S -c '{
    windows: {
      version: .sources.windows.version,
      packageMoniker: .sources.windows.packageMoniker,
      contentLength: .sources.windows.contentLength
    },
    macos: {
      arm64: {
        appcast: .sources.macos.arm64.appcast,
        contentLength: .sources.macos.arm64.contentLength,
        etag: .sources.macos.arm64.etag,
        lastModified: .sources.macos.arm64.lastModified
      },
      x64: {
        appcast: .sources.macos.x64.appcast,
        contentLength: .sources.macos.x64.contentLength,
        etag: .sources.macos.x64.etag,
        lastModified: .sources.macos.x64.lastModified
      }
    }
  }' "$1"
}

public_mirror_manifest_key_matches() {
  local manifest="$1"
  local live_manifest
  local current_key
  local live_key

  live_manifest="$(mktemp)"
  if ! curl_get "public mirror manifest" "$r2_public_base_url/latest/manifest?probe=$$" > "$live_manifest"; then
    rm -f "$live_manifest"
    return 1
  fi

  if ! current_key="$(manifest_key "$manifest")" || ! live_key="$(manifest_key "$live_manifest")"; then
    rm -f "$live_manifest"
    return 1
  fi

  rm -f "$live_manifest"
  [[ "$current_key" == "$live_key" ]]
}

public_mirror_appcasts_match() {
  local manifest="$1"
  local dir

  dir="$(mktemp -d)"
  if ! bash scripts/build-appcast.sh arm64 "$manifest" "$r2_public_base_url" "$dir/appcast.xml" >/dev/null; then
    rm -rf "$dir"
    return 1
  fi
  if ! bash scripts/build-appcast.sh x64 "$manifest" "$r2_public_base_url" "$dir/appcast-x64.xml" >/dev/null; then
    rm -rf "$dir"
    return 1
  fi

  if ! curl_get "public mirror arm64 appcast" "$r2_public_base_url/latest/appcast.xml?probe=$$" > "$dir/live-appcast.xml"; then
    rm -rf "$dir"
    return 1
  fi
  if ! curl_get "public mirror x64 appcast" "$r2_public_base_url/latest/appcast-x64.xml?probe=$$" > "$dir/live-appcast-x64.xml"; then
    rm -rf "$dir"
    return 1
  fi

  if cmp -s "$dir/appcast.xml" "$dir/live-appcast.xml" &&
     cmp -s "$dir/appcast-x64.xml" "$dir/live-appcast-x64.xml"; then
    rm -rf "$dir"
    return 0
  fi

  rm -rf "$dir"
  return 1
}

public_mirror_object_exists() {
  local label="$1"
  local object_path="$2"

  curl_range_headers "$label" "$r2_public_base_url/$object_path?probe=$$" >/dev/null
}

public_mirror_object_size_matches() {
  local label="$1"
  local object_path="$2"
  local expected_size="$3"
  local headers
  local actual_size

  if [[ ! "$expected_size" =~ ^[1-9][0-9]*$ ]]; then
    public_mirror_object_exists "$label" "$object_path"
    return
  fi

  if ! headers="$(curl_range_headers "$label" "$r2_public_base_url/$object_path?probe=$$")"; then
    return 1
  fi
  if ! actual_size="$(object_size_from_range_headers "$headers")"; then
    return 1
  fi

  [[ "$actual_size" == "$expected_size" ]]
}

public_mirror_checksums_match() {
  local tag="$1"
  local dir

  [[ -n "$tag" ]] || return 1

  dir="$(mktemp -d)"
  if ! download_release_asset "$tag" SHA256SUMS.txt "$dir" >/dev/null 2>&1; then
    rm -rf "$dir"
    return 1
  fi

  if ! curl_get "public mirror checksums" "$r2_public_base_url/latest/checksums?probe=$$" > "$dir/live-SHA256SUMS.txt"; then
    rm -rf "$dir"
    return 1
  fi

  if cmp -s "$dir/SHA256SUMS.txt" "$dir/live-SHA256SUMS.txt"; then
    rm -rf "$dir"
    return 0
  fi

  rm -rf "$dir"
  return 1
}

public_mirror_delta_objects_match() {
  local manifest="$1"
  local arch_key="$2"
  local mirror_dir="$3"
  local basename
  local expected_size

  while IFS=$'\t' read -r basename expected_size; do
    [[ -n "$basename" ]] || return 1
    public_mirror_object_size_matches \
      "public mirror macOS $arch_key delta $basename" \
      "latest/mac/$mirror_dir/$basename" \
      "$expected_size" || return 1
  done < <(
    jq -r --arg a "$arch_key" '
      .sources.macos[$a].appcast.deltas[]?
      | [(.basename // ((.url // "") | split("/")[-1]) // ""), (.length // 0)]
      | @tsv
    ' "$manifest"
  )
}

public_mirror_objects_match() {
  local manifest="$1"
  local arm_short_version
  local x64_short_version

  arm_short_version="$(jq -r '.sources.macos.arm64.appcast.shortVersionString // ""' "$manifest")"
  x64_short_version="$(jq -r '.sources.macos.x64.appcast.shortVersionString // ""' "$manifest")"

  [[ -n "$arm_short_version" && -n "$x64_short_version" ]] || return 1

  public_mirror_object_size_matches \
    "public mirror Windows alias" \
    "latest/win" \
    "$(jq -r '.sources.windows.contentLength // 0' "$manifest")" &&
  public_mirror_object_size_matches \
    "public mirror macOS arm64 DMG alias" \
    "latest/mac-arm64" \
    "$(jq -r '.sources.macos.arm64.contentLength // 0' "$manifest")" &&
  public_mirror_object_size_matches \
    "public mirror macOS x64 DMG alias" \
    "latest/mac-intel" \
    "$(jq -r '.sources.macos.x64.contentLength // 0' "$manifest")" &&
  public_mirror_object_size_matches \
    "public mirror macOS arm64 Sparkle archive" \
    "latest/mac/arm64/Codex-darwin-arm64-${arm_short_version}.zip" \
    "$(jq -r '.sources.macos.arm64.appcast.enclosureLength // 0' "$manifest")" &&
  public_mirror_object_size_matches \
    "public mirror macOS x64 Sparkle archive" \
    "latest/mac/intel/Codex-darwin-x64-${x64_short_version}.zip" \
    "$(jq -r '.sources.macos.x64.appcast.enclosureLength // 0' "$manifest")" &&
  public_mirror_delta_objects_match "$manifest" arm64 arm64 &&
  public_mirror_delta_objects_match "$manifest" x64 intel
}

public_mirror_latest_matches() {
  local manifest="$1"
  local tag="$2"

  public_mirror_manifest_key_matches "$manifest" &&
    public_mirror_appcasts_match "$manifest" &&
    public_mirror_checksums_match "$tag" &&
    public_mirror_objects_match "$manifest"
}

github_output_value() {
  local name="$1"
  local value="$2"
  local delimiter="__codex_output_${name}_$$_$(date +%s%N)__"

  printf '%s<<%s\n%s\n%s\n' "$name" "$delimiter" "$value" "$delimiter"
}

if [[ -n "$release_tag_input" ]]; then
  validate_release_tag "$release_tag_input"
fi

require curl
require dotnet
require gh
require jq
require python3

resolve_store_link() {
  local attempt
  local max_attempts="${STORE_LINK_MAX_ATTEMPTS:-3}"
  local delay="${STORE_LINK_RETRY_DELAY_SECONDS:-10}"

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    echo "Resolving Microsoft Store package link (attempt $attempt/$max_attempts)" >&2
    if dotnet run --project scripts/store-link -- "$product_id" "$architecture"; then
      return 0
    fi

    if ((attempt == max_attempts)); then
      break
    fi

    echo "Microsoft Store resolver failed; retrying in ${delay}s." >&2
    sleep "$delay"
    delay=$((delay * 2))
  done

  return 1
}

link_line="$(resolve_store_link |
  awk '/^OpenAI\.Codex_/ { print; exit }')"

if [[ -z "$link_line" ]]; then
  echo "No Microsoft Store package link was resolved." >&2
  exit 1
fi

windows_package="${link_line%%$'\t'*}"
windows_url="${link_line#*$'\t'}"
windows_version="$(sed -E 's/^OpenAI\.Codex_([^_]+)_.*/\1/' <<<"$windows_package")"
windows_update_json="$(curl_get "Windows update manifest" "$windows_update_manifest_url")"
windows_update_version="$(jq -r '.buildVersion // empty' <<<"$windows_update_json")"
windows_update_product_id="$(jq -r '.storeProductId // empty' <<<"$windows_update_json")"
windows_update_package_identity="$(jq -r '.packageIdentity // empty' <<<"$windows_update_json")"
windows_headers="$(curl_head "Windows MSIX" "$windows_url")"
windows_content_length="$(header_value "$windows_headers" "content-length")"
windows_last_modified="$(header_value "$windows_headers" "last-modified")"
windows_etag="$(header_value "$windows_headers" "etag")"

arm_appcast_json="$(appcast_latest "macOS arm64 appcast" "$arm_appcast_url")"
x64_appcast_json="$(appcast_latest "macOS x64 appcast" "$x64_appcast_url")"
arm_appcast_version="$(jq -r '.shortVersionString' <<<"$arm_appcast_json")"
arm_appcast_build="$(jq -r '.version' <<<"$arm_appcast_json")"
x64_appcast_version="$(jq -r '.shortVersionString' <<<"$x64_appcast_json")"
x64_appcast_build="$(jq -r '.version' <<<"$x64_appcast_json")"

if [[ -z "$arm_appcast_version" || -z "$arm_appcast_build" || -z "$x64_appcast_version" || -z "$x64_appcast_build" ]]; then
  echo "Missing macOS appcast version metadata." >&2
  exit 1
fi

arm_url="https://persistent.oaistatic.com/codex-app-prod/Codex-${arm_appcast_version}-arm64.dmg"
x64_url="https://persistent.oaistatic.com/codex-app-prod/Codex-${x64_appcast_version}-x64.dmg"
arm_headers="$(curl_head "macOS arm64 DMG" "$arm_url")"
x64_headers="$(curl_head "macOS x64 DMG" "$x64_url")"
arm_content_length="$(header_value "$arm_headers" "content-length")"
arm_last_modified="$(header_value "$arm_headers" "last-modified")"
arm_etag="$(header_value "$arm_headers" "etag")"
x64_content_length="$(header_value "$x64_headers" "content-length")"
x64_last_modified="$(header_value "$x64_headers" "last-modified")"
x64_etag="$(header_value "$x64_headers" "etag")"

jq -n \
  --arg generatedAt "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --arg productId "$product_id" \
  --arg architecture "$architecture" \
  --arg windowsVersion "$windows_version" \
  --arg windowsPackage "$windows_package" \
  --arg windowsUrlHost "$(printf '%s' "$windows_url" | sed -E 's#^(https?://[^/]+).*#\1#')" \
  --arg windowsUpdateManifestUrl "$windows_update_manifest_url" \
  --arg windowsUpdateVersion "$windows_update_version" \
  --arg windowsUpdateProductId "$windows_update_product_id" \
  --arg windowsUpdatePackageIdentity "$windows_update_package_identity" \
  --argjson windowsContentLength "$(json_number "$windows_content_length")" \
  --arg windowsLastModified "$windows_last_modified" \
  --arg windowsEtag "$windows_etag" \
  --arg armUrl "$arm_url" \
  --arg armAppcastUrl "$arm_appcast_url" \
  --argjson armAppcast "$arm_appcast_json" \
  --argjson armContentLength "$(json_number "$arm_content_length")" \
  --arg armLastModified "$arm_last_modified" \
  --arg armEtag "$arm_etag" \
  --arg x64Url "$x64_url" \
  --arg x64AppcastUrl "$x64_appcast_url" \
  --argjson x64Appcast "$x64_appcast_json" \
  --argjson x64ContentLength "$(json_number "$x64_content_length")" \
  --arg x64LastModified "$x64_last_modified" \
  --arg x64Etag "$x64_etag" \
  '{
    schemaVersion: 1,
    generatedAt: $generatedAt,
    sources: {
      windows: {
        productId: $productId,
        architecture: $architecture,
        version: $windowsVersion,
        packageMoniker: $windowsPackage,
        urlHost: $windowsUrlHost,
        updateManifestUrl: $windowsUpdateManifestUrl,
        updateManifest: {
          buildVersion: $windowsUpdateVersion,
          storeProductId: $windowsUpdateProductId,
          packageIdentity: $windowsUpdatePackageIdentity
        },
        contentLength: $windowsContentLength,
        lastModified: $windowsLastModified,
        etag: $windowsEtag
      },
      macos: {
        arm64: {
          url: $armUrl,
          appcastUrl: $armAppcastUrl,
          appcast: $armAppcast,
          contentLength: $armContentLength,
          lastModified: $armLastModified,
          etag: $armEtag
        },
        x64: {
          url: $x64Url,
          appcastUrl: $x64AppcastUrl,
          appcast: $x64Appcast,
          contentLength: $x64ContentLength,
          lastModified: $x64LastModified,
          etag: $x64Etag
        }
      }
    }
  }' > "$manifest_path"

should_release="true"
skip_reason=""
latest_tag=""
release_tag_fallback=""
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

if [[ "$force_release" == "true" ]]; then
  skip_reason="force_release=true"
else
  latest_tag="$(latest_release_tag)"
  update_notice="$(windows_update_wait_notice "$manifest_path")"
  if [[ -n "$windows_update_version" && -n "$windows_version" ]] && version_gt "$windows_update_version" "$windows_version"; then
    should_release="false"
    if [[ -n "$latest_tag" ]]; then
      skip_reason="$update_notice Latest release remains $latest_tag."
    else
      skip_reason="$update_notice"
    fi
  elif [[ -n "$latest_tag" ]]; then
    if download_release_asset "$latest_tag" release-manifest.json "$tmp_dir" >/dev/null 2>&1; then
      current_key="$(manifest_key "$manifest_path")"
      previous_key="$(manifest_key "$tmp_dir/release-manifest.json")"
      if [[ "$current_key" == "$previous_key" ]]; then
        if public_mirror_latest_matches "$manifest_path" "$latest_tag"; then
          should_release="false"
          update_notice="$(windows_update_wait_notice "$manifest_path")"
          if [[ -n "$update_notice" ]]; then
            skip_reason="$update_notice Latest mirrored package still matches $latest_tag."
          else
            skip_reason="manifest matches latest release $latest_tag"
          fi
        else
          release_tag_fallback="$latest_tag"
          skip_reason="latest release $latest_tag matches current sources, but public mirror aliases or appcasts are stale; republishing"
        fi
      fi
    else
      assets_json="$(release_assets_json "$latest_tag")"
      windows_asset_size="$(asset_size "$assets_json" "$windows_package.Msix")"
      arm_asset_size="$(asset_size "$assets_json" "Codex-mac-arm64.dmg")"
      x64_asset_size="$(asset_size "$assets_json" "Codex-mac-x64.dmg")"
      if [[ "$windows_asset_size" == "$windows_content_length" &&
            "$arm_asset_size" == "$arm_content_length" &&
            "$x64_asset_size" == "$x64_content_length" ]]; then
        if public_mirror_latest_matches "$manifest_path" "$latest_tag"; then
          should_release="false"
          skip_reason="asset names and sizes match latest release $latest_tag"
        else
          release_tag_fallback="$latest_tag"
          skip_reason="latest release $latest_tag asset sizes match current sources, but public mirror aliases or appcasts are stale; republishing"
        fi
      fi
    fi
  fi
fi

if [[ "$should_release" == "true" && "$force_release" != "true" && -z "$release_tag_input" && -z "$release_tag_fallback" ]]; then
  predicted_tag="$(predicted_release_tag "$windows_version" "$arm_appcast_version" "$arm_appcast_build" "$x64_appcast_version" "$x64_appcast_build")"
  if release_exists "$predicted_tag"; then
    if public_mirror_latest_matches "$manifest_path" "$predicted_tag"; then
      should_release="false"
      update_notice="$(windows_update_wait_notice "$manifest_path")"
      if [[ -n "$update_notice" ]]; then
        skip_reason="$update_notice Release tag $predicted_tag already exists."
      else
        skip_reason="release tag $predicted_tag already exists"
      fi
    else
      release_tag_fallback="$predicted_tag"
      skip_reason="release tag $predicted_tag already exists, but public mirror aliases or appcasts are stale; republishing"
    fi
  fi
fi

if [[ -n "$release_tag_input" ]]; then
  release_tag="$release_tag_input"
elif [[ "$force_release" == "true" ]]; then
  release_tag="codex-app-force-$(date -u +'%Y%m%d-%H%M%S')"
elif [[ -n "$release_tag_fallback" ]]; then
  release_tag="$release_tag_fallback"
else
  release_tag=""
fi

if [[ -n "$release_tag" ]]; then
  validate_release_tag "$release_tag"
fi

version_summary="windows=$windows_version ($windows_package; updateManifest=$windows_update_version); mac-arm64=$arm_appcast_version-b$arm_appcast_build/$arm_etag/$arm_content_length; mac-x64=$x64_appcast_version-b$x64_appcast_build/$x64_etag/$x64_content_length"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    github_output_value "should_release" "$should_release"
    github_output_value "release_tag" "$release_tag"
    github_output_value "latest_tag" "$latest_tag"
    github_output_value "skip_reason" "$skip_reason"
    github_output_value "version_summary" "$version_summary"
    github_output_value "manifest" "$(cat "$manifest_path")"
  } >> "$GITHUB_OUTPUT"
fi

echo "should_release=$should_release"
echo "release_tag=$release_tag"
echo "latest_tag=$latest_tag"
echo "skip_reason=$skip_reason"
echo "version_summary=$version_summary"
