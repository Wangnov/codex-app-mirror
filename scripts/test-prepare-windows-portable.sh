#!/usr/bin/env bash
set -euo pipefail

tmp_dir="$(mktemp -d)"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

payload_dir="$tmp_dir/msix payload"
mkdir -p "$payload_dir/app"
cat > "$payload_dir/AppxManifest.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<Package>
  <Identity Name="OpenAI.Codex" Publisher="CN=OpenAI" Version="1.2.3.4" />
</Package>
XML
printf 'fake exe' > "$payload_dir/app/Codex.exe"
printf 'fake icon' > "$payload_dir/app/resources.ico"

(
  cd "$payload_dir"
  zip -qr "$tmp_dir/Codex test.msix" AppxManifest.xml app
)

output_dir="$tmp_dir/output with spaces"
outputs_path="$tmp_dir/outputs.txt"
"$repo_root/scripts/prepare-windows-portable.sh" "$tmp_dir/Codex test.msix" "$output_dir" > "$outputs_path"
zip_path="$(sed -n '1p' "$outputs_path")"
checksum_path="$(sed -n '2p' "$outputs_path")"
package_dir="$output_dir/Codex-Windows-x64-portable-1.2.3.4"

test -f "$zip_path"
test -f "$checksum_path"
test -f "$package_dir/Run-Codex.cmd"
test -f "$package_dir/Install-Current-User.cmd"
test -f "$package_dir/Uninstall-Current-User.cmd"
test -f "$package_dir/Codex.exe"

grep -F 'set "CODEX_EXE=%~dp0Codex.exe"' "$package_dir/Run-Codex.cmd"
grep -F 'start "" "%CODEX_EXE%" %*' "$package_dir/Run-Codex.cmd"
grep -F 'if not exist "%SHORTCUT_DIR%" mkdir "%SHORTCUT_DIR%"' "$package_dir/Install-Current-User.cmd"
grep -F '$s=$w.CreateShortcut($env:SHORTCUT)' "$package_dir/Install-Current-User.cmd"
grep -F '$s.TargetPath=(Join-Path $env:TARGET_DIR '"'"'Codex.exe'"'"')' "$package_dir/Install-Current-User.cmd"

unzip -l "$zip_path" | grep -F 'Codex-Windows-x64-portable-1.2.3.4/Run-Codex.cmd'
grep -F 'Codex-Windows-x64-portable-1.2.3.4.zip' "$checksum_path"

echo "prepare-windows-portable fixture test PASS"
