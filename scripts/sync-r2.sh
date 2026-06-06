#!/usr/bin/env bash
set -euo pipefail

: "${R2_S3_ENDPOINT:?R2_S3_ENDPOINT must be set, for example https://<account-id>.r2.cloudflarestorage.com}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID must be set}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY must be set}"

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI is required for multipart-capable R2 uploads." >&2
  exit 1
fi

content_type_for() {
  case "$1" in
    *.dmg) printf '%s' 'application/x-apple-diskimage' ;;
    *.Msix|*.msix) printf '%s' 'application/vnd.ms-appx' ;;
    *.json) printf '%s' 'application/json' ;;
    *.xml) printf '%s' 'application/xml' ;;
    *.zip) printf '%s' 'application/octet-stream' ;;
    *.txt) printf '%s' 'text/plain; charset=utf-8' ;;
    *) printf '%s' 'application/octet-stream' ;;
  esac
}

upload_file() {
  local file="$1"
  local object_path="${2#/}"
  local download_name="$3"
  local content_type_source="$4"
  local cache_control="${R2_CACHE_CONTROL:-no-cache}"

  if [[ ! -f "$file" ]]; then
    echo "Not a file: $file" >&2
    exit 1
  fi

  if [[ -z "$object_path" || -z "$download_name" ]]; then
    echo "Object path and download name are required." >&2
    exit 2
  fi

  content_type="$(content_type_for "$content_type_source")"

  echo "Uploading $file to r2://$bucket/$object_path"
  aws s3 cp "$file" "s3://$bucket/$object_path" \
    --endpoint-url "$R2_S3_ENDPOINT" \
    --region "${AWS_DEFAULT_REGION:-auto}" \
    --content-type "$content_type" \
    --content-disposition "attachment; filename=\"$download_name\"" \
    --cache-control "$cache_control" \
    --no-progress
}

if [[ "${1:-}" == "--object" ]]; then
  if [[ $# -lt 4 || $# -gt 5 ]]; then
    echo "Usage: sync-r2.sh --object <bucket> <object-key> <file> [download-name]" >&2
    exit 2
  fi

  bucket="$2"
  object_path="$3"
  file="$4"
  download_name="${5:-$(basename "$file")}"

  if [[ -z "$bucket" ]]; then
    echo "Bucket is required." >&2
    exit 2
  fi

  upload_file "$file" "$object_path" "$download_name" "$(basename "$file")"
  exit 0
fi

if [[ $# -lt 3 ]]; then
  echo "Usage: sync-r2.sh <bucket> <prefix> <file> [file ...]" >&2
  exit 2
fi

bucket="$1"
prefix="${2#/}"
prefix="${prefix%/}"
shift 2

if [[ -z "$bucket" || -z "$prefix" ]]; then
  echo "Bucket and prefix are required." >&2
  exit 2
fi

for file in "$@"; do
  name="$(basename "$file")"
  upload_file "$file" "$prefix/$name" "$name" "$name"
done
