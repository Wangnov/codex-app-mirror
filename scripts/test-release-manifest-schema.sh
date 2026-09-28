#!/usr/bin/env bash
# Validates every fixture under schemas/fixtures/ against
# schemas/release-manifest.schema.json: real/positive fixtures must pass,
# and schemas/fixtures/invalid/* must be rejected.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
schema="$repo_root/schemas/release-manifest.schema.json"
validator="$repo_root/scripts/schema/validate.js"
fixtures_dir="$repo_root/schemas/fixtures"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require node

if [[ ! -f "$schema" ]]; then
  echo "Missing schema: $schema" >&2
  exit 1
fi

if [[ ! -d "$repo_root/scripts/schema/node_modules/ajv" ]]; then
  echo "Installing pinned schema validator dependencies (npm ci)..." >&2
  (cd "$repo_root/scripts/schema" && npm ci)
fi

positive_files=()
while IFS= read -r -d '' f; do
  positive_files+=("$f")
done < <(find "$fixtures_dir" -mindepth 1 -maxdepth 1 -type d ! -name invalid -print0 | sort -z | xargs -0 -I{} find {} -name '*.json' -print0)

invalid_files=()
if [[ -d "$fixtures_dir/invalid" ]]; then
  while IFS= read -r -d '' f; do
    invalid_files+=("$f")
  done < <(find "$fixtures_dir/invalid" -name '*.json' -print0 | sort -z)
fi

if [[ ${#positive_files[@]} -eq 0 ]]; then
  echo "No positive fixtures found under $fixtures_dir" >&2
  exit 1
fi
if [[ ${#invalid_files[@]} -eq 0 ]]; then
  echo "No negative fixtures found under $fixtures_dir/invalid" >&2
  exit 1
fi

echo "== Validating ${#positive_files[@]} real/positive fixture(s) =="
node "$validator" "$schema" "${positive_files[@]}"

echo
echo "== Validating ${#invalid_files[@]} negative fixture(s) (must be rejected) =="
node "$validator" "$schema" --expect-invalid "${invalid_files[@]}"

echo
echo "release-manifest schema fixture test PASS"
