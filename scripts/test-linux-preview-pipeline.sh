#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/artifacts" "$tmp_dir/sources"
artifacts="$tmp_dir/artifacts"
sources="$tmp_dir/sources"
key_b64="$(tr -d '\r\n' < "$repo_root/scripts/codex-linux-repository-key.b64")"

printf 'deb-x64' > "$sources/chatgpt_26.803.81509_amd64.deb"
printf 'deb-arm64' > "$sources/chatgpt_26.803.81509_arm64.deb"
printf 'rpm-x64' > "$sources/chatgpt-26.803.81509-1.x86_64.rpm"
printf 'rpm-arm64' > "$sources/chatgpt-26.803.81509-1.aarch64.rpm"

deb_x64_sha="$(sha256sum "$sources/chatgpt_26.803.81509_amd64.deb" | awk '{print $1}')"
deb_arm_sha="$(sha256sum "$sources/chatgpt_26.803.81509_arm64.deb" | awk '{print $1}')"
rpm_x64_sha="$(sha256sum "$sources/chatgpt-26.803.81509-1.x86_64.rpm" | awk '{print $1}')"
rpm_arm_sha="$(sha256sum "$sources/chatgpt-26.803.81509-1.aarch64.rpm" | awk '{print $1}')"
deb_x64_size="$(wc -c < "$sources/chatgpt_26.803.81509_amd64.deb" | tr -d '[:space:]')"
deb_arm_size="$(wc -c < "$sources/chatgpt_26.803.81509_arm64.deb" | tr -d '[:space:]')"
rpm_x64_size="$(wc -c < "$sources/chatgpt-26.803.81509-1.x86_64.rpm" | tr -d '[:space:]')"
rpm_arm_size="$(wc -c < "$sources/chatgpt-26.803.81509-1.aarch64.rpm" | tr -d '[:space:]')"

cat > "$tmp_dir/probe-manifest.json" <<JSON
{
  "schemaVersion": 6,
  "channel": "linux-preview",
  "preview": {
    "contract": "linux-preview-v1",
    "expectedVersion": "26.803.81509",
    "repositorySigningKey": {
      "fingerprint": "3BFA0E4AE8B8CC16A2D9BA684A3B4A566C4660E4",
      "sha256": "23e2cfbdef6afe95505f9e95a2cb63585da7ffe9b06a51ec08a32407c847d596"
    }
  },
  "publication": {
    "githubPrereleaseOnly": true,
    "githubLatestAdvanced": false,
    "objectStoragePublished": false,
    "sharedLatestAdvanced": false
  },
  "derived": {"prerelease": true, "publishLatest": false, "syncLatest": false},
  "sources": {
    "linux": {
      "product": "ChatGPT desktop app with Codex",
      "packageName": "chatgpt",
      "version": "26.803.81509",
      "architectures": {
        "x64": {
          "deb": {"format":"deb","url":"https://persistent.oaistatic.com/codex-app-prod/linux/deb/pool/main/c/chatgpt/chatgpt_26.803.81509_amd64.deb","sourceBasename":"chatgpt_26.803.81509_amd64.deb","mirrorBasename":"chatgpt_26.803.81509_amd64.deb","contentLength":$deb_x64_size,"sha256":"$deb_x64_sha","packageArchitecture":"amd64","version":"26.803.81509"},
          "rpm": {"format":"rpm","url":"https://persistent.oaistatic.com/codex-app-prod/linux/rpm/x86_64/chatgpt-26.803.81509-1.x86_64.rpm","sourceBasename":"chatgpt-26.803.81509-1.x86_64.rpm","mirrorBasename":"chatgpt-26.803.81509-1.x86_64.rpm","contentLength":$rpm_x64_size,"sha256":"$rpm_x64_sha","packageArchitecture":"x86_64","version":"26.803.81509"}
        },
        "arm64": {
          "deb": {"format":"deb","url":"https://persistent.oaistatic.com/codex-app-prod/linux/deb/pool/main/c/chatgpt/chatgpt_26.803.81509_arm64.deb","sourceBasename":"chatgpt_26.803.81509_arm64.deb","mirrorBasename":"chatgpt_26.803.81509_arm64.deb","contentLength":$deb_arm_size,"sha256":"$deb_arm_sha","packageArchitecture":"arm64","version":"26.803.81509"},
          "rpm": {"format":"rpm","url":"https://persistent.oaistatic.com/codex-app-prod/linux/rpm/aarch64/chatgpt-26.803.81509-1.aarch64.rpm","sourceBasename":"chatgpt-26.803.81509-1.aarch64.rpm","mirrorBasename":"chatgpt-26.803.81509-1.aarch64.rpm","contentLength":$rpm_arm_size,"sha256":"$rpm_arm_sha","packageArchitecture":"aarch64","version":"26.803.81509"}
        }
      }
    }
  }
}
JSON

cat > "$tmp_dir/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
url=""
output=""
while (($#)); do
  case "$1" in
    -o|--output)
      output="$2"
      shift 2
      ;;
    --retry|--retry-delay|--retry-max-time|--connect-timeout)
      shift 2
      ;;
    --*)
      shift
      ;;
    https://*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "$url" && -n "$output" ]] || { echo "mock curl could not parse package request" >&2; exit 1; }
cp "${FIXTURE_SOURCES:?}/${url##*/}" "$output"
SH
chmod +x "$tmp_dir/bin/curl"

env \
  PATH="$tmp_dir/bin:$PATH" \
  FIXTURE_SOURCES="$sources" \
  bash "$repo_root/scripts/download-linux-preview.sh" \
    "$artifacts" \
    "$tmp_dir/probe-manifest.json" > "$tmp_dir/download.log"
test "$(wc -l < "$artifacts/SHA256SUMS-linux.txt" | tr -d '[:space:]')" = 4

cat > "$tmp_dir/bin/dpkg-deb" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  -f)
    file="$2"
    field="$3"
    arch=arm64
    [[ "$file" == *_amd64.deb ]] && arch=amd64
    case "$field" in
      Package) printf 'chatgpt\n' ;;
      Version) printf '26.803.81509\n' ;;
      Architecture) printf '%s\n' "$arch" ;;
      Maintainer) printf 'OpenAI <support@openai.com>\n' ;;
      Homepage) printf 'https://developers.openai.com/codex/app\n' ;;
      *) exit 1 ;;
    esac
    ;;
  --contents)
    printf '%s\n' \
      'lrwxrwxrwx root/root 0 2026-08-10 23:37 ./usr/bin/chatgpt -> ../lib/chatgpt/codex-launcher' \
      '-rwxr-xr-x root/root 63 2026-08-10 23:37 ./usr/lib/chatgpt/codex-launcher'
    for ((i = 0; i < 10000; i++)); do
      printf -- '-rw-r--r-- root/root 1 2026-08-10 23:37 ./usr/lib/chatgpt/fixture-%05d\n' "$i"
    done
    ;;
  --control)
    mkdir -p "$3"
    printf "SIGNING_KEY_BASE64='%s'\n" "${FIXTURE_KEY_B64:?}" > "$3/postinst"
    ;;
  *)
    echo "unexpected dpkg-deb mock command: $*" >&2
    exit 1
    ;;
esac
SH

cat > "$tmp_dir/bin/rpm" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *'--initdb'* ]]; then
  exit 0
fi
if [[ "$1" == '-qp' && "$2" == '--queryformat' ]]; then
  file="${@: -1}"
  arch=aarch64
  [[ "$file" == *.x86_64.rpm ]] && arch=x86_64
  printf 'chatgpt\t26.803.81509\t1\t%s\thttps://developers.openai.com/codex/app\tChatGPT by OpenAI\topenai.com\tRSA/SHA512, fixture, Key ID 4a3b4a566c4660e4' "$arch"
elif [[ "$1" == '-qpl' ]]; then
  printf '%s\n' '/usr/bin/chatgpt' '/usr/lib/chatgpt/codex-launcher'
  for ((i = 0; i < 10000; i++)); do
    printf '/usr/lib/chatgpt/fixture-%05d\n' "$i"
  done
elif [[ "$1" == '-qp' && "$2" == '--scripts' ]]; then
  printf "SIGNING_KEY_BASE64='%s'\n" "${FIXTURE_KEY_B64:?}"
else
  echo "unexpected rpm mock command: $*" >&2
  exit 1
fi
SH

cat > "$tmp_dir/bin/rpmkeys" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *'--import'* ]]; then
  exit 0
fi
if [[ "$*" == *'--checksig'* ]]; then
  printf '%s: digests signatures OK\n' "${@: -1}"
  exit 0
fi
echo "unexpected rpmkeys mock command: $*" >&2
exit 1
SH
chmod +x "$tmp_dir/bin/dpkg-deb" "$tmp_dir/bin/rpm" "$tmp_dir/bin/rpmkeys"

env \
  PATH="$tmp_dir/bin:$PATH" \
  FIXTURE_KEY_B64="$key_b64" \
  bash "$repo_root/scripts/verify-linux-preview.sh" \
    "$tmp_dir/probe-manifest.json" \
    "$artifacts" \
    "$artifacts/linux-identity.json" > "$tmp_dir/verify.log"

jq -e '
  .channel == "linux-preview"
  and .versionsMatch == true
  and ([.packages[][]] | length == 4)
  and .packages.x64.deb.packageArchitecture == "amd64"
  and .packages.arm64.rpm.packageArchitecture == "aarch64"
  and .packages.x64.rpm.packageSignatureVerified == true
  and .packages.arm64.rpm.packageSignatureVerified == true
  ' "$artifacts/linux-identity.json" >/dev/null

(
  cd "$tmp_dir"
  bash "$repo_root/scripts/finalize-linux-preview.sh" \
    probe-manifest.json \
    artifacts/linux-identity.json \
    artifacts \
    26.803.81509 \
    codex-app-linux-preview-26.803.81509 > finalize.log
)

jq -e '
  .channel == "linux-preview"
  and .release.tag == "codex-app-linux-preview-26.803.81509"
  and .release.destination == "github-prerelease"
  and ([.sources.linux.architectures[][] | .verified == true] | all)
  ' "$tmp_dir/probe-manifest.json" >/dev/null
test "$(wc -l < "$tmp_dir/SHA256SUMS.txt" | tr -d '[:space:]')" = 7
grep -Fq '不会推进 GitHub Latest' "$tmp_dir/release-notes.md"
grep -Fq '官方安装包会配置 OpenAI 自己的 APT/RPM 更新仓库' "$tmp_dir/release-notes.md"

cp "$artifacts/linux-identity.json" "$tmp_dir/drifted-identity.json"
jq '.packages.arm64.rpm.packageArchitecture = "x86_64"' "$tmp_dir/drifted-identity.json" > "$tmp_dir/drifted.next.json"
mv "$tmp_dir/drifted.next.json" "$tmp_dir/drifted-identity.json"
set +e
drift_output="$(cd "$tmp_dir" && bash "$repo_root/scripts/finalize-linux-preview.sh" probe-manifest.json drifted-identity.json artifacts 26.803.81509 codex-app-linux-preview-26.803.81509 2>&1)"
drift_status=$?
set -e
if [[ "$drift_status" -eq 0 ]] || ! grep -Fq 'identity differs' <<< "$drift_output"; then
  echo "Expected verified package identity drift to fail closed." >&2
  printf '%s\n' "$drift_output" >&2
  exit 1
fi

echo "Linux Preview identity and finalization fixture PASS"
