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
  # Old, timestamped objects (2020) are prune candidates unless kept; the 2099
  # object is inside any sane grace window so it must always survive. The
  # *-live-*.delta entries are old by timestamp but referenced by the appcast,
  # so they must be kept; old-3000-arm64.delta is old AND unreferenced -> pruned.
  cat <<'OBJECTS'
latest/mac/arm64/Codex-darwin-arm64-current.zip	2020-01-01T00:00:00.000Z
latest/mac/intel/Codex-darwin-x64-current.zip	2020-01-01T00:00:00.000Z
latest/mac/arm64/Codex9999-live-arm64.delta	2020-01-01T00:00:00.000Z
latest/mac/intel/Codex9999-live-x64.delta	2020-01-01T00:00:00.000Z
latest/mac/arm64/old-3000-arm64.delta	2020-01-01T00:00:00.000Z
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

# Freshly built appcasts that reference the current full .zip plus the live
# deltas. Passing these to prune-mac-source.sh must protect the deltas from the
# grace-window prune (the delta-aware keep list).
cat > "$tmp_dir/keep/appcast.xml" <<'XML'
<?xml version='1.0' encoding='utf-8'?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <item>
            <enclosure url="https://m/latest/mac/arm64/Codex-darwin-arm64-current.zip" length="1" type="application/octet-stream" sparkle:edSignature="S==" />
            <sparkle:deltas>
                <enclosure url="https://m/latest/mac/arm64/Codex9999-live-arm64.delta" sparkle:deltaFrom="3575" length="1" type="application/octet-stream" sparkle:edSignature="D==" />
            </sparkle:deltas>
        </item>
    </channel>
</rss>
XML
cat > "$tmp_dir/keep/appcast-x64.xml" <<'XML'
<?xml version='1.0' encoding='utf-8'?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <item>
            <enclosure url="https://m/latest/mac/intel/Codex-darwin-x64-current.zip" length="1" type="application/octet-stream" sparkle:edSignature="S==" />
            <sparkle:deltas>
                <enclosure url="https://m/latest/mac/intel/Codex9999-live-x64.delta" sparkle:deltaFrom="3575" length="1" type="application/octet-stream" sparkle:edSignature="D==" />
            </sparkle:deltas>
        </item>
    </channel>
</rss>
XML

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
    "$tmp_dir/keep/Codex-darwin-x64-current.zip" \
    "$tmp_dir/keep/appcast.xml" \
    "$tmp_dir/keep/appcast-x64.xml"

if ! grep -q 's3://test-bucket/latest/mac/arm64/old.zip' "$rm_log"; then
  echo "expected old.zip to be pruned" >&2
  exit 1
fi
# An old, unreferenced delta must still be pruned.
if ! grep -q 's3://test-bucket/latest/mac/arm64/old-3000-arm64.delta' "$rm_log"; then
  echo "expected old-3000-arm64.delta (old + unreferenced) to be pruned" >&2
  exit 1
fi
if grep -Eq 'current\.zip|recent\.zip|latest/mac/arm64/ ' "$rm_log"; then
  echo "pruned a current, recent, or directory marker object" >&2
  cat "$rm_log" >&2
  exit 1
fi
# Live deltas referenced by the freshly built appcasts must NOT be pruned, even
# though their timestamps are outside the grace window.
if grep -Eq 'Codex9999-live-arm64\.delta|Codex9999-live-x64\.delta' "$rm_log"; then
  echo "pruned a live delta still referenced by the appcast" >&2
  cat "$rm_log" >&2
  exit 1
fi

# Secondary mirror (IHEP S3) case: the mirror.yml prune step maps the
# SECONDARY_S3_* credentials/endpoint onto the R2/AWS env vars the script expects
# and runs against a different bucket while keeping the same safety rules. Drive
# the script through that same mapping and assert it prunes only the stale object.
secondary_rm_log="$tmp_dir/rm-secondary.log"
: > "$secondary_rm_log"

PATH="$tmp_dir/bin:$PATH" \
AWS_RM_LOG="$secondary_rm_log" \
R2_S3_ENDPOINT="https://fgws3.example.invalid" \
AWS_ACCESS_KEY_ID="secondary" \
AWS_SECRET_ACCESS_KEY="secondary" \
AWS_DEFAULT_REGION="auto" \
PRUNE_GRACE_DAYS=7 \
  bash scripts/prune-mac-source.sh \
    secondary-bucket \
    latest/mac \
    "$tmp_dir/keep/Codex-darwin-arm64-current.zip" \
    "$tmp_dir/keep/Codex-darwin-x64-current.zip" \
    "$tmp_dir/keep/appcast.xml" \
    "$tmp_dir/keep/appcast-x64.xml"

if ! grep -q 's3://secondary-bucket/latest/mac/arm64/old.zip' "$secondary_rm_log"; then
  echo "expected old.zip to be pruned on the secondary mirror" >&2
  cat "$secondary_rm_log" >&2
  exit 1
fi
if grep -Eq 'current\.zip|recent\.zip|latest/mac/arm64/ ' "$secondary_rm_log"; then
  echo "secondary prune removed a current, recent, or directory marker object" >&2
  cat "$secondary_rm_log" >&2
  exit 1
fi
# The secondary prune is delta-aware too (the appcasts are passed as keep args):
# live deltas referenced by the feed must survive even though their timestamps
# are outside the grace window, while an old unreferenced delta is still pruned.
if grep -Eq 's3://secondary-bucket/.*Codex9999-live-(arm64|x64)\.delta' "$secondary_rm_log"; then
  echo "secondary prune removed a live delta still referenced by the appcast" >&2
  cat "$secondary_rm_log" >&2
  exit 1
fi
if ! grep -q 's3://secondary-bucket/latest/mac/arm64/old-3000-arm64.delta' "$secondary_rm_log"; then
  echo "expected old-3000-arm64.delta (old + unreferenced) to be pruned on the secondary mirror" >&2
  cat "$secondary_rm_log" >&2
  exit 1
fi

echo "prune-mac-source fixture test PASS"
