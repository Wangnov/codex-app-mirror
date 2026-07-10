#!/usr/bin/env bash
set -euo pipefail

manifest_path="${1:?release manifest is required}"
artifacts_dir="${2:?artifacts directory is required}"
candidate_checksums="${3:?candidate checksums path is required}"
arm_appcast="${4:?arm64 appcast path is required}"
x64_appcast="${5:?x64 appcast path is required}"
candidate_prefix="${6:?candidate prefix is required}"

: "${S3_ENDPOINT:?S3_ENDPOINT is required}"
: "${S3_BUCKET:?S3_BUCKET is required}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is required}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is required}"

region="${AWS_DEFAULT_REGION:-auto}"
upload_attempts="${S3_UPLOAD_ATTEMPTS:-4}"
backend_label="${S3_BACKEND_LABEL:-S3}"
connect_timeout="${S3_CONNECT_TIMEOUT_SECONDS:-20}"
read_timeout="${S3_READ_TIMEOUT_SECONDS:-300}"
verification_mode="${S3_SHA256_VERIFICATION_MODE:-metadata}"
bootstrap_sidecars="${S3_BOOTSTRAP_SIDECARS:-false}"

if [[ ! "$candidate_prefix" =~ ^releases/codex-app-[0-9A-Za-z._-]+$ ]]; then
  echo "Refusing unsafe candidate prefix: $candidate_prefix" >&2
  exit 1
fi
if [[ ! "$upload_attempts" =~ ^[1-9][0-9]*$ ]]; then
  echo "S3_UPLOAD_ATTEMPTS must be a positive integer" >&2
  exit 1
fi
if [[ "$verification_mode" != "metadata" && "$verification_mode" != "sidecar" ]]; then
  echo "S3_SHA256_VERIFICATION_MODE must be metadata or sidecar" >&2
  exit 1
fi

for command in aws jq sha256sum stat; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing required command: $command" >&2
    exit 1
  fi
done

export AWS_RETRY_MODE="${AWS_RETRY_MODE:-adaptive}"
export AWS_MAX_ATTEMPTS="${AWS_MAX_ATTEMPTS:-10}"
export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"
export AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}"
aws configure set default.s3.multipart_threshold 64MB
aws configure set default.s3.multipart_chunksize 64MB
aws configure set default.s3.max_concurrent_requests 4

aws_common=(
  --endpoint-url "$S3_ENDPOINT"
  --region "$region"
  --cli-connect-timeout "$connect_timeout"
  --cli-read-timeout "$read_timeout"
)

lowercase() {
  tr '[:upper:]' '[:lower:]' <<<"$1"
}

head_object() {
  local key="$1"
  aws s3api head-object \
    --bucket "$S3_BUCKET" \
    --key "$key" \
    "${aws_common[@]}" \
    --output json 2>/dev/null
}

sidecar_key() {
  printf '%s.sha256.json' "$1"
}

sidecar_exists() {
  head_object "$(sidecar_key "$1")" >/dev/null
}

sidecar_matches() {
  local key="$1"
  local expected_size="$2"
  local expected_sha="$3"
  local sidecar_file

  sidecar_file="$(mktemp)"
  if ! aws s3api get-object \
    --bucket "$S3_BUCKET" \
    --key "$(sidecar_key "$key")" \
    "$sidecar_file" \
    "${aws_common[@]}" \
    >/dev/null 2>&1; then
    rm -f "$sidecar_file"
    return 1
  fi
  if jq -e \
    --arg sha "$(lowercase "$expected_sha")" \
    --argjson size "$expected_size" '
      (.sha256 | ascii_downcase) == $sha and .size == $size
    ' "$sidecar_file" >/dev/null 2>&1; then
    rm -f "$sidecar_file"
    return 0
  fi
  rm -f "$sidecar_file"
  return 1
}

persist_sidecar() {
  local key="$1"
  local size="$2"
  local sha="$3"
  local sidecar_file attempt

  [[ "$verification_mode" == "sidecar" ]] || return 0
  sidecar_file="$(mktemp)"
  jq -n --arg sha "$(lowercase "$sha")" --argjson size "$size" \
    '{schemaVersion: 1, sha256: $sha, size: $size}' > "$sidecar_file"
  for ((attempt = 1; attempt <= upload_attempts; attempt++)); do
    if aws s3 cp "$sidecar_file" "s3://$S3_BUCKET/$(sidecar_key "$key")" \
      "${aws_common[@]}" \
      --content-type application/json \
      --cache-control "public, max-age=600" \
      --only-show-errors \
      --no-progress && sidecar_matches "$key" "$size" "$sha"; then
      rm -f "$sidecar_file"
      return 0
    fi
    if ((attempt < upload_attempts)); then
      sleep $((attempt * 2))
    fi
  done
  rm -f "$sidecar_file"
  return 1
}

object_size_matches() {
  local key="$1"
  local expected_size="$2"
  local head_json actual_size
  head_json="$(head_object "$key")" || return 1
  actual_size="$(jq -r '.ContentLength // 0' <<<"$head_json")"
  [[ "$actual_size" == "$expected_size" ]]
}

head_matches() {
  local key="$1"
  local expected_size="$2"
  local expected_sha="$3"
  local head_json actual_size actual_sha

  if ! head_json="$(head_object "$key")"; then
    return 1
  fi
  actual_size="$(jq -r '.ContentLength // 0' <<<"$head_json")"
  [[ "$actual_size" == "$expected_size" ]] || return 1
  if [[ "$verification_mode" == "sidecar" ]]; then
    sidecar_matches "$key" "$expected_size" "$expected_sha"
    return
  fi
  actual_sha="$(jq -r '.Metadata.sha256 // ""' <<<"$head_json")"
  [[ "$(lowercase "$actual_sha")" == "$(lowercase "$expected_sha")" ]]
}

file_size() {
  local file="$1"
  if stat -c '%s' "$file" >/dev/null 2>&1; then
    stat -c '%s' "$file"
  else
    stat -f '%z' "$file"
  fi
}

put_immutable() {
  local key="$1"
  local file="$2"
  local content_type="$3"
  local size sha head_json existing_size existing_sha attempt upload_ok

  [[ -f "$file" ]] || { echo "Missing upload file: $file" >&2; exit 1; }
  size="$(file_size "$file")"
  sha="$(sha256sum "$file" | awk '{print tolower($1)}')"

  if head_json="$(head_object "$key")"; then
    existing_size="$(jq -r '.ContentLength // 0' <<<"$head_json")"
    existing_sha="$(jq -r '.Metadata.sha256 // ""' <<<"$head_json")"
    if head_matches "$key" "$size" "$sha"; then
      echo "[$backend_label] immutable object already matches: s3://$S3_BUCKET/$key"
      return 0
    fi
    if [[ "$verification_mode" == "sidecar" && "$bootstrap_sidecars" == "true" ]] && ! sidecar_exists "$key"; then
      echo "[$backend_label] replacing one unverified object to bootstrap its SHA-256 sidecar: s3://$S3_BUCKET/$key" >&2
    else
      echo "[$backend_label] refusing to overwrite immutable object s3://$S3_BUCKET/$key (existing=$existing_size/${existing_sha:-no-sha256}, local=$size/$sha, verification=$verification_mode)" >&2
      exit 1
    fi
  fi

  for ((attempt = 1; attempt <= upload_attempts; attempt++)); do
    echo "[$backend_label] upload $attempt/$upload_attempts: s3://$S3_BUCKET/$key"
    upload_ok=false
    if aws s3 cp "$file" "s3://$S3_BUCKET/$key" \
      "${aws_common[@]}" \
      --metadata "sha256=$sha" \
      --content-type "$content_type" \
      --cache-control "public, max-age=31536000, immutable" \
      --only-show-errors \
      --no-progress; then
      upload_ok=true
    fi
    if [[ "$upload_ok" == "true" ]] && object_size_matches "$key" "$size" && persist_sidecar "$key" "$size" "$sha" && head_matches "$key" "$size" "$sha"; then
      return 0
    fi
    echo "[$backend_label] post-upload $verification_mode verification failed for $key" >&2

    if ((attempt < upload_attempts)); then
      sleep $((attempt * 5))
    fi
  done

  echo "[$backend_label] failed to upload verified immutable object: $key" >&2
  exit 1
}

put_replaceable_metadata() {
  local key="$1"
  local file="$2"
  local content_type="$3"
  local size sha attempt upload_ok

  [[ -f "$file" ]] || { echo "Missing upload file: $file" >&2; exit 1; }
  size="$(file_size "$file")"
  sha="$(sha256sum "$file" | awk '{print tolower($1)}')"
  if head_matches "$key" "$size" "$sha"; then
    echo "[$backend_label] candidate metadata already matches: s3://$S3_BUCKET/$key"
    return 0
  fi

  for ((attempt = 1; attempt <= upload_attempts; attempt++)); do
    echo "[$backend_label] metadata upload $attempt/$upload_attempts: s3://$S3_BUCKET/$key"
    upload_ok=false
    if aws s3 cp "$file" "s3://$S3_BUCKET/$key" \
      "${aws_common[@]}" \
      --metadata "sha256=$sha" \
      --content-type "$content_type" \
      --cache-control "public, max-age=600" \
      --only-show-errors \
      --no-progress; then
      upload_ok=true
    fi
    if [[ "$upload_ok" == "true" ]] && object_size_matches "$key" "$size" && persist_sidecar "$key" "$size" "$sha" && head_matches "$key" "$size" "$sha"; then
      return 0
    fi
    if ((attempt < upload_attempts)); then
      sleep $((attempt * 5))
    fi
  done

  echo "[$backend_label] failed to upload verified candidate metadata: $key" >&2
  exit 1
}

mac_dir="$artifacts_dir/codex-macos"
windows_dir="$artifacts_dir/codex-windows"
win_x64="$(find "$windows_dir" -maxdepth 1 -type f \( -name '*_x64__*.Msix' -o -name '*_x64__*.msix' \) | sort | head -n 1)"
win_arm64="$(find "$windows_dir" -maxdepth 1 -type f \( -name '*_arm64__*.Msix' -o -name '*_arm64__*.msix' \) | sort | head -n 1)"
arm_dmg="$mac_dir/$(jq -r '.sources.macos.arm64.mirrorBasename' "$manifest_path")"
x64_dmg="$mac_dir/$(jq -r '.sources.macos.x64.mirrorBasename' "$manifest_path")"
arm_zip_name="$(jq -r '.sources.macos.arm64.appcast.mirrorEnclosureBasename' "$manifest_path")"
x64_zip_name="$(jq -r '.sources.macos.x64.appcast.mirrorEnclosureBasename' "$manifest_path")"

base="$candidate_prefix/latest"

# Upload all bytes first. The candidate appcasts and manifest are committed last,
# so readers never observe metadata that points to a missing immutable object.
put_immutable "$base/mac-arm64" "$arm_dmg" application/x-apple-diskimage
put_immutable "$base/mac-intel" "$x64_dmg" application/x-apple-diskimage
put_immutable "$base/win" "$win_x64" application/msix
put_immutable "$base/win-x64" "$win_x64" application/msix
put_immutable "$base/win-arm64" "$win_arm64" application/msix
put_immutable "$base/mac/arm64/$arm_zip_name" "$mac_dir/$arm_zip_name" application/zip
put_immutable "$base/mac/intel/$x64_zip_name" "$mac_dir/$x64_zip_name" application/zip

while IFS= read -r basename; do
  [[ -n "$basename" ]] || continue
  if [[ "$basename" == */* ]]; then
    echo "Unsafe arm64 delta basename: $basename" >&2
    exit 1
  fi
  put_immutable "$base/mac/arm64/$basename" "$mac_dir/$basename" application/octet-stream
done < <(jq -r '.sources.macos.arm64.appcast.deltas[]?.basename // empty' "$manifest_path")

while IFS= read -r basename; do
  [[ -n "$basename" ]] || continue
  if [[ "$basename" == */* ]]; then
    echo "Unsafe x64 delta basename: $basename" >&2
    exit 1
  fi
  put_immutable "$base/mac/intel/$basename" "$mac_dir/$basename" application/octet-stream
done < <(jq -r '.sources.macos.x64.appcast.deltas[]?.basename // empty' "$manifest_path")

put_replaceable_metadata "$base/checksums" "$candidate_checksums" text/plain
put_replaceable_metadata "$base/appcast.xml" "$arm_appcast" application/xml
put_replaceable_metadata "$base/appcast-x64.xml" "$x64_appcast" application/xml
put_replaceable_metadata "$base/manifest" "$manifest_path" application/json

echo "[$backend_label] candidate snapshot complete: s3://$S3_BUCKET/$candidate_prefix/"
