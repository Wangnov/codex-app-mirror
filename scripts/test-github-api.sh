#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_dir/bin"
counter_file="$tmp_dir/counter"

cat > "$tmp_dir/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == "api" ]] || { echo "unexpected gh invocation: $*" >&2; exit 2; }
count="$(cat "${TEST_GH_COUNTER:?}")"
count=$((count + 1))
printf '%s' "$count" > "$TEST_GH_COUNTER"

case "${TEST_GH_MODE:?}" in
  recover)
    if ((count < 3)); then
      echo 'gh: HTTP 503' >&2
      exit 1
    fi
    printf '{"tag_name":"codex-app-1.2.3"}\n'
    ;;
  persistent-503)
    echo 'gh: HTTP 503' >&2
    exit 1
    ;;
  not-found)
    echo 'gh: Not Found (HTTP 404)' >&2
    exit 1
    ;;
  release-assets)
    printf '{"assets":[{"name":"asset.bin","size":3,"digest":"sha256:abc"}]}\n'
    ;;
  *)
    echo "unexpected TEST_GH_MODE: $TEST_GH_MODE" >&2
    exit 2
    ;;
esac
GH
chmod +x "$tmp_dir/bin/gh"

source "$repo_root/scripts/github-api.sh"

run_with_mode() {
  local mode="$1"
  shift

  printf '0' > "$counter_file"
  PATH="$tmp_dir/bin:$PATH" \
    TEST_GH_MODE="$mode" \
    TEST_GH_COUNTER="$counter_file" \
    GITHUB_API_ATTEMPTS=3 \
    GITHUB_API_RETRY_DELAY_SECONDS=0 \
    "$@"
}

output="$(run_with_mode recover github_api_json_allow_404 'repos/{owner}/{repo}/releases/latest' 2>"$tmp_dir/recover.err")"
[[ "$(jq -r .tag_name <<<"$output")" == "codex-app-1.2.3" ]]
[[ "$(cat "$counter_file")" == "3" ]]
[[ "$(grep -c 'retrying' "$tmp_dir/recover.err")" == "2" ]]

set +e
run_with_mode persistent-503 github_api_json_allow_404 'repos/{owner}/{repo}/releases/latest' >"$tmp_dir/503.out" 2>"$tmp_dir/503.err"
status=$?
set -e
[[ "$status" -ne 0 && "$status" -ne "$GITHUB_API_NOT_FOUND_STATUS" ]]
[[ "$(cat "$counter_file")" == "3" ]]
[[ ! -s "$tmp_dir/503.out" ]]
grep -Fq 'gh: HTTP 503' "$tmp_dir/503.err"

set +e
run_with_mode not-found github_api_json_allow_404 'repos/{owner}/{repo}/releases/latest' >"$tmp_dir/404.out" 2>"$tmp_dir/404.err"
status=$?
set -e
[[ "$status" -eq "$GITHUB_API_NOT_FOUND_STATUS" ]]
[[ "$(cat "$counter_file")" == "1" ]]
[[ ! -s "$tmp_dir/404.out" ]]

assets="$(run_with_mode release-assets github_release_assets_json_allow_404 codex-app-1.2.3)"
[[ "$(jq -r '.[0].name' <<<"$assets")" == "asset.bin" ]]

echo "GitHub API retry and 404 handling fixture PASS"
