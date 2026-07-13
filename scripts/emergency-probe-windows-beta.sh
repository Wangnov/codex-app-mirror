#!/usr/bin/env bash
set -euo pipefail

output_path="${1:-probe-manifest.json}"
product_id="${BETA_PRODUCT_ID:-9N8CJ4W95TBZ}"
package_identity="${BETA_PACKAGE_IDENTITY:-OpenAI.CodexBeta}"
expected_version="${EXPECTED_WINDOWS_PACKAGE_VERSION:?EXPECTED_WINDOWS_PACKAGE_VERSION is required}"
display_catalog_url="https://displaycatalog.mp.microsoft.com/v7.0/products/${product_id}?market=US&languages=en-US,en,neutral"
resolve_attempts="${STORE_LINK_STABILITY_MAX_ATTEMPTS:-12}"
resolve_delay="${STORE_LINK_STABILITY_RETRY_DELAY_SECONDS:-30}"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

for command in curl dotnet jq; do
  require "$command"
done

if [[ ! "$resolve_attempts" =~ ^[1-9][0-9]*$ || ! "$resolve_delay" =~ ^[0-9]+$ ]]; then
  echo "Store resolver retry settings must be non-negative integers with at least one attempt." >&2
  exit 2
fi

curl_args=(
  --retry 5
  --retry-delay 2
  --retry-max-time 300
  --connect-timeout 20
  --max-time 180
  --retry-all-errors
)

package_version() {
  local moniker="$1"
  local remainder="${moniker#${package_identity}_}"
  printf '%s' "${remainder%%_*}"
}

header_value() {
  local headers="$1"
  local wanted="$2"
  tr -d '\r' <<<"$headers" |
    awk -v wanted="$(tr '[:upper:]' '[:lower:]' <<<"$wanted")" '
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

resolve_exact_package() {
  local arch="$1"
  local expected_moniker="$2"
  local attempt output line moniker

  for ((attempt = 1; attempt <= resolve_attempts; attempt++)); do
    echo "Resolving Microsoft Store Beta $arch package (attempt $attempt/$resolve_attempts)" >&2
    if output="$(dotnet run --project scripts/store-link -- "$product_id" "$arch" "$package_identity")"; then
      line="$(awk -v prefix="${package_identity}_" 'index($0, prefix) == 1 { print; exit }' <<<"$output")"
      moniker="${line%%$'\t'*}"
      if [[ -n "$line" && "$line" == *$'\t'* && "$moniker" == "$expected_moniker" ]]; then
        printf '%s\n' "$line"
        return 0
      fi
      echo "Store resolver returned ${moniker:-no matching package}; DisplayCatalog expects $expected_moniker." >&2
    fi

    if ((attempt < resolve_attempts && resolve_delay > 0)); then
      sleep "$resolve_delay"
    fi
  done

  echo "Microsoft Store Beta $arch did not converge on $expected_moniker." >&2
  return 1
}

catalog_json="$(curl -fsSL "${curl_args[@]}" "$display_catalog_url")"

catalog_package() {
  local arch="$1"
  jq -c --arg arch "$arch" --arg identity "$package_identity" '
    [
      .Product.DisplaySkuAvailabilities[].Sku.Properties.Packages[]?
      | select((.PackageFamilyName // "") | startswith($identity + "_"))
      | select(((.Architectures // []) | map(ascii_downcase) | index($arch)) != null)
    ]
    | unique_by(.PackageFullName)
    | sort_by(.PackageFullName)
    | last // {}
  ' <<<"$catalog_json"
}

x64_catalog="$(catalog_package x64)"
arm64_catalog="$(catalog_package arm64)"
x64_catalog_moniker="$(jq -r '.PackageFullName // empty' <<<"$x64_catalog")"
arm64_catalog_moniker="$(jq -r '.PackageFullName // empty' <<<"$arm64_catalog")"

if [[ -z "$x64_catalog_moniker" || -z "$arm64_catalog_moniker" ]]; then
  echo "DisplayCatalog is missing a Windows Beta x64 or ARM64 package." >&2
  exit 1
fi

x64_version="$(package_version "$x64_catalog_moniker")"
arm64_version="$(package_version "$arm64_catalog_moniker")"
if [[ "$x64_version" != "$expected_version" || "$arm64_version" != "$expected_version" ]]; then
  echo "Windows Beta version drift: expected=$expected_version x64=$x64_version arm64=$arm64_version" >&2
  exit 1
fi

x64_line="$(resolve_exact_package x64 "$x64_catalog_moniker")"
arm64_line="$(resolve_exact_package arm64 "$arm64_catalog_moniker")"
x64_url="${x64_line#*$'\t'}"
arm64_url="${arm64_line#*$'\t'}"

x64_headers="$(curl -fsSI -L "${curl_args[@]}" "$x64_url")"
arm64_headers="$(curl -fsSI -L "${curl_args[@]}" "$arm64_url")"
x64_size="$(header_value "$x64_headers" content-length)"
arm64_size="$(header_value "$arm64_headers" content-length)"
x64_catalog_size="$(jq -r '.MaxDownloadSizeInBytes // 0' <<<"$x64_catalog")"
arm64_catalog_size="$(jq -r '.MaxDownloadSizeInBytes // 0' <<<"$arm64_catalog")"

if [[ ! "$x64_size" =~ ^[0-9]+$ || ! "$arm64_size" =~ ^[0-9]+$ ]]; then
  echo "Microsoft CDN did not return valid Windows Beta Content-Length headers." >&2
  exit 1
fi
if [[ "$x64_size" != "$x64_catalog_size" || "$arm64_size" != "$arm64_catalog_size" ]]; then
  echo "Windows Beta size drift: CDN=$x64_size/$arm64_size catalog=$x64_catalog_size/$arm64_catalog_size" >&2
  exit 1
fi

mkdir -p "$(dirname "$output_path")"
jq -n \
  --arg generatedAt "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --arg productId "$product_id" \
  --arg packageIdentity "$package_identity" \
  --arg version "$expected_version" \
  --arg x64UrlHost "$(sed -E 's#^(https?://[^/]+).*#\1#' <<<"$x64_url")" \
  --arg arm64UrlHost "$(sed -E 's#^(https?://[^/]+).*#\1#' <<<"$arm64_url")" \
  --arg x64LastModified "$(header_value "$x64_headers" last-modified)" \
  --arg arm64LastModified "$(header_value "$arm64_headers" last-modified)" \
  --arg x64Etag "$(header_value "$x64_headers" etag)" \
  --arg arm64Etag "$(header_value "$arm64_headers" etag)" \
  --argjson x64Catalog "$x64_catalog" \
  --argjson arm64Catalog "$arm64_catalog" '
  {
    schemaVersion: 2,
    generatedAt: $generatedAt,
    version: $version,
    channel: "beta",
    beta: {
      contract: "issue-36-beta-prerelease",
      expectedExecutable: "app/ChatGPT (Beta).exe",
      expectedWindowsPackageVersion: $version
    },
    publication: {
      githubPrereleaseOnly: true,
      githubLatestAdvanced: false,
      objectStoragePublished: false,
      sharedLatestAdvanced: false
    },
    derived: {
      prerelease: true,
      publishLatest: false,
      syncLatest: false,
      includeWindowsX64: true,
      includeWindowsArm64: true,
      includeMacosArm64: false,
      includeMacosX64: false,
      missingArchitectures: []
    },
    sources: {
      windows: {
        productId: $productId,
        packageIdentity: $packageIdentity,
        packageFamilyName: ($x64Catalog.PackageFamilyName // ""),
        version: $version,
        architectures: {
          x64: {
            architecture: "x64",
            status: "downloadable",
            downloadable: true,
            version: $version,
            packageMoniker: ($x64Catalog.PackageFullName // ""),
            urlHost: $x64UrlHost,
            contentLength: ($x64Catalog.MaxDownloadSizeInBytes // 0),
            lastModified: $x64LastModified,
            etag: $x64Etag,
            catalog: $x64Catalog
          },
          arm64: {
            architecture: "arm64",
            status: "downloadable",
            downloadable: true,
            version: $version,
            packageMoniker: ($arm64Catalog.PackageFullName // ""),
            urlHost: $arm64UrlHost,
            contentLength: ($arm64Catalog.MaxDownloadSizeInBytes // 0),
            lastModified: $arm64LastModified,
            etag: $arm64Etag,
            catalog: $arm64Catalog
          }
        }
      }
    }
  }
  ' > "$output_path"

jq -e \
  --arg productId "$product_id" \
  --arg identity "$package_identity" \
  --arg version "$expected_version" '
    .channel == "beta"
    and .beta.contract == "issue-36-beta-prerelease"
    and .publication.githubPrereleaseOnly == true
    and .publication.githubLatestAdvanced == false
    and .publication.objectStoragePublished == false
    and .publication.sharedLatestAdvanced == false
    and .sources.windows.productId == $productId
    and .sources.windows.packageIdentity == $identity
    and .sources.windows.version == $version
    and .sources.windows.architectures.x64.downloadable == true
    and .sources.windows.architectures.arm64.downloadable == true
    and (.sources.windows.architectures.x64.packageMoniker | startswith($identity + "_"))
    and (.sources.windows.architectures.arm64.packageMoniker | startswith($identity + "_"))
  ' "$output_path" >/dev/null

jq '{version, channel, publication, productId: .sources.windows.productId, packageIdentity: .sources.windows.packageIdentity, architectures: (.sources.windows.architectures | map_values({packageMoniker, contentLength, urlHost}))}' "$output_path"
