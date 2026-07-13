#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$repo_root/.github/workflows/beta-prerelease.yml"
publisher="$repo_root/scripts/emergency-publish-release.sh"
finalizer="$repo_root/scripts/emergency-finalize-windows-beta.sh"

[[ -f "$workflow" ]] || {
  echo "Missing GitHub-only Beta prerelease workflow." >&2
  exit 1
}
[[ ! -e "$repo_root/.github/workflows/emergency-windows-beta-release.yml" ]] || {
  echo "Superseded object-storage Beta workflow still exists." >&2
  exit 1
}
[[ ! -e "$repo_root/scripts/emergency-sync-candidate-s3.sh" ]] || {
  echo "Superseded Beta object-storage sync helper still exists." >&2
  exit 1
}

for forbidden in \
  'aws ' \
  'awscli' \
  'R2_ACCESS_KEY_ID' \
  'R2_SECRET_ACCESS_KEY' \
  'SECONDARY_S3_' \
  'emergency-sync-candidate-s3.sh' \
  'cloudflarestorage.com'; do
  if grep -Fqi "$forbidden" "$workflow"; then
    echo "Beta workflow contains forbidden object-storage operation: $forbidden" >&2
    exit 1
  fi
done

grep -Fq 'name: Publish Beta GitHub prerelease' "$workflow"
grep -Fq 'expected_windows_package_version:' "$workflow"
grep -Fq 'expected_macos_version:' "$workflow"
grep -Fq 'runs-on: windows-latest' "$workflow"
grep -Fq 'runs-on: macos-latest' "$workflow"
grep -Fq 'GitHub Latest before Beta publication' "$workflow"
grep -Fq 'cmp artifacts/beta-probe/github-latest-before.txt github-latest-after.txt' "$workflow"

grep -Fq -- '--prerelease' "$publisher"
grep -Fq -- '--latest=false' "$publisher"
grep -Fq '.publication.objectStoragePublished == false' "$publisher"
grep -Fq '.release.destination == "github-prerelease"' "$publisher"

grep -Fq '.publication.objectStoragePublished != false' "$finalizer"
grep -Fq 'destination: "github-prerelease"' "$finalizer"
if grep -Eq 'https://codexapp|candidate(BaseUrl|Prefix|Url)' "$finalizer"; then
  echo "Beta finalizer contains an object-storage candidate URL contract." >&2
  exit 1
fi

echo "Beta prerelease-only policy fixture PASS"
