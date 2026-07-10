#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/source"

printf 'arm-dmg' > "$tmp_dir/source/ChatGPT-1.2.3-arm64.dmg"
printf 'x64-dmg' > "$tmp_dir/source/ChatGPT-1.2.3-x64.dmg"
printf 'arm-zip' > "$tmp_dir/source/ChatGPT-darwin-arm64-1.2.3.zip"
printf 'x64-zip' > "$tmp_dir/source/ChatGPT-darwin-x64-1.2.3.zip"
printf 'arm-delta' > "$tmp_dir/source/ChatGPT5-4-arm64.delta"
printf 'x64-delta' > "$tmp_dir/source/ChatGPT5-4-x64.delta"

file_size() {
  if stat -f '%z' "$1" >/dev/null 2>&1; then
    stat -f '%z' "$1"
  else
    stat -c '%s' "$1"
  fi
}

cat > "$tmp_dir/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail

output=""
url=""
while (($#)); do
  case "$1" in
    -o)
      output="$2"
      shift
      ;;
    http://*|https://*)
      url="$1"
      ;;
  esac
  shift
done

if [[ -z "$output" || -z "$url" ]]; then
  echo "fixture curl expected an output path and URL" >&2
  exit 1
fi

basename="${url%%\?*}"
basename="${basename##*/}"
source="${TEST_SOURCE_DIR:?TEST_SOURCE_DIR must be set}/$basename"
if [[ ! -f "$source" ]]; then
  echo "unexpected fixture URL: $url" >&2
  exit 1
fi
cp "$source" "$output"
CURL
chmod +x "$tmp_dir/bin/curl"

arm_dmg_size="$(file_size "$tmp_dir/source/ChatGPT-1.2.3-arm64.dmg")"
x64_dmg_size="$(file_size "$tmp_dir/source/ChatGPT-1.2.3-x64.dmg")"
arm_zip_size="$(file_size "$tmp_dir/source/ChatGPT-darwin-arm64-1.2.3.zip")"
x64_zip_size="$(file_size "$tmp_dir/source/ChatGPT-darwin-x64-1.2.3.zip")"
arm_delta_size="$(file_size "$tmp_dir/source/ChatGPT5-4-arm64.delta")"
x64_delta_size="$(file_size "$tmp_dir/source/ChatGPT5-4-x64.delta")"

cat > "$tmp_dir/manifest.json" <<JSON
{
  "schemaVersion": 5,
  "sources": {
    "macos": {
      "arm64": {
        "url": "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-1.2.3-arm64.dmg",
        "contentLength": $arm_dmg_size,
        "appcast": {
          "enclosureUrl": "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-darwin-arm64-1.2.3.zip",
          "sourceBasename": "ChatGPT-darwin-arm64-1.2.3.zip",
          "mirrorEnclosureBasename": "Codex-darwin-arm64-1.2.3.zip",
          "enclosureLength": $arm_zip_size,
          "deltas": [{
            "url": "https://persistent.oaistatic.com/codex-app-prod/ChatGPT5-4-arm64.delta",
            "basename": "ChatGPT5-4-arm64.delta",
            "length": $arm_delta_size
          }]
        }
      },
      "x64": {
        "url": "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-1.2.3-x64.dmg",
        "contentLength": $x64_dmg_size,
        "appcast": {
          "enclosureUrl": "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-darwin-x64-1.2.3.zip",
          "sourceBasename": "ChatGPT-darwin-x64-1.2.3.zip",
          "mirrorEnclosureBasename": "Codex-darwin-x64-1.2.3.zip",
          "enclosureLength": $x64_zip_size,
          "deltas": [{
            "url": "https://persistent.oaistatic.com/codex-app-prod/ChatGPT5-4-x64.delta",
            "basename": "ChatGPT5-4-x64.delta",
            "length": $x64_delta_size
          }]
        }
      }
    }
  }
}
JSON

output_dir="$tmp_dir/output"
PATH="$tmp_dir/bin:$PATH" TEST_SOURCE_DIR="$tmp_dir/source" \
  bash "$repo_root/scripts/download-macos.sh" "$output_dir" "$tmp_dir/manifest.json"

test -f "$output_dir/Codex-mac-arm64.dmg"
test -f "$output_dir/Codex-mac-x64.dmg"
test -f "$output_dir/Codex-darwin-arm64-1.2.3.zip"
test -f "$output_dir/Codex-darwin-x64-1.2.3.zip"
test -f "$output_dir/ChatGPT5-4-arm64.delta"
test -f "$output_dir/ChatGPT5-4-x64.delta"
test ! -e "$output_dir/ChatGPT-darwin-arm64-1.2.3.zip"
test ! -e "$output_dir/ChatGPT-darwin-x64-1.2.3.zip"
grep -F 'Codex-darwin-arm64-1.2.3.zip' "$output_dir/SHA256SUMS-macos.txt"
grep -F 'ChatGPT5-4-arm64.delta' "$output_dir/SHA256SUMS-macos.txt"

jq '.sources.macos.arm64.appcast.mirrorEnclosureBasename = "../escape.zip"' \
  "$tmp_dir/manifest.json" > "$tmp_dir/unsafe.json"
set +e
unsafe_output="$(
  PATH="$tmp_dir/bin:$PATH" TEST_SOURCE_DIR="$tmp_dir/source" \
    bash "$repo_root/scripts/download-macos.sh" "$tmp_dir/unsafe-output" "$tmp_dir/unsafe.json" 2>&1
)"
unsafe_status=$?
set -e
if [[ "$unsafe_status" -eq 0 ]] ||
   ! grep -Fq "Invalid macOS arm64 mirror enclosure basename" <<<"$unsafe_output"; then
  echo "Expected an unsafe mirrorEnclosureBasename to be rejected" >&2
  printf '%s\n' "$unsafe_output" >&2
  exit 1
fi

jq '.sources.macos.arm64.appcast.sourceBasename = "wrong.zip"' \
  "$tmp_dir/manifest.json" > "$tmp_dir/mismatch.json"
set +e
mismatch_output="$(
  PATH="$tmp_dir/bin:$PATH" TEST_SOURCE_DIR="$tmp_dir/source" \
    bash "$repo_root/scripts/download-macos.sh" "$tmp_dir/mismatch-output" "$tmp_dir/mismatch.json" 2>&1
)"
mismatch_status=$?
set -e
if [[ "$mismatch_status" -eq 0 ]] ||
   ! grep -Fq "source basename mismatch" <<<"$mismatch_output"; then
  echo "Expected an enclosure URL/sourceBasename mismatch to be rejected" >&2
  printf '%s\n' "$mismatch_output" >&2
  exit 1
fi

echo "download-macos double-basename fixture PASS"
