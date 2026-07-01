#!/usr/bin/env bash
set -euo pipefail

: "${SECONDARY_S3_ENDPOINT:?SECONDARY_S3_ENDPOINT must be set, for example https://s3.example.com}"
: "${SECONDARY_S3_BUCKET:?SECONDARY_S3_BUCKET must be set}"
: "${SECONDARY_S3_ACCESS_KEY_ID:?SECONDARY_S3_ACCESS_KEY_ID must be set}"
: "${SECONDARY_S3_SECRET_ACCESS_KEY:?SECONDARY_S3_SECRET_ACCESS_KEY must be set}"

if [[ $# -ne 9 && $# -ne 10 ]]; then
  echo "Usage: sync-secondary-s3.sh <mac-arm64-dmg> <mac-intel-dmg> <windows-x64-msix> <checksums> <manifest> <mac-arm64-zip> <mac-intel-zip> <appcast-arm64> <appcast-x64> [windows-arm64-msix]" >&2
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
upload_attempts="${SECONDARY_S3_UPLOAD_ATTEMPTS:-4}"
retry_sleep="${SECONDARY_S3_RETRY_SLEEP_SECONDS:-5}"
connect_timeout="${SECONDARY_S3_CONNECT_TIMEOUT_SECONDS:-20}"
read_timeout="${SECONDARY_S3_READ_TIMEOUT_SECONDS:-120}"
aws_max_attempts="${SECONDARY_S3_AWS_MAX_ATTEMPTS:-3}"
aws_retry_mode="${SECONDARY_S3_AWS_RETRY_MODE:-standard}"
multipart_threshold="${SECONDARY_S3_MULTIPART_THRESHOLD:-64MB}"
multipart_chunksize="${SECONDARY_S3_MULTIPART_CHUNKSIZE:-64MB}"
max_concurrent_requests="${SECONDARY_S3_MAX_CONCURRENT_REQUESTS:-2}"
upload_mode="${SECONDARY_S3_UPLOAD_MODE:-put-object}"

if [[ -z "$prefix" ]]; then
  echo "SECONDARY_S3_PREFIX must not resolve to an empty prefix." >&2
  exit 2
fi

require_non_negative_integer() {
  local name="$1"
  local value="$2"

  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "$name must be a non-negative integer, got '$value'." >&2
    exit 2
  fi
}

require_positive_integer() {
  local name="$1"
  local value="$2"

  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "$name must be a positive integer, got '$value'." >&2
    exit 2
  fi
}

require_positive_integer SECONDARY_S3_UPLOAD_ATTEMPTS "$upload_attempts"
require_non_negative_integer SECONDARY_S3_RETRY_SLEEP_SECONDS "$retry_sleep"
require_positive_integer SECONDARY_S3_CONNECT_TIMEOUT_SECONDS "$connect_timeout"
require_positive_integer SECONDARY_S3_READ_TIMEOUT_SECONDS "$read_timeout"
require_positive_integer SECONDARY_S3_AWS_MAX_ATTEMPTS "$aws_max_attempts"
require_positive_integer SECONDARY_S3_MAX_CONCURRENT_REQUESTS "$max_concurrent_requests"

tmp_config="$(mktemp)"
cleanup() {
  rm -f "$tmp_config"
}
trap cleanup EXIT

cat > "$tmp_config" <<EOF
[default]
region = $region
retry_mode = $aws_retry_mode
max_attempts = $aws_max_attempts
s3 =
    addressing_style = $addressing_style
    max_concurrent_requests = $max_concurrent_requests
    multipart_threshold = $multipart_threshold
    multipart_chunksize = $multipart_chunksize
EOF

export AWS_ACCESS_KEY_ID="$SECONDARY_S3_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$SECONDARY_S3_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="$region"
export AWS_EC2_METADATA_DISABLED=true
export AWS_CONFIG_FILE="$tmp_config"
export AWS_MAX_ATTEMPTS="$aws_max_attempts"
export AWS_RETRY_MODE="$aws_retry_mode"
export R2_S3_ENDPOINT="$SECONDARY_S3_ENDPOINT"
export R2_CACHE_CONTROL="$cache_control"
export R2_CLI_CONNECT_TIMEOUT_SECONDS="$connect_timeout"
export R2_CLI_READ_TIMEOUT_SECONDS="$read_timeout"
export R2_UPLOAD_MODE="$upload_mode"

mac_arm64="$1"
mac_intel="$2"
win_msix="$3"
checksums="$4"
manifest="$5"
mac_arm64_zip="$6"
mac_intel_zip="$7"
appcast_arm64="$8"
appcast_x64="$9"
win_arm64_msix="${10:-}"
win_arm64_mode="$(
  python3 - "$manifest" "${win_arm64_msix:+has-arg}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)
has_arg = len(sys.argv) > 2

arm64 = (
    manifest.get("sources", {})
    .get("windows", {})
    .get("architectures", {})
    .get("arm64", {})
)

if arm64.get("currentLocalArtifact") is True:
    mode = "upload"
elif arm64.get("downloadable") is True:
    # A preserved ARM64 latest alias is already present on the secondary
    # bucket. Do not overwrite it with a stale local artifact, and do not
    # delete it while the manifest still advertises it as downloadable.
    mode = "keep"
elif any(key in arm64 for key in ("downloadable", "currentLocalArtifact", "currentForCodexVersion")):
    mode = "delete"
else:
    # Older manifests predate per-architecture current markers; preserve the
    # legacy positional-argument behavior for those callers.
    mode = "upload" if has_arg else "keep"
print(mode)
PY
)"
if [[ "$win_arm64_mode" == "upload" && -z "$win_arm64_msix" ]]; then
  echo "Manifest marks Windows ARM64 as current, but no ARM64 MSIX was provided." >&2
  exit 2
fi

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
    secondary_upload_object "$prefix/mac/$mac_dir/$bn" "$src_dir/$bn" "$bn"
  done < <(delta_basenames_from_appcast "$appcast")
}

secondary_upload_object() {
  local object_path="$1"
  local file="$2"
  local download_name="$3"
  local attempt
  local expected_size
  local rc

  expected_size="$(wc -c < "$file" | tr -d '[:space:]')"

  for ((attempt = 1; attempt <= upload_attempts; attempt++)); do
    echo "Secondary S3 upload attempt $attempt/$upload_attempts: $object_path"
    if bash "$repo_root/scripts/sync-r2.sh" --object "$SECONDARY_S3_BUCKET" "$object_path" "$file" "$download_name" &&
      secondary_verify_object_size "$object_path" "$expected_size"; then
      return 0
    else
      rc=$?
    fi

    if ((attempt == upload_attempts)); then
      return "$rc"
    fi

    echo "Secondary S3 upload failed for $object_path; retrying in ${retry_sleep}s." >&2
    if ((retry_sleep > 0)); then
      sleep "$retry_sleep"
    fi
  done
}

secondary_verify_object_size() {
  local object_path="$1"
  local expected_size="$2"
  local actual_size

  actual_size="$(
    aws s3api head-object \
      --bucket "$SECONDARY_S3_BUCKET" \
      --key "$object_path" \
      --endpoint-url "$SECONDARY_S3_ENDPOINT" \
      --region "$region" \
      --query ContentLength \
      --output text
  )"

  if [[ "$actual_size" != "$expected_size" ]]; then
    echo "Secondary S3 verification failed for $object_path: expected $expected_size bytes, got $actual_size." >&2
    return 1
  fi

  echo "Secondary S3 verified $object_path ($actual_size bytes)."
}

secondary_remove_object() {
  local object_path="$1"

  echo "Secondary S3 remove: $object_path"
  aws s3 rm "s3://$SECONDARY_S3_BUCKET/$object_path" \
    --endpoint-url "$SECONDARY_S3_ENDPOINT" \
    --region "$region"
}

secondary_upload_object "$prefix/mac-arm64" "$mac_arm64" Codex-mac-arm64.dmg
secondary_upload_object "$prefix/mac-intel" "$mac_intel" Codex-mac-intel.dmg
secondary_upload_object "$prefix/win" "$win_msix" Codex-Windows-x64.msix
secondary_upload_object "$prefix/win-x64" "$win_msix" Codex-Windows-x64.msix
if [[ "$win_arm64_mode" == "upload" ]]; then
  secondary_upload_object "$prefix/win-arm64" "$win_arm64_msix" Codex-Windows-arm64.msix
elif [[ "$win_arm64_mode" == "delete" ]]; then
  secondary_remove_object "$prefix/win-arm64"
fi

# Sparkle update archives, keyed to match the appcast enclosure URLs. Upload the
# archives (full .zip + every .delta) before the appcasts so the feed never
# advertises a missing enclosure.
secondary_upload_object "$prefix/mac/arm64/$mac_arm64_zip_name" "$mac_arm64_zip" "$mac_arm64_zip_name"
secondary_upload_object "$prefix/mac/intel/$mac_intel_zip_name" "$mac_intel_zip" "$mac_intel_zip_name"
upload_deltas_for_appcast "$appcast_arm64" "$mac_arm64_zip" arm64
upload_deltas_for_appcast "$appcast_x64" "$mac_intel_zip" intel

secondary_upload_object "$prefix/checksums" "$checksums" SHA256SUMS.txt
secondary_upload_object "$prefix/manifest" "$manifest" release-manifest.json

# appcast feeds change every release; keep their CDN cache short.
R2_CACHE_CONTROL="public, max-age=600" \
  secondary_upload_object "$prefix/appcast.xml" "$appcast_arm64" appcast.xml
R2_CACHE_CONTROL="public, max-age=600" \
  secondary_upload_object "$prefix/appcast-x64.xml" "$appcast_x64" appcast-x64.xml
