#!/usr/bin/env bash
set -euo pipefail

product_id="9PLM9XGG6VKS"
architecture="x64"
windows_display_catalog_url="https://displaycatalog.mp.microsoft.com/v7.0/products/${product_id}?market=US&languages=en-US,en,neutral"
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

source_object_size() {
  local label="$1"
  local url="$2"
  local headers
  local size

  if [[ -z "$url" || "$url" == "null" ]]; then
    echo "Missing $label URL; cannot determine source object size." >&2
    return 1
  fi

  if ! headers="$(curl_range_headers "$label" "$url")"; then
    echo "Failed to fetch $label source object size." >&2
    return 1
  fi
  if ! size="$(object_size_from_range_headers "$headers")"; then
    echo "Could not determine $label source object size from range headers." >&2
    return 1
  fi

  printf '%s' "$size"
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

reconcile_appcast_object_lengths() {
  local label="$1"
  local appcast_json="$2"
  local tmp
  local next
  local url
  local expected_size
  local actual_size
  local count
  local i

  tmp="$(mktemp)"
  next="$tmp.next"
  printf '%s\n' "$appcast_json" > "$tmp"

  url="$(jq -r '.enclosureUrl // ""' "$tmp")"
  expected_size="$(jq -r '.enclosureLength // 0' "$tmp")"
  actual_size="$(source_object_size "$label Sparkle archive" "$url")"
  if [[ "$actual_size" != "$expected_size" ]]; then
    echo "$label appcast enclosure length $expected_size differs from source object size $actual_size; using source object size." >&2
  fi
  jq --argjson actual "$actual_size" '.enclosureLength = $actual' "$tmp" > "$next"
  mv "$next" "$tmp"

  count="$(jq -r '.deltas | length // 0' "$tmp")"
  for ((i = 0; i < count; i++)); do
    url="$(jq -r --argjson i "$i" '.deltas[$i].url // ""' "$tmp")"
    expected_size="$(jq -r --argjson i "$i" '.deltas[$i].length // 0' "$tmp")"
    actual_size="$(source_object_size "$label Sparkle delta[$i]" "$url")"
    if [[ "$actual_size" != "$expected_size" ]]; then
      echo "$label appcast delta[$i] length $expected_size differs from source object size $actual_size; using source object size." >&2
    fi
    jq --argjson i "$i" --argjson actual "$actual_size" '
      .deltas[$i].length = $actual
      | .deltas[$i].attributes = (.deltas[$i].attributes // {})
      | .deltas[$i].attributes.length = ($actual | tostring)
    ' "$tmp" > "$next"
    mv "$next" "$tmp"
  done

  cat "$tmp"
  rm -f "$tmp" "$next"
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
  else
    # Capture gh's real exit status here: `$?` taken after the closing `fi` would
    # be the if-statement's status (0 when the condition is false and there is no
    # else), masking the failure.
    status=$?
  fi
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
  else
    # `$?` after the closing `fi` is the if-statement's status (0 on a false
    # condition with no else), not the helper's — capture it in the else branch.
    status=$?
  fi
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

validate_release_tag() {
  local tag="$1"

  if [[ ! "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
    echo "Invalid release tag '$tag'. Use 1-128 ASCII letters, numbers, dots, underscores, or hyphens; the first character must be alphanumeric." >&2
    exit 1
  fi
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
      contentLength: .sources.windows.contentLength,
      architectures: (
        .sources.windows.architectures // {
          x64: {
            status: "downloadable",
            downloadable: true,
            version: .sources.windows.version,
            packageMoniker: .sources.windows.packageMoniker,
            contentLength: .sources.windows.contentLength
          }
        }
        | with_entries(
            .value |= {
              status: (.status // ""),
              downloadable: (.downloadable // false),
              version: (.version // ""),
              packageMoniker: (.packageMoniker // ""),
              contentLength: (.contentLength // 0),
              catalog: {
                packageFullName: (.catalog.packageFullName // ""),
                packageId: (.catalog.packageId // ""),
                contentId: (.catalog.contentId // ""),
                hashAlgorithm: (.catalog.hashAlgorithm // ""),
                hash: (.catalog.hash // ""),
                contentLength: (.catalog.contentLength // 0)
              }
            }
          )
      )
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

public_mirror_current_latest_view() {
  local manifest="$1"
  local live_manifest="$2"
  local output="$3"

  jq '
    . as $current
    | input as $live
    | if
        (($live.sources.windows.architectures.arm64.preservedFromLatest // false) == true)
        and (($current.sources.windows.architectures.arm64.downloadable // false) != true)
      then
        $current
        | .sources.windows.architectures.arm64 = $live.sources.windows.architectures.arm64
      else
        $current
      end
  ' "$manifest" "$live_manifest" > "$output"
}

public_mirror_manifest_key_matches() {
  local manifest="$1"
  local dir
  local live_manifest
  local current_view
  local current_key
  local live_key

  dir="$(mktemp -d)"
  live_manifest="$dir/live-manifest.json"
  current_view="$dir/current-latest-view.json"
  if ! curl_get "public mirror manifest" "$r2_public_base_url/latest/manifest?probe=$$" > "$live_manifest"; then
    rm -rf "$dir"
    return 1
  fi

  if ! public_mirror_current_latest_view "$manifest" "$live_manifest" "$current_view"; then
    rm -rf "$dir"
    return 1
  fi

  if ! current_key="$(manifest_key "$current_view")" || ! live_key="$(manifest_key "$live_manifest")"; then
    rm -rf "$dir"
    return 1
  fi

  rm -rf "$dir"
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
  local manifest="$1"
  local dir
  local live_manifest

  dir="$(mktemp -d)"
  live_manifest="$dir/live-manifest.json"
  if ! curl_get "public mirror manifest" "$r2_public_base_url/latest/manifest?probe=$$" > "$live_manifest"; then
    rm -rf "$dir"
    return 1
  fi
  if ! curl_get "public mirror checksums" "$r2_public_base_url/latest/checksums?probe=$$" > "$dir/live-SHA256SUMS.txt"; then
    rm -rf "$dir"
    return 1
  fi

  if ! jq -e '.derived.latestChecksums | type == "object" and length > 0' "$live_manifest" >/dev/null; then
    rm -rf "$dir"
    return 1
  fi

  if ! jq -r '
    .derived.latestChecksums
    | to_entries[]
    | ((.value | ascii_downcase) + "  " + .key)
  ' "$live_manifest" | LC_ALL=C sort > "$dir/expected-SHA256SUMS.txt"; then
    rm -rf "$dir"
    return 1
  fi
  live_manifest_sha="$(sha256sum "$live_manifest" | awk '{print tolower($1)}')"
  if ! grep -F -q "  release-manifest.json" "$dir/expected-SHA256SUMS.txt"; then
    printf '%s  release-manifest.json\n' "$live_manifest_sha" >> "$dir/expected-SHA256SUMS.txt"
  elif ! awk -v expected="$live_manifest_sha" '
    $2 == "release-manifest.json" && tolower($1) != expected { exit 1 }
  ' "$dir/expected-SHA256SUMS.txt"; then
    rm -rf "$dir"
    return 1
  fi
  LC_ALL=C sort -o "$dir/expected-SHA256SUMS.txt" "$dir/expected-SHA256SUMS.txt"

  if ! awk '
    NF == 0 { next }
    {
      digest = $1
      name = $0
      sub(/^[^[:space:]]+[[:space:]]+/, "", name)
      if (digest !~ /^[0-9A-Fa-f]{64}$/ || name == "") {
        exit 1
      }
      print tolower(digest) "  " name
    }
  ' "$dir/live-SHA256SUMS.txt" | LC_ALL=C sort > "$dir/actual-SHA256SUMS.txt"; then
    rm -rf "$dir"
    return 1
  fi

  if ! cmp -s "$dir/expected-SHA256SUMS.txt" "$dir/actual-SHA256SUMS.txt"; then
    rm -rf "$dir"
    return 1
  fi

  rm -rf "$dir"
  return 0
}

public_mirror_objects_match() {
  local manifest="$1"
  local dir
  local live_manifest
  local current_view
  local arm_short_version
  local x64_short_version

  dir="$(mktemp -d)"
  live_manifest="$dir/live-manifest.json"
  current_view="$dir/current-latest-view.json"
  if ! curl_get "public mirror manifest" "$r2_public_base_url/latest/manifest?probe=$$" > "$live_manifest"; then
    rm -rf "$dir"
    return 1
  fi
  if ! public_mirror_current_latest_view "$manifest" "$live_manifest" "$current_view"; then
    rm -rf "$dir"
    return 1
  fi

  manifest="$current_view"
  arm_short_version="$(jq -r '.sources.macos.arm64.appcast.shortVersionString // ""' "$manifest")"
  x64_short_version="$(jq -r '.sources.macos.x64.appcast.shortVersionString // ""' "$manifest")"

  if [[ -z "$arm_short_version" || -z "$x64_short_version" ]]; then
    rm -rf "$dir"
    return 1
  fi

  if public_mirror_object_size_matches \
      "public mirror Windows alias" \
      "latest/win" \
      "$(jq -r '.sources.windows.contentLength // 0' "$manifest")" &&
    public_mirror_object_size_matches \
      "public mirror Windows x64 alias" \
      "latest/win-x64" \
      "$(jq -r '.sources.windows.architectures.x64.contentLength // .sources.windows.contentLength // 0' "$manifest")" &&
    {
      if jq -e '.sources.windows.architectures.arm64.downloadable == true' "$manifest" >/dev/null; then
        public_mirror_object_size_matches \
          "public mirror Windows arm64 alias" \
          "latest/win-arm64" \
          "$(jq -r '.sources.windows.architectures.arm64.contentLength // 0' "$manifest")"
      else
        true
      fi
    } &&
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
    public_mirror_delta_objects_match "$manifest" x64 intel; then
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

public_mirror_latest_matches() {
  local manifest="$1"
  local tag="$2"

  public_mirror_manifest_key_matches "$manifest" &&
    public_mirror_appcasts_match "$manifest" &&
    public_mirror_checksums_match "$manifest" &&
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
  local desired_arch="$1"
  local max_attempts="$2"
  local delay="$3"
  local attempt

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    echo "Resolving Microsoft Store $desired_arch package link (attempt $attempt/$max_attempts)" >&2
    if dotnet run --project scripts/store-link -- "$product_id" "$desired_arch"; then
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

package_version() {
  sed -E 's/^OpenAI\.Codex_([^_]+)_.*/\1/' <<<"$1"
}

catalog_package_for_arch() {
  local arch="$1"
  jq -c --arg arch "$arch" '
    [
      .Product.DisplaySkuAvailabilities[].Sku.Properties.Packages[]?
      | select((.PackageFamilyName // "") == "OpenAI.Codex_2p2nqsd0c76g0")
      | select(((.Architectures // []) | map(ascii_downcase) | index($arch)) != null)
    ]
    | unique_by(.PackageFullName)
    | sort_by(.PackageFullName)
    | last // {}
  ' <<<"$windows_catalog_json"
}

catalog_field() {
  local catalog_json="$1"
  local field="$2"
  jq -r --arg field "$field" '.[$field] // empty' <<<"$catalog_json"
}

windows_catalog_json="$(curl_get "Windows DisplayCatalog" "$windows_display_catalog_url")"
windows_x64_catalog="$(catalog_package_for_arch x64)"
windows_arm64_catalog="$(catalog_package_for_arch arm64)"

link_line="$(resolve_store_link "$architecture" "${STORE_LINK_MAX_ATTEMPTS:-3}" "${STORE_LINK_RETRY_DELAY_SECONDS:-10}" |
  awk '/^OpenAI\.Codex_/ { print; exit }')"

if [[ -z "$link_line" ]]; then
  echo "No Microsoft Store package link was resolved." >&2
  exit 1
fi

windows_package="${link_line%%$'\t'*}"
windows_url="${link_line#*$'\t'}"
windows_version="$(package_version "$windows_package")"
windows_update_json="$(curl_get "Windows update manifest" "$windows_update_manifest_url")"
windows_update_version="$(jq -r '.buildVersion // empty' <<<"$windows_update_json")"
windows_update_product_id="$(jq -r '.storeProductId // empty' <<<"$windows_update_json")"
windows_update_package_identity="$(jq -r '.packageIdentity // empty' <<<"$windows_update_json")"
windows_headers="$(curl_head "Windows MSIX" "$windows_url")"
windows_content_length="$(header_value "$windows_headers" "content-length")"
windows_last_modified="$(header_value "$windows_headers" "last-modified")"
windows_etag="$(header_value "$windows_headers" "etag")"

windows_arm64_package="$(catalog_field "$windows_arm64_catalog" PackageFullName)"
windows_arm64_version=""
windows_arm64_url_host=""
windows_arm64_content_length="$(catalog_field "$windows_arm64_catalog" MaxDownloadSizeInBytes)"
windows_arm64_last_modified=""
windows_arm64_etag=""
windows_arm64_status="catalog-only"
windows_arm64_downloadable=false

if [[ -n "$windows_arm64_package" ]]; then
  windows_arm64_version="$(package_version "$windows_arm64_package")"
fi

windows_arm64_link_output=""
if windows_arm64_link_output="$(resolve_store_link arm64 "${STORE_LINK_OPTIONAL_MAX_ATTEMPTS:-1}" "${STORE_LINK_OPTIONAL_RETRY_DELAY_SECONDS:-0}")"; then
  windows_arm64_link_line="$(awk '/^OpenAI\.Codex_/ { print; exit }' <<<"$windows_arm64_link_output")"
  if [[ -n "$windows_arm64_link_line" ]]; then
    windows_arm64_package="${windows_arm64_link_line%%$'\t'*}"
    windows_arm64_url="${windows_arm64_link_line#*$'\t'}"
    windows_arm64_version="$(package_version "$windows_arm64_package")"
    windows_arm64_headers="$(curl_head "Windows arm64 MSIX" "$windows_arm64_url")"
    windows_arm64_content_length="$(header_value "$windows_arm64_headers" "content-length")"
    windows_arm64_last_modified="$(header_value "$windows_arm64_headers" "last-modified")"
    windows_arm64_etag="$(header_value "$windows_arm64_headers" "etag")"
    windows_arm64_url_host="$(printf '%s' "$windows_arm64_url" | sed -E 's#^(https?://[^/]+).*#\1#')"
    windows_arm64_status="downloadable"
    windows_arm64_downloadable=true
  fi
else
  echo "Windows arm64 Store package link is not downloadable yet; recording catalog metadata only." >&2
fi

windows_x64_catalog_package="$(catalog_field "$windows_x64_catalog" PackageFullName)"
if [[ -n "$windows_x64_catalog_package" && "$windows_x64_catalog_package" != "$windows_package" ]]; then
  echo "Windows x64 DisplayCatalog package ($windows_x64_catalog_package) differs from FE3 downloadable package ($windows_package); using downloadable package." >&2
fi

arm_appcast_json="$(appcast_latest "macOS arm64 appcast" "$arm_appcast_url")"
x64_appcast_json="$(appcast_latest "macOS x64 appcast" "$x64_appcast_url")"
arm_appcast_json="$(reconcile_appcast_object_lengths "macOS arm64" "$arm_appcast_json")"
x64_appcast_json="$(reconcile_appcast_object_lengths "macOS x64" "$x64_appcast_json")"
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
  --argjson windowsX64Catalog "$windows_x64_catalog" \
  --arg windowsArm64Version "$windows_arm64_version" \
  --arg windowsArm64Package "$windows_arm64_package" \
  --arg windowsArm64UrlHost "$windows_arm64_url_host" \
  --arg windowsArm64Status "$windows_arm64_status" \
  --argjson windowsArm64Downloadable "$windows_arm64_downloadable" \
  --argjson windowsArm64Catalog "$windows_arm64_catalog" \
  --argjson windowsArm64ContentLength "$(json_number "$windows_arm64_content_length")" \
  --arg windowsArm64LastModified "$windows_arm64_last_modified" \
  --arg windowsArm64Etag "$windows_arm64_etag" \
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
        etag: $windowsEtag,
        architectures: {
          x64: {
            architecture: "x64",
            status: "downloadable",
            downloadable: true,
            version: $windowsVersion,
            packageMoniker: $windowsPackage,
            urlHost: $windowsUrlHost,
            contentLength: $windowsContentLength,
            lastModified: $windowsLastModified,
            etag: $windowsEtag,
            catalog: {
              packageFullName: ($windowsX64Catalog.PackageFullName // ""),
              packageId: ($windowsX64Catalog.PackageId // ""),
              contentId: ($windowsX64Catalog.ContentId // ""),
              packageFamilyName: ($windowsX64Catalog.PackageFamilyName // ""),
              hashAlgorithm: ($windowsX64Catalog.HashAlgorithm // ""),
              hash: ($windowsX64Catalog.Hash // ""),
              contentLength: ($windowsX64Catalog.MaxDownloadSizeInBytes // 0)
            }
          },
          arm64: {
            architecture: "arm64",
            status: $windowsArm64Status,
            downloadable: $windowsArm64Downloadable,
            version: $windowsArm64Version,
            packageMoniker: $windowsArm64Package,
            urlHost: $windowsArm64UrlHost,
            contentLength: $windowsArm64ContentLength,
            lastModified: $windowsArm64LastModified,
            etag: $windowsArm64Etag,
            catalog: {
              packageFullName: ($windowsArm64Catalog.PackageFullName // ""),
              packageId: ($windowsArm64Catalog.PackageId // ""),
              contentId: ($windowsArm64Catalog.ContentId // ""),
              packageFamilyName: ($windowsArm64Catalog.PackageFamilyName // ""),
              hashAlgorithm: ($windowsArm64Catalog.HashAlgorithm // ""),
              hash: ($windowsArm64Catalog.Hash // ""),
              contentLength: ($windowsArm64Catalog.MaxDownloadSizeInBytes // 0)
            }
          }
        }
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
  # The Windows Store update manifest can advertise a new build before its MSIX
  # bytes are downloadable. `update_notice` captures that wait, but it must NOT
  # veto a release: `should_release` gates the combined win+mac publish, so a
  # veto here also blocks a macOS update that is already downloadable (mac ships
  # from persistent.oaistatic.com, independent of the Microsoft Store rollout).
  # The generated manifest always records the DOWNLOADABLE Windows version in
  # sources.windows.version (never the advertised updateManifest.buildVersion),
  # so the manifest-key comparison below releases only when real downloadable
  # bytes change (macOS now, or Windows once its MSIX lands) and no-ops otherwise.
  # The notice is woven into the skip/release messaging purely as context.
  if [[ -n "$latest_tag" ]]; then
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
      elif public_mirror_latest_matches "$manifest_path" "$latest_tag"; then
        should_release="false"
        skip_reason="public mirror latest already matches current sources; GitHub latest remains $latest_tag until all architectures are complete"
      fi
    else
      assets_json="$(release_assets_json "$latest_tag")"
      windows_asset_size="$(asset_size "$assets_json" "$windows_package.Msix")"
      windows_arm64_asset_size=""
      if jq -e '.sources.windows.architectures.arm64.downloadable == true' "$manifest_path" >/dev/null; then
        windows_arm64_asset_size="$(asset_size "$assets_json" "$windows_arm64_package.Msix")"
      fi
      arm_asset_size="$(asset_size "$assets_json" "Codex-mac-arm64.dmg")"
      x64_asset_size="$(asset_size "$assets_json" "Codex-mac-x64.dmg")"
      if [[ "$windows_asset_size" == "$windows_content_length" &&
            ( "$windows_arm64_downloadable" != "true" || "$windows_arm64_asset_size" == "$windows_arm64_content_length" ) &&
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

# The canonical tag now depends on the Windows Codex app's internal version,
# which is stored inside the downloaded MSIX (app.asar/package.json) rather than
# in Microsoft Store's four-part package moniker. Leave release_tag empty here so
# prepare-release-metadata.sh can derive the exact codex-app-<version> tag after
# the Windows artifact has been downloaded. The latest-tag fallback above is
# still used when this run is only repairing stale latest aliases for the already
# published latest release.

if [[ -n "$release_tag_input" ]]; then
  release_tag="$release_tag_input"
elif [[ "$force_release" == "true" ]]; then
  release_tag=""
elif [[ -n "$release_tag_fallback" ]]; then
  release_tag="$release_tag_fallback"
else
  release_tag=""
fi

if [[ -n "$release_tag" ]]; then
  validate_release_tag "$release_tag"
fi

version_summary="windows-x64=$windows_version ($windows_package; updateManifest=$windows_update_version); windows-arm64=${windows_arm64_status}:${windows_arm64_version:-none} (${windows_arm64_package:-none}); mac-arm64=$arm_appcast_version-b$arm_appcast_build/$arm_etag/$arm_content_length; mac-x64=$x64_appcast_version-b$x64_appcast_build/$x64_etag/$x64_content_length"

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
