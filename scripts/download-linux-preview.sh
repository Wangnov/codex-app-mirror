#!/usr/bin/env bash
set -euo pipefail

out_dir="${1:-dist/linux}"
manifest_path="${2:-probe-manifest.json}"

for command in curl jq python3 sha256sum stat; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Missing required command: $command" >&2
    exit 1
  }
done

[[ -f "$manifest_path" ]] || {
  echo "Linux Preview probe manifest not found: $manifest_path" >&2
  exit 1
}

jq -e '
  .schemaVersion == 6
  and .channel == "linux-preview"
  and .preview.contract == "linux-preview-v1"
  and .publication.githubPrereleaseOnly == true
  and .publication.objectStoragePublished == false
  and .publication.githubLatestAdvanced == false
  and .publication.sharedLatestAdvanced == false
  and ([.sources.linux.architectures[][]] | length == 4)
  ' "$manifest_path" >/dev/null || {
    echo "Refusing to download outside the Linux Preview GitHub-only contract." >&2
    exit 1
  }

mkdir -p "$out_dir"
tmp_sums="$(mktemp)"
cleanup() {
  rm -f "$tmp_sums"
}
trap cleanup EXIT

curl_args=(
  --fail
  --location
  --show-error
  --retry 5
  --retry-delay 2
  --retry-max-time 1800
  --connect-timeout 20
  --retry-all-errors
)

file_size() {
  local file="$1"
  if stat -c '%s' "$file" >/dev/null 2>&1; then
    stat -c '%s' "$file"
  else
    stat -f '%z' "$file"
  fi
}

validate_source() {
  local logical_arch="$1"
  local format="$2"
  local url="$3"
  local source_basename="$4"
  local mirror_basename="$5"
  python3 - "$logical_arch" "$format" "$url" "$source_basename" "$mirror_basename" <<'PY'
import pathlib
import sys
from urllib.parse import urlsplit

logical_arch, package_format, url, source_basename, mirror_basename = sys.argv[1:]
parts = urlsplit(url)
if parts.scheme != "https" or parts.netloc != "persistent.oaistatic.com" or parts.query or parts.fragment:
    raise SystemExit(f"Linux Preview source is not an official HTTPS URL: {url!r}")
expected_prefixes = {
    ("x64", "deb"): "/codex-app-prod/linux/deb/pool/main/c/chatgpt/",
    ("arm64", "deb"): "/codex-app-prod/linux/deb/pool/main/c/chatgpt/",
    ("x64", "rpm"): "/codex-app-prod/linux/rpm/x86_64/",
    ("arm64", "rpm"): "/codex-app-prod/linux/rpm/aarch64/",
}
prefix = expected_prefixes.get((logical_arch, package_format))
if not prefix or not parts.path.startswith(prefix):
    raise SystemExit(f"Linux Preview source path is outside the official repository: {parts.path!r}")
actual_basename = pathlib.PurePosixPath(parts.path).name
expected_suffix = f".{package_format}"
for label, value in (("source", source_basename), ("mirror", mirror_basename)):
    if (
        not value
        or pathlib.PurePosixPath(value).name != value
        or ".." in value
        or not value.endswith(expected_suffix)
        or any(ord(char) < 32 or ord(char) == 127 for char in value)
    ):
        raise SystemExit(f"Unsafe Linux Preview {label} basename: {value!r}")
if actual_basename != source_basename or mirror_basename != source_basename:
    raise SystemExit(
        f"Linux Preview basename drift: URL={actual_basename!r}, source={source_basename!r}, mirror={mirror_basename!r}"
    )
PY
}

while IFS=$'\t' read -r logical_arch format url source_basename mirror_basename expected_size expected_sha; do
  [[ -n "$logical_arch" && -n "$format" && -n "$url" ]] || {
    echo "Linux Preview manifest contains an incomplete package entry." >&2
    exit 1
  }
  validate_source "$logical_arch" "$format" "$url" "$source_basename" "$mirror_basename"
  output="$out_dir/$mirror_basename"
  echo "Downloading Linux Preview $logical_arch $format: $url" >&2
  curl "${curl_args[@]}" --output "$output" "$url"

  actual_size="$(file_size "$output")"
  if [[ "$actual_size" != "$expected_size" ]]; then
    echo "Linux Preview $logical_arch $format size mismatch: expected $expected_size, got $actual_size" >&2
    exit 1
  fi
  actual_sha="$(sha256sum "$output" | awk '{print tolower($1)}')"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    echo "Linux Preview $logical_arch $format SHA-256 mismatch: expected $expected_sha, got $actual_sha" >&2
    exit 1
  fi
  printf '%s  %s\n' "$actual_sha" "$mirror_basename" >> "$tmp_sums"
done < <(
  jq -r '
    .sources.linux.architectures
    | to_entries[] as $architecture
    | $architecture.value
    | to_entries[]
    | [
        $architecture.key,
        .key,
        .value.url,
        .value.sourceBasename,
        .value.mirrorBasename,
        (.value.contentLength | tostring),
        .value.sha256
      ]
    | @tsv
    ' "$manifest_path"
)

[[ "$(wc -l < "$tmp_sums" | tr -d '[:space:]')" == "4" ]] || {
  echo "Expected exactly four Linux Preview packages." >&2
  exit 1
}
sort -k2 "$tmp_sums" > "$out_dir/SHA256SUMS-linux.txt"
echo "Downloaded and checksum-verified four Linux Preview packages."
