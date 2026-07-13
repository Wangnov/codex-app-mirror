#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/artifacts/codex-windows" "$tmp_dir/artifacts/codex-macos"
windows_dir="$tmp_dir/artifacts/codex-windows"
macos_dir="$tmp_dir/artifacts/codex-macos"
tag="codex-app-beta-win-1.2.3.4-mac-1.2.3"

printf 'win-x64' > "$windows_dir/OpenAI.CodexBeta_1.2.3.4_x64__fixture.Msix"
printf 'win-arm64' > "$windows_dir/OpenAI.CodexBeta_1.2.3.4_arm64__fixture.Msix"
printf 'windows sums' > "$windows_dir/SHA256SUMS-windows.txt"
printf '{"channel":"beta"}\n' > "$windows_dir/windows-identity.json"
printf 'mac-arm64' > "$macos_dir/ChatGPT-Beta-mac-arm64.dmg"
printf 'mac-x64' > "$macos_dir/ChatGPT-Beta-mac-x64.dmg"
printf 'zip-arm64' > "$macos_dir/ChatGPT-Beta-darwin-arm64-1.2.3.zip"
printf 'zip-x64' > "$macos_dir/ChatGPT-Beta-darwin-x64-1.2.3.zip"
printf 'macos sums' > "$macos_dir/SHA256SUMS-macos.txt"
printf '{"channel":"beta"}\n' > "$macos_dir/macos-identity.json"
printf 'all sums' > "$tmp_dir/SHA256SUMS.txt"
printf 'Beta prerelease fixture\n' > "$tmp_dir/release-notes.md"

cat > "$tmp_dir/release-manifest.json" <<JSON
{
  "channel": "beta",
  "publication": {
    "githubPrereleaseOnly": true,
    "githubLatestAdvanced": false,
    "objectStoragePublished": false,
    "sharedLatestAdvanced": false
  },
  "release": {
    "tag": "$tag",
    "destination": "github-prerelease"
  },
  "sources": {
    "macos": {
      "arm64": {
        "mirrorBasename": "ChatGPT-Beta-mac-arm64.dmg",
        "appcast": {"mirrorEnclosureBasename": "ChatGPT-Beta-darwin-arm64-1.2.3.zip"}
      },
      "x64": {
        "mirrorBasename": "ChatGPT-Beta-mac-x64.dmg",
        "appcast": {"mirrorEnclosureBasename": "ChatGPT-Beta-darwin-x64-1.2.3.zip"}
      }
    }
  }
}
JSON

cat > "$tmp_dir/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${GH_MOCK_LOG:?}"
[[ "${1:-}" == "release" ]] || { echo "unexpected gh command: $*" >&2; exit 1; }
operation="${2:-}"
tag="${3:-}"

case "$operation" in
  view)
    [[ -f "${GH_MOCK_STATE:?}" ]] || exit 1
    if [[ "$*" == *"--jq .assets"* ]]; then
      jq -c '.assets' "$GH_MOCK_STATE"
    else
      cat "$GH_MOCK_STATE"
    fi
    ;;
  create)
    shift 3
    asset_list="$(mktemp)"
    : > "$asset_list"
    while (($#)); do
      case "$1" in
        --target|--title|--notes-file)
          shift 2
          ;;
        --prerelease|--latest=false)
          shift
          ;;
        *)
          [[ -f "$1" ]] || { echo "unexpected gh release create argument: $1" >&2; exit 1; }
          printf '%s\n' "$1" >> "$asset_list"
          shift
          ;;
      esac
    done
    python3 - "$GH_MOCK_STATE" "$tag" "$asset_list" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

state_path, tag, asset_list = sys.argv[1:]
assets = []
for raw in Path(asset_list).read_text().splitlines():
    path = Path(raw)
    assets.append({
        "name": path.name,
        "size": path.stat().st_size,
        "digest": "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest(),
    })
payload = {
    "tagName": tag,
    "name": "fixture",
    "isDraft": False,
    "isPrerelease": True,
    "publishedAt": "2026-07-13T00:00:00Z",
    "assets": assets,
}
Path(state_path).write_text(json.dumps(payload), encoding="utf-8")
PY
    rm -f "$asset_list"
    ;;
  edit)
    ;;
  upload|delete-asset)
    echo "unexpected asset mutation in fixture: $*" >&2
    exit 1
    ;;
  *)
    echo "unexpected gh release operation: $operation" >&2
    exit 1
    ;;
esac
GH
chmod +x "$tmp_dir/bin/gh"

publish() {
  env \
    PATH="$tmp_dir/bin:$PATH" \
    GH_TOKEN=fixture \
    GH_REPO=Wangnov/codex-app-mirror \
    GH_MOCK_STATE="$tmp_dir/release-state.json" \
    GH_MOCK_LOG="$tmp_dir/gh.log" \
    GITHUB_SHA=fixture-sha \
    bash "$repo_root/scripts/emergency-publish-release.sh" \
      "$tag" \
      "Beta fixture" \
      "$tmp_dir/release-notes.md" \
      "$tmp_dir/release-manifest.json" \
      "$tmp_dir/SHA256SUMS.txt" \
      "$tmp_dir/artifacts"
}

(
  cd "$repo_root"
  publish > "$tmp_dir/first.log"
)
grep -Fq "release create $tag" "$tmp_dir/gh.log"
grep -Fq -- '--prerelease --latest=false' "$tmp_dir/gh.log"
test "$(jq '.assets | length' "$tmp_dir/release-state.json")" = 13

# A byte-identical rerun edits metadata but must not re-upload any asset.
(
  cd "$repo_root"
  publish > "$tmp_dir/second.log"
)
grep -Fq "release edit $tag" "$tmp_dir/gh.log"
test "$(grep -c '^release upload ' "$tmp_dir/gh.log" || true)" = 0

# A colliding immutable binary must fail before the release is edited.
edit_count_before="$(grep -c "^release edit $tag" "$tmp_dir/gh.log" || true)"
printf 'drift' >> "$windows_dir/OpenAI.CodexBeta_1.2.3.4_x64__fixture.Msix"
set +e
mismatch_output="$(cd "$repo_root" && publish 2>&1)"
mismatch_status=$?
set -e
if [[ "$mismatch_status" -eq 0 ]] ||
   ! grep -Fq 'mismatched immutable asset' <<<"$mismatch_output"; then
  echo "Expected immutable GitHub asset drift to fail before mutation." >&2
  printf '%s\n' "$mismatch_output" >&2
  exit 1
fi
edit_count_after="$(grep -c "^release edit $tag" "$tmp_dir/gh.log" || true)"
test "$edit_count_before" = "$edit_count_after"

echo "Beta GitHub prerelease publisher fixture PASS"
