#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/artifacts"
artifacts="$tmp_dir/artifacts"
tag="codex-app-linux-preview-26.803.81509"

printf 'deb-x64' > "$artifacts/chatgpt_26.803.81509_amd64.deb"
printf 'deb-arm64' > "$artifacts/chatgpt_26.803.81509_arm64.deb"
printf 'rpm-x64' > "$artifacts/chatgpt-26.803.81509-1.x86_64.rpm"
printf 'rpm-arm64' > "$artifacts/chatgpt-26.803.81509-1.aarch64.rpm"
printf 'linux sums' > "$artifacts/SHA256SUMS-linux.txt"
printf '{"channel":"linux-preview"}\n' > "$artifacts/linux-identity.json"
printf 'all sums' > "$tmp_dir/SHA256SUMS.txt"
printf 'Linux Preview fixture\n' > "$tmp_dir/release-notes.md"

cat > "$tmp_dir/release-manifest.json" <<JSON
{
  "schemaVersion": 6,
  "channel": "linux-preview",
  "preview": {"contract": "linux-preview-v1"},
  "publication": {
    "githubPrereleaseOnly": true,
    "githubLatestAdvanced": false,
    "objectStoragePublished": false,
    "sharedLatestAdvanced": false
  },
  "derived": {"prerelease": true, "publishLatest": false, "syncLatest": false},
  "release": {"tag": "$tag", "destination": "github-prerelease", "immutableAssets": true},
  "sources": {
    "linux": {
      "architectures": {
        "x64": {
          "deb": {"mirrorBasename":"chatgpt_26.803.81509_amd64.deb"},
          "rpm": {"mirrorBasename":"chatgpt-26.803.81509-1.x86_64.rpm"}
        },
        "arm64": {
          "deb": {"mirrorBasename":"chatgpt_26.803.81509_arm64.deb"},
          "rpm": {"mirrorBasename":"chatgpt-26.803.81509-1.aarch64.rpm"}
        }
      }
    }
  }
}
JSON

cat > "$tmp_dir/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${GH_MOCK_LOG:?}"
if [[ "${1:-}" == "api" ]]; then
  if [[ "${GH_MOCK_API_ERROR:-}" == "503" ]]; then
    echo 'gh: HTTP 503' >&2
    exit 1
  fi
  if [[ ! -f "${GH_MOCK_STATE:?}" ]]; then
    echo 'gh: Not Found (HTTP 404)' >&2
    exit 1
  fi
  cat "$GH_MOCK_STATE"
  exit 0
fi
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
    "publishedAt": "2026-08-12T00:00:00Z",
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
    GH_MOCK_API_ERROR="${GH_MOCK_API_ERROR:-}" \
    GITHUB_API_RETRY_DELAY_SECONDS=0 \
    GITHUB_SHA=fixture-sha \
    bash "$repo_root/scripts/publish-linux-preview-release.sh" \
      "$tag" \
      "Linux Preview fixture" \
      "$tmp_dir/release-notes.md" \
      "$tmp_dir/release-manifest.json" \
      "$tmp_dir/SHA256SUMS.txt" \
      "$artifacts"
}

set +e
GH_MOCK_API_ERROR=503 publish > "$tmp_dir/503.log" 2>&1
lookup_status=$?
set -e
if [[ "$lookup_status" -eq 0 ]] ||
   [[ -f "$tmp_dir/release-state.json" ]] ||
   grep -Fq "release create $tag" "$tmp_dir/gh.log"; then
  echo "Expected GitHub API 503 to fail closed before Linux Preview creation." >&2
  cat "$tmp_dir/503.log" >&2
  exit 1
fi
: > "$tmp_dir/gh.log"

publish > "$tmp_dir/first.log"
grep -Fq "release create $tag" "$tmp_dir/gh.log"
grep -Fq -- '--prerelease --latest=false' "$tmp_dir/gh.log"
test "$(jq '.assets | length' "$tmp_dir/release-state.json")" = 8

publish > "$tmp_dir/second.log"
grep -Fq "release edit $tag" "$tmp_dir/gh.log"
test "$(grep -c '^release upload ' "$tmp_dir/gh.log" || true)" = 0

edit_count_before="$(grep -c "^release edit $tag" "$tmp_dir/gh.log" || true)"
printf 'drift' >> "$artifacts/chatgpt_26.803.81509_amd64.deb"
set +e
mismatch_output="$(publish 2>&1)"
mismatch_status=$?
set -e
if [[ "$mismatch_status" -eq 0 ]] ||
   ! grep -Fq 'mismatched immutable Linux package' <<< "$mismatch_output"; then
  echo "Expected immutable Linux package drift to fail before mutation." >&2
  printf '%s\n' "$mismatch_output" >&2
  exit 1
fi
edit_count_after="$(grep -c "^release edit $tag" "$tmp_dir/gh.log" || true)"
test "$edit_count_before" = "$edit_count_after"

echo "Linux Preview GitHub prerelease publisher fixture PASS"
