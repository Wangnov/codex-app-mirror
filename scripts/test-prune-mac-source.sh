#!/usr/bin/env bash
set -euo pipefail

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/keep"
rm_log="$tmp_dir/rm.log"
: > "$rm_log"

cat > "$tmp_dir/bin/aws" <<'AWS'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "s3api" && "$2" == "list-objects-v2" ]]; then
  cat <<'OBJECTS'
latest/mac/arm64/Codex-darwin-arm64-current.zip	2020-01-01T00:00:00.000Z
latest/mac/intel/Codex-darwin-x64-current.zip	2020-01-01T00:00:00.000Z
latest/mac/arm64/old.zip	2020-01-01T00:00:00.000Z
latest/mac/intel/recent.zip	2099-01-01T00:00:00.000Z
latest/mac/arm64/	2020-01-01T00:00:00.000Z
OBJECTS
  exit 0
fi

if [[ "$1" == "s3" && "$2" == "rm" ]]; then
  echo "$*" >> "${AWS_RM_LOG:?AWS_RM_LOG must be set}"
  exit 0
fi

echo "unexpected aws invocation: $*" >&2
exit 1
AWS
chmod +x "$tmp_dir/bin/aws"

touch \
  "$tmp_dir/keep/Codex-darwin-arm64-current.zip" \
  "$tmp_dir/keep/Codex-darwin-x64-current.zip"

PATH="$tmp_dir/bin:$PATH" \
AWS_RM_LOG="$rm_log" \
R2_S3_ENDPOINT="https://example.invalid" \
AWS_ACCESS_KEY_ID="test" \
AWS_SECRET_ACCESS_KEY="test" \
PRUNE_GRACE_DAYS=7 \
  bash scripts/prune-mac-source.sh \
    test-bucket \
    latest/mac \
    "$tmp_dir/keep/Codex-darwin-arm64-current.zip" \
    "$tmp_dir/keep/Codex-darwin-x64-current.zip"

if ! grep -q 's3://test-bucket/latest/mac/arm64/old.zip' "$rm_log"; then
  echo "expected old.zip to be pruned" >&2
  exit 1
fi
if grep -Eq 'current\.zip|recent\.zip|latest/mac/arm64/ ' "$rm_log"; then
  echo "pruned a current, recent, or directory marker object" >&2
  cat "$rm_log" >&2
  exit 1
fi

echo "prune-mac-source fixture test PASS"
