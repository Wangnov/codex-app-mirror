#!/usr/bin/env python3
import os
import re
import sys


BACKEND_VERSION_PATTERNS = (
    re.compile(rb"\bcodex-cli ([0-9]+(?:\.[0-9A-Za-z][0-9A-Za-z._+-]*)*)\b"),
    re.compile(rb"\b([0-9]+\.[0-9]+\.[0-9][0-9A-Za-z._+-]*)https://chatgpt\.com/backend-api/"),
)


def die(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def iter_paths(root):
    if os.path.isfile(root):
        yield root
        return

    if not os.path.isdir(root):
        return

    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for filename in sorted(filenames):
            yield os.path.join(dirpath, filename)


def backend_version_from_file(path):
    overlap = b""
    try:
        with open(path, "rb") as handle:
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    return ""

                data = overlap + chunk
                for pattern in BACKEND_VERSION_PATTERNS:
                    match = pattern.search(data)
                    if match:
                        return match.group(1).decode("ascii")

                overlap = data[-128:]
    except OSError:
        return ""


def read_backend_version(root):
    for path in iter_paths(root):
        version = backend_version_from_file(path)
        if version:
            return version
    return ""


def main(argv):
    if len(argv) != 2:
        die("Usage: read-codex-backend-version.py <file-or-directory>")

    version = read_backend_version(argv[1])
    if version:
        print(version)
        return

    die("Could not find Codex backend version.")


if __name__ == "__main__":
    main(sys.argv)
