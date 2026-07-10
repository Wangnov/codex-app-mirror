#!/usr/bin/env bash
set -euo pipefail

tmp_dir="$(mktemp -d)"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/server" "$tmp_dir/out"
counter_path="$tmp_dir/store-link-count"
printf '0' > "$counter_path"

expected_package="OpenAI.Codex_26.616.4196.0_x64__2p2nqsd0c76g0"
old_package="OpenAI.Codex_26.616.3767.0_x64__2p2nqsd0c76g0"
expected_arm64_package="OpenAI.Codex_26.616.4196.0_arm64__2p2nqsd0c76g0"
changed_arm64_package="OpenAI.Codex_26.616.5000.0_arm64__2p2nqsd0c76g0"
printf 'win' > "$tmp_dir/server/$expected_package.Msix"
printf 'arm64-new' > "$tmp_dir/server/$changed_arm64_package.Msix"

cat > "$tmp_dir/bin/dotnet" <<'DOTNET'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  --info)
    printf 'fake dotnet info\n'
    ;;
  run)
    if [[ "${!#}" != "OpenAI.Codex" ]]; then
      echo "store-link did not receive the exact Stable package identity: $*" >&2
      exit 1
    fi
    if [[ "$*" == *" arm64 OpenAI.Codex" ]]; then
      printf '%s\thttp://127.0.0.1:%s/%s.Msix\n' \
        "${TEST_CHANGED_ARM64_PACKAGE:?TEST_CHANGED_ARM64_PACKAGE must be set}" \
        "${TEST_HTTP_PORT:?TEST_HTTP_PORT must be set}" \
        "$TEST_CHANGED_ARM64_PACKAGE"
      exit 0
    fi

    count="$(cat "${TEST_STORE_LINK_COUNTER:?TEST_STORE_LINK_COUNTER must be set}")"
    count=$((count + 1))
    printf '%s' "$count" > "$TEST_STORE_LINK_COUNTER"
    if [[ "$count" -eq 1 ]]; then
      printf '%s\thttp://127.0.0.1:%s/%s.Msix\n' \
        "${TEST_OLD_PACKAGE:?TEST_OLD_PACKAGE must be set}" \
        "${TEST_HTTP_PORT:?TEST_HTTP_PORT must be set}" \
        "$TEST_OLD_PACKAGE"
    else
      printf '%s\thttp://127.0.0.1:%s/%s.Msix\n' \
        "${TEST_EXPECTED_PACKAGE:?TEST_EXPECTED_PACKAGE must be set}" \
        "${TEST_HTTP_PORT:?TEST_HTTP_PORT must be set}" \
        "$TEST_EXPECTED_PACKAGE"
    fi
    ;;
  *)
    echo "unexpected dotnet invocation: $*" >&2
    exit 1
    ;;
esac
DOTNET
chmod +x "$tmp_dir/bin/dotnet"

port="$(
  python3 - <<'PY'
import socket

with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1])
PY
)"

(
  cd "$tmp_dir/server"
  python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1
) &
server_pid="$!"

for _ in {1..50}; do
  if python3 - "$port" 2>/dev/null <<'PY'
import socket
import sys

port = int(sys.argv[1])
with socket.create_connection(("127.0.0.1", port), timeout=0.2):
    pass
PY
  then
    break
  fi
  sleep 0.1
done

cat > "$tmp_dir/probe-manifest.json" <<JSON
{
  "schemaVersion": 1,
  "sources": {
    "windows": {
      "packageMoniker": "$expected_package",
      "contentLength": 3,
      "architectures": {
        "x64": {
          "architecture": "x64",
          "status": "downloadable",
          "downloadable": true,
          "packageMoniker": "$expected_package",
          "contentLength": 3
        },
        "arm64": {
          "architecture": "arm64",
          "status": "downloadable",
          "downloadable": true,
          "packageMoniker": "$expected_arm64_package",
          "contentLength": 4
        }
      }
    }
  }
}
JSON

(
  cd "$repo_root"
  PATH="$tmp_dir/bin:$PATH" \
  TEST_STORE_LINK_COUNTER="$counter_path" \
  TEST_OLD_PACKAGE="$old_package" \
  TEST_EXPECTED_PACKAGE="$expected_package" \
  TEST_CHANGED_ARM64_PACKAGE="$changed_arm64_package" \
  TEST_HTTP_PORT="$port" \
    pwsh -NoLogo -NoProfile -File scripts/download-windows.ps1 \
      -OutDir "$tmp_dir/out" \
      -ManifestPath "$tmp_dir/probe-manifest.json" \
      -StoreLinkMaxAttempts 2 \
      -StoreLinkRetryDelaySeconds 0
)

test "$(cat "$counter_path")" = "2"
test -f "$tmp_dir/out/$expected_package.Msix"
test ! -f "$tmp_dir/out/$expected_arm64_package.Msix"
test ! -f "$tmp_dir/out/$changed_arm64_package.Msix"
grep -F "$expected_package.Msix" "$tmp_dir/out/SHA256SUMS-windows.txt"
if grep -F 'arm64' "$tmp_dir/out/SHA256SUMS-windows.txt"; then
  echo "Optional ARM64 drift should not appear in SHA256SUMS-windows.txt." >&2
  exit 1
fi

echo "download-windows retry fixture PASS"
