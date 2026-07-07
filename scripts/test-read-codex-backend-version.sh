#!/usr/bin/env bash
set -euo pipefail

tmp_dir="$(mktemp -d)"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p \
  "$tmp_dir/Codex.app/Contents/MacOS" \
  "$tmp_dir/Codex.app/Contents/Resources" \
  "$tmp_dir/msix/app/resources"

cat > "$tmp_dir/Codex.app/Contents/MacOS/Codex" <<'SH'
#!/usr/bin/env bash
printf 'Codex 149.0.7827.197\n'
SH
chmod +x "$tmp_dir/Codex.app/Contents/MacOS/Codex"

cat > "$tmp_dir/Codex.app/Contents/Resources/codex" <<'SH'
#!/usr/bin/env bash
printf 'codex-cli 0.142.5\n'
SH
chmod +x "$tmp_dir/Codex.app/Contents/Resources/codex"

test "$(python3 "$repo_root/scripts/read-codex-backend-version.py" "$tmp_dir/Codex.app")" = "0.142.5"

cat > "$tmp_dir/msix/app/Codex.exe" <<'SH'
#!/usr/bin/env bash
printf 'Codex 149.0.7827.197\n'
SH
chmod +x "$tmp_dir/msix/app/Codex.exe"

cat > "$tmp_dir/msix/app/resources/codex.exe" <<'SH'
#!/usr/bin/env bash
printf '0.143.0\n'
SH
chmod +x "$tmp_dir/msix/app/resources/codex.exe"
(
  cd "$tmp_dir/msix"
  zip -q -r "$tmp_dir/backend.Msix" app
)

test "$(python3 "$repo_root/scripts/read-codex-backend-version.py" "$tmp_dir/backend.Msix")" = "0.143.0"
python3 "$repo_root/scripts/read-codex-backend-version.py" \
  --json \
  --platform windows \
  --architecture x64 \
  "$tmp_dir/backend.Msix" > "$tmp_dir/backend.json"
test "$(jq -r '.backendVersion' "$tmp_dir/backend.json")" = "0.143.0"
test "$(jq -r '.status' "$tmp_dir/backend.json")" = "found"

windows_input_dir="$tmp_dir/windows-arm64-input"
windows_source_sha256="$(sha256sum "$tmp_dir/backend.Msix" | awk '{print $1}')"
python3 "$repo_root/scripts/read-codex-backend-version.py" \
  --prepare-input-dir "$windows_input_dir" \
  --source-package "$tmp_dir/backend.Msix" \
  --source-package-sha256 "$windows_source_sha256" \
  --platform windows \
  --architecture arm64 \
  "$tmp_dir/backend.Msix" > "$tmp_dir/windows-input.log"

windows_input_manifest="$windows_input_dir/backend-input.json"
test "$(jq -r '.status' "$windows_input_manifest")" = "ready"
test "$(jq -r '.platform' "$windows_input_manifest")" = "windows"
test "$(jq -r '.architecture' "$windows_input_manifest")" = "arm64"
test "$(jq -r '.sourcePackageFileName' "$windows_input_manifest")" = "backend.Msix"
test "$(jq -r '.sourcePackageSha256' "$windows_input_manifest")" = "$windows_source_sha256"
test "$(jq -r '.backendFileName' "$windows_input_manifest")" = "codex.exe"
test "$(jq -r '.backendSha256' "$windows_input_manifest")" = "$(sha256sum "$windows_input_dir/codex.exe" | awk '{print $1}')"
test "$(find "$windows_input_dir" -maxdepth 1 -type f | wc -l | tr -d ' ')" = "2"
test -z "$(find "$windows_input_dir" -maxdepth 1 -name '*.tmp' -print -quit)"

python3 "$repo_root/scripts/read-codex-backend-version.py" \
  --prepared-input \
  --json \
  --platform windows \
  --architecture arm64 \
  "$windows_input_manifest" > "$tmp_dir/windows-native.json"
test "$(jq -r '.status' "$tmp_dir/windows-native.json")" = "found"
test "$(jq -r '.backendVersion' "$tmp_dir/windows-native.json")" = "0.143.0"

cp -R "$windows_input_dir" "$tmp_dir/windows-tampered-input"
printf '\ntampered\n' >> "$tmp_dir/windows-tampered-input/codex.exe"
python3 "$repo_root/scripts/read-codex-backend-version.py" \
  --prepared-input \
  --json \
  --platform windows \
  --architecture arm64 \
  "$tmp_dir/windows-tampered-input/backend-input.json" > "$tmp_dir/windows-tampered.json"
test "$(jq -r '.status' "$tmp_dir/windows-tampered.json")" = "unavailable"
test "$(jq -r '.backendVersion // empty' "$tmp_dir/windows-tampered.json")" = ""

cp -R "$windows_input_dir" "$tmp_dir/windows-invalid-source-input"
python3 - "$tmp_dir/windows-invalid-source-input/backend-input.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
payload["sourcePackageSha256"] = "invalid"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
python3 "$repo_root/scripts/read-codex-backend-version.py" \
  --prepared-input \
  --json \
  --platform windows \
  --architecture arm64 \
  "$tmp_dir/windows-invalid-source-input/backend-input.json" > "$tmp_dir/windows-invalid-source.json"
test "$(jq -r '.status' "$tmp_dir/windows-invalid-source.json")" = "unavailable"

cp -R "$windows_input_dir" "$tmp_dir/windows-wrong-arch-input"
python3 "$repo_root/scripts/read-codex-backend-version.py" \
  --prepared-input \
  --json \
  --platform windows \
  --architecture x64 \
  "$tmp_dir/windows-wrong-arch-input/backend-input.json" > "$tmp_dir/windows-wrong-arch.json"
test "$(jq -r '.status' "$tmp_dir/windows-wrong-arch.json")" = "unavailable"

mkdir -p "$tmp_dir/no-backend-msix/app"
cp "$tmp_dir/msix/app/Codex.exe" "$tmp_dir/no-backend-msix/app/Codex.exe"
(
  cd "$tmp_dir/no-backend-msix"
  zip -q -r "$tmp_dir/no-backend.Msix" app
)
python3 "$repo_root/scripts/read-codex-backend-version.py" \
  --prepare-input-dir "$tmp_dir/unavailable-windows-input" \
  --source-package "$tmp_dir/no-backend.Msix" \
  --platform windows \
  --architecture arm64 \
  "$tmp_dir/no-backend.Msix" > "$tmp_dir/unavailable-windows-input.log"
test "$(jq -r '.status' "$tmp_dir/unavailable-windows-input/backend-input.json")" = "unavailable"
test "$(find "$tmp_dir/unavailable-windows-input" -maxdepth 1 -type f | wc -l | tr -d ' ')" = "1"

mkdir -p \
  "$tmp_dir/electron-app/Codex.app/Contents/MacOS" \
  "$tmp_dir/electron-app/Codex.app/Contents/Resources" \
  "$tmp_dir/electron-app/Codex.app/Nested.app/Contents/Resources"
cat > "$tmp_dir/electron-app/Codex.app/Contents/MacOS/Codex" <<'SH'
#!/usr/bin/env bash
printf 'Codex 149.0.7827.197\n'
SH
chmod +x "$tmp_dir/electron-app/Codex.app/Contents/MacOS/Codex"
cat > "$tmp_dir/electron-app/Codex.app/Contents/Resources/codex" <<'SH'
#!/usr/bin/env bash
printf 'Codex 149.0.7827.197\n'
SH
chmod +x "$tmp_dir/electron-app/Codex.app/Contents/Resources/codex"
cat > "$tmp_dir/electron-app/Codex.app/Nested.app/Contents/Resources/codex" <<'SH'
#!/usr/bin/env bash
printf 'codex-cli 9.9.9\n'
SH
chmod +x "$tmp_dir/electron-app/Codex.app/Nested.app/Contents/Resources/codex"
if python3 "$repo_root/scripts/read-codex-backend-version.py" "$tmp_dir/electron-app/Codex.app" >/dev/null 2>&1; then
  echo "Expected invalid canonical macOS backend to remain unavailable." >&2
  exit 1
fi
python3 "$repo_root/scripts/read-codex-backend-version.py" \
  --json \
  --platform macos \
  --architecture arm64 \
  "$tmp_dir/electron-app/Codex.app" > "$tmp_dir/electron-app.json"
test "$(jq -r '.status' "$tmp_dir/electron-app.json")" = "unavailable"
test "$(jq -r '.backendVersion // empty' "$tmp_dir/electron-app.json")" = ""

mkdir -p \
  "$tmp_dir/electron-msix/app" \
  "$tmp_dir/electron-msix/app/resources" \
  "$tmp_dir/electron-msix/decoy/app/resources"
cat > "$tmp_dir/electron-msix/app/Codex.exe" <<'SH'
#!/usr/bin/env bash
printf 'Codex 149.0.7827.197\n'
SH
chmod +x "$tmp_dir/electron-msix/app/Codex.exe"
cat > "$tmp_dir/electron-msix/app/resources/codex.exe" <<'SH'
#!/usr/bin/env bash
printf 'Codex 149.0.7827.197\n'
SH
chmod +x "$tmp_dir/electron-msix/app/resources/codex.exe"
cat > "$tmp_dir/electron-msix/decoy/app/resources/codex.exe" <<'SH'
#!/usr/bin/env bash
printf 'codex-cli 9.9.9\n'
SH
chmod +x "$tmp_dir/electron-msix/decoy/app/resources/codex.exe"
(
  cd "$tmp_dir/electron-msix"
  zip -q -r "$tmp_dir/electron-only.Msix" app decoy
)
python3 - "$tmp_dir/electron-only.Msix" <<'PY'
import sys
import zipfile

decoy = b"#!/usr/bin/env bash\nprintf 'codex-cli 9.9.8\\n'\n"
with zipfile.ZipFile(sys.argv[1], "a") as archive:
    archive.writestr("../app/resources/codex.exe", decoy)
    archive.writestr("/app/resources/codex.exe", decoy)
PY
if python3 "$repo_root/scripts/read-codex-backend-version.py" "$tmp_dir/electron-only.Msix" >/dev/null 2>&1; then
  echo "Expected invalid canonical Windows backend to remain unavailable." >&2
  exit 1
fi
python3 "$repo_root/scripts/read-codex-backend-version.py" \
  --json \
  --platform windows \
  --architecture x64 \
  "$tmp_dir/electron-only.Msix" > "$tmp_dir/electron-msix.json"
test "$(jq -r '.status' "$tmp_dir/electron-msix.json")" = "unavailable"
test "$(jq -r '.backendVersion // empty' "$tmp_dir/electron-msix.json")" = ""

cat > "$tmp_dir/electron-direct" <<'SH'
#!/usr/bin/env bash
printf 'Codex 149.0.7827.197\n'
SH
chmod +x "$tmp_dir/electron-direct"
if python3 "$repo_root/scripts/read-codex-backend-version.py" "$tmp_dir/electron-direct" >/dev/null 2>&1; then
  echo "Expected Electron version output to be rejected." >&2
  exit 1
fi

cat > "$tmp_dir/failing-backend" <<'SH'
#!/usr/bin/env bash
printf 'codex-cli 9.9.7\n'
exit 1
SH
chmod +x "$tmp_dir/failing-backend"
if python3 "$repo_root/scripts/read-codex-backend-version.py" "$tmp_dir/failing-backend" >/dev/null 2>&1; then
  echo "Expected nonzero backend exit status to be rejected." >&2
  exit 1
fi
python3 "$repo_root/scripts/read-codex-backend-version.py" --json "$tmp_dir/failing-backend" > "$tmp_dir/failing-backend.json"
test "$(jq -r '.status' "$tmp_dir/failing-backend.json")" = "unavailable"
test "$(jq -r '.backendVersion // empty' "$tmp_dir/failing-backend.json")" = ""

printf 'not executable' > "$tmp_dir/missing"
if python3 "$repo_root/scripts/read-codex-backend-version.py" "$tmp_dir/missing" >/dev/null 2>&1; then
  echo "Expected missing backend version to fail." >&2
  exit 1
fi
python3 "$repo_root/scripts/read-codex-backend-version.py" --json "$tmp_dir/missing" > "$tmp_dir/missing.json"
test "$(jq -r '.status' "$tmp_dir/missing.json")" = "unavailable"
test "$(jq -r '.backendVersion // empty' "$tmp_dir/missing.json")" = ""

echo "read-codex-backend-version fixture PASS"
