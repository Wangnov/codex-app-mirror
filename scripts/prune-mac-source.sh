#!/usr/bin/env bash
set -euo pipefail

# Prune stale macOS Sparkle archives from the public mirror.
#
# The release workflow publishes the current appcast archives under
# latest/mac/{arm64,intel}/. Those files are versioned by filename, so old
# archives would accumulate forever unless we remove objects that are no longer
# referenced by the freshly published appcasts.
#
# Safety rules:
# - keep every basename passed as an argument;
# - keep objects modified inside PRUNE_GRACE_DAYS, so clients with a cached
#   previous appcast can finish downloading;
# - keep objects with an unparsable timestamp;
# - never delete directory marker keys.
#
# Usage:
#   prune-mac-source.sh <bucket> <prefix> <keep-file-or-basename> [...]

: "${R2_S3_ENDPOINT:?R2_S3_ENDPOINT must be set}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID must be set}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY must be set}"

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI is required for pruning." >&2
  exit 1
fi

if [[ $# -lt 3 ]]; then
  echo "Usage: prune-mac-source.sh <bucket> <prefix> <keep-file-or-basename> [...]" >&2
  exit 2
fi

bucket="$1"
prefix="${2#/}"
prefix="${prefix%/}"
shift 2
region="${AWS_DEFAULT_REGION:-auto}"
grace_days="${PRUNE_GRACE_DAYS:-7}"

if [[ -z "$bucket" || -z "$prefix" ]]; then
  echo "Bucket and prefix are required." >&2
  exit 2
fi
if [[ ! "$grace_days" =~ ^[0-9]+$ ]]; then
  echo "PRUNE_GRACE_DAYS must be a non-negative integer." >&2
  exit 2
fi

keep_file="$(mktemp)"
trap 'rm -f "$keep_file"' EXIT
for item in "$@"; do
  basename "$item"
done | sort -u > "$keep_file"

if [[ ! -s "$keep_file" ]]; then
  echo "At least one keep file or basename is required." >&2
  exit 2
fi

object_epoch() {
  local lastmod="$1"
  local ts
  ts="${lastmod%%.*}"
  ts="${ts%%+*}"
  ts="${ts%Z}"
  date -u -d "$lastmod" +%s 2>/dev/null \
    || date -u -jf '%Y-%m-%dT%H:%M:%S' "$ts" +%s 2>/dev/null \
    || echo 0
}

cutoff_epoch=$(( $(date -u +%s) - grace_days * 86400 ))

aws s3api list-objects-v2 \
  --bucket "$bucket" \
  --prefix "$prefix/" \
  --endpoint-url "$R2_S3_ENDPOINT" \
  --region "$region" \
  --query 'Contents[].[Key,LastModified]' \
  --output text 2>/dev/null | while read -r key lastmod _rest; do
  [[ -z "$key" || "$key" == "None" ]] && continue
  [[ "$key" == */ ]] && continue

  if grep -qxF "$(basename "$key")" "$keep_file"; then
    continue
  fi

  obj_epoch="$(object_epoch "$lastmod")"
  if [[ "$obj_epoch" -eq 0 || "$obj_epoch" -ge "$cutoff_epoch" ]]; then
    continue
  fi

  echo "prune s3://$bucket/$key"
  aws s3 rm "s3://$bucket/$key" \
    --endpoint-url "$R2_S3_ENDPOINT" \
    --region "$region" \
    --only-show-errors
done
