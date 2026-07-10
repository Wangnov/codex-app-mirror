#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

readonly expected_bundle_identifier="com.openai.codex"
readonly expected_team_identifier="2DC432GLL2"
readonly expected_sparkle_public_ed_key="mNfr1v9t63BfgDtlw4C8lRvSY6uMggIXABDOCi3tS6k="

mkdir -p "$tmp_dir/bin" "$tmp_dir/volumes"
codesign_log="$tmp_dir/codesign.log"
: > "$codesign_log"

# The fixture tools keep the test fast and deterministic while preserving the
# production script's hdiutil/codesign command contracts. Identity policy is
# not overridden: the fake signer only supplies the metadata a real signed app
# would expose, and read-macos-metadata.sh still enforces its built-in constants.
cat > "$tmp_dir/bin/hdiutil" <<'HDIUTIL'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  attach)
    dmg=""
    for arg in "$@"; do
      dmg="$arg"
    done
    mount_point="$(cat "$dmg")"
    python3 - "$mount_point" <<'PY'
import plistlib
import sys

payload = {"system-entities": [{"mount-point": sys.argv[1]}]}
sys.stdout.buffer.write(plistlib.dumps(payload, fmt=plistlib.FMT_XML))
PY
    ;;
  detach)
    ;;
  *)
    echo "unexpected hdiutil invocation: $*" >&2
    exit 1
    ;;
esac
HDIUTIL

cat > "$tmp_dir/bin/codesign" <<'CODESIGN'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${TEST_CODESIGN_LOG:?TEST_CODESIGN_LOG must be set}"
app_path=""
for arg in "$@"; do
  app_path="$arg"
done

case "${1:-}" in
  --verify)
    if [[ -f "$app_path/.fixture-invalid-signature" ]]; then
      echo "fixture signature rejected" >&2
      exit 1
    fi
    ;;
  -d)
    printf 'TeamIdentifier=%s\n' "$(cat "$app_path/.fixture-team-identifier")" >&2
    ;;
  *)
    echo "unexpected codesign invocation: $*" >&2
    exit 1
    ;;
esac
CODESIGN

cat > "$tmp_dir/bin/ditto" <<'DITTO'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != "-x" || "${2:-}" != "-k" || "$#" -ne 4 ]]; then
  echo "unexpected ditto invocation: $*" >&2
  exit 1
fi

source_dir="$(cat "$3")"
mkdir -p "$4"
cp -R "$source_dir/." "$4/"
DITTO

chmod +x "$tmp_dir/bin/hdiutil" "$tmp_dir/bin/codesign" "$tmp_dir/bin/ditto"

make_volume() {
  local fixture_name="$1"
  mkdir -p "$tmp_dir/volumes/$fixture_name"
  printf '%s\n' "$tmp_dir/volumes/$fixture_name" > "$tmp_dir/$fixture_name.dmg"
}

add_app() {
  local fixture_name="$1"
  local app_name="$2"
  local bundle_name="$3"
  local bundle_executable="$4"
  local bundle_identifier="$5"
  local sparkle_public_ed_key="$6"
  local team_identifier="${7:-$expected_team_identifier}"
  local bundle_short_version="${8:-26.707.31428}"
  local bundle_version="${9:-5059}"
  local app_path="$tmp_dir/volumes/$fixture_name/$app_name"

  mkdir -p "$app_path/Contents/MacOS"
  python3 - "$app_path/Contents/Info.plist" "$bundle_name" "$bundle_executable" "$bundle_identifier" "$sparkle_public_ed_key" "$bundle_short_version" "$bundle_version" <<'PY'
import plistlib
import sys

path, name, executable, bundle_id, sparkle_key, short_version, bundle_version = sys.argv[1:]
payload = {
    "CFBundleExecutable": executable,
    "CFBundleIdentifier": bundle_id,
    "CFBundleName": name,
    "CFBundleShortVersionString": short_version,
    "CFBundleVersion": bundle_version,
    "LSMinimumSystemVersion": "12.0",
    "SUPublicEDKey": sparkle_key,
}
with open(path, "wb") as handle:
    plistlib.dump(payload, handle)
PY
  printf '#!/bin/sh\nexit 0\n' > "$app_path/Contents/MacOS/$bundle_executable"
  chmod +x "$app_path/Contents/MacOS/$bundle_executable"
  printf '%s\n' "$team_identifier" > "$app_path/.fixture-team-identifier"
}

make_volume codex
add_app codex Codex.app Codex Codex "$expected_bundle_identifier" "$expected_sparkle_public_ed_key"

make_volume chatgpt
add_app chatgpt ChatGPT.app ChatGPT ChatGPT "$expected_bundle_identifier" "$expected_sparkle_public_ed_key"

# Sparkle archive builds are intentionally different from the DMG fixture.
# The archive is checked against appcast metadata later, not against the DMG
# build, because upstream legitimately allows those two builds to differ.
make_volume codex-zip
add_app codex-zip Codex.app Codex Codex "$expected_bundle_identifier" "$expected_sparkle_public_ed_key" "$expected_team_identifier" 26.707.31428 5060

make_volume chatgpt-zip
add_app chatgpt-zip ChatGPT.app ChatGPT ChatGPT "$expected_bundle_identifier" "$expected_sparkle_public_ed_key" "$expected_team_identifier" 26.707.31428 5060

make_volume classic
add_app classic ChatGPT.app ChatGPT ChatGPT com.openai.chat "$expected_sparkle_public_ed_key"

make_volume multiple
add_app multiple Codex.app Codex Codex "$expected_bundle_identifier" "$expected_sparkle_public_ed_key"
add_app multiple ChatGPT.app ChatGPT ChatGPT "$expected_bundle_identifier" "$expected_sparkle_public_ed_key"

make_volume wrong-key
add_app wrong-key ChatGPT.app ChatGPT ChatGPT "$expected_bundle_identifier" wrong-key

make_volume wrong-team
add_app wrong-team ChatGPT.app ChatGPT ChatGPT "$expected_bundle_identifier" "$expected_sparkle_public_ed_key" WRONGTEAM

make_volume invalid-signature
add_app invalid-signature ChatGPT.app ChatGPT ChatGPT "$expected_bundle_identifier" "$expected_sparkle_public_ed_key"
touch "$tmp_dir/volumes/invalid-signature/ChatGPT.app/.fixture-invalid-signature"

printf '%s\n' "$tmp_dir/volumes/codex-zip" > "$tmp_dir/codex.zip"
printf '%s\n' "$tmp_dir/volumes/chatgpt-zip" > "$tmp_dir/chatgpt.zip"
printf '%s\n' "$tmp_dir/volumes/classic" > "$tmp_dir/classic.zip"

run_reader() {
  env \
    PATH="$tmp_dir/bin:$PATH" \
    TEST_CODESIGN_LOG="$codesign_log" \
    READ_MACOS_METADATA_TEST_MODE=1 \
    EXPECTED_BUNDLE_IDENTIFIER="com.openai.chat" \
    EXPECTED_TEAM_IDENTIFIER="OVERRIDE" \
    EXPECTED_SPARKLE_PUBLIC_ED_KEY="override-key" \
    bash "$repo_root/scripts/read-macos-metadata.sh" "$@"
}

output_json="$tmp_dir/macos-metadata.json"
run_reader \
  "$output_json" \
  "$tmp_dir/codex.dmg" \
  "$tmp_dir/chatgpt.dmg" \
  "$tmp_dir/codex.zip" \
  "$tmp_dir/chatgpt.zip" > "$tmp_dir/success.log"

python3 - "$output_json" "$expected_sparkle_public_ed_key" <<'PY'
import json
import sys

path, expected_key = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)

arm64 = payload["macos"]["arm64"]
x64 = payload["macos"]["x64"]
assert arm64["bundleName"] == "Codex", arm64
assert arm64["bundleExecutable"] == "Codex", arm64
assert x64["bundleName"] == "ChatGPT", x64
assert x64["bundleExecutable"] == "ChatGPT", x64
for item in (arm64, x64):
    assert item["bundleIdentifier"] == "com.openai.codex", item
    assert item["teamIdentifier"] == "2DC432GLL2", item
    assert item["sparklePublicEdKey"] == expected_key, item
    assert item["sparkleArchiveIdentityVerified"] is True, item
    assert item["bundleVersion"] == "5059", item
    assert item["sparkleArchiveBundleVersion"] == "5060", item
assert payload["versionsMatch"] is True, payload
PY

if ! grep -Fq -- '--verify --deep --strict --verbose=2' "$codesign_log"; then
  echo "Expected strict deep code signature verification" >&2
  cat "$codesign_log" >&2
  exit 1
fi

assert_failure() {
  local fixture_name="$1"
  local expected_message="$2"
  local output
  local status

  set +e
  output="$(run_reader \
    "$tmp_dir/$fixture_name-output.json" \
    "$tmp_dir/$fixture_name.dmg" \
    "$tmp_dir/chatgpt.dmg" 2>&1)"
  status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    echo "Expected $fixture_name fixture to fail" >&2
    exit 1
  fi
  if ! grep -Fq "$expected_message" <<<"$output"; then
    echo "Expected $fixture_name failure to contain: $expected_message" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

# The hostile inherited variables passed by run_reader must not relax any of
# these checks. In particular, ChatGPT Classic remains out of product scope.
assert_failure classic 'expected com.openai.codex, got com.openai.chat'
assert_failure multiple 'Expected exactly one top-level .app'
assert_failure wrong-key 'Unexpected Sparkle public key'
assert_failure wrong-team 'expected 2DC432GLL2, got WRONGTEAM'
assert_failure invalid-signature 'Code signature verification failed'

set +e
zip_failure_output="$(run_reader \
  "$tmp_dir/classic-zip-output.json" \
  "$tmp_dir/codex.dmg" \
  "$tmp_dir/chatgpt.dmg" \
  "$tmp_dir/classic.zip" \
  "$tmp_dir/chatgpt.zip" 2>&1)"
zip_failure_status=$?
set -e
if [[ "$zip_failure_status" -eq 0 ]] ||
   ! grep -Fq 'expected com.openai.codex, got com.openai.chat' <<<"$zip_failure_output"; then
  echo "Expected ChatGPT Classic Sparkle archive to be rejected" >&2
  printf '%s\n' "$zip_failure_output" >&2
  exit 1
fi

echo "read-macos-metadata identity fixture PASS"
