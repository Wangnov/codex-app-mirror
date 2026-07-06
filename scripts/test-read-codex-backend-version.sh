#!/usr/bin/env bash
set -euo pipefail

tmp_dir="$(mktemp -d)"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_dir/Codex.app/Contents/Resources"

printf 'noise codex-cli 0.142.5 more noise' > "$tmp_dir/Codex.app/Contents/Resources/codex"
test "$(python3 "$repo_root/scripts/read-codex-backend-version.py" "$tmp_dir/Codex.app")" = "0.142.5"

printf 'prefix 0.143.0https://chatgpt.com/backend-api/ suffix' > "$tmp_dir/backend"
test "$(python3 "$repo_root/scripts/read-codex-backend-version.py" "$tmp_dir/backend")" = "0.143.0"

printf 'no backend version here' > "$tmp_dir/missing"
if python3 "$repo_root/scripts/read-codex-backend-version.py" "$tmp_dir/missing" >/dev/null 2>&1; then
  echo "Expected missing backend version to fail." >&2
  exit 1
fi

echo "read-codex-backend-version fixture PASS"
