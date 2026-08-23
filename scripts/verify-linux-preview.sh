#!/usr/bin/env bash
set -euo pipefail

manifest_path="${1:-probe-manifest.json}"
artifacts_dir="${2:-dist/linux}"
output_path="${3:-$artifacts_dir/linux-identity.json}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
key_b64_file="${CODEX_LINUX_REPOSITORY_KEY_FILE:-$repo_root/scripts/codex-linux-repository-key.b64}"
expected_key_fingerprint="3BFA0E4AE8B8CC16A2D9BA684A3B4A566C4660E4"
expected_key_sha256="23e2cfbdef6afe95505f9e95a2cb63585da7ffe9b06a51ec08a32407c847d596"

for command in base64 dpkg-deb gpg jq rpm rpmkeys sha256sum; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Missing required command: $command" >&2
    exit 1
  }
done

[[ -f "$manifest_path" ]] || { echo "Missing manifest: $manifest_path" >&2; exit 1; }
[[ -d "$artifacts_dir" ]] || { echo "Missing Linux artifacts directory: $artifacts_dir" >&2; exit 1; }
[[ -f "$key_b64_file" ]] || { echo "Missing pinned repository key: $key_b64_file" >&2; exit 1; }

expected_version="$(jq -r '.preview.expectedVersion // empty' "$manifest_path")"
jq -e --arg version "$expected_version" --arg fingerprint "$expected_key_fingerprint" '
  .channel == "linux-preview"
  and .preview.contract == "linux-preview-v1"
  and .preview.repositorySigningKey.fingerprint == $fingerprint
  and .sources.linux.packageName == "chatgpt"
  and .sources.linux.version == $version
  and ([.sources.linux.architectures[][]] | length == 4)
  ' "$manifest_path" >/dev/null || {
    echo "Linux Preview manifest identity contract mismatch." >&2
    exit 1
  }

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

decode_base64_file() {
  local input="$1"
  local output="$2"
  if ! base64 --decode < "$input" > "$output" 2>/dev/null; then
    base64 -D < "$input" > "$output"
  fi
}

decode_base64_text() {
  local value="$1"
  local output="$2"
  if ! printf '%s' "$value" | base64 --decode > "$output" 2>/dev/null; then
    printf '%s' "$value" | base64 -D > "$output"
  fi
}

key_identity() {
  local key_file="$1"
  local label="$2"
  local sha fingerprint
  sha="$(sha256sum "$key_file" | awk '{print tolower($1)}')"
  fingerprint="$(gpg --batch --show-keys --with-colons "$key_file" 2>/dev/null | awk -F: '$1 == "fpr" {print toupper($10); exit}')"
  if [[ "$sha" != "$expected_key_sha256" || "$fingerprint" != "$expected_key_fingerprint" ]]; then
    echo "$label repository signing key identity mismatch." >&2
    exit 1
  fi
}

decode_base64_file "$key_b64_file" "$tmp_dir/repository-key.gpg"
key_identity "$tmp_dir/repository-key.gpg" "Pinned"

# rpmkeys imports an ASCII-armored public key even though APT/gpgv can consume
# the compact binary keyring shipped by OpenAI. Convert through an isolated
# GnuPG home without changing the pinned key material or fingerprint.
mkdir -p "$tmp_dir/gnupg"
chmod 0700 "$tmp_dir/gnupg"
gpg --homedir "$tmp_dir/gnupg" --batch --import "$tmp_dir/repository-key.gpg" >/dev/null 2>&1
gpg --homedir "$tmp_dir/gnupg" --batch --armor --export "$expected_key_fingerprint" > "$tmp_dir/repository-key.asc"
[[ -s "$tmp_dir/repository-key.asc" ]] || {
  echo "Failed to render the pinned Codex Linux repository key for rpmkeys." >&2
  exit 1
}

mkdir -p "$tmp_dir/rpmdb"
rpm --dbpath "$tmp_dir/rpmdb" --initdb
rpmkeys --dbpath "$tmp_dir/rpmdb" --import "$tmp_dir/repository-key.asc"
: > "$tmp_dir/packages.jsonl"

verify_embedded_key() {
  local key_b64="$1"
  local label="$2"
  local suffix="$3"
  if [[ -z "$key_b64" ]]; then
    echo "$label does not embed the Codex Linux repository key." >&2
    exit 1
  fi
  decode_base64_text "$key_b64" "$tmp_dir/embedded-key-$suffix.gpg"
  key_identity "$tmp_dir/embedded-key-$suffix.gpg" "$label embedded"
}

while IFS=$'\t' read -r logical_arch format file_name expected_arch expected_sha; do
  file="$artifacts_dir/$file_name"
  [[ -f "$file" ]] || { echo "Missing Linux Preview package: $file" >&2; exit 1; }
  actual_sha="$(sha256sum "$file" | awk '{print tolower($1)}')"
  [[ "$actual_sha" == "$expected_sha" ]] || {
    echo "Linux Preview package checksum drift for $file_name" >&2
    exit 1
  }

  if [[ "$format" == "deb" ]]; then
    package_name="$(dpkg-deb -f "$file" Package)"
    version="$(dpkg-deb -f "$file" Version)"
    package_arch="$(dpkg-deb -f "$file" Architecture)"
    maintainer="$(dpkg-deb -f "$file" Maintainer)"
    homepage="$(dpkg-deb -f "$file" Homepage)"
    [[ "$package_name" == "chatgpt" && "$version" == "$expected_version" && "$package_arch" == "$expected_arch" ]] || {
      echo "Debian package identity mismatch for $file_name: $package_name $version $package_arch" >&2
      exit 1
    }
    deb_file_list="$tmp_dir/deb-files-$logical_arch.txt"
    # dpkg-deb renders symlinks as "path -> target". The package path is the
    # sixth field, not the final field, for both regular files and symlinks.
    dpkg-deb --contents "$file" | awk '{print $6}' > "$deb_file_list"
    grep -Eq '^\.?/usr/bin/chatgpt$' "$deb_file_list" || {
      echo "Debian package is missing /usr/bin/chatgpt: $file_name" >&2
      exit 1
    }
    grep -Eq '^\.?/usr/lib/chatgpt/codex-launcher$' "$deb_file_list" || {
      echo "Debian package is missing /usr/lib/chatgpt/codex-launcher: $file_name" >&2
      exit 1
    }
    control_dir="$tmp_dir/control-$logical_arch"
    mkdir -p "$control_dir"
    dpkg-deb --control "$file" "$control_dir"
    embedded_key_b64="$(sed -n "s/^SIGNING_KEY_BASE64='\(.*\)'$/\1/p" "$control_dir/postinst" | head -n 1)"
    verify_embedded_key "$embedded_key_b64" "Debian $logical_arch" "deb-$logical_arch"
    jq -nc \
      --arg logicalArchitecture "$logical_arch" \
      --arg format "$format" \
      --arg fileName "$file_name" \
      --arg sha256 "$actual_sha" \
      --arg packageName "$package_name" \
      --arg version "$version" \
      --arg packageArchitecture "$package_arch" \
      --arg maintainer "$maintainer" \
      --arg homepage "$homepage" \
      --arg keyFingerprint "$expected_key_fingerprint" '
      {
        logicalArchitecture: $logicalArchitecture,
        format: $format,
        fileName: $fileName,
        sha256: $sha256,
        packageName: $packageName,
        version: $version,
        packageArchitecture: $packageArchitecture,
        maintainer: $maintainer,
        homepage: $homepage,
        repositoryMetadataSignatureVerified: true,
        packageChecksumVerified: true,
        embeddedRepositoryKeyVerified: true,
        repositorySigningKeyFingerprint: $keyFingerprint,
        packageSignatureVerified: null
      }
      ' >> "$tmp_dir/packages.jsonl"
  elif [[ "$format" == "rpm" ]]; then
    query="$(rpm -qp --queryformat $'%{NAME}\t%{VERSION}\t%{RELEASE}\t%{ARCH}\t%{URL}\t%{SUMMARY}\t%{BUILDHOST}\t%{RSAHEADER:pgpsig}' "$file")"
    IFS=$'\t' read -r package_name version release package_arch homepage summary build_host signature <<< "$query"
    [[ "$package_name" == "chatgpt" && "$version" == "$expected_version" && "$release" == "1" && "$package_arch" == "$expected_arch" ]] || {
      echo "RPM package identity mismatch for $file_name: $package_name $version-$release $package_arch" >&2
      exit 1
    }
    grep -Fqi 'key id 4a3b4a566c4660e4' <<< "$signature" || {
      echo "RPM package signing key ID mismatch for $file_name: $signature" >&2
      exit 1
    }
    rpm_file_list="$tmp_dir/rpm-files-$logical_arch.txt"
    rpm -qpl "$file" > "$rpm_file_list"
    grep -Fxq '/usr/bin/chatgpt' "$rpm_file_list" || {
      echo "RPM package is missing /usr/bin/chatgpt: $file_name" >&2
      exit 1
    }
    grep -Fxq '/usr/lib/chatgpt/codex-launcher' "$rpm_file_list" || {
      echo "RPM package is missing /usr/lib/chatgpt/codex-launcher: $file_name" >&2
      exit 1
    }
    embedded_key_b64="$(rpm -qp --scripts "$file" | sed -n "s/^SIGNING_KEY_BASE64='\(.*\)'$/\1/p" | head -n 1)"
    verify_embedded_key "$embedded_key_b64" "RPM $logical_arch" "rpm-$logical_arch"
    signature_output="$(rpmkeys --dbpath "$tmp_dir/rpmdb" --checksig "$file")"
    grep -Eq 'digests signatures OK|digests OK' <<< "$signature_output" || {
      echo "RPM signature verification failed for $file_name: $signature_output" >&2
      exit 1
    }
    jq -nc \
      --arg logicalArchitecture "$logical_arch" \
      --arg format "$format" \
      --arg fileName "$file_name" \
      --arg sha256 "$actual_sha" \
      --arg packageName "$package_name" \
      --arg version "$version" \
      --arg release "$release" \
      --arg packageArchitecture "$package_arch" \
      --arg homepage "$homepage" \
      --arg summary "$summary" \
      --arg buildHost "$build_host" \
      --arg signature "$signature" \
      --arg keyFingerprint "$expected_key_fingerprint" '
      {
        logicalArchitecture: $logicalArchitecture,
        format: $format,
        fileName: $fileName,
        sha256: $sha256,
        packageName: $packageName,
        version: $version,
        release: $release,
        packageArchitecture: $packageArchitecture,
        homepage: $homepage,
        summary: $summary,
        buildHost: $buildHost,
        rpmHeaderSignature: $signature,
        repositoryMetadataSignatureVerified: true,
        packageChecksumVerified: true,
        embeddedRepositoryKeyVerified: true,
        repositorySigningKeyFingerprint: $keyFingerprint,
        packageSignatureVerified: true
      }
      ' >> "$tmp_dir/packages.jsonl"
  else
    echo "Unsupported Linux package format: $format" >&2
    exit 1
  fi
done < <(
  jq -r '
    .sources.linux.architectures
    | to_entries[] as $architecture
    | $architecture.value
    | to_entries[]
    | [
        $architecture.key,
        .key,
        .value.mirrorBasename,
        .value.packageArchitecture,
        .value.sha256
      ]
    | @tsv
    ' "$manifest_path"
)

jq -s \
  --arg version "$expected_version" \
  --arg fingerprint "$expected_key_fingerprint" '
  if length != 4 then error("expected four verified Linux packages") else . end
  | {
      schemaVersion: 1,
      channel: "linux-preview",
      product: "ChatGPT desktop app with Codex",
      expectedPackageName: "chatgpt",
      expectedVersion: $version,
      versionsMatch: ([.[].version] | unique == [$version]),
      repositorySigningKeyFingerprint: $fingerprint,
      packages: (
        reduce .[] as $package ({};
          .[$package.logicalArchitecture][$package.format] = $package
        )
      )
    }
  ' "$tmp_dir/packages.jsonl" > "$output_path"

jq -e --arg version "$expected_version" --arg fingerprint "$expected_key_fingerprint" '
  .channel == "linux-preview"
  and .expectedPackageName == "chatgpt"
  and .expectedVersion == $version
  and .versionsMatch == true
  and .repositorySigningKeyFingerprint == $fingerprint
  and ([.packages[][]] | length == 4)
  and ([.packages[][] | .packageChecksumVerified == true] | all)
  and ([.packages[][] | .embeddedRepositoryKeyVerified == true] | all)
  and .packages.x64.rpm.packageSignatureVerified == true
  and .packages.arm64.rpm.packageSignatureVerified == true
  ' "$output_path" >/dev/null

jq . "$output_path"
