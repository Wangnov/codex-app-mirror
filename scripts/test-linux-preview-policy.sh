#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$repo_root/.github/workflows/linux-preview.yml"
publisher="$repo_root/scripts/publish-linux-preview-release.sh"
finalizer="$repo_root/scripts/finalize-linux-preview.sh"
probe="$repo_root/scripts/probe-linux-preview.sh"

for file in "$workflow" "$publisher" "$finalizer" "$probe"; do
  [[ -f "$file" ]] || { echo "Missing Linux Preview contract file: $file" >&2; exit 1; }
done

for forbidden in \
  'aws ' \
  'awscli' \
  'wrangler' \
  'R2_ACCESS_KEY_ID' \
  'R2_SECRET_ACCESS_KEY' \
  'SECONDARY_S3_' \
  'sync-secondary-s3.sh' \
  '.mirror-kit' \
  'cloudflarestorage.com'; do
  if grep -Fqi "$forbidden" "$workflow"; then
    echo "Linux Preview workflow contains forbidden object-storage operation: $forbidden" >&2
    exit 1
  fi
done

grep -Fq 'name: Publish Linux Preview GitHub prerelease' "$workflow"
grep -Fq 'expected_linux_version:' "$workflow"
grep -Fq 'group: codex-app-mirror' "$workflow"
grep -Fq 'GitHub Latest before Linux Preview publication' "$workflow"
grep -Fq 'cmp artifacts/linux-preview-probe/github-latest-before.txt github-latest-after.txt' "$workflow"
grep -Fq '(.assets | length) == 8' "$workflow"

grep -Fq -- '--prerelease' "$publisher"
grep -Fq -- '--latest=false' "$publisher"
grep -Fq '.publication.objectStoragePublished == false' "$publisher"
grep -Fq '.release.destination == "github-prerelease"' "$publisher"
grep -Fq 'exactly eight assets' "$publisher"

grep -Fq '.publication.objectStoragePublished != false' "$finalizer"
grep -Fq 'destination: "github-prerelease"' "$finalizer"
grep -Fq 'objectStoragePublished: false' "$probe"
grep -Fq 'sharedLatestAdvanced: false' "$probe"

if grep -Eq 'https://codexapp|latest/(win|mac|linux|manifest|checksums)|candidate(BaseUrl|Prefix|Url)' "$finalizer" "$probe"; then
  echo "Linux Preview scripts contain a shared mirror route contract." >&2
  exit 1
fi

echo "Linux Preview GitHub-only policy fixture PASS"
