#!/usr/bin/env bash
set -euo pipefail

mode="${SECONDARY_SYNC_MODE:-start}"
base_url="${CF_SECONDARY_SYNC_URL:-}"
token="${CF_SECONDARY_SYNC_TOKEN:-}"
release_tag="${SECONDARY_SYNC_RELEASE_TAG:-}"
force="${SECONDARY_SYNC_FORCE:-false}"
timeout_seconds="${SECONDARY_SYNC_TIMEOUT_SECONDS:-2400}"
poll_interval="${SECONDARY_SYNC_POLL_INTERVAL_SECONDS:-20}"

if [[ -z "$base_url" && -z "$token" ]]; then
  echo "Cloudflare secondary sync is not configured; skipping."
  exit 0
fi
if [[ -z "$base_url" || -z "$token" ]]; then
  echo "Cloudflare secondary sync is partially configured; set CF_SECONDARY_SYNC_URL and CF_SECONDARY_SYNC_TOKEN." >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to trigger and poll Cloudflare secondary sync." >&2
  exit 1
fi
if [[ "$mode" != "start" && "$mode" != "reconcile" ]]; then
  echo "SECONDARY_SYNC_MODE must be start or reconcile, got '$mode'." >&2
  exit 2
fi
if [[ "$force" != "true" && "$force" != "false" ]]; then
  echo "SECONDARY_SYNC_FORCE must be true or false, got '$force'." >&2
  exit 2
fi
if [[ ! "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
  echo "SECONDARY_SYNC_TIMEOUT_SECONDS must be a positive integer, got '$timeout_seconds'." >&2
  exit 2
fi
if [[ ! "$poll_interval" =~ ^[1-9][0-9]*$ ]]; then
  echo "SECONDARY_SYNC_POLL_INTERVAL_SECONDS must be a positive integer, got '$poll_interval'." >&2
  exit 2
fi

base_url="${base_url%/}"
endpoint="$base_url/sync/$mode"
payload="$(
  jq -nc \
    --arg releaseTag "$release_tag" \
    --argjson force "$force" \
    '{force: $force} + (if $releaseTag == "" then {} else {releaseTag: $releaseTag} end)'
)"

echo "Triggering Cloudflare secondary sync ($mode)."
response="$(
  curl -fsS \
    --retry 3 \
    --retry-delay 2 \
    --retry-all-errors \
    --connect-timeout 20 \
    --max-time 120 \
    -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    --data "$payload" \
    "$endpoint"
)"
echo "$response"

if [[ "$(jq -r '.skipped // false' <<<"$response")" == "true" ]]; then
  echo "Cloudflare secondary sync skipped: $(jq -r '.reason // "already in sync"' <<<"$response")"
  exit 0
fi

instance_id="$(jq -r '.id // empty' <<<"$response")"
if [[ -z "$instance_id" ]]; then
  echo "Cloudflare secondary sync response did not include a workflow instance id." >&2
  exit 1
fi

deadline=$((SECONDS + timeout_seconds))
while ((SECONDS < deadline)); do
  status="$(
    curl -fsS \
      --retry 3 \
      --retry-delay 2 \
      --retry-all-errors \
      --connect-timeout 20 \
      --max-time 120 \
      -H "Authorization: Bearer $token" \
      "$base_url/sync/status?id=$instance_id"
  )"
  state="$(jq -r '.state // .status.status // "unknown"' <<<"$status")"
  echo "Cloudflare secondary sync $instance_id state: $state"
  case "$state" in
    complete)
      echo "$status"
      exit 0
      ;;
    errored|terminated)
      echo "$status" >&2
      exit 1
      ;;
  esac
  sleep "$poll_interval"
done

echo "Timed out waiting for Cloudflare secondary sync $instance_id after ${timeout_seconds}s." >&2
exit 1
