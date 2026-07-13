#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

write_manifest() {
  local entry="$1"
  jq -n --argjson entry "$entry" '{sources:{windows:{architectures:{arm64:$entry}}}}' \
    > "$tmp_dir/manifest.json"
}

# An explicit false must win over the legacy currentForCodexVersion=true
# compatibility marker. jq's `false // true` would incorrectly return true.
write_manifest '{"currentLocalArtifact":false,"currentForCodexVersion":true}'
test "$(bash "$repo_root/scripts/read-current-local-artifact.sh" "$tmp_dir/manifest.json" arm64)" = false

write_manifest '{"currentLocalArtifact":true,"currentForCodexVersion":false}'
test "$(bash "$repo_root/scripts/read-current-local-artifact.sh" "$tmp_dir/manifest.json" arm64)" = true

# Older manifests without the explicit marker retain the compatibility fallback.
write_manifest '{"currentForCodexVersion":true}'
test "$(bash "$repo_root/scripts/read-current-local-artifact.sh" "$tmp_dir/manifest.json" arm64)" = true

write_manifest '{}'
test "$(bash "$repo_root/scripts/read-current-local-artifact.sh" "$tmp_dir/manifest.json" arm64)" = false

write_manifest '{"currentLocalArtifact":"false","currentForCodexVersion":true}'
set +e
invalid_output="$(bash "$repo_root/scripts/read-current-local-artifact.sh" "$tmp_dir/manifest.json" arm64 2>&1)"
invalid_status=$?
set -e
if [[ "$invalid_status" -eq 0 ]] || ! grep -Fq 'current-local marker is not boolean' <<<"$invalid_output"; then
  echo "Expected a non-boolean current-local marker to fail closed." >&2
  printf '%s\n' "$invalid_output" >&2
  exit 1
fi

echo "read-current-local-artifact fixture PASS"
