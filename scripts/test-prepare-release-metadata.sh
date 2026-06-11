#!/usr/bin/env bash
set -euo pipefail

tmp_dir="$(mktemp -d)"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_dir/artifacts/codex-macos" "$tmp_dir/artifacts/codex-windows"

printf 'arm' > "$tmp_dir/artifacts/codex-macos/Codex-mac-arm64.dmg"
printf 'x64' > "$tmp_dir/artifacts/codex-macos/Codex-mac-x64.dmg"
printf 'win' > "$tmp_dir/artifacts/codex-windows/OpenAI.Codex_1.2.3.4_x64__2p2nqsd0c76g0.Msix"
printf 'macsum' > "$tmp_dir/artifacts/codex-macos/SHA256SUMS-macos.txt"
printf 'winsum' > "$tmp_dir/artifacts/codex-windows/SHA256SUMS-windows.txt"

cat > "$tmp_dir/probe-manifest.json" <<'JSON'
{
  "schemaVersion": 1,
  "sources": {
    "windows": {
      "version": "1.2.3.4",
      "packageMoniker": "OpenAI.Codex_1.2.3.4_x64__2p2nqsd0c76g0",
      "contentLength": 3,
      "etag": "windows-etag"
    },
    "macos": {
      "arm64": {
        "contentLength": 3,
        "etag": "arm64-etag"
      },
      "x64": {
        "contentLength": 3,
        "etag": "x64-etag"
      }
    }
  }
}
JSON

cat > "$tmp_dir/macos-metadata.json" <<'JSON'
{
  "macos": {
    "arm64": {
      "bundleShortVersion": "1.2.3",
      "bundleVersion": "5",
      "bundleIdentifier": "com.openai.codex",
      "minimumSystemVersion": "12.0",
      "sha256": "arm64-sha256"
    },
    "x64": {
      "bundleShortVersion": "1.2.3",
      "bundleVersion": "5",
      "bundleIdentifier": "com.openai.codex",
      "minimumSystemVersion": "12.0",
      "sha256": "x64-sha256"
    }
  },
  "commonShortVersion": "1.2.3",
  "commonBundleVersion": "5",
  "versionsMatch": true
}
JSON

(
  cd "$tmp_dir"
  "$repo_root/scripts/prepare-release-metadata.sh" \
    probe-manifest.json \
    macos-metadata.json \
    artifacts \
    https://example.com > output.txt

  grep -F 'tag=codex-app-win-1.2.3.4-mac-1.2.3-b5' output.txt
  grep -F 'title=Codex App Mirror 1.2' output.txt
  grep -F 'Codex-mac-arm64.dmg' SHA256SUMS.txt
  grep -F 'OpenAI.Codex_1.2.3.4_x64__2p2nqsd0c76g0.Msix' SHA256SUMS.txt
  grep -F '![Codex App Mirror](https://github.com/Wangnov/codex-app-mirror/releases/latest/download/status.png)' release-notes.md
  grep -F 'These links always point to the newest mirrored version.' release-notes.md

  if grep -F 'artifacts/' SHA256SUMS.txt; then
    echo "SHA256SUMS.txt should use basenames, not CI artifact paths." >&2
    exit 1
  fi

  if "$repo_root/scripts/prepare-release-metadata.sh" \
    probe-manifest.json \
    macos-metadata.json \
    artifacts \
    https://example.com \
    $'bad-tag\nrelease_tag=evil' > "$tmp_dir/invalid-tag-output.txt" 2>&1; then
    echo "prepare-release-metadata.sh should reject multiline release tags." >&2
    exit 1
  fi
  grep -F 'Invalid release tag' "$tmp_dir/invalid-tag-output.txt"
)
