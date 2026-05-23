#!/usr/bin/env bash
set -euo pipefail

tag="${1:-}"

if [[ -z "$tag" ]]; then
  echo "Usage: $0 <release-tag>" >&2
  exit 2
fi

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

body_path="$tmp_dir/body.md"
updated_path="$tmp_dir/body-with-banner.md"

gh release view "$tag" --json body --jq '.body' > "$body_path"

python3 - "$body_path" "$updated_path" <<'PY'
import re
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])

banner = """<!-- release-banner:start -->
![Codex App Mirror](https://github.com/Wangnov/codex-app-mirror/releases/latest/download/status.png)
<!-- release-banner:end -->
"""

body = source.read_text(encoding="utf-8")
body = re.sub(
    r"\A\s*<!-- release-banner:start -->.*?<!-- release-banner:end -->\s*",
    "",
    body,
    flags=re.DOTALL,
)

updated = banner + "\n" + body.lstrip()
target.write_text(updated.rstrip() + "\n", encoding="utf-8")
PY

if cmp -s "$body_path" "$updated_path"; then
  echo "Release banner already current in $tag."
  exit 0
fi

gh release edit "$tag" --notes-file "$updated_path"
echo "Added release banner to $tag."
