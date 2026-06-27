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

python3 - "$tmp_dir/minimal.Msix" <<'PY'
import json
import struct
import sys
import zipfile

msix_path = sys.argv[1]
package_json = json.dumps({"version": "9.8.7"}, separators=(",", ":")).encode()
header_json = json.dumps(
    {"files": {"package.json": {"size": len(package_json), "offset": "0"}}},
    separators=(",", ":"),
).encode()
header_size = 8 + len(header_json)
asar = struct.pack("<IIII", 4, header_size, len(header_json) + 4, len(header_json)) + header_json + package_json
with zipfile.ZipFile(msix_path, "w") as archive:
    archive.writestr("app/resources/app.asar", asar)
PY

test "$(python3 "$repo_root/scripts/read-windows-msix-version.py" "$tmp_dir/minimal.Msix")" = "9.8.7"

cat > "$tmp_dir/probe-manifest.json" <<'JSON'
{
  "schemaVersion": 1,
  "sources": {
    "windows": {
      "version": "1.2.3.4",
      "packageMoniker": "OpenAI.Codex_1.2.3.4_x64__2p2nqsd0c76g0",
      "contentLength": 3,
      "etag": "windows-etag",
      "architectures": {
        "x64": {
          "architecture": "x64",
          "status": "downloadable",
          "downloadable": true,
          "version": "1.2.3.4",
          "packageMoniker": "OpenAI.Codex_1.2.3.4_x64__2p2nqsd0c76g0",
          "contentLength": 3
        },
        "arm64": {
          "architecture": "arm64",
          "status": "catalog-only",
          "downloadable": false,
          "version": "1.2.3.4",
          "packageMoniker": "OpenAI.Codex_1.2.3.4_arm64__2p2nqsd0c76g0",
          "contentLength": 4
        }
      }
    },
    "macos": {
      "arm64": {
        "contentLength": 3,
        "etag": "arm64-etag",
        "appcast": {
          "shortVersionString": "1.2.3",
          "version": "6"
        }
      },
      "x64": {
        "contentLength": 3,
        "etag": "x64-etag",
        "appcast": {
          "shortVersionString": "1.2.3",
          "version": "6"
        }
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
  WINDOWS_APP_VERSION=1.2.3 "$repo_root/scripts/prepare-release-metadata.sh" \
    probe-manifest.json \
    macos-metadata.json \
    artifacts \
    https://example.com > output.txt

  grep -F 'tag=codex-app-1.2.3' output.txt
  grep -F 'title=Codex App Mirror 1.2.3' output.txt
  grep -F 'codex_version=1.2.3' output.txt
  grep -F 'include_windows=true' output.txt
  grep -F 'include_macos=true' output.txt
  grep -F 'prerelease=false' output.txt
  grep -F 'publish_latest=true' output.txt
  grep -F 'Codex-mac-arm64.dmg' SHA256SUMS.txt
  grep -F 'OpenAI.Codex_1.2.3.4_x64__2p2nqsd0c76g0.Msix' SHA256SUMS.txt
  grep -F '![Codex App Mirror](https://github.com/Wangnov/codex-app-mirror/releases/latest/download/status.png)' release-notes.md
  grep -F '| Windows x64 | `1.2.3` | `1.2.3.4` |' release-notes.md
  grep -F '| Windows ARM64 | `1.2.3` | `1.2.3.4` |  |  | Microsoft Store 目录已出现，下载 URL 待解析（`catalog-only`） |' release-notes.md
  grep -F 'Windows x64: https://example.com/latest/win-x64' release-notes.md
  grep -F '| macOS Apple Silicon | `1.2.3` | build `5` |' release-notes.md
  grep -F 'These links always point to the newest complete mirrored version.' release-notes.md

  if grep -F 'artifacts/' SHA256SUMS.txt; then
    echo "SHA256SUMS.txt should use basenames, not CI artifact paths." >&2
    exit 1
  fi

  jq '
    .sources.windows.architectures.arm64.downloadable = true
    | .sources.windows.architectures.arm64.status = "downloadable"
  ' probe-manifest.json > probe-manifest-arm64-drift.json
  mkdir arm64-drift
  (
    cd arm64-drift
    WINDOWS_APP_VERSION=1.2.3 "$repo_root/scripts/prepare-release-metadata.sh" \
      ../probe-manifest-arm64-drift.json \
      ../macos-metadata.json \
      ../artifacts \
      https://example.com > output.txt

    grep -F 'include_windows=true' output.txt
    grep -F 'publish_latest=true' output.txt
    grep -F '下载阶段上游版本漂移，待下次探测补齐（`skipped-rollout-drift`）' release-notes.md
    grep -F 'Upstream version drifted during download; will be completed on the next probe (`skipped-rollout-drift`)' release-notes.md
    test "$(jq -r '.sources.windows.architectures.arm64.downloadable' release-manifest.json)" = "false"
    test "$(jq -r '.sources.windows.architectures.arm64.status' release-manifest.json)" = "skipped-rollout-drift"
  )

  cp -R artifacts artifacts-arm64-mismatch
  cp minimal.Msix artifacts-arm64-mismatch/codex-windows/OpenAI.Codex_1.2.3.4_arm64__2p2nqsd0c76g0.Msix
  mkdir arm64-mismatch
  (
    cd arm64-mismatch
    WINDOWS_APP_VERSION=1.2.3 "$repo_root/scripts/prepare-release-metadata.sh" \
      ../probe-manifest-arm64-drift.json \
      ../macos-metadata.json \
      ../artifacts-arm64-mismatch \
      https://example.com > output.txt

    grep -F 'include_windows=true' output.txt
    grep -F '内部版本与 Windows x64 `1.2.3` 不一致，待下次探测补齐（`skipped-version-mismatch`）' release-notes.md
    grep -F 'Internal version differs from Windows x64 `1.2.3`; will be completed on the next probe (`skipped-version-mismatch`)' release-notes.md
    test "$(jq -r '.sources.windows.architectures.arm64.downloadable' release-manifest.json)" = "false"
    test "$(jq -r '.sources.windows.architectures.arm64.status' release-manifest.json)" = "skipped-version-mismatch"
    test "$(jq -r '.sources.windows.architectures.arm64.appVersion' release-manifest.json)" = "9.8.7"
    if grep -E 'OpenAI\.Codex_.*_arm64__' SHA256SUMS.txt ../artifacts-arm64-mismatch/codex-windows/SHA256SUMS-windows.txt; then
      echo "Skipped ARM64 package should not appear in checksum files." >&2
      exit 1
    fi
  )

  mkdir partial
  (
    cd partial
    WINDOWS_APP_VERSION=1.2.2 "$repo_root/scripts/prepare-release-metadata.sh" \
      ../probe-manifest.json \
      ../macos-metadata.json \
      ../artifacts \
      https://example.com > output.txt

    grep -F 'tag=codex-app-1.2.3' output.txt
    grep -F 'include_windows=false' output.txt
    grep -F 'include_macos=true' output.txt
    grep -F 'prerelease=true' output.txt
    grep -F 'publish_latest=false' output.txt
    grep -F '| Windows x64 |  |  |  |  | 待官方发布对应版本 |' release-notes.md
    grep -F 'This is a prerelease while platform coverage is incomplete.' release-notes.md
    grep -F 'Codex-mac-arm64.dmg' SHA256SUMS.txt
    if grep -F 'OpenAI.Codex_1.2.3.4_x64__2p2nqsd0c76g0.Msix' SHA256SUMS.txt; then
      echo "Partial macOS-only checksums should not reference Windows assets." >&2
      exit 1
    fi
    test "$(jq -r '.derived.platformCompleteness' release-manifest.json)" = "partial"
    test "$(jq -r '.derived.missingPlatforms[0]' release-manifest.json)" = "windows"
  )

  if WINDOWS_APP_VERSION=1.2.3 "$repo_root/scripts/prepare-release-metadata.sh" \
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
