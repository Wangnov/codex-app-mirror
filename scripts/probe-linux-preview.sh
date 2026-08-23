#!/usr/bin/env bash
set -euo pipefail

manifest_path="${1:-probe-manifest.json}"
expected_version="${EXPECTED_LINUX_VERSION:?EXPECTED_LINUX_VERSION is required}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
key_b64_file="${CODEX_LINUX_REPOSITORY_KEY_FILE:-$repo_root/scripts/codex-linux-repository-key.b64}"
expected_key_fingerprint="3BFA0E4AE8B8CC16A2D9BA684A3B4A566C4660E4"
expected_key_sha256="23e2cfbdef6afe95505f9e95a2cb63585da7ffe9b06a51ec08a32407c847d596"
deb_base_url="https://persistent.oaistatic.com/codex-app-prod/linux/deb"
rpm_x64_base_url="https://persistent.oaistatic.com/codex-app-prod/linux/rpm/x86_64"
rpm_arm64_base_url="https://persistent.oaistatic.com/codex-app-prod/linux/rpm/aarch64"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

for command in base64 curl gpg gpgv gzip jq python3 sha256sum; do
  require "$command"
done

if [[ ! "$expected_version" =~ ^[0-9]+([.][0-9]+)+$ ]]; then
  echo "Invalid expected Linux Preview version: $expected_version" >&2
  exit 2
fi

[[ -f "$key_b64_file" ]] || {
  echo "Pinned Codex Linux repository key not found: $key_b64_file" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

if ! base64 --decode < "$key_b64_file" > "$tmp_dir/repository-key.gpg" 2>/dev/null; then
  base64 -D < "$key_b64_file" > "$tmp_dir/repository-key.gpg"
fi

key_sha256="$(sha256sum "$tmp_dir/repository-key.gpg" | awk '{print tolower($1)}')"
key_fingerprint="$(gpg --batch --show-keys --with-colons "$tmp_dir/repository-key.gpg" 2>/dev/null | awk -F: '$1 == "fpr" {print toupper($10); exit}')"
if [[ "$key_sha256" != "$expected_key_sha256" || "$key_fingerprint" != "$expected_key_fingerprint" ]]; then
  echo "Pinned Codex Linux repository key identity mismatch." >&2
  exit 1
fi

curl_args=(
  --fail
  --location
  --silent
  --show-error
  --retry 5
  --retry-delay 2
  --retry-max-time 300
  --connect-timeout 20
  --max-time 180
  --retry-all-errors
)

download() {
  local url="$1"
  local output="$2"
  curl "${curl_args[@]}" "$url" -o "$output"
}

verify_sha256() {
  local file="$1"
  local expected="$2"
  local label="$3"
  local actual expected_lower
  actual="$(sha256sum "$file" | awk '{print tolower($1)}')"
  expected_lower="$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')"
  if [[ "$actual" != "$expected_lower" ]]; then
    echo "$label SHA-256 mismatch: expected $expected, got $actual" >&2
    exit 1
  fi
}

inrelease_url="$deb_base_url/dists/stable/InRelease"
download "$inrelease_url" "$tmp_dir/InRelease"
gpgv --keyring "$tmp_dir/repository-key.gpg" --output "$tmp_dir/Release" "$tmp_dir/InRelease"

python3 - "$tmp_dir/Release" "$tmp_dir/deb-indexes.json" <<'PY'
import json
import re
import sys

release_path, output_path = sys.argv[1:]
text = open(release_path, encoding="utf-8").read()
match = re.search(r"(?ms)^SHA256:\n((?: [0-9a-f]{64} +[0-9]+ +\S+\n)+)", text)
if not match:
    raise SystemExit("Verified Debian Release metadata has no SHA256 section")

entries = {}
for line in match.group(1).splitlines():
    digest, size, path = line.split()
    entries[path] = {"sha256": digest, "size": int(size)}

required = [
    "main/binary-amd64/Packages.gz",
    "main/binary-arm64/Packages.gz",
]
missing = [path for path in required if path not in entries]
if missing:
    raise SystemExit(f"Verified Debian Release metadata is missing {missing}")
json.dump({path: entries[path] for path in required}, open(output_path, "w"), sort_keys=True)
PY

for arch in amd64 arm64; do
  index_path="main/binary-$arch/Packages.gz"
  index_file="$tmp_dir/Packages-$arch.gz"
  download "$deb_base_url/dists/stable/$index_path" "$index_file"
  expected_index_size="$(jq -r --arg path "$index_path" '.[$path].size' "$tmp_dir/deb-indexes.json")"
  actual_index_size="$(wc -c < "$index_file" | tr -d '[:space:]')"
  [[ "$actual_index_size" == "$expected_index_size" ]] || {
    echo "Debian $arch Packages.gz size mismatch: expected $expected_index_size, got $actual_index_size" >&2
    exit 1
  }
  verify_sha256 "$index_file" "$(jq -r --arg path "$index_path" '.[$path].sha256' "$tmp_dir/deb-indexes.json")" "Debian $arch Packages.gz"
  gzip -dc "$index_file" > "$tmp_dir/Packages-$arch"
done

for repo_arch in x86_64 aarch64; do
  if [[ "$repo_arch" == "x86_64" ]]; then
    repo_url="$rpm_x64_base_url"
  else
    repo_url="$rpm_arm64_base_url"
  fi
  download "$repo_url/repodata/repomd.xml" "$tmp_dir/repomd-$repo_arch.xml"
  download "$repo_url/repodata/repomd.xml.asc" "$tmp_dir/repomd-$repo_arch.xml.asc"
  gpgv --keyring "$tmp_dir/repository-key.gpg" "$tmp_dir/repomd-$repo_arch.xml.asc" "$tmp_dir/repomd-$repo_arch.xml"

  python3 - "$tmp_dir/repomd-$repo_arch.xml" "$tmp_dir/primary-$repo_arch.json" <<'PY'
import json
import sys
import xml.etree.ElementTree as ET

input_path, output_path = sys.argv[1:]
ns = {"repo": "http://linux.duke.edu/metadata/repo"}
root = ET.parse(input_path).getroot()
primary = next((item for item in root.findall("repo:data", ns) if item.attrib.get("type") == "primary"), None)
if primary is None:
    raise SystemExit("Verified RPM repomd.xml has no primary metadata")
location = primary.find("repo:location", ns)
checksum = primary.find("repo:checksum", ns)
size = primary.find("repo:size", ns)
if location is None or checksum is None or size is None or checksum.attrib.get("type") != "sha256":
    raise SystemExit("Verified RPM primary metadata entry is incomplete")
href = location.attrib.get("href", "")
if not href.startswith("repodata/") or not href.endswith("-primary.xml.gz") or ".." in href:
    raise SystemExit(f"Unsafe RPM primary metadata location: {href!r}")
payload = {"href": href, "sha256": checksum.text or "", "size": int(size.text or "0")}
json.dump(payload, open(output_path, "w"), sort_keys=True)
PY

  primary_href="$(jq -r '.href' "$tmp_dir/primary-$repo_arch.json")"
  download "$repo_url/$primary_href" "$tmp_dir/primary-$repo_arch.xml.gz"
  expected_primary_size="$(jq -r '.size' "$tmp_dir/primary-$repo_arch.json")"
  actual_primary_size="$(wc -c < "$tmp_dir/primary-$repo_arch.xml.gz" | tr -d '[:space:]')"
  [[ "$actual_primary_size" == "$expected_primary_size" ]] || {
    echo "RPM $repo_arch primary metadata size mismatch: expected $expected_primary_size, got $actual_primary_size" >&2
    exit 1
  }
  verify_sha256 "$tmp_dir/primary-$repo_arch.xml.gz" "$(jq -r '.sha256' "$tmp_dir/primary-$repo_arch.json")" "RPM $repo_arch primary metadata"
  gzip -dc "$tmp_dir/primary-$repo_arch.xml.gz" > "$tmp_dir/primary-$repo_arch.xml"
done

python3 - \
  "$tmp_dir/Packages-amd64" \
  "$tmp_dir/Packages-arm64" \
  "$tmp_dir/primary-x86_64.xml" \
  "$tmp_dir/primary-aarch64.xml" \
  "$expected_version" \
  "$tmp_dir/sources.json" <<'PY'
import json
import pathlib
import re
import sys
import xml.etree.ElementTree as ET
from urllib.parse import urljoin, urlsplit

deb_amd64_path, deb_arm64_path, rpm_x64_path, rpm_arm64_path, expected_version, output_path = sys.argv[1:]
host = "persistent.oaistatic.com"
deb_base = f"https://{host}/codex-app-prod/linux/deb/"
rpm_bases = {
    "x86_64": f"https://{host}/codex-app-prod/linux/rpm/x86_64/",
    "aarch64": f"https://{host}/codex-app-prod/linux/rpm/aarch64/",
}


def safe_relative_path(value, suffix, prefix=None):
    path = pathlib.PurePosixPath(value)
    if not value or value.startswith("/") or ".." in path.parts or not value.endswith(suffix):
        raise SystemExit(f"Unsafe repository package path: {value!r}")
    if prefix and not value.startswith(prefix):
        raise SystemExit(f"Unexpected repository package path: {value!r}")
    return value


def parse_debian(path, architecture):
    paragraphs = pathlib.Path(path).read_text(encoding="utf-8").strip().split("\n\n")
    packages = []
    for paragraph in paragraphs:
        fields = {}
        current = None
        for line in paragraph.splitlines():
            if line.startswith((" ", "\t")) and current:
                fields[current] += "\n" + line
                continue
            key, separator, value = line.partition(":")
            if not separator:
                raise SystemExit(f"Invalid Debian Packages line: {line!r}")
            current = key
            fields[key] = value.strip()
        if fields.get("Package") == "chatgpt" and fields.get("Architecture") == architecture:
            packages.append(fields)
    if len(packages) != 1:
        raise SystemExit(f"Expected one chatgpt {architecture} Debian package, got {len(packages)}")
    package = packages[0]
    if package.get("Version") != expected_version:
        raise SystemExit(
            f"Debian {architecture} version drift: expected {expected_version}, got {package.get('Version')}"
        )
    filename = safe_relative_path(package.get("Filename", ""), ".deb", "pool/main/c/chatgpt/")
    sha256 = package.get("SHA256", "").lower()
    if not re.fullmatch(r"[0-9a-f]{64}", sha256):
        raise SystemExit(f"Debian {architecture} package has invalid SHA-256")
    size = int(package.get("Size", "0"))
    if size <= 0:
        raise SystemExit(f"Debian {architecture} package has invalid size")
    return {
        "format": "deb",
        "packageName": "chatgpt",
        "version": expected_version,
        "packageArchitecture": architecture,
        "url": urljoin(deb_base, filename),
        "sourcePath": filename,
        "sourceBasename": pathlib.PurePosixPath(filename).name,
        "mirrorBasename": pathlib.PurePosixPath(filename).name,
        "contentLength": size,
        "sha256": sha256,
    }


def parse_rpm(path, architecture):
    ns = {"common": "http://linux.duke.edu/metadata/common"}
    root = ET.parse(path).getroot()
    packages = [
        item
        for item in root.findall("common:package", ns)
        if item.findtext("common:name", default="", namespaces=ns) == "chatgpt"
        and item.findtext("common:arch", default="", namespaces=ns) == architecture
    ]
    if len(packages) != 1:
        raise SystemExit(f"Expected one chatgpt {architecture} RPM package, got {len(packages)}")
    package = packages[0]
    version_node = package.find("common:version", ns)
    checksum_node = package.find("common:checksum", ns)
    size_node = package.find("common:size", ns)
    location_node = package.find("common:location", ns)
    if None in (version_node, checksum_node, size_node, location_node):
        raise SystemExit(f"RPM {architecture} package metadata is incomplete")
    version = version_node.attrib.get("ver", "")
    release = version_node.attrib.get("rel", "")
    if version != expected_version or release != "1":
        raise SystemExit(
            f"RPM {architecture} version drift: expected {expected_version}-1, got {version}-{release}"
        )
    if checksum_node.attrib.get("type") != "sha256":
        raise SystemExit(f"RPM {architecture} package checksum is not SHA-256")
    sha256 = (checksum_node.text or "").lower()
    if not re.fullmatch(r"[0-9a-f]{64}", sha256):
        raise SystemExit(f"RPM {architecture} package has invalid SHA-256")
    location = safe_relative_path(location_node.attrib.get("href", ""), ".rpm")
    size = int(size_node.attrib.get("package", "0"))
    if size <= 0:
        raise SystemExit(f"RPM {architecture} package has invalid size")
    return {
        "format": "rpm",
        "packageName": "chatgpt",
        "version": version,
        "release": release,
        "packageArchitecture": architecture,
        "url": urljoin(rpm_bases[architecture], location),
        "sourcePath": location,
        "sourceBasename": pathlib.PurePosixPath(location).name,
        "mirrorBasename": pathlib.PurePosixPath(location).name,
        "contentLength": size,
        "sha256": sha256,
    }


sources = {
    "product": "ChatGPT desktop app with Codex",
    "packageName": "chatgpt",
    "version": expected_version,
    "supportedDistributions": ["Ubuntu 24.04 LTS", "Ubuntu 26.04 LTS", "Debian 13", "Fedora 43", "Fedora 44"],
    "architectures": {
        "x64": {
            "deb": parse_debian(deb_amd64_path, "amd64"),
            "rpm": parse_rpm(rpm_x64_path, "x86_64"),
        },
        "arm64": {
            "deb": parse_debian(deb_arm64_path, "arm64"),
            "rpm": parse_rpm(rpm_arm64_path, "aarch64"),
        },
    },
}

for architecture in sources["architectures"].values():
    for package in architecture.values():
        parts = urlsplit(package["url"])
        if parts.scheme != "https" or parts.netloc != host or parts.query or parts.fragment:
            raise SystemExit(f"Package URL is outside the official repository: {package['url']!r}")

pathlib.Path(output_path).write_text(json.dumps(sources, sort_keys=True), encoding="utf-8")
PY

generated_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
jq -n \
  --arg generatedAt "$generated_at" \
  --arg expectedVersion "$expected_version" \
  --arg keyFingerprint "$expected_key_fingerprint" \
  --arg keySha256 "$expected_key_sha256" \
  --arg inReleaseUrl "$inrelease_url" \
  --arg inReleaseSha256 "$(sha256sum "$tmp_dir/InRelease" | awk '{print tolower($1)}')" \
  --arg rpmX64RepomdUrl "$rpm_x64_base_url/repodata/repomd.xml" \
  --arg rpmX64RepomdSha256 "$(sha256sum "$tmp_dir/repomd-x86_64.xml" | awk '{print tolower($1)}')" \
  --arg rpmArm64RepomdUrl "$rpm_arm64_base_url/repodata/repomd.xml" \
  --arg rpmArm64RepomdSha256 "$(sha256sum "$tmp_dir/repomd-aarch64.xml" | awk '{print tolower($1)}')" \
  --slurpfile linux "$tmp_dir/sources.json" '
  {
    schemaVersion: 6,
    channel: "linux-preview",
    generatedAt: $generatedAt,
    preview: {
      contract: "linux-preview-v1",
      expectedVersion: $expectedVersion,
      officialAnnouncement: "https://x.com/OpenAI/status/2087248033906094175",
      officialLandingPage: "https://openai.com/codex/",
      repositorySigningKey: {
        fingerprint: $keyFingerprint,
        sha256: $keySha256
      }
    },
    publication: {
      githubPrereleaseOnly: true,
      githubLatestAdvanced: false,
      objectStoragePublished: false,
      sharedLatestAdvanced: false
    },
    derived: {
      prerelease: true,
      publishLatest: false,
      syncLatest: false
    },
    repositories: {
      deb: {
        inReleaseUrl: $inReleaseUrl,
        inReleaseSha256: $inReleaseSha256,
        signatureVerified: true
      },
      rpm: {
        x64: {
          repomdUrl: $rpmX64RepomdUrl,
          repomdSha256: $rpmX64RepomdSha256,
          signatureVerified: true
        },
        arm64: {
          repomdUrl: $rpmArm64RepomdUrl,
          repomdSha256: $rpmArm64RepomdSha256,
          signatureVerified: true
        }
      }
    },
    sources: {linux: $linux[0]}
  }
  ' > "$manifest_path"

jq -e --arg version "$expected_version" --arg fingerprint "$expected_key_fingerprint" '
  .schemaVersion == 6
  and .channel == "linux-preview"
  and .preview.contract == "linux-preview-v1"
  and .preview.expectedVersion == $version
  and .preview.repositorySigningKey.fingerprint == $fingerprint
  and .publication.githubPrereleaseOnly == true
  and .publication.objectStoragePublished == false
  and .publication.githubLatestAdvanced == false
  and .publication.sharedLatestAdvanced == false
  and .repositories.deb.signatureVerified == true
  and .repositories.rpm.x64.signatureVerified == true
  and .repositories.rpm.arm64.signatureVerified == true
  and ([.sources.linux.architectures[][] | .version] | unique == [$version])
  and ([.sources.linux.architectures[][] | .sha256 | test("^[0-9a-f]{64}$")] | all)
  and ([.sources.linux.architectures[][] | .contentLength > 0] | all)
  ' "$manifest_path" >/dev/null

jq '{channel, preview, publication, repositories, linux: .sources.linux}' "$manifest_path"
