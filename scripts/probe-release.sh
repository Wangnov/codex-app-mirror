#!/usr/bin/env bash
set -euo pipefail

product_id="9PLM9XGG6VKS"
architecture="x64"
arm_appcast_url="https://persistent.oaistatic.com/codex-app-prod/appcast.xml"
x64_appcast_url="https://persistent.oaistatic.com/codex-app-prod/appcast-x64.xml"
windows_update_manifest_url="https://persistent.oaistatic.com/codex-app-prod/windows-store-update.json"
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

sanitize_tag_part() {
  tr -cs 'A-Za-z0-9._-' '-' <<<"$1" | sed -E 's/^-+//; s/-+$//'
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
        appcastVersion: .sources.macos.arm64.appcast.shortVersionString,
        appcastBuild: .sources.macos.arm64.appcast.version,
        contentLength: .sources.macos.arm64.contentLength,
        etag: .sources.macos.arm64.etag,
        lastModified: .sources.macos.arm64.lastModified
      },
      x64: {
        appcastVersion: .sources.macos.x64.appcast.shortVersionString,
        appcastBuild: .sources.macos.x64.appcast.version,
        contentLength: .sources.macos.x64.contentLength,
        etag: .sources.macos.x64.etag,
        lastModified: .sources.macos.x64.lastModified
      }
    }
  }' "$1"
}

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
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

if [[ "$force_release" == "true" ]]; then
  skip_reason="force_release=true"
else
  latest_tag="$(gh release list --limit 1 --exclude-drafts --exclude-pre-releases --json tagName --jq '.[0].tagName // ""')"
  update_notice="$(windows_update_wait_notice "$manifest_path")"
  if [[ -n "$windows_update_version" && -n "$windows_version" ]] && version_gt "$windows_update_version" "$windows_version"; then
    should_release="false"
    if [[ -n "$latest_tag" ]]; then
      skip_reason="$update_notice Latest release remains $latest_tag."
    else
      skip_reason="$update_notice"
    fi
  elif [[ -n "$latest_tag" ]]; then
    if gh release download "$latest_tag" -p release-manifest.json -D "$tmp_dir" --clobber >/dev/null 2>&1; then
      current_key="$(manifest_key "$manifest_path")"
      previous_key="$(manifest_key "$tmp_dir/release-manifest.json")"
      if [[ "$current_key" == "$previous_key" ]]; then
        should_release="false"
        update_notice="$(windows_update_wait_notice "$manifest_path")"
        if [[ -n "$update_notice" ]]; then
          skip_reason="$update_notice Latest mirrored package still matches $latest_tag."
        else
          skip_reason="manifest matches latest release $latest_tag"
        fi
      fi
    else
      assets_json="$(gh release view "$latest_tag" --json assets --jq '.assets')"
      windows_asset_size="$(asset_size "$assets_json" "$windows_package.Msix")"
      arm_asset_size="$(asset_size "$assets_json" "Codex-mac-arm64.dmg")"
      x64_asset_size="$(asset_size "$assets_json" "Codex-mac-x64.dmg")"
      if [[ "$windows_asset_size" == "$windows_content_length" &&
            "$arm_asset_size" == "$arm_content_length" &&
            "$x64_asset_size" == "$x64_content_length" ]]; then
        should_release="false"
        skip_reason="asset names and sizes match latest release $latest_tag"
      fi
    fi
  fi
fi

if [[ "$should_release" == "true" && "$force_release" != "true" && -z "$release_tag_input" ]]; then
  predicted_tag="$(predicted_release_tag "$windows_version" "$arm_appcast_version" "$arm_appcast_build" "$x64_appcast_version" "$x64_appcast_build")"
  if gh release view "$predicted_tag" >/dev/null 2>&1; then
    should_release="false"
    update_notice="$(windows_update_wait_notice "$manifest_path")"
    if [[ -n "$update_notice" ]]; then
      skip_reason="$update_notice Release tag $predicted_tag already exists."
    else
      skip_reason="release tag $predicted_tag already exists"
    fi
  fi
fi

if [[ -n "$release_tag_input" ]]; then
  release_tag="$release_tag_input"
elif [[ "$force_release" == "true" ]]; then
  release_tag="codex-app-force-$(date -u +'%Y%m%d-%H%M%S')"
else
  release_tag=""
fi

version_summary="windows=$windows_version ($windows_package; updateManifest=$windows_update_version); mac-arm64=$arm_appcast_version-b$arm_appcast_build/$arm_etag/$arm_content_length; mac-x64=$x64_appcast_version-b$x64_appcast_build/$x64_etag/$x64_content_length"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "should_release=$should_release"
    echo "release_tag=$release_tag"
    echo "latest_tag=$latest_tag"
    echo "skip_reason=$skip_reason"
    echo "version_summary=$version_summary"
    echo "manifest<<EOF"
    cat "$manifest_path"
    echo "EOF"
  } >> "$GITHUB_OUTPUT"
fi

echo "should_release=$should_release"
echo "release_tag=$release_tag"
echo "latest_tag=$latest_tag"
echo "skip_reason=$skip_reason"
echo "version_summary=$version_summary"
