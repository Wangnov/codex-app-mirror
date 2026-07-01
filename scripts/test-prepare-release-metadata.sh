#!/usr/bin/env bash
set -euo pipefail

tmp_dir="$(mktemp -d)"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

write_minimal_msix() {
  local path="$1"
  local version="$2"

  python3 - "$path" "$version" <<'PY'
import json
import struct
import sys
import zipfile

msix_path = sys.argv[1]
version = sys.argv[2]
package_json = json.dumps({"version": version}, separators=(",", ":")).encode()
header_json = json.dumps(
    {"files": {"package.json": {"size": len(package_json), "offset": "0"}}},
    separators=(",", ":"),
).encode()
header_size = 8 + len(header_json)
asar = struct.pack("<IIII", 4, header_size, len(header_json) + 4, len(header_json)) + header_json + package_json
with zipfile.ZipFile(msix_path, "w") as archive:
    archive.writestr("app/resources/app.asar", asar)
PY
}

mkdir -p "$tmp_dir/artifacts/codex-macos" "$tmp_dir/artifacts/codex-windows"
mkdir -p "$tmp_dir/bin"

printf 'arm' > "$tmp_dir/artifacts/codex-macos/Codex-mac-arm64.dmg"
printf 'x64' > "$tmp_dir/artifacts/codex-macos/Codex-mac-x64.dmg"
printf 'armzip123' > "$tmp_dir/artifacts/codex-macos/Codex-darwin-arm64-1.2.3.zip"
printf 'armzip124' > "$tmp_dir/artifacts/codex-macos/Codex-darwin-arm64-1.2.4.zip"
printf 'x64zip123' > "$tmp_dir/artifacts/codex-macos/Codex-darwin-x64-1.2.3.zip"
printf 'win' > "$tmp_dir/artifacts/codex-windows/OpenAI.Codex_1.2.3.4_x64__2p2nqsd0c76g0.Msix"
write_minimal_msix "$tmp_dir/artifacts/codex-windows/OpenAI.Codex_1.2.3.4_arm64__2p2nqsd0c76g0.Msix" 1.2.3
write_minimal_msix "$tmp_dir/minimal-9.8.7.Msix" 9.8.7

test "$(python3 "$repo_root/scripts/read-windows-msix-version.py" "$tmp_dir/artifacts/codex-windows/OpenAI.Codex_1.2.3.4_arm64__2p2nqsd0c76g0.Msix")" = "1.2.3"
test "$(python3 "$repo_root/scripts/read-windows-msix-version.py" "$tmp_dir/minimal-9.8.7.Msix")" = "9.8.7"

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
          "status": "downloadable",
          "downloadable": true,
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
  grep -F 'include_windows_x64=true' output.txt
  grep -F 'include_windows_arm64=true' output.txt
  grep -F 'include_macos_arm64=true' output.txt
  grep -F 'include_macos_x64=true' output.txt
  grep -F 'prerelease=false' output.txt
  grep -F 'publish_latest=true' output.txt
  grep -F 'sync_latest=true' output.txt
  grep -F 'Codex-mac-arm64.dmg' SHA256SUMS.txt
  grep -F 'Codex-darwin-x64-1.2.3.zip' SHA256SUMS.txt
  grep -F 'OpenAI.Codex_1.2.3.4_x64__2p2nqsd0c76g0.Msix' SHA256SUMS.txt
  grep -F 'OpenAI.Codex_1.2.3.4_arm64__2p2nqsd0c76g0.Msix' SHA256SUMS.txt
  grep -F 'OpenAI.Codex_1.2.3.4_arm64__2p2nqsd0c76g0.Msix' latest-SHA256SUMS.txt
  grep -F '![Codex App Mirror](https://github.com/Wangnov/codex-app-mirror/releases/latest/download/status.png)' release-notes.md
  grep -F '| Windows x64 | `1.2.3` | `1.2.3.4` |' release-notes.md
  grep -F '| Windows ARM64 | `1.2.3` | `1.2.3.4` |' release-notes.md
  grep -F 'Windows x64: https://example.com/latest/win-x64' release-notes.md
  grep -F '| macOS Apple Silicon | `1.2.3` | build `5` |' release-notes.md
  grep -F 'These latest links roll forward per architecture:' release-notes.md
  test "$(jq -r '.schemaVersion' release-manifest.json)" = "4"
  test "$(jq -r '.derived.missingArchitectures | length' release-manifest.json)" = "0"
  test "$(jq -r '.sources.windows.architectures.arm64.currentForCodexVersion' release-manifest.json)" = "true"
  test "$(jq -r '.sources.windows.architectures.arm64.currentLocalArtifact' release-manifest.json)" = "true"
  test "$(jq -r '.derived.latestChecksums["Codex-mac-arm64.dmg"] | test("^[0-9a-f]{64}$")' release-manifest.json)" = "true"
  test "$(jq -r '.derived.latestChecksums["OpenAI.Codex_1.2.3.4_arm64__2p2nqsd0c76g0.Msix"] | test("^[0-9a-f]{64}$")' release-manifest.json)" = "true"

  if grep -F 'artifacts/' SHA256SUMS.txt; then
    echo "SHA256SUMS.txt should use basenames, not CI artifact paths." >&2
    exit 1
  fi

  cp -R artifacts artifacts-arm64-drift
  rm artifacts-arm64-drift/codex-windows/OpenAI.Codex_1.2.3.4_arm64__2p2nqsd0c76g0.Msix
  mkdir arm64-drift
  (
    cd arm64-drift
    WINDOWS_APP_VERSION=1.2.3 "$repo_root/scripts/prepare-release-metadata.sh" \
      ../probe-manifest.json \
      ../macos-metadata.json \
      ../artifacts-arm64-drift \
      https://example.com > output.txt

    grep -F 'include_windows=true' output.txt
    grep -F 'include_windows_x64=true' output.txt
    grep -F 'include_windows_arm64=false' output.txt
    grep -F 'publish_latest=false' output.txt
    grep -F '下载阶段上游版本漂移，待下次探测补齐（`skipped-rollout-drift`）' release-notes.md
    grep -F 'Upstream version drifted during download; will be retried on the next probe (`skipped-rollout-drift`)' release-notes.md
    test "$(jq -r '.sources.windows.architectures.arm64.downloadable' release-manifest.json)" = "false"
    test "$(jq -r '.sources.windows.architectures.arm64.status' release-manifest.json)" = "skipped-rollout-drift"
    if grep -E 'OpenAI\.Codex_.*_arm64__' SHA256SUMS.txt ../artifacts-arm64-drift/codex-windows/SHA256SUMS-windows.txt; then
      echo "Missing ARM64 package should not appear in release checksum files." >&2
      exit 1
    fi
  )

  cat > previous-release-manifest.json <<'JSON'
{
  "schemaVersion": 4,
  "sources": {
    "windows": {
      "architectures": {
        "arm64": {
          "architecture": "arm64",
          "status": "downloadable",
          "downloadable": true,
          "version": "1.2.2.4",
          "appVersion": "1.2.2",
          "packageMoniker": "OpenAI.Codex_1.2.2.4_arm64__2p2nqsd0c76g0",
          "contentLength": 12,
          "lastModified": "Wed, 10 Jun 2026 00:00:00 GMT"
        }
      }
    }
  }
}
JSON
  cat > previous-SHA256SUMS.txt <<'SUMS'
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  OpenAI.Codex_1.2.2.4_arm64__2p2nqsd0c76g0.Msix
SUMS
  cat > bin/curl <<'CURL'
#!/usr/bin/env bash
set -euo pipefail

url="${*: -1}"
case "$url" in
  *latest/manifest*)
    cat ../previous-release-manifest.json
    ;;
  *latest/checksums*)
    cat ../previous-SHA256SUMS.txt
    ;;
  *)
    echo "unexpected curl URL: $url" >&2
    exit 1
    ;;
esac
CURL
  chmod +x bin/curl
  mkdir arm64-drift-preserve
  (
    cd arm64-drift-preserve
    PATH="../bin:$PATH" \
    INHERIT_LATEST_FROM_MIRROR=true \
    WINDOWS_APP_VERSION=1.2.3 "$repo_root/scripts/prepare-release-metadata.sh" \
      ../probe-manifest.json \
      ../macos-metadata.json \
      ../artifacts-arm64-drift \
      https://example.com > output.txt

    grep -F 'include_windows_arm64=false' output.txt
    grep -F 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  OpenAI.Codex_1.2.2.4_arm64__2p2nqsd0c76g0.Msix' latest-SHA256SUMS.txt
    if grep -F 'OpenAI.Codex_1.2.2.4_arm64__2p2nqsd0c76g0.Msix' SHA256SUMS.txt; then
      echo "Preserved ARM64 package should not appear in this release checksum." >&2
      exit 1
    fi
    test "$(jq -r '.sources.windows.architectures.arm64.downloadable' release-manifest.json)" = "true"
    test "$(jq -r '.sources.windows.architectures.arm64.appVersion' release-manifest.json)" = "1.2.2"
    test "$(jq -r '.sources.windows.architectures.arm64.currentForCodexVersion' release-manifest.json)" = "false"
    test "$(jq -r '.sources.windows.architectures.arm64.currentLocalArtifact' release-manifest.json)" = "false"
    test "$(jq -r '.sources.windows.architectures.arm64.preservedFromLatest' release-manifest.json)" = "true"
    test "$(jq -r '.derived.latestChecksums["OpenAI.Codex_1.2.2.4_arm64__2p2nqsd0c76g0.Msix"]' release-manifest.json)" = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  )

  cp -R artifacts artifacts-arm64-unreadable
  printf 'not a zip' > artifacts-arm64-unreadable/codex-windows/OpenAI.Codex_1.2.3.4_arm64__2p2nqsd0c76g0.Msix
  mkdir arm64-unreadable-preserve
  (
    cd arm64-unreadable-preserve
    PATH="../bin:$PATH" \
    INHERIT_LATEST_FROM_MIRROR=true \
    WINDOWS_APP_VERSION=1.2.3 "$repo_root/scripts/prepare-release-metadata.sh" \
      ../probe-manifest.json \
      ../macos-metadata.json \
      ../artifacts-arm64-unreadable \
      https://example.com > output.txt

    grep -F 'tag=codex-app-1.2.3' output.txt
    grep -F 'include_windows_arm64=false' output.txt
    grep -F 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  OpenAI.Codex_1.2.2.4_arm64__2p2nqsd0c76g0.Msix' latest-SHA256SUMS.txt
    if grep -F 'OpenAI.Codex_1.2.3.4_arm64__2p2nqsd0c76g0.Msix' latest-SHA256SUMS.txt; then
      echo "Unreadable local ARM64 package should not overwrite preserved latest checksum." >&2
      exit 1
    fi
    test "$(jq -r '.sources.windows.architectures.arm64.appVersion' release-manifest.json)" = "1.2.2"
    test "$(jq -r '.sources.windows.architectures.arm64.currentForCodexVersion' release-manifest.json)" = "false"
    test "$(jq -r '.sources.windows.architectures.arm64.currentLocalArtifact' release-manifest.json)" = "false"
  )

  cat > previous-release-manifest.json <<'JSON'
{
  "schemaVersion": 4,
  "sources": {
    "windows": {
      "architectures": {
        "arm64": {
          "architecture": "arm64",
          "status": "downloadable",
          "downloadable": true,
          "version": "1.2.3.4",
          "appVersion": "1.2.3",
          "packageMoniker": "OpenAI.Codex_1.2.3.4_arm64__2p2nqsd0c76g0",
          "contentLength": 12,
          "lastModified": "Wed, 10 Jun 2026 00:00:00 GMT"
        }
      }
    }
  }
}
JSON
  cat > previous-SHA256SUMS.txt <<'SUMS'
cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc  OpenAI.Codex_1.2.3.4_arm64__2p2nqsd0c76g0.Msix
SUMS
  mkdir arm64-drift-preserve-same-version
  (
    cd arm64-drift-preserve-same-version
    PATH="../bin:$PATH" \
    INHERIT_LATEST_FROM_MIRROR=true \
    WINDOWS_APP_VERSION=1.2.3 "$repo_root/scripts/prepare-release-metadata.sh" \
      ../probe-manifest.json \
      ../macos-metadata.json \
      ../artifacts-arm64-drift \
      https://example.com > output.txt

    grep -F 'include_windows_arm64=true' output.txt
    grep -F 'publish_latest=true' output.txt
    grep -F 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc  OpenAI.Codex_1.2.3.4_arm64__2p2nqsd0c76g0.Msix' latest-SHA256SUMS.txt
    grep -F 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc  OpenAI.Codex_1.2.3.4_arm64__2p2nqsd0c76g0.Msix' SHA256SUMS.txt
    grep -F 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc  OpenAI.Codex_1.2.3.4_arm64__2p2nqsd0c76g0.Msix' ../artifacts-arm64-drift/codex-windows/SHA256SUMS-windows.txt
    test "$(jq -r '.derived.platformCompleteness' release-manifest.json)" = "complete"
    test "$(jq -r '.sources.windows.architectures.arm64.appVersion' release-manifest.json)" = "1.2.3"
    test "$(jq -r '.sources.windows.architectures.arm64.currentForCodexVersion' release-manifest.json)" = "true"
    test "$(jq -r '.sources.windows.architectures.arm64.currentLocalArtifact' release-manifest.json)" = "false"
    test "$(jq -r '.sources.windows.architectures.arm64.preservedFromLatest' release-manifest.json)" = "true"
    test "$(jq -r '.derived.latestChecksums["OpenAI.Codex_1.2.3.4_arm64__2p2nqsd0c76g0.Msix"]' release-manifest.json)" = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  )

  cat > previous-release-manifest.json <<'JSON'
{
  "schemaVersion": 4,
  "sources": {
    "windows": {
      "architectures": {
        "arm64": {
          "architecture": "arm64",
          "status": "downloadable",
          "downloadable": true,
          "version": "1.2.4.4",
          "appVersion": "1.2.4",
          "packageMoniker": "OpenAI.Codex_1.2.4.4_arm64__2p2nqsd0c76g0",
          "contentLength": 12,
          "lastModified": "Wed, 10 Jun 2026 00:00:00 GMT"
        }
      }
    }
  }
}
JSON
  cat > previous-SHA256SUMS.txt <<'SUMS'
bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  OpenAI.Codex_1.2.4.4_arm64__2p2nqsd0c76g0.Msix
SUMS
  mkdir arm64-preserved-newer-than-target
  (
    cd arm64-preserved-newer-than-target
    PATH="../bin:$PATH" \
    INHERIT_LATEST_FROM_MIRROR=true \
    WINDOWS_APP_VERSION=1.2.3 "$repo_root/scripts/prepare-release-metadata.sh" \
      ../probe-manifest.json \
      ../macos-metadata.json \
      ../artifacts-arm64-drift \
      https://example.com > output.txt

    grep -F 'tag=codex-app-1.2.3' output.txt
    grep -F 'codex_version=1.2.3' output.txt
    grep -F 'include_windows_x64=true' output.txt
    grep -F 'include_windows_arm64=false' output.txt
    grep -F 'include_macos=true' output.txt
    grep -F 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  OpenAI.Codex_1.2.4.4_arm64__2p2nqsd0c76g0.Msix' latest-SHA256SUMS.txt
    test "$(jq -r '.sources.windows.architectures.arm64.appVersion' release-manifest.json)" = "1.2.4"
    test "$(jq -r '.sources.windows.architectures.arm64.currentForCodexVersion' release-manifest.json)" = "false"
    test "$(jq -r '.sources.windows.architectures.arm64.currentLocalArtifact' release-manifest.json)" = "false"
    test "$(jq -r '.derived.latestChecksums["OpenAI.Codex_1.2.4.4_arm64__2p2nqsd0c76g0.Msix"]' release-manifest.json)" = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  )

  cp -R artifacts artifacts-arm64-new
  cp minimal-9.8.7.Msix artifacts-arm64-new/codex-windows/OpenAI.Codex_1.2.3.4_arm64__2p2nqsd0c76g0.Msix
  mkdir arm64-newer
  (
    cd arm64-newer
    WINDOWS_APP_VERSION=1.2.3 "$repo_root/scripts/prepare-release-metadata.sh" \
      ../probe-manifest.json \
      ../macos-metadata.json \
      ../artifacts-arm64-new \
      https://example.com > output.txt

    grep -F 'tag=codex-app-9.8.7' output.txt
    grep -F 'include_windows=true' output.txt
    grep -F 'include_windows_x64=false' output.txt
    grep -F 'include_windows_arm64=true' output.txt
    grep -F 'include_macos=false' output.txt
    grep -F 'publish_latest=false' output.txt
    grep -F 'OpenAI.Codex_1.2.3.4_arm64__2p2nqsd0c76g0.Msix' SHA256SUMS.txt
    grep -F 'OpenAI.Codex_1.2.3.4_x64__2p2nqsd0c76g0.Msix' latest-SHA256SUMS.txt
    if grep -F 'OpenAI.Codex_1.2.3.4_x64__2p2nqsd0c76g0.Msix' SHA256SUMS.txt; then
      echo "Windows x64 should stay out of the target release checksum when only ARM64 advanced." >&2
      exit 1
    fi
    test "$(jq -r '.sources.windows.architectures.arm64.downloadable' release-manifest.json)" = "true"
    test "$(jq -r '.sources.windows.architectures.arm64.status' release-manifest.json)" = "downloadable"
    test "$(jq -r '.sources.windows.architectures.arm64.appVersion' release-manifest.json)" = "9.8.7"
    test "$(jq -r '.sources.windows.architectures.arm64.currentForCodexVersion' release-manifest.json)" = "true"
    test "$(jq -r '.sources.windows.architectures.arm64.currentLocalArtifact' release-manifest.json)" = "true"
    test "$(jq -r '.sources.windows.architectures.x64.currentForCodexVersion' release-manifest.json)" = "false"
  )

  jq '.sources.macos.arm64.appcast.shortVersionString = "1.2.4"' \
    probe-manifest.json > probe-manifest-mac-arm-ahead.json
  jq '
    .macos.arm64.bundleShortVersion = "1.2.4"
    | .commonShortVersion = ""
    | .versionsMatch = false
  ' macos-metadata.json > macos-metadata-arm-ahead.json
  mkdir mac-arm-ahead
  (
    cd mac-arm-ahead
    WINDOWS_APP_VERSION=1.2.3 "$repo_root/scripts/prepare-release-metadata.sh" \
      ../probe-manifest-mac-arm-ahead.json \
      ../macos-metadata-arm-ahead.json \
      ../artifacts \
      https://example.com > output.txt

    grep -F 'tag=codex-app-1.2.4' output.txt
    grep -F 'include_windows=false' output.txt
    grep -F 'include_macos=true' output.txt
    grep -F 'include_macos_arm64=true' output.txt
    grep -F 'include_macos_x64=false' output.txt
    grep -F 'prerelease=true' output.txt
    grep -F 'publish_latest=false' output.txt
    grep -F 'sync_latest=true' output.txt
    grep -F 'Codex-mac-arm64.dmg' SHA256SUMS.txt
    grep -F 'Codex-darwin-arm64-1.2.4.zip' SHA256SUMS.txt
    grep -F 'Codex-mac-x64.dmg' latest-SHA256SUMS.txt
    grep -F 'OpenAI.Codex_1.2.3.4_x64__2p2nqsd0c76g0.Msix' latest-SHA256SUMS.txt
    grep -F 'OpenAI.Codex_1.2.3.4_arm64__2p2nqsd0c76g0.Msix' latest-SHA256SUMS.txt
    if grep -F 'Codex-mac-x64.dmg' SHA256SUMS.txt; then
      echo "macOS x64 should stay out of the target release checksum when only arm64 advanced." >&2
      exit 1
    fi
    if grep -F 'OpenAI.Codex_1.2.3.4_x64__2p2nqsd0c76g0.Msix' SHA256SUMS.txt; then
      echo "Windows x64 should stay out of the target release checksum when only macOS arm64 advanced." >&2
      exit 1
    fi
    test "$(jq -r '.derived.platformCompleteness' release-manifest.json)" = "partial"
    test "$(jq -r '.derived.missingArchitectures | index("macos-x64") != null' release-manifest.json)" = "true"
    test "$(jq -r '.sources.macos.arm64.currentForCodexVersion' release-manifest.json)" = "true"
    test "$(jq -r '.sources.macos.x64.currentForCodexVersion' release-manifest.json)" = "false"
    test "$(jq -r '.sources.windows.architectures.arm64.currentForCodexVersion' release-manifest.json)" = "false"
    test "$(jq -r '.sources.windows.architectures.arm64.currentLocalArtifact' release-manifest.json)" = "true"
    grep -F '这些 latest 链接按架构滚动' release-notes.md
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

echo "prepare-release-metadata fixture test PASS"
