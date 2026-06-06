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
# - keep every enclosure basename referenced by a Sparkle appcast passed as an
#   argument: the full .zip AND every <sparkle:deltas> .delta. This is what makes
#   the keep list delta-aware -- pass the freshly built appcast(s) and no live
#   delta gets pruned. (PR #8's secondary-S3 prune reuses these rules, so adding
#   the appcasts to its invocation protects deltas there too.)
# - keep objects modified inside PRUNE_GRACE_DAYS, so clients with a cached
#   previous appcast can finish downloading;
# - keep objects with an unparsable timestamp;
# - never delete directory marker keys.
#
# Usage:
#   prune-mac-source.sh <bucket> <prefix> <keep-file-or-basename-or-appcast.xml> [...]
#
# A keep argument is interpreted as:
#   - an appcast feed, if it is an existing file ending in .xml -> every
#     enclosure basename it references (full + deltas) is kept;
#   - otherwise a plain path/basename -> its basename is kept.

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

# Print every enclosure basename (full .zip + each <sparkle:deltas> .delta) that
# a Sparkle appcast references. Used to make the keep list delta-aware.
appcast_enclosure_basenames() {
  local appcast="$1"
  python3 - "$appcast" <<'PY'
import sys
import xml.etree.ElementTree as ET

SP = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
item = ET.parse(sys.argv[1]).getroot().find("./channel/item")
if item is None:
    sys.exit(0)
names = []
top = item.find("enclosure")
if top is not None and top.attrib.get("url"):
    names.append(top.attrib["url"].rsplit("/", 1)[-1])
deltas = item.find(SP + "deltas")
if deltas is not None:
    for enc in deltas.findall("enclosure"):
        url = enc.attrib.get("url", "")
        if url:
            names.append(url.rsplit("/", 1)[-1])
for name in names:
    if name:
        print(name)
PY
}

keep_file="$(mktemp)"
trap 'rm -f "$keep_file"' EXIT
for item in "$@"; do
  if [[ -f "$item" && "$item" == *.xml ]]; then
    # An appcast feed: keep every enclosure it references (full + deltas).
    if ! command -v python3 >/dev/null 2>&1; then
      echo "python3 is required to parse appcast keep argument: $item" >&2
      exit 1
    fi
    appcast_enclosure_basenames "$item"
  else
    basename "$item"
  fi
done | sort -u > "$keep_file"

if [[ ! -s "$keep_file" ]]; then
  echo "At least one keep file, basename, or appcast.xml is required." >&2
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
