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
require python3
require rm
require unzip
require zip

readonly EXPECTED_PACKAGE_IDENTITY="OpenAI.Codex"

if [[ ! -f "$msix_path" ]]; then
  echo "MSIX not found: $msix_path" >&2
  exit 1
fi

metadata="$({
  python3 - "$msix_path" "$EXPECTED_PACKAGE_IDENTITY" <<'PY'
import pathlib
import sys
import xml.etree.ElementTree as ET
import zipfile


def local_name(value: str) -> str:
    return value.rsplit("}", 1)[-1]


def attribute(element: ET.Element, name: str) -> str:
    for key, value in element.attrib.items():
        if local_name(key) == name:
            return value
    return ""


try:
    msix_path, expected_identity = sys.argv[1:]
    with zipfile.ZipFile(msix_path) as archive:
        manifest_names = [
            name for name in archive.namelist()
            if name.lower() == "appxmanifest.xml"
        ]
        if len(manifest_names) != 1:
            raise ValueError("MSIX must contain exactly one top-level AppxManifest.xml")
        root = ET.fromstring(archive.read(manifest_names[0]))

    identity = next(
        (element for element in root.iter() if local_name(element.tag) == "Identity"),
        None,
    )
    identity_name = attribute(identity, "Name") if identity is not None else ""
    if identity_name != expected_identity:
        raise ValueError(
            f"package identity must be {expected_identity!r}, got {identity_name!r}"
        )
    version = attribute(identity, "Version") if identity is not None else ""
    if not version:
        version = "unknown"

    executables = {
        attribute(element, "Executable")
        for element in root.iter()
        if local_name(element.tag) == "Application"
        and attribute(element, "Executable")
    }
    if len(executables) != 1:
        raise ValueError(
            "AppxManifest.xml must declare exactly one distinct Application Executable"
        )

    package_executable = executables.pop().replace("\\", "/")
    path = pathlib.PurePosixPath(package_executable)
    if (
        path.is_absolute()
        or len(path.parts) < 2
        or path.parts[0].lower() != "app"
        or any(part in ("", ".", "..") for part in path.parts)
    ):
        raise ValueError(
            f"Application Executable must be a safe path below app/: {package_executable!r}"
        )

    portable_executable = pathlib.PurePosixPath(*path.parts[1:]).as_posix()
    if (
        not portable_executable.lower().endswith(".exe")
        or any(character in portable_executable for character in ('\r', '\n', '\t', '"', '%'))
    ):
        raise ValueError(f"unsafe Application Executable: {package_executable!r}")

    print(f"{version}\t{portable_executable}")
except (ET.ParseError, OSError, ValueError, zipfile.BadZipFile) as error:
    raise SystemExit(f"Invalid Windows MSIX metadata: {error}")
PY
} 2>&1)" || {
  printf '%s\n' "$metadata" >&2
  exit 1
}

if [[ "$metadata" != *$'\t'* ]]; then
  echo "Invalid Windows MSIX metadata output." >&2
  exit 1
fi

version="${metadata%%$'\t'*}"
portable_executable="${metadata#*$'\t'}"
portable_executable_windows="${portable_executable//\//\\}"

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

if [[ ! -f "$package_dir/$portable_executable" ]]; then
  echo "AppxManifest Application executable was not found in the MSIX app payload: $portable_executable" >&2
  exit 1
fi

{
  cat <<'EOF'
@echo off
setlocal
EOF
  printf 'set "CODEX_EXE_REL=%s"\n' "$portable_executable_windows"
  cat <<'EOF'
set "CODEX_EXE=%~dp0%CODEX_EXE_REL%"
if not exist "%CODEX_EXE%" (
  echo %CODEX_EXE_REL% was not found next to this script.
  exit /b 1
)
start "" "%CODEX_EXE%" %*
EOF
} > "$package_dir/Run-Codex.cmd"

{
  cat <<'EOF'
@echo off
setlocal
EOF
  printf 'set "CODEX_EXE_REL=%s"\n' "$portable_executable_windows"
  cat <<'EOF'
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

powershell -NoProfile -Command "$w=New-Object -ComObject WScript.Shell; $s=$w.CreateShortcut($env:SHORTCUT); $s.TargetPath=(Join-Path $env:TARGET_DIR $env:CODEX_EXE_REL); $s.WorkingDirectory=$env:TARGET_DIR; $s.IconLocation=(Join-Path $env:TARGET_DIR 'resources\icon.ico'); $s.Save()"

echo Codex was installed for the current user:
echo %TARGET_DIR%
echo.
echo Start Menu shortcut:
echo %SHORTCUT%
EOF
} > "$package_dir/Install-Current-User.cmd"

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
The launcher target was read from AppxManifest.xml: $portable_executable_windows
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
