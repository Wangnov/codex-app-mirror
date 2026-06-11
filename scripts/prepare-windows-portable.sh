#!/usr/bin/env bash
set -euo pipefail

msix_path="${1:?Usage: prepare-windows-portable.sh <Codex.msix> [output-dir]}"
output_root="${2:-dist/windows-portable}"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require mkdir
require rm
require unzip
require zip

if [[ ! -f "$msix_path" ]]; then
  echo "MSIX not found: $msix_path" >&2
  exit 1
fi

manifest="$(unzip -p "$msix_path" AppxManifest.xml)"
version="$(sed -nE 's/.*<Identity[^>]* Version="([^"]+)".*/\1/p' <<<"$manifest" | head -n 1)"
version="${version:-unknown}"

package_dir="$output_root/Codex-Windows-x64-portable-$version"
zip_path="$output_root/Codex-Windows-x64-portable-$version.zip"
checksum_path="$output_root/SHA256SUMS-windows-portable.txt"

rm -rf "$package_dir" "$zip_path" "$checksum_path"
mkdir -p "$package_dir"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

unzip -q "$msix_path" 'app/*' -d "$tmp_dir"
cp -R "$tmp_dir/app/." "$package_dir/"

cat > "$package_dir/Run-Codex.cmd" <<'EOF'
@echo off
setlocal
set "CODEX_EXE=%~dp0Codex.exe"
if not exist "%CODEX_EXE%" (
  echo Codex.exe was not found next to this script.
  exit /b 1
)
start "" "%CODEX_EXE%" %*
EOF

cat > "$package_dir/Install-Current-User.cmd" <<'EOF'
@echo off
setlocal
set "SOURCE_DIR=%~dp0"
set "TARGET_DIR=%LOCALAPPDATA%\Programs\Codex"
set "SHORTCUT_DIR=%APPDATA%\Microsoft\Windows\Start Menu\Programs"
set "SHORTCUT=%SHORTCUT_DIR%\Codex.lnk"

if not exist "%TARGET_DIR%" mkdir "%TARGET_DIR%"
if not exist "%SHORTCUT_DIR%" mkdir "%SHORTCUT_DIR%"
robocopy "%SOURCE_DIR%" "%TARGET_DIR%" /MIR /XF "Install-Current-User.cmd" >nul
if errorlevel 8 (
  echo Copy failed.
  exit /b 1
)

powershell -NoProfile -Command "$w=New-Object -ComObject WScript.Shell; $s=$w.CreateShortcut($env:SHORTCUT); $s.TargetPath=(Join-Path $env:TARGET_DIR 'Codex.exe'); $s.WorkingDirectory=$env:TARGET_DIR; $s.IconLocation=(Join-Path $env:TARGET_DIR 'resources\icon.ico'); $s.Save()"

echo Codex was installed for the current user:
echo %TARGET_DIR%
echo.
echo Start Menu shortcut:
echo %SHORTCUT%
EOF

cat > "$package_dir/Uninstall-Current-User.cmd" <<'EOF'
@echo off
setlocal
set "TARGET_DIR=%LOCALAPPDATA%\Programs\Codex"
set "SHORTCUT=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Codex.lnk"

if exist "%SHORTCUT%" del "%SHORTCUT%"
if exist "%TARGET_DIR%" rmdir /s /q "%TARGET_DIR%"

echo Codex current-user install removed.
EOF

cat > "$package_dir/README-portable.txt" <<EOF
Codex Windows portable package
Version: $version

This package was produced by extracting the app/ payload from the official MSIX.
It is not a normal MSIX installation and does not register package identity,
the codex:// protocol, file associations, Microsoft Store updates, or MSIX
deployment metadata.

Quick run:
  Run-Codex.cmd

Current-user install:
  Install-Current-User.cmd

Uninstall current-user copy:
  Uninstall-Current-User.cmd

If Windows policy blocks unknown executables or scripts, this portable package
may still be blocked. In that case, use Microsoft Store or ask the device
administrator to deploy Codex.
EOF

if command -v perl >/dev/null 2>&1; then
  perl -0pi -e 's/\r?\n/\r\n/g' "$package_dir"/*.cmd "$package_dir/README-portable.txt"
fi

(
  cd "$output_root"
  zip -qr "$(basename "$zip_path")" "$(basename "$package_dir")"
)

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$zip_path" | awk -v name="$(basename "$zip_path")" '{ print $1 "  " name }' > "$checksum_path"
elif command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$zip_path" | awk -v name="$(basename "$zip_path")" '{ print $1 "  " name }' > "$checksum_path"
else
  echo "Warning: no SHA-256 checksum tool found; skipped checksum file." >&2
fi

echo "$zip_path"
if [[ -f "$checksum_path" ]]; then
  echo "$checksum_path"
fi
