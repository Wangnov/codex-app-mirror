#!/usr/bin/env bash
set -euo pipefail

manifest_path="${1:?manifest path is required}"
architecture="${2:-arm64}"

[[ -f "$manifest_path" ]] || {
  echo "Manifest not found: $manifest_path" >&2
  exit 1
}

jq -er --arg architecture "$architecture" '
  (.sources.windows.architectures[$architecture] // {}) as $entry
  | if ($entry | has("currentLocalArtifact")) then
      $entry.currentLocalArtifact
    else
      ($entry.currentForCodexVersion // false)
    end
  | if type == "boolean" then tostring
    else error("Windows " + $architecture + " current-local marker is not boolean")
    end
' "$manifest_path"
