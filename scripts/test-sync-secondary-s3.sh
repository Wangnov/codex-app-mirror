#!/usr/bin/env bash
set -euo pipefail

tmp_dir="$(mktemp -d)"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/artifacts"
aws_log="$tmp_dir/aws.log"
config_snapshot="$tmp_dir/aws-config.snapshot"
fail_once_marker="$tmp_dir/failed-once"
object_state_dir="$tmp_dir/object-state"
: > "$aws_log"
mkdir -p "$object_state_dir"

cat > "$tmp_dir/bin/aws" <<'AWS'
#!/usr/bin/env bash
set -euo pipefail

printf 'CALL %s\n' "$*" >> "${TEST_AWS_LOG:?TEST_AWS_LOG must be set}"
if [[ -n "${AWS_CONFIG_FILE:-}" && ! -f "${TEST_AWS_CONFIG_SNAPSHOT:?TEST_AWS_CONFIG_SNAPSHOT must be set}" ]]; then
  cp "$AWS_CONFIG_FILE" "$TEST_AWS_CONFIG_SNAPSHOT"
fi
printf 'ENV AWS_MAX_ATTEMPTS=%s AWS_RETRY_MODE=%s\n' "${AWS_MAX_ATTEMPTS:-}" "${AWS_RETRY_MODE:-}" >> "$TEST_AWS_LOG"

state_path() {
  local key="$1"
  printf '%s/%s' "${TEST_OBJECT_STATE_DIR:?TEST_OBJECT_STATE_DIR must be set}" "${key//\//__}"
}

if [[ "${1:-}" == "s3api" && "${2:-}" == "put-object" ]]; then
  shift 2
  bucket=""
  key=""
  body=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bucket) bucket="$2"; shift 2 ;;
      --key) key="$2"; shift 2 ;;
      --body) body="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  target="s3://$bucket/$key"
  printf 'PUT %s\n' "$target" >> "$TEST_AWS_LOG"
  if [[ "$target" == "s3://secondary-bucket/latest/mac-arm64" && ! -f "${TEST_FAIL_ONCE_MARKER:?TEST_FAIL_ONCE_MARKER must be set}" ]]; then
    touch "$TEST_FAIL_ONCE_MARKER"
    echo "upload failed: test Connect timeout on endpoint URL: \"$target?uploads\"" >&2
    exit 1
  fi

  wc -c < "$body" | tr -d '[:space:]' > "$(state_path "$key")"
  exit 0
fi

if [[ "${1:-}" == "s3api" && "${2:-}" == "head-object" ]]; then
  shift 2
  bucket=""
  key=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bucket) bucket="$2"; shift 2 ;;
      --key) key="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  target="s3://$bucket/$key"
  printf 'HEAD %s\n' "$target" >> "$TEST_AWS_LOG"
  cat "$(state_path "$key")"
  printf '\n'
  exit 0
fi

if [[ "${1:-}" == "s3" && "${2:-}" == "rm" ]]; then
  target="${3:-}"
  printf 'RM %s\n' "$target" >> "$TEST_AWS_LOG"
  key="${target#s3://*/}"
  rm -f "$(state_path "$key")"
  exit 0
fi

exit 0
AWS
chmod +x "$tmp_dir/bin/aws"

printf 'arm dmg' > "$tmp_dir/artifacts/Codex-mac-arm64.dmg"
printf 'intel dmg' > "$tmp_dir/artifacts/Codex-mac-x64.dmg"
printf 'win msix' > "$tmp_dir/artifacts/Codex.msix"
printf 'win arm64 msix' > "$tmp_dir/artifacts/Codex-arm64.msix"
printf 'checksums' > "$tmp_dir/artifacts/SHA256SUMS.txt"
printf '{"schemaVersion":2}' > "$tmp_dir/artifacts/release-manifest.json"
printf 'arm zip' > "$tmp_dir/artifacts/Codex-darwin-arm64-1.2.3.zip"
printf 'intel zip' > "$tmp_dir/artifacts/Codex-darwin-x64-1.2.3.zip"
printf 'arm delta' > "$tmp_dir/artifacts/Codex1234-1200-arm64.delta"
printf 'intel delta' > "$tmp_dir/artifacts/Codex1234-1200-x64.delta"

cat > "$tmp_dir/artifacts/appcast.xml" <<'XML'
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <sparkle:deltas>
        <enclosure url="https://example.test/latest/mac/arm64/Codex1234-1200-arm64.delta" />
      </sparkle:deltas>
    </item>
  </channel>
</rss>
XML

cat > "$tmp_dir/artifacts/appcast-x64.xml" <<'XML'
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <sparkle:deltas>
        <enclosure url="https://example.test/latest/mac/intel/Codex1234-1200-x64.delta" />
      </sparkle:deltas>
    </item>
  </channel>
</rss>
XML

(
  cd "$repo_root"
  PATH="$tmp_dir/bin:$PATH" \
  TEST_AWS_LOG="$aws_log" \
  TEST_AWS_CONFIG_SNAPSHOT="$config_snapshot" \
  TEST_OBJECT_STATE_DIR="$object_state_dir" \
  TEST_FAIL_ONCE_MARKER="$fail_once_marker" \
  SECONDARY_S3_ENDPOINT="https://s3.example.invalid" \
  SECONDARY_S3_BUCKET="secondary-bucket" \
  SECONDARY_S3_REGION="auto" \
  SECONDARY_S3_ACCESS_KEY_ID="key" \
  SECONDARY_S3_SECRET_ACCESS_KEY="secret" \
  SECONDARY_S3_UPLOAD_ATTEMPTS=2 \
  SECONDARY_S3_RETRY_SLEEP_SECONDS=0 \
  SECONDARY_S3_CONNECT_TIMEOUT_SECONDS=7 \
  SECONDARY_S3_READ_TIMEOUT_SECONDS=11 \
  SECONDARY_S3_AWS_MAX_ATTEMPTS=5 \
  SECONDARY_S3_AWS_RETRY_MODE=standard \
  SECONDARY_S3_UPLOAD_MODE=put-object \
  SECONDARY_S3_MULTIPART_THRESHOLD=16MB \
  SECONDARY_S3_MULTIPART_CHUNKSIZE=32MB \
  SECONDARY_S3_MAX_CONCURRENT_REQUESTS=1 \
    scripts/sync-secondary-s3.sh \
      "$tmp_dir/artifacts/Codex-mac-arm64.dmg" \
      "$tmp_dir/artifacts/Codex-mac-x64.dmg" \
      "$tmp_dir/artifacts/Codex.msix" \
      "$tmp_dir/artifacts/SHA256SUMS.txt" \
      "$tmp_dir/artifacts/release-manifest.json" \
      "$tmp_dir/artifacts/Codex-darwin-arm64-1.2.3.zip" \
      "$tmp_dir/artifacts/Codex-darwin-x64-1.2.3.zip" \
      "$tmp_dir/artifacts/appcast.xml" \
      "$tmp_dir/artifacts/appcast-x64.xml" \
      "$tmp_dir/artifacts/Codex-arm64.msix"
)

test "$(grep -c 'PUT s3://secondary-bucket/latest/mac-arm64' "$aws_log")" = "2"
grep -Fq 'HEAD s3://secondary-bucket/latest/mac-arm64' "$aws_log"
grep -Fq -- '--cli-connect-timeout 7' "$aws_log"
grep -Fq -- '--cli-read-timeout 11' "$aws_log"
grep -Fq 'ENV AWS_MAX_ATTEMPTS=5 AWS_RETRY_MODE=standard' "$aws_log"
grep -Fq 'PUT s3://secondary-bucket/latest/win' "$aws_log"
grep -Fq 'PUT s3://secondary-bucket/latest/win-x64' "$aws_log"
grep -Fq 'PUT s3://secondary-bucket/latest/win-arm64' "$aws_log"
grep -Fq 'PUT s3://secondary-bucket/latest/mac/arm64/Codex1234-1200-arm64.delta' "$aws_log"
grep -Fq 'PUT s3://secondary-bucket/latest/appcast.xml' "$aws_log"
grep -Fq 'CALL s3api put-object' "$aws_log"

grep -Fq 'max_attempts = 5' "$config_snapshot"
grep -Fq 'max_concurrent_requests = 1' "$config_snapshot"
grep -Fq 'multipart_threshold = 16MB' "$config_snapshot"
grep -Fq 'multipart_chunksize = 32MB' "$config_snapshot"

cat > "$tmp_dir/artifacts/release-manifest-preserved-arm64.json" <<'JSON'
{
  "schemaVersion": 4,
  "sources": {
    "windows": {
      "architectures": {
        "arm64": {
          "downloadable": true,
          "currentLocalArtifact": false,
          "currentForCodexVersion": false
        }
      }
    }
  }
}
JSON
: > "$aws_log"
rm -rf "$object_state_dir"
mkdir -p "$object_state_dir"
(
  cd "$repo_root"
  PATH="$tmp_dir/bin:$PATH" \
  TEST_AWS_LOG="$aws_log" \
  TEST_AWS_CONFIG_SNAPSHOT="$config_snapshot" \
  TEST_OBJECT_STATE_DIR="$object_state_dir" \
  TEST_FAIL_ONCE_MARKER="$fail_once_marker" \
  SECONDARY_S3_ENDPOINT="https://s3.example.invalid" \
  SECONDARY_S3_BUCKET="secondary-bucket" \
  SECONDARY_S3_REGION="auto" \
  SECONDARY_S3_ACCESS_KEY_ID="key" \
  SECONDARY_S3_SECRET_ACCESS_KEY="secret" \
  SECONDARY_S3_UPLOAD_ATTEMPTS=2 \
  SECONDARY_S3_RETRY_SLEEP_SECONDS=0 \
  SECONDARY_S3_CONNECT_TIMEOUT_SECONDS=7 \
  SECONDARY_S3_READ_TIMEOUT_SECONDS=11 \
  SECONDARY_S3_AWS_MAX_ATTEMPTS=5 \
  SECONDARY_S3_AWS_RETRY_MODE=standard \
  SECONDARY_S3_UPLOAD_MODE=put-object \
  SECONDARY_S3_MULTIPART_THRESHOLD=16MB \
  SECONDARY_S3_MULTIPART_CHUNKSIZE=32MB \
  SECONDARY_S3_MAX_CONCURRENT_REQUESTS=1 \
    scripts/sync-secondary-s3.sh \
      "$tmp_dir/artifacts/Codex-mac-arm64.dmg" \
      "$tmp_dir/artifacts/Codex-mac-x64.dmg" \
      "$tmp_dir/artifacts/Codex.msix" \
      "$tmp_dir/artifacts/SHA256SUMS.txt" \
      "$tmp_dir/artifacts/release-manifest-preserved-arm64.json" \
      "$tmp_dir/artifacts/Codex-darwin-arm64-1.2.3.zip" \
      "$tmp_dir/artifacts/Codex-darwin-x64-1.2.3.zip" \
      "$tmp_dir/artifacts/appcast.xml" \
      "$tmp_dir/artifacts/appcast-x64.xml" \
      "$tmp_dir/artifacts/Codex-arm64.msix"
)
if grep -Fq 'PUT s3://secondary-bucket/latest/win-arm64' "$aws_log"; then
  echo "Preserved ARM64 should not upload a local secondary win-arm64 object." >&2
  exit 1
fi
if grep -Fq 'RM s3://secondary-bucket/latest/win-arm64' "$aws_log"; then
  echo "Preserved ARM64 should not delete the existing secondary win-arm64 object." >&2
  exit 1
fi

cat > "$tmp_dir/artifacts/release-manifest-missing-arm64.json" <<'JSON'
{
  "schemaVersion": 4,
  "sources": {
    "windows": {
      "architectures": {
        "arm64": {
          "downloadable": false,
          "currentLocalArtifact": false,
          "currentForCodexVersion": false
        }
      }
    }
  }
}
JSON
: > "$aws_log"
rm -rf "$object_state_dir"
mkdir -p "$object_state_dir"
(
  cd "$repo_root"
  PATH="$tmp_dir/bin:$PATH" \
  TEST_AWS_LOG="$aws_log" \
  TEST_AWS_CONFIG_SNAPSHOT="$config_snapshot" \
  TEST_OBJECT_STATE_DIR="$object_state_dir" \
  TEST_FAIL_ONCE_MARKER="$fail_once_marker" \
  SECONDARY_S3_ENDPOINT="https://s3.example.invalid" \
  SECONDARY_S3_BUCKET="secondary-bucket" \
  SECONDARY_S3_REGION="auto" \
  SECONDARY_S3_ACCESS_KEY_ID="key" \
  SECONDARY_S3_SECRET_ACCESS_KEY="secret" \
  SECONDARY_S3_UPLOAD_ATTEMPTS=2 \
  SECONDARY_S3_RETRY_SLEEP_SECONDS=0 \
  SECONDARY_S3_CONNECT_TIMEOUT_SECONDS=7 \
  SECONDARY_S3_READ_TIMEOUT_SECONDS=11 \
  SECONDARY_S3_AWS_MAX_ATTEMPTS=5 \
  SECONDARY_S3_AWS_RETRY_MODE=standard \
  SECONDARY_S3_UPLOAD_MODE=put-object \
  SECONDARY_S3_MULTIPART_THRESHOLD=16MB \
  SECONDARY_S3_MULTIPART_CHUNKSIZE=32MB \
  SECONDARY_S3_MAX_CONCURRENT_REQUESTS=1 \
    scripts/sync-secondary-s3.sh \
      "$tmp_dir/artifacts/Codex-mac-arm64.dmg" \
      "$tmp_dir/artifacts/Codex-mac-x64.dmg" \
      "$tmp_dir/artifacts/Codex.msix" \
      "$tmp_dir/artifacts/SHA256SUMS.txt" \
      "$tmp_dir/artifacts/release-manifest-missing-arm64.json" \
      "$tmp_dir/artifacts/Codex-darwin-arm64-1.2.3.zip" \
      "$tmp_dir/artifacts/Codex-darwin-x64-1.2.3.zip" \
      "$tmp_dir/artifacts/appcast.xml" \
      "$tmp_dir/artifacts/appcast-x64.xml" \
      "$tmp_dir/artifacts/Codex-arm64.msix"
)
if grep -Fq 'PUT s3://secondary-bucket/latest/win-arm64' "$aws_log"; then
  echo "Missing ARM64 should not upload a secondary win-arm64 object." >&2
  exit 1
fi
grep -Fq 'RM s3://secondary-bucket/latest/win-arm64' "$aws_log"

cat > "$tmp_dir/artifacts/release-manifest-lagging-arm64.json" <<'JSON'
{
  "schemaVersion": 4,
  "sources": {
    "windows": {
      "architectures": {
        "arm64": {
          "downloadable": true,
          "currentLocalArtifact": true,
          "currentForCodexVersion": false
        }
      }
    }
  }
}
JSON
: > "$aws_log"
rm -rf "$object_state_dir"
mkdir -p "$object_state_dir"
(
  cd "$repo_root"
  PATH="$tmp_dir/bin:$PATH" \
  TEST_AWS_LOG="$aws_log" \
  TEST_AWS_CONFIG_SNAPSHOT="$config_snapshot" \
  TEST_OBJECT_STATE_DIR="$object_state_dir" \
  TEST_FAIL_ONCE_MARKER="$fail_once_marker" \
  SECONDARY_S3_ENDPOINT="https://s3.example.invalid" \
  SECONDARY_S3_BUCKET="secondary-bucket" \
  SECONDARY_S3_REGION="auto" \
  SECONDARY_S3_ACCESS_KEY_ID="key" \
  SECONDARY_S3_SECRET_ACCESS_KEY="secret" \
  SECONDARY_S3_UPLOAD_ATTEMPTS=2 \
  SECONDARY_S3_RETRY_SLEEP_SECONDS=0 \
  SECONDARY_S3_CONNECT_TIMEOUT_SECONDS=7 \
  SECONDARY_S3_READ_TIMEOUT_SECONDS=11 \
  SECONDARY_S3_AWS_MAX_ATTEMPTS=5 \
  SECONDARY_S3_AWS_RETRY_MODE=standard \
  SECONDARY_S3_UPLOAD_MODE=put-object \
  SECONDARY_S3_MULTIPART_THRESHOLD=16MB \
  SECONDARY_S3_MULTIPART_CHUNKSIZE=32MB \
  SECONDARY_S3_MAX_CONCURRENT_REQUESTS=1 \
    scripts/sync-secondary-s3.sh \
      "$tmp_dir/artifacts/Codex-mac-arm64.dmg" \
      "$tmp_dir/artifacts/Codex-mac-x64.dmg" \
      "$tmp_dir/artifacts/Codex.msix" \
      "$tmp_dir/artifacts/SHA256SUMS.txt" \
      "$tmp_dir/artifacts/release-manifest-lagging-arm64.json" \
      "$tmp_dir/artifacts/Codex-darwin-arm64-1.2.3.zip" \
      "$tmp_dir/artifacts/Codex-darwin-x64-1.2.3.zip" \
      "$tmp_dir/artifacts/appcast.xml" \
      "$tmp_dir/artifacts/appcast-x64.xml" \
      "$tmp_dir/artifacts/Codex-arm64.msix"
)
grep -Fq 'PUT s3://secondary-bucket/latest/win-arm64' "$aws_log"

echo "sync-secondary-s3 retry fixture PASS"
