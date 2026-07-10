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
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10">
  <Identity Name="OpenAI.Codex" Publisher="CN=OpenAI" Version="1.2.3.4" />
  <Applications>
    <Application Id="ChatGPT" Executable="app\ChatGPT.exe" EntryPoint="Windows.FullTrustApplication" />
  </Applications>
</Package>
XML
printf 'fake chatgpt exe' > "$payload_dir/app/ChatGPT.exe"
# Keep the legacy shim in the fixture to prove the manifest, not filename
# discovery, selects the portable launcher target.
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
test -f "$package_dir/ChatGPT.exe"
test -f "$package_dir/Codex.exe"

grep -F 'set "CODEX_EXE_REL=ChatGPT.exe"' "$package_dir/Run-Codex.cmd"
grep -F 'set "CODEX_EXE=%~dp0%CODEX_EXE_REL%"' "$package_dir/Run-Codex.cmd"
grep -F 'start "" "%CODEX_EXE%" %*' "$package_dir/Run-Codex.cmd"
grep -F 'set "CODEX_EXE_REL=ChatGPT.exe"' "$package_dir/Install-Current-User.cmd"
grep -F 'if not exist "%SHORTCUT_DIR%" mkdir "%SHORTCUT_DIR%"' "$package_dir/Install-Current-User.cmd"
grep -F '$s=$w.CreateShortcut($env:SHORTCUT)' "$package_dir/Install-Current-User.cmd"
grep -F '$s.TargetPath=(Join-Path $env:TARGET_DIR $env:CODEX_EXE_REL)' "$package_dir/Install-Current-User.cmd"
grep -F 'The launcher target was read from AppxManifest.xml: ChatGPT.exe' "$package_dir/README-portable.txt"

unzip -l "$zip_path" | grep -F 'Codex-Windows-x64-portable-1.2.3.4/Run-Codex.cmd'
grep -F 'Codex-Windows-x64-portable-1.2.3.4.zip' "$checksum_path"

legacy_payload_dir="$tmp_dir/legacy msix payload"
mkdir -p "$legacy_payload_dir/app"
cat > "$legacy_payload_dir/AppxManifest.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<Package>
  <Identity Name="OpenAI.Codex" Publisher="CN=OpenAI" Version="1.2.3.5" />
  <Applications>
    <Application Id="Codex" Executable="app/Codex.exe" EntryPoint="Windows.FullTrustApplication" />
  </Applications>
</Package>
XML
printf 'legacy exe' > "$legacy_payload_dir/app/Codex.exe"
(
  cd "$legacy_payload_dir"
  zip -qr "$tmp_dir/Codex legacy.msix" AppxManifest.xml app
)

legacy_output_dir="$tmp_dir/legacy output"
"$repo_root/scripts/prepare-windows-portable.sh" \
  "$tmp_dir/Codex legacy.msix" \
  "$legacy_output_dir" >/dev/null
legacy_package_dir="$legacy_output_dir/Codex-Windows-x64-portable-1.2.3.5"
test -f "$legacy_package_dir/Codex.exe"
grep -F 'set "CODEX_EXE_REL=Codex.exe"' "$legacy_package_dir/Run-Codex.cmd"
grep -F 'set "CODEX_EXE_REL=Codex.exe"' "$legacy_package_dir/Install-Current-User.cmd"

beta_payload_dir="$tmp_dir/beta msix payload"
cp -R "$payload_dir" "$beta_payload_dir"
python3 - "$beta_payload_dir/AppxManifest.xml" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text(
    path.read_text(encoding="utf-8").replace("OpenAI.Codex", "OpenAI.CodexBeta"),
    encoding="utf-8",
)
PY
(
  cd "$beta_payload_dir"
  zip -qr "$tmp_dir/Codex beta.msix" AppxManifest.xml app
)
set +e
beta_output="$(
  "$repo_root/scripts/prepare-windows-portable.sh" \
    "$tmp_dir/Codex beta.msix" \
    "$tmp_dir/beta output" 2>&1
)"
beta_status=$?
set -e
if [[ "$beta_status" -eq 0 ]] ||
   ! grep -Fq "package identity must be 'OpenAI.Codex', got 'OpenAI.CodexBeta'" <<<"$beta_output"; then
  echo "Expected the Stable portable packager to reject Codex Beta" >&2
  printf '%s\n' "$beta_output" >&2
  exit 1
fi

echo "prepare-windows-portable fixture test PASS"
