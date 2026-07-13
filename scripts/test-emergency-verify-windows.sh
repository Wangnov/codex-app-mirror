#!/usr/bin/env bash
set -euo pipefail

tmp_dir="$(mktemp -d)"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

python3 - "$tmp_dir" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
import zipfile

root = Path(sys.argv[1])
artifacts = root / "artifacts" / "codex-windows"
artifacts.mkdir(parents=True)
macos_artifacts = root / "artifacts" / "codex-macos"
macos_artifacts.mkdir(parents=True)
version = "26.707.3351.0"
macos_version = "26.707.31428"
macos_build = "5061"
identity = "OpenAI.CodexBeta"
family = "OpenAI.CodexBeta_2p2nqsd0c76g0"
architectures = {}

for arch in ("x64", "arm64"):
    moniker = f"{identity}_{version}_{arch}__2p2nqsd0c76g0"
    package_path = artifacts / f"{moniker}.Msix"
    manifest_xml = f'''<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10">
  <Identity Name="{identity}" Version="{version}" ProcessorArchitecture="{arch}" />
  <Applications>
    <Application Id="App" Executable="app\\ChatGPT (Beta).exe" />
  </Applications>
</Package>
'''
    with zipfile.ZipFile(package_path, "w", compression=zipfile.ZIP_DEFLATED) as package:
        package.writestr("AppxManifest.xml", manifest_xml)
        package.writestr("app/ChatGPT%20%28Beta%29.exe", b"fixture")

    architectures[arch] = {
        "architecture": arch,
        "downloadable": True,
        "version": version,
        "packageMoniker": moniker,
        "contentLength": package_path.stat().st_size,
        "catalog": {"packageFamilyName": family},
    }

macos = {}
macos_identity = {}
macos_checksum_lines = []
for arch in ("arm64", "x64"):
    dmg_name = f"ChatGPT-Beta-mac-{arch}.dmg"
    zip_name = f"ChatGPT-Beta-darwin-{arch}-{macos_version}.zip"
    dmg_path = macos_artifacts / dmg_name
    zip_path = macos_artifacts / zip_name
    dmg_path.write_bytes(f"{arch}-beta-dmg".encode())
    zip_path.write_bytes(f"{arch}-beta-zip".encode())
    dmg_sha = hashlib.sha256(dmg_path.read_bytes()).hexdigest()
    zip_sha = hashlib.sha256(zip_path.read_bytes()).hexdigest()
    macos_checksum_lines.extend((f"{dmg_sha}  {dmg_name}", f"{zip_sha}  {zip_name}"))
    macos[arch] = {
        "url": f"https://persistent.oaistatic.com/codex-app-beta/ChatGPT%20(Beta)-{macos_version}-{arch}.dmg",
        "sourceBasename": f"ChatGPT%20(Beta)-{macos_version}-{arch}.dmg",
        "mirrorBasename": dmg_name,
        "contentLength": dmg_path.stat().st_size,
        "appcastUrl": f"https://persistent.oaistatic.com/codex-app-beta/appcast{'-x64' if arch == 'x64' else ''}.xml",
        "appcast": {
            "channelTitle": "Codex (Beta)" if arch == "x64" else "Codex Updates (Public Beta)",
            "version": macos_build,
            "shortVersionString": macos_version,
            "enclosureUrl": f"https://persistent.oaistatic.com/codex-app-beta/ChatGPT%20(Beta)-darwin-{arch}-{macos_version}.zip",
            "sourceBasename": f"ChatGPT%20(Beta)-darwin-{arch}-{macos_version}.zip",
            "mirrorEnclosureBasename": zip_name,
            "enclosureLength": zip_path.stat().st_size,
            "enclosureSignature": "fixture-signature",
            "deltas": [],
        },
    }
    macos_identity[arch] = {
        "architecture": arch,
        "fileName": dmg_name,
        "sha256": dmg_sha,
        "bundleShortVersion": macos_version,
        "bundleVersion": "5059",
        "bundleIdentifier": "com.openai.codex.beta",
        "bundleName": "ChatGPT (Beta)",
        "bundleExecutable": "ChatGPT (Beta)",
        "minimumSystemVersion": "12.0",
        "teamIdentifier": "2DC432GLL2",
        "sparklePublicEdKey": "mNfr1v9t63BfgDtlw4C8lRvSY6uMggIXABDOCi3tS6k=",
        "sparkleArchiveFileName": zip_name,
        "sparkleArchiveIdentityVerified": True,
        "sparkleArchiveBundleShortVersion": macos_version,
        "sparkleArchiveBundleVersion": macos_build,
        "sparkleArchiveBundleIdentifier": "com.openai.codex.beta",
        "sparkleArchiveBundleName": "ChatGPT (Beta)",
        "sparkleArchiveBundleExecutable": "ChatGPT (Beta)",
        "sparkleArchiveTeamIdentifier": "2DC432GLL2",
        "sparkleArchivePublicEdKey": "mNfr1v9t63BfgDtlw4C8lRvSY6uMggIXABDOCi3tS6k=",
    }

(macos_artifacts / "SHA256SUMS-macos.txt").write_text(
    "\n".join(macos_checksum_lines) + "\n", encoding="ascii"
)
(macos_artifacts / "macos-identity.json").write_text(
    json.dumps({
        "schemaVersion": 1,
        "macos": macos_identity,
        "commonShortVersion": macos_version,
        "commonBundleVersion": "5059",
        "versionsMatch": True,
    }),
    encoding="utf-8",
)

probe = {
    "schemaVersion": 2,
    "version": version,
    "channel": "beta",
    "beta": {
        "contract": "issue-36-beta-prerelease",
        "expectedExecutable": "app/ChatGPT (Beta).exe",
        "expectedWindowsPackageVersion": version,
        "expectedMacosVersion": macos_version,
    },
    "publication": {
        "githubPrereleaseOnly": True,
        "githubLatestAdvanced": False,
        "objectStoragePublished": False,
        "sharedLatestAdvanced": False,
    },
    "derived": {
        "prerelease": True,
        "publishLatest": False,
        "syncLatest": False,
        "includeWindowsX64": True,
        "includeWindowsArm64": True,
        "includeMacosArm64": True,
        "includeMacosX64": True,
        "missingArchitectures": [],
    },
    "sources": {
        "windows": {
            "productId": "9N8CJ4W95TBZ",
            "packageIdentity": identity,
            "packageFamilyName": family,
            "version": version,
            "architectures": architectures,
        },
        "macos": macos,
    },
}
(root / "probe-manifest.json").write_text(json.dumps(probe), encoding="utf-8")
PY

pwsh -NoLogo -NoProfile -File "$repo_root/scripts/emergency-verify-windows.ps1" \
  -ManifestPath "$tmp_dir/probe-manifest.json" \
  -ArtifactsDir "$tmp_dir/artifacts/codex-windows" \
  -OutputPath "$tmp_dir/artifacts/codex-windows/windows-identity.json" \
  -ExpectedIdentity OpenAI.CodexBeta \
  -Channel beta \
  -ExpectedExecutable 'app/ChatGPT (Beta).exe'

jq -e '
  .channel == "beta"
  and .expectedIdentity == "OpenAI.CodexBeta"
  and .expectedExecutable == "app/ChatGPT (Beta).exe"
  and ([.architectures[]
    | .applicationExecutable == "app/ChatGPT (Beta).exe"
      and .applicationArchivePath == "app/ChatGPT%20%28Beta%29.exe"] | all)
' "$tmp_dir/artifacts/codex-windows/windows-identity.json" >/dev/null

python3 - "$tmp_dir/artifacts/codex-windows" <<'PY'
import hashlib
from pathlib import Path
import sys

root = Path(sys.argv[1])
lines = []
for package in sorted(root.glob("*.Msix")):
    lines.append(f"{hashlib.sha256(package.read_bytes()).hexdigest()}  {package.name}")
(root / "SHA256SUMS-windows.txt").write_bytes(("\r\n".join(lines) + "\r\n").encode("ascii"))
PY

cp "$tmp_dir/probe-manifest.json" "$tmp_dir/release-manifest.json"
(
  cd "$tmp_dir"

  assert_finalize_failure() {
    local manifest="$1"
    local mac_identity="$2"
    local expected_message="$3"
    local output status

    set +e
    output="$(
      bash "$repo_root/scripts/emergency-finalize-windows-beta.sh" \
        "$manifest" \
        artifacts/codex-windows/windows-identity.json \
        "$mac_identity" \
        artifacts \
        26.707.3351.0 \
        26.707.31428 \
        codex-app-beta-win-26.707.3351.0-mac-26.707.31428 2>&1
    )"
    status=$?
    set -e
    if [[ "$status" -eq 0 ]] || ! grep -Fq "$expected_message" <<<"$output"; then
      echo "Expected Beta finalizer to fail with: $expected_message" >&2
      printf '%s\n' "$output" >&2
      exit 1
    fi
  }

  jq '.commonShortVersion = "26.707.30000"' \
    artifacts/codex-macos/macos-identity.json > wrong-macos-version.json
  assert_finalize_failure \
    release-manifest.json \
    wrong-macos-version.json \
    "verified macOS Beta package version drift"

  jq '.publication.objectStoragePublished = true' \
    release-manifest.json > wrong-publication-policy.json
  assert_finalize_failure \
    wrong-publication-policy.json \
    artifacts/codex-macos/macos-identity.json \
    "Beta publication policy is not GitHub-prerelease-only"

  bash "$repo_root/scripts/emergency-finalize-windows-beta.sh" \
    release-manifest.json \
    artifacts/codex-windows/windows-identity.json \
    artifacts/codex-macos/macos-identity.json \
    artifacts \
    26.707.3351.0 \
    26.707.31428 \
    codex-app-beta-win-26.707.3351.0-mac-26.707.31428 >/dev/null

  if LC_ALL=C grep -q $'\r' SHA256SUMS.txt; then
    echo "Canonical Beta checksums must use LF line endings." >&2
    exit 1
  fi
  jq -e '
    .sources.windows.architectures.x64.applicationArchivePath == "app/ChatGPT%20%28Beta%29.exe"
    and .sources.windows.architectures.arm64.applicationArchivePath == "app/ChatGPT%20%28Beta%29.exe"
    and .sources.macos.arm64.bundleIdentifier == "com.openai.codex.beta"
    and .sources.macos.x64.bundleIdentifier == "com.openai.codex.beta"
    and .publication.githubPrereleaseOnly == true
    and .publication.objectStoragePublished == false
    and .release.destination == "github-prerelease"
    and (.candidate? == null)
  ' release-manifest.json >/dev/null

  for expected_asset in \
    ChatGPT-Beta-mac-arm64.dmg \
    ChatGPT-Beta-mac-x64.dmg \
    ChatGPT-Beta-darwin-arm64-26.707.31428.zip \
    ChatGPT-Beta-darwin-x64-26.707.31428.zip \
    windows-identity.json \
    macos-identity.json \
    release-manifest.json; do
    grep -Fq "  $expected_asset" SHA256SUMS.txt || {
      echo "Missing canonical checksum for $expected_asset" >&2
      exit 1
    }
  done

  if grep -Eq 'https://codexapp|candidate(BaseUrl|Prefix|Url)' release-manifest.json release-notes.md; then
    echo "GitHub-only Beta metadata must not contain object-storage candidate URLs." >&2
    exit 1
  fi
)

echo "Beta prerelease identity and finalization fixture PASS"
