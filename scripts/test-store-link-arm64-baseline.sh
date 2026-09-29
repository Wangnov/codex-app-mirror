#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if ! grep -Eq '^[[:space:]]*133399034,' scripts/store-link/Program.cs; then
  echo "store-link baseline is missing non-leaf update id 133399034, which is required for ARM64 Store package applicability." >&2
  exit 1
fi

echo "store-link arm64 baseline fixture PASS"
