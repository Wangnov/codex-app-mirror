#!/usr/bin/env bash
set -euo pipefail

tmp_dir="$(mktemp -d)"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

python3 - "$tmp_dir" <<'PY'
import json
from pathlib import Path
import sys
import zipfile

root = Path(sys.argv[1])
artifacts = root / "artifacts" / "codex-windows"
artifacts.mkdir(parents=True)
version = "26.707.3351.0"
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

probe = {
    "version": version,
    "emergency": {
        "contract": "issue-36-windows-beta",
        "channel": "beta",
        "expectedExecutable": "app/ChatGPT (Beta).exe",
        "sharedLatestAdvanced": False,
    },
    "derived": {
        "prerelease": True,
        "publishLatest": False,
        "syncLatest": False,
        "includeWindowsX64": True,
        "includeWindowsArm64": True,
        "includeMacosArm64": False,
        "includeMacosX64": False,
        "missingArchitectures": [],
    },
    "sources": {
        "windows": {
            "productId": "9N8CJ4W95TBZ",
            "packageIdentity": identity,
            "packageFamilyName": family,
            "version": version,
            "architectures": architectures,
        }
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
  bash "$repo_root/scripts/emergency-finalize-windows-beta.sh" \
    release-manifest.json \
    artifacts/codex-windows/windows-identity.json \
    artifacts \
    26.707.3351.0 \
    https://codexapp-r2.agentsmirror.com \
    codex-app-beta-26.707.3351.0 >/dev/null

  if LC_ALL=C grep -q $'\r' SHA256SUMS.txt; then
    echo "Canonical Beta checksums must use LF line endings." >&2
    exit 1
  fi
  jq -e '
    .sources.windows.architectures.x64.applicationArchivePath == "app/ChatGPT%20%28Beta%29.exe"
    and .sources.windows.architectures.arm64.applicationArchivePath == "app/ChatGPT%20%28Beta%29.exe"
    and .candidate.sharedLatestAdvanced == false
  ' release-manifest.json >/dev/null
)

echo "emergency Windows identity fixture PASS"
